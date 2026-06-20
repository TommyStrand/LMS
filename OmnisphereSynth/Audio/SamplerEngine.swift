import AVFoundation

/// Plays back synthesised WAV samples with per-note pitch shifting.
///
/// Architecture mirrors DrumEngine: samples are loaded as AVAudioPCMBuffers by
/// scanning the app bundle, then played via a round-robin pool of
/// AVAudioPlayerNode → AVAudioUnitVarispeed pairs.  Varispeed shifts pitch by
/// changing playback rate (2^(semitones/12)), exactly as a hardware sampler does.
///
/// Connect outputNode to the audio graph; call attach(to:) before load().
final class SamplerEngine {

    // MARK: - Graph

    /// Connect this node to the rest of the audio graph (e.g. voiceMixer).
    let outputNode = AVAudioMixerNode()

    // MARK: - Private state

    private let instrument: SamplerInstrument

    private struct VoiceSlot {
        let player:    AVAudioPlayerNode
        let varispeed: AVAudioUnitVarispeed
    }
    private var pool: [VoiceSlot] = []
    private var poolCursor = 0
    private let poolSize   = 12
    private var lastStealLog: TimeInterval = 0   // throttles voice-steal logging

    // Looping-voice bookkeeping (main-thread only). slotNote maps a pool index to
    // the MIDI note currently sustaining on it so noteOff can release that slot;
    // slotToken is a per-slot generation counter so an in-flight volume ramp can
    // tell when a newer note-on/note-off has superseded it and bail out.
    private var slotNote:  [Int: Int] = [:]
    private var slotToken: [Int: Int] = [:]

    // rootNote → velocityMidiValue → buffer
    private var buffers: [Int: [Int: AVAudioPCMBuffer]] = [:]

    // MARK: - Init

    init(instrument: SamplerInstrument) {
        self.instrument = instrument
    }

    // MARK: - Setup

    /// Attach all nodes to `engine` and wire them into outputNode.
    /// Call before engine.start() so connections are stable at launch.
    func attach(to engine: AVAudioEngine) {
        engine.attach(outputNode)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for _ in 0..<poolSize {
            let player    = AVAudioPlayerNode()
            let varispeed = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(varispeed)
            engine.connect(player,    to: varispeed,  format: fmt)
            engine.connect(varispeed, to: outputNode, format: fmt)
            pool.append(VoiceSlot(player: player, varispeed: varispeed))
        }
    }

    // MARK: - Sample loading

    /// Scans the bundle tree for WAV files and loads matching samples into memory.
    /// Uses FileManager enumeration (same technique as DrumEngine) which works
    /// reliably with Xcode folder references, unlike Bundle.url(forResource:subdirectory:).
    func load() {
        // Key by "<folder>/<filename>" — NOT the bare filename. All three sampler
        // instruments name their files identically (e.g. grand_piano/60_64.wav,
        // string_ensemble/60_64.wav, concert_flute/60_64.wav). Keying on the bare
        // filename let the last-enumerated folder overwrite the others, so every
        // instrument ended up playing whichever folder won the collision (flute,
        // in practice) for any note present in more than one folder. Including the
        // parent folder makes each sample unique. Relies on the Samples directory
        // being added to Xcode as a folder reference (structure preserved in bundle).
        var wavMap: [String: URL] = [:]
        if let en = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in en where url.pathExtension.lowercased() == "wav" {
                let folder = url.deletingLastPathComponent().lastPathComponent
                let name   = url.deletingPathExtension().lastPathComponent
                wavMap["\(folder)/\(name)"] = url
            }
        }

        var loaded = 0
        for layer in instrument.velocityLayers {
            for root in instrument.rootNotes {
                let key = "\(instrument.id)/\(root)_\(layer.midiValue)"
                guard let url  = wavMap[key],
                      let file = try? AVAudioFile(forReading: url),
                      let mono = AVAudioPCMBuffer(
                          pcmFormat: file.processingFormat,
                          frameCapacity: AVAudioFrameCount(file.length)
                      ),
                      (try? file.read(into: mono)) != nil,
                      // Player nodes are connected with stereo format; scheduleBuffer
                      // requires the buffer channel count to match exactly.
                      let buf  = makeStereo(mono)
                else { continue }
                // Identity guard: the resolved file MUST live in this instrument's
                // folder. This is the invariant the old bare-filename lookup violated
                // silently (loading flute samples for piano/strings). Cheap to check,
                // and it turns that whole class of bug into an immediate debug crash.
                assert(url.deletingLastPathComponent().lastPathComponent == instrument.id,
                       "SamplerEngine[\(instrument.id)] resolved \(key) to \(url.path) — wrong folder")
                // One-shots get zero-crossing edge fades to declick note-on and
                // slot recycling. Looping buffers must NOT — an edge fade would
                // dip to silence at every loop wrap; they rely on their seamless
                // crossfade (generator) and the engine's note-on/off volume ramps.
                if !instrument.loops { applyEdgeFades(buf) }
                buffers[root, default: [:]][layer.midiValue] = buf
                loaded += 1
            }
        }
        let expected = instrument.rootNotes.count * instrument.velocityLayers.count
        let summary = "SamplerEngine[\(instrument.id)]: \(loaded)/\(expected) samples loaded"
        print(summary)
        Diagnostics.shared.log(summary)
        // Catch missing/corrupt samples at launch in debug builds rather than as a
        // silent gap heard later. Allows 0 (bundle not present in some test contexts).
        assert(loaded == expected || loaded == 0,
               "SamplerEngine[\(instrument.id)] loaded \(loaded)/\(expected) samples")
    }

    // MARK: - Playback

    func noteOn(_ note: UInt8, velocity: UInt8) {
        let midi = Int(note)
        let vel  = Int(velocity)
        guard let (root, buf) = findBuffer(midi: midi, vel: vel) else { return }

        let idx  = nextSlotIndex()
        let slot = pool[idx]
        if slot.player.isPlaying { slot.player.stop() }

        // Bump the slot's generation so any ramp still scheduled on it stops.
        let token = (slotToken[idx] ?? 0) + 1
        slotToken[idx] = token

        // Rate = 2^(semitones/12), clamped to AVAudioUnitVarispeed valid range [0.25, 4.0].
        let rate = Float(pow(2.0, Double(midi - root) / 12.0))
        slot.varispeed.rate = max(0.25, min(4.0, rate))

        let target = max(0.3, Float(vel) / 127.0)
        let options: AVAudioPlayerNodeBufferOptions = instrument.loops ? [.loops] : []

        if instrument.loops {
            // Sustain by looping; ramp volume up so the (non-zero-crossing) loop
            // start doesn't click, and remember the note so noteOff can release it.
            slotNote[idx]      = midi
            slot.player.volume = 0
            slot.player.scheduleBuffer(buf, at: nil, options: options)
            slot.player.play()
            rampVolume(idx: idx, token: token, to: target, duration: instrument.attack)
        } else {
            // One-shot: play once at full level and let the tail ring out.
            slotNote.removeValue(forKey: idx)
            slot.player.volume = target
            slot.player.scheduleBuffer(buf, at: nil, options: options)
            slot.player.play()
        }
    }

    func noteOff(_ note: UInt8) {
        // One-shots carry their own decay tail — let them ring out.
        guard instrument.loops else { return }
        let midi = Int(note)
        // Collect first — releasing mutates slotNote, which can't be done while
        // iterating it.
        let indices = slotNote.compactMap { $0.value == midi ? $0.key : nil }
        for idx in indices {
            let token = (slotToken[idx] ?? 0) + 1
            slotToken[idx] = token
            slotNote.removeValue(forKey: idx)
            let player = pool[idx].player
            // Fade the looping note out, then stop it (unless a newer note-on has
            // already claimed the slot, in which case the token guard skips stop).
            rampVolume(idx: idx, token: token, to: 0, duration: instrument.release) { [weak self] in
                guard let self = self, self.slotToken[idx] == token else { return }
                player.stop()
            }
        }
    }

    /// Number of pool slots currently producing audio — surfaced for diagnostics.
    var activeVoiceCount: Int {
        pool.reduce(0) { $0 + ($1.player.isPlaying ? 1 : 0) }
    }

    // MARK: - Helpers

    /// Ramps the first and last few milliseconds of every channel to zero so the
    /// buffer always begins and ends on a zero crossing. Without this, samples
    /// whose first/last frame is non-zero produce an audible click on note-on and
    /// when a slot is recycled mid-tail.
    private func applyEdgeFades(_ buf: AVAudioPCMBuffer, ms: Double = 5) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let f = min(n / 2, Int(ms / 1000.0 * buf.format.sampleRate))
        guard f > 0 else { return }
        for c in 0..<Int(buf.format.channelCount) {
            let data = ch[c]
            for i in 0..<f {
                let g = Float(i) / Float(f)
                data[i]         *= g
                data[n - 1 - i] *= g
            }
        }
    }

    private func nextSlotIndex() -> Int {
        // Prefer an idle slot to avoid cutting release tails on busy pools.
        if let idle = pool.firstIndex(where: { !$0.player.isPlaying }) { return idle }
        // All slots busy — steal round-robin. Stealing truncates a still-ringing
        // note and can click, so surface it (throttled) as a likely culprit when
        // troubleshooting audio artefacts during dense playing.
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastStealLog > 0.5 {
            lastStealLog = now
            Diagnostics.shared.log("Sampler[\(instrument.id)] stealing voices — pool full (\(poolSize))")
        }
        let idx = poolCursor % poolSize
        poolCursor += 1
        return idx
    }

    /// Linearly ramps a slot's player volume to `target` over `duration`, stepping
    /// on the main run loop. Each step checks `slotToken[idx]` so a ramp that has
    /// been superseded by a newer note-on/note-off on the same slot stops cleanly.
    /// Runs entirely at control rate (never on the audio render thread).
    private func rampVolume(idx: Int, token: Int, to target: Float,
                            duration: TimeInterval, completion: (() -> Void)? = nil) {
        let player  = pool[idx].player
        let stepDur = 0.008
        let steps   = max(1, Int(duration / stepDur))
        let start   = player.volume
        func step(_ k: Int) {
            guard slotToken[idx] == token else { return }   // superseded
            player.volume = start + (target - start) * Float(k) / Float(steps)
            if k >= steps { completion?(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDur) { step(k + 1) }
        }
        step(0)
    }

    /// Duplicates a mono buffer into a non-interleaved stereo buffer.
    /// AVAudioPlayerNode requires buffer.format.channelCount == node output channelCount,
    /// so we must promote our synthesised mono WAVs to stereo before scheduling.
    /// Done manually to avoid the AVAudioConverter mono→stereo failure mode noted in DrumEngine.
    private func makeStereo(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard src.format.channelCount == 1,
              let srcData = src.floatChannelData?[0]
        else { return src }  // already stereo or non-float — return as-is

        guard let stereoFmt = AVAudioFormat(
            commonFormat:  .pcmFormatFloat32,
            sampleRate:    src.format.sampleRate,
            channels:      2,
            interleaved:   false
        ),
              let dst = AVAudioPCMBuffer(pcmFormat: stereoFmt,
                                         frameCapacity: src.frameLength)
        else { return nil }

        dst.frameLength = src.frameLength
        let n = Int(src.frameLength)
        dst.floatChannelData![0].update(from: srcData, count: n)  // L = source
        dst.floatChannelData![1].update(from: srcData, count: n)  // R = source
        return dst
    }

    private func findBuffer(midi: Int, vel: Int) -> (rootNote: Int, buf: AVAudioPCMBuffer)? {
        guard let velMidi = SamplerSelection.velocityMidiValue(
                for: vel, layers: instrument.velocityLayers) else { return nil }

        let roots = buffers.keys.filter { buffers[$0]?[velMidi] != nil }
        guard let root = SamplerSelection.nearestRoot(
                to: midi, available: Array(roots)) else { return nil }

        return (root, buffers[root]![velMidi]!)
    }
}

// MARK: - Pure selection logic (no AVFoundation — unit-tested in SuperNovaPadTests)

/// The note/velocity → sample selection rules, factored out of `SamplerEngine`
/// so they can be tested without loading any audio. Keeping them pure also makes
/// the tie-breaking deterministic, which the old `Dictionary.keys` ordering was not.
enum SamplerSelection {

    /// The recorded velocity layer (its file-suffix `midiValue`) that covers a
    /// given MIDI velocity. Falls back to the last layer if none matches.
    static func velocityMidiValue(for vel: Int,
                                  layers: [SamplerInstrument.VelocityLayer]) -> Int? {
        let layer = layers.first { vel >= $0.loVel && vel <= $0.hiVel } ?? layers.last
        return layer?.midiValue
    }

    /// The available root note closest to `midi`. Ties resolve to the LOWER root
    /// so the result is deterministic regardless of input ordering.
    static func nearestRoot(to midi: Int, available roots: [Int]) -> Int? {
        guard !roots.isEmpty else { return nil }
        return roots.min { a, b in
            let da = abs(a - midi), db = abs(b - midi)
            return da != db ? da < db : a < b
        }
    }
}
