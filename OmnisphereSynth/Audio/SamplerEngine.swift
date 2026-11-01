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
    // Every sounding slot's played note + the root sample it was pitched from, so a
    // glide can re-tune it (bend). Main-thread only.
    private var slotPitch: [Int: (midi: Int, root: Int)] = [:]
    // One-shot slots: when their buffer will have finished (seconds, uptime clock).
    // AVAudioPlayerNode.isPlaying stays TRUE after a non-looping buffer ends (only
    // stop() clears it), so without this every slot looked busy forever after the
    // first 12 notes and every new note stole a slot — often one still ringing.
    private var slotBusyUntil: [Int: TimeInterval] = [:]

    /// Identifies one note-on, so the caller can bend exactly that note later. A
    /// stale handle (its slot since reused by another note) is ignored by `bend`.
    struct Handle: Equatable { let slot: Int; let token: Int }

    // rootNote → velocityMidiValue → buffer
    private var buffers: [Int: [Int: AVAudioPCMBuffer]] = [:]
    // Sustain-loop instruments (organ, real strings/flute): each recording split
    // into its attack (`head`, played once) and a seamless sustain loop (`body`).
    private var sustainParts: [Int: [Int: (head: AVAudioPCMBuffer, body: AVAudioPCMBuffer)]] = [:]

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

    /// Decoded sample set, built off the main thread and installed on it.
    private struct Decoded {
        var buffers: [Int: [Int: AVAudioPCMBuffer]] = [:]
        var parts:   [Int: [Int: (head: AVAudioPCMBuffer, body: AVAudioPCMBuffer)]] = [:]
        var loaded = 0, expected = 0, sustainLooped = 0
    }

    /// Loads the instrument's samples. Reading, stereo conversion and sustain-loop
    /// analysis run on a background queue (they used to block the main thread —
    /// a hitch the first time a sampler preset was played); the result is installed
    /// on the main thread, where `buffers` / `sustainParts` are read. Notes played
    /// before it lands are skipped, which is why AudioEngine starts loading as
    /// soon as a sampler preset is SELECTED rather than on its first note.
    func load() {
        let instrument = self.instrument
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = SamplerEngine.decode(instrument)
            DispatchQueue.main.async { self?.install(decoded) }
        }
    }

    private func install(_ d: Decoded) {
        buffers      = d.buffers
        sustainParts = d.parts
        let summary = "SamplerEngine[\(instrument.id)]: \(d.loaded)/\(d.expected) samples loaded"
            + (instrument.sustainLoop && !instrument.loops ? ", \(d.sustainLooped) with a sustain loop" : "")
        print(summary)
        Diagnostics.shared.log(summary)
        // Catch missing/corrupt samples in debug builds rather than as a silent gap
        // heard later. Allows 0 (bundle not present in some test contexts).
        assert(d.loaded == d.expected || d.loaded == 0,
               "SamplerEngine[\(instrument.id)] loaded \(d.loaded)/\(d.expected) samples")
    }

    /// Thread-safe: reads only the immutable BundleIndex and builds new buffers.
    private static func decode(_ instrument: SamplerInstrument) -> Decoded {
        // Keyed by "<folder>/<filename>" — NOT the bare filename. All sampler
        // instruments name their files identically (e.g. grand_piano/60_64.wav,
        // string_ensemble/60_64.wav); keying on the bare filename let the
        // last-enumerated folder overwrite the others, so every instrument played
        // whichever folder won. Relies on Samples being an Xcode folder reference.
        let wavMap = BundleIndex.shared.wavByFolderAndName
        var d = Decoded()
        // Generated instruments declare their roots; imported ones (pipe organ)
        // discover them from the folder, because those samples live only on the
        // machine that ran the importer while the descriptor lives in git — a
        // pull/reset would otherwise put the two out of step and trip the assert.
        let roots = instrument.discoversRoots
            ? SamplerSelection.discoverRoots(keys: Array(wavMap.keys), folder: instrument.id,
                                             layers: instrument.velocityLayers)
            : instrument.rootNotes
        if instrument.discoversRoots && roots.isEmpty {
            Diagnostics.shared.log("SamplerEngine[\(instrument.id)]: no samples in bundle — run Scripts/import_samples.py")
        }
        for layer in instrument.velocityLayers {
            for root in roots {
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
                // Identity guard: the resolved file MUST live in this instrument's folder.
                assert(url.deletingLastPathComponent().lastPathComponent == instrument.id,
                       "SamplerEngine[\(instrument.id)] resolved \(key) to \(url.path) — wrong folder")
                // Real recordings of sustaining instruments: find the steady part and
                // loop it, so the note holds as long as the key does.
                if !instrument.loops && instrument.sustainLoop, let parts = makeSustainParts(mono) {
                    d.parts[root, default: [:]][layer.midiValue] = parts
                    d.sustainLooped += 1
                }
                // One-shots get zero-crossing edge fades to declick note-on and slot
                // recycling. Looping buffers must NOT — a fade would dip at every wrap.
                if !instrument.loops { applyEdgeFades(buf) }
                d.buffers[root, default: [:]][layer.midiValue] = buf
                d.loaded += 1
            }
        }
        d.expected = roots.count * instrument.velocityLayers.count
        return d
    }

    // MARK: - Playback

    @discardableResult
    func noteOn(_ note: UInt8, velocity: UInt8) -> Handle? {
        let midi = Int(note)
        let vel  = Int(velocity)
        guard let (root, velMidi, buf) = findBuffer(midi: midi, vel: vel) else { return nil }

        let idx  = nextSlotIndex()
        let slot = pool[idx]
        // AVAudioPlayerNode.play() raises an exception (crash) if its engine isn't
        // running — e.g. during an interruption (call/Siri) or a route-change restart.
        guard slot.player.engine?.isRunning == true else {
            Diagnostics.shared.log("Sampler[\(instrument.id)] note ignored — audio engine not running")
            return nil
        }
        if slot.player.isPlaying { slot.player.stop() }

        // Bump the slot's generation so any ramp still scheduled on it stops.
        let token = (slotToken[idx] ?? 0) + 1
        slotToken[idx] = token
        slotPitch[idx] = (midi, root)

        // Rate = 2^(semitones/12), clamped to AVAudioUnitVarispeed valid range [0.25, 4.0].
        let rate = Float(pow(2.0, Double(midi - root) / 12.0))
        slot.varispeed.rate = max(0.25, min(4.0, rate))

        let target = max(0.3, Float(vel) / 127.0)
        let parts  = (!instrument.loops && instrument.sustainLoop) ? sustainParts[root]?[velMidi] : nil

        if instrument.loops || parts != nil {
            // Sustaining note: held until noteOff. Ramp the volume up so a non-zero
            // start doesn't click, and remember the note so noteOff can release it.
            slotNote[idx]      = midi
            slotBusyUntil.removeValue(forKey: idx)
            slot.player.volume = 0
            if let parts {
                // The recording's own attack once, then its sustain loops until release.
                slot.player.scheduleBuffer(parts.head, at: nil, options: [])
                slot.player.scheduleBuffer(parts.body, at: nil, options: [.loops])
            } else {
                // Synthesised seamless loop: the whole buffer loops.
                slot.player.scheduleBuffer(buf, at: nil, options: [.loops])
            }
            slot.player.play()
            rampVolume(idx: idx, token: token, to: target, duration: instrument.attack)
        } else {
            // One-shot: play once at full level and let the tail ring out.
            slotNote.removeValue(forKey: idx)
            let seconds = Double(buf.frameLength) / buf.format.sampleRate / Double(max(0.25, min(4.0, rate)))
            slotBusyUntil[idx] = ProcessInfo.processInfo.systemUptime + seconds + 0.05
            slot.player.volume = target
            slot.player.scheduleBuffer(buf, at: nil, options: [])
            slot.player.play()
        }
        return Handle(slot: idx, token: token)
    }

    /// Pitch-bends one sounding note (keyboard glide, finger vibrato, glissando)
    /// by re-tuning its varispeed. No-op if the slot has since been reused or the
    /// note released (its token no longer matches).
    func bend(_ handle: Handle, semitones: Float) {
        guard slotToken[handle.slot] == handle.token,
              let p = slotPitch[handle.slot] else { return }
        let rate = max(0.25, min(4.0, Float(pow(2.0, (Double(p.midi - p.root) + Double(semitones)) / 12.0))))
        let varispeed = pool[handle.slot].varispeed
        // A one-shot played slower lasts longer: stretch its remaining busy time so
        // a note bent down isn't treated as finished (and stolen) while still ringing.
        let now = ProcessInfo.processInfo.systemUptime
        if let until = slotBusyUntil[handle.slot], until > now, varispeed.rate > 0 {
            slotBusyUntil[handle.slot] = now + (until - now) * Double(varispeed.rate / rate)
        }
        varispeed.rate = rate
    }

    /// Releases exactly the note started with `handle` (sustaining notes only —
    /// one-shots ring out on their own).
    /// Preferred over noteOff(_ note:), which releases EVERY slot playing that MIDI
    /// note — so the looper and a finger on the same key would silence each other.
    func noteOff(_ handle: Handle) {
        guard slotToken[handle.slot] == handle.token,     // not reused / not already released
              slotNote[handle.slot] != nil else { return }   // only sustaining notes are held
        let idx   = handle.slot
        let token = handle.token + 1
        slotToken[idx] = token
        slotNote.removeValue(forKey: idx)
        markReleasing(idx)
        let player = pool[idx].player
        rampVolume(idx: idx, token: token, to: 0, duration: instrument.release) { [weak self] in
            guard let self = self, self.slotToken[idx] == token else { return }
            player.stop()
        }
    }

    func noteOff(_ note: UInt8) {
        // Only sustaining notes are in slotNote; one-shots ring out on their own.
        let midi = Int(note)
        // Collect first — releasing mutates slotNote, which can't be done while
        // iterating it.
        let indices = slotNote.compactMap { $0.value == midi ? $0.key : nil }
        for idx in indices {
            let token = (slotToken[idx] ?? 0) + 1
            slotToken[idx] = token
            slotNote.removeValue(forKey: idx)
            markReleasing(idx)
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
        pool.indices.reduce(0) { $0 + (isBusy($1) ? 1 : 0) }
    }

    /// A slot is busy if it's playing AND (for one-shots) its buffer hasn't ended.
    private func isBusy(_ idx: Int) -> Bool {
        guard pool[idx].player.isPlaying else { return false }
        if slotNote[idx] != nil { return true }                    // held (sustaining)
        return ProcessInfo.processInfo.systemUptime < (slotBusyUntil[idx] ?? 0)
    }

    /// A released sustaining note is still fading out; keep its slot busy until the
    /// release ramp has finished so a new note doesn't steal it mid-fade.
    private func markReleasing(_ idx: Int) {
        slotBusyUntil[idx] = ProcessInfo.processInfo.systemUptime + instrument.release + 0.05
    }

    /// Splits a mono recording into attack (head) + seamless sustain loop (body),
    /// both promoted to stereo. nil if it has no steady part long enough to loop.
    private static func makeSustainParts(_ mono: AVAudioPCMBuffer)
        -> (head: AVAudioPCMBuffer, body: AVAudioPCMBuffer)? {
        guard mono.format.channelCount == 1, let src = mono.floatChannelData?[0] else { return nil }
        var x = Array(UnsafeBufferPointer(start: src, count: Int(mono.frameLength)))
        guard let loop = SustainLoop.prepare(&x, sampleRate: mono.format.sampleRate),
              let head = monoBuffer(x[0..<loop.lowerBound], format: mono.format),
              let body = monoBuffer(x[loop], format: mono.format),
              let headStereo = makeStereo(head),
              let bodyStereo = makeStereo(body)
        else { return nil }
        applyFadeIn(headStereo)          // declick the note start; the loop seam is crossfaded
        return (headStereo, bodyStereo)
    }

    private static func monoBuffer(_ samples: ArraySlice<Float>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let d = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { d.update(from: $0.baseAddress!, count: samples.count) }
        return b
    }

    private static func applyFadeIn(_ buf: AVAudioPCMBuffer, ms: Double = 5) {
        guard let ch = buf.floatChannelData else { return }
        let f = min(Int(buf.frameLength), Int(ms / 1000.0 * buf.format.sampleRate))
        guard f > 0 else { return }
        for c in 0..<Int(buf.format.channelCount) {
            for i in 0..<f { ch[c][i] *= Float(i) / Float(f) }
        }
    }

    // MARK: - Helpers

    /// Ramps the first and last few milliseconds of every channel to zero so the
    /// buffer always begins and ends on a zero crossing. Without this, samples
    /// whose first/last frame is non-zero produce an audible click on note-on and
    /// when a slot is recycled mid-tail.
    private static func applyEdgeFades(_ buf: AVAudioPCMBuffer, ms: Double = 5) {
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
        if let idle = pool.indices.first(where: { !isBusy($0) }) { return idle }
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
    private static func makeStereo(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    private func findBuffer(midi: Int, vel: Int) -> (rootNote: Int, velMidi: Int, buf: AVAudioPCMBuffer)? {
        guard let velMidi = SamplerSelection.velocityMidiValue(
                for: vel, layers: instrument.velocityLayers) else { return nil }

        let roots = buffers.keys.filter { buffers[$0]?[velMidi] != nil }
        guard let root = SamplerSelection.nearestRoot(
                to: midi, available: Array(roots)) else { return nil }

        return (root, velMidi, buffers[root]![velMidi]!)
    }
}

// MARK: - Pure selection logic (no AVFoundation — unit-tested in SuperNovaPadTests)

/// The note/velocity → sample selection rules, factored out of `SamplerEngine`
/// so they can be tested without loading any audio. Keeping them pure also makes
/// the tie-breaking deterministic, which the old `Dictionary.keys` ordering was not.
enum SamplerSelection {

    /// Roots present in `folder` that have a sample for EVERY velocity layer, from
    /// bundle keys of the form "<folder>/<root>_<velocity>". Incomplete roots are
    /// dropped so velocity selection can never land on a missing layer.
    static func discoverRoots(keys: [String], folder: String,
                              layers: [SamplerInstrument.VelocityLayer]) -> [Int] {
        let prefix = folder + "/"
        var found: [Int: Set<Int>] = [:]
        for key in keys where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: "_")
            guard parts.count == 2, let root = Int(parts[0]), let vel = Int(parts[1]) else { continue }
            found[root, default: []].insert(vel)
        }
        let needed = Set(layers.map(\.midiValue))
        return found.filter { needed.isSubset(of: $0.value) }.keys.sorted()
    }

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

// MARK: - Sustain loop (pure — unit-tested in SuperNovaPadTests)

/// Turns a real recording of a sustaining instrument (organ pipe, bowed string,
/// flute) into attack + seamless loop:
///  1. find: the steady region — from just after the attack settles (≥ 70 % of
///     the loud reference level) to the last window still ≥ 90 % of it, before the
///     release tail (50 ms RMS windows; reference = the 75th-percentile window);
///  2. alignEnd: move the loop end back by up to 30 ms to where the waveform best
///     matches the waveform just before the loop start, so the two ends are in phase;
///  3. makeSeamless: LINEAR crossfade (80 ms) of the loop's end into the material
///     just before its start — linear because the aligned ends are correlated.
/// Prototyped in Python on synthetic organ tones (41 Hz – 1 kHz): seam jump well
/// below a normal sample step, level change across the seam < 1 dB.
enum SustainLoop {
    static let window      = 0.05   // RMS window (s)
    static let crossfade   = 0.08   // seam crossfade (s)
    static let alignWindow = 0.01   // waveform compared when aligning the end (s)
    static let alignSearch = 0.03   // how far the end may move (s)
    static let minLoop     = 0.25   // shortest loop worth making (s)

    /// Finds, phase-aligns and crossfades the loop IN PLACE. nil = nothing to loop.
    static func prepare(_ x: inout [Float], sampleRate: Double) -> Range<Int>? {
        guard let found = find(x, sampleRate: sampleRate) else { return nil }
        let loop = found.lowerBound ..< alignEnd(x, loop: found, sampleRate: sampleRate)
        makeSeamless(&x, loop: loop, crossfade: Int(sampleRate * crossfade))
        return loop
    }

    static func find(_ x: [Float], sampleRate: Double) -> Range<Int>? {
        let win = Int(sampleRate * window)
        guard win > 0, x.count >= win * 12 else { return nil }
        let nw = x.count / win
        var rms = [Float](repeating: 0, count: nw)
        x.withUnsafeBufferPointer { p in
            for w in 0..<nw {
                var sum: Float = 0
                for i in (w * win)..<((w + 1) * win) { sum += p[i] * p[i] }
                rms[w] = (sum / Float(win)).squareRoot()
            }
        }
        let ref = rms.sorted()[nw * 3 / 4]
        guard ref > 1e-4,
              let a = rms.firstIndex(where: { $0 >= 0.7 * ref }),
              // End threshold is stricter (90 %): at 70 % the loop reached ~110 ms
              // into a decaying release, so every pass would dip in level.
              let e = rms.lastIndex(where: { $0 >= 0.9 * ref }) else { return nil }
        let start = (a + 2) * win
        let end   = min(x.count, (e + 1) * win)
        guard end - start >= max(2 * Int(sampleRate * crossfade), Int(sampleRate * minLoop)) else { return nil }
        return start..<end
    }

    static func alignEnd(_ x: [Float], loop: Range<Int>, sampleRate: Double) -> Int {
        let len = Int(sampleRate * alignWindow)
        let search = Int(sampleRate * alignSearch)
        let lo = loop.lowerBound, hi = loop.upperBound
        guard len > 0, lo >= len else { return hi }
        var best = hi
        var bestD = Float.infinity
        x.withUnsafeBufferPointer { p in
            var c = hi - search
            while c <= hi {
                if c - len >= lo {
                    var d: Float = 0
                    for k in 0..<len {
                        let diff = p[c - len + k] - p[lo - len + k]
                        d += diff * diff
                    }
                    if d < bestD { bestD = d; best = c }
                }
                c += 1
            }
        }
        return best
    }

    static func makeSeamless(_ x: inout [Float], loop: Range<Int>, crossfade: Int) {
        let xf = min(crossfade, loop.lowerBound, loop.count / 2)
        guard xf > 0 else { return }
        for k in 0..<xf {
            let a = Float(k + 1) / Float(xf + 1)
            let i = loop.upperBound - xf + k
            let j = loop.lowerBound - xf + k
            x[i] = x[i] * (1 - a) + x[j] * a
        }
    }
}
