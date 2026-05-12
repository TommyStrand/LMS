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
        var wavMap: [String: URL] = [:]
        if let en = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in en where url.pathExtension.lowercased() == "wav" {
                wavMap[url.deletingPathExtension().lastPathComponent] = url
            }
        }

        var loaded = 0
        for layer in instrument.velocityLayers {
            for root in instrument.rootNotes {
                let name = "\(root)_\(layer.midiValue)"
                guard let url  = wavMap[name],
                      let file = try? AVAudioFile(forReading: url),
                      let buf  = AVAudioPCMBuffer(
                          pcmFormat: file.processingFormat,
                          frameCapacity: AVAudioFrameCount(file.length)
                      ),
                      (try? file.read(into: buf)) != nil
                else { continue }
                buffers[root, default: [:]][layer.midiValue] = buf
                loaded += 1
            }
        }
        let expected = instrument.rootNotes.count * instrument.velocityLayers.count
        print("SamplerEngine[\(instrument.id)]: \(loaded)/\(expected) samples loaded")
    }

    // MARK: - Playback

    func noteOn(_ note: UInt8, velocity: UInt8) {
        let midi = Int(note)
        let vel  = Int(velocity)
        guard let (root, buf) = findBuffer(midi: midi, vel: vel) else { return }

        let slot = nextSlot()
        if slot.player.isPlaying { slot.player.stop() }

        // Rate = 2^(semitones/12), clamped to AVAudioUnitVarispeed valid range [0.25, 4.0].
        let rate = Float(pow(2.0, Double(midi - root) / 12.0))
        slot.varispeed.rate = max(0.25, min(4.0, rate))
        slot.player.volume  = max(0.3, Float(vel) / 127.0)
        slot.player.scheduleBuffer(buf, at: nil, options: [])
        slot.player.play()
    }

    func noteOff(_ note: UInt8) {
        // Samples carry their own decay/release tail — let them play to completion.
    }

    // MARK: - Helpers

    private func nextSlot() -> VoiceSlot {
        let slot = pool[poolCursor % poolSize]
        poolCursor += 1
        return slot
    }

    private func findBuffer(midi: Int, vel: Int) -> (rootNote: Int, buf: AVAudioPCMBuffer)? {
        let layer = instrument.velocityLayers.first { vel >= $0.loVel && vel <= $0.hiVel }
            ?? instrument.velocityLayers.last
        guard let velMidi = layer?.midiValue else { return nil }

        let roots = buffers.keys.filter { buffers[$0]?[velMidi] != nil }
        guard !roots.isEmpty else { return nil }

        let root = roots.min(by: { abs($0 - midi) < abs($1 - midi) })!
        return (root, buffers[root]![velMidi]!)
    }
}
