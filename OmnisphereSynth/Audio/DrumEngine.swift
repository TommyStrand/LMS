import AVFoundation
import Foundation

// MARK: - Sample voice (value type, pool-allocated, no ARC in hot path)

struct SampleVoice {
    private let leftData:  UnsafeMutablePointer<Float>
    private let rightData: UnsafeMutablePointer<Float>
    private let frameLen:  Int
    let velocity: Float
    var position: Int = 0

    init(buffer: AVAudioPCMBuffer, velocity: Float) {
        let ch    = buffer.floatChannelData!
        leftData  = ch[0]
        rightData = buffer.format.channelCount > 1 ? ch[1] : ch[0]
        frameLen  = Int(buffer.frameLength)
        self.velocity = velocity
    }

    var done: Bool { position >= frameLen }

    mutating func nextStereo() -> (Float, Float) {
        guard position < frameLen else { return (0, 0) }
        let l = leftData[position]  * velocity
        let r = rightData[position] * velocity
        position += 1
        return (l, r)
    }
}

// MARK: - DrumEngine

final class DrumEngine: ObservableObject {

    // MARK: Published

    @Published var isPlaying   = false
    @Published var bpm: Double = 90 {
        didSet { renderBpm = bpm; updateDelayTime() }
    }
    @Published var patternIndex: Int = 0 {
        didSet {
            let idx  = max(0, min(patternIndex, DrumPattern.all.count - 1))
            _pattern         = DrumPattern.all[idx]
            tickPosition     = 0
            customHits       = nil
            renderCustomHits = nil
        }
    }
    @Published var delayMix: Float = 0.22 {
        didSet { delayNode.wetDryMix = delayMix * 100 }
    }
    @Published var shimmer: Float = 0.32 {
        didSet { reverbNode.wetDryMix = shimmer * 100 }
    }
    @Published var grit: Float = 0.0 {
        didSet { renderGrit = grit }
    }
    @Published var masterVolume: Float = 0.8 {
        didSet { renderMasterVolume = masterVolume }
    }
    @Published var beatFraction: Double = 0
    @Published var customHits: [DrumHit]?

    // MARK: Audio graph

    private let audioEngine = AVAudioEngine()
    var avEngine: AVAudioEngine { audioEngine }
    private let delayNode   = AVAudioUnitDelay()
    private let reverbNode  = AVAudioUnitReverb()
    private var sourceNode: AVAudioSourceNode!

    // MARK: Sample bank (main-thread write before engine start, audio-thread read only)

    // Buffers are retained here for the engine's lifetime so SampleVoice raw pointers stay valid
    private var sampleBuffers: [DrumVoiceID: [AVAudioPCMBuffer]] = [:]
    private var rrIndex: [Int] = Array(repeating: 0, count: DrumVoiceID.allCases.count)

    // Lowercased filename (no extension) → URL, built by scanning the entire bundle tree.
    // Handles both flat resources and folder-reference subdirectories added in Xcode.
    private var bundleWavMap: [String: URL] = [:]

    // MARK: Render-thread state

    private var voicePool:       [SampleVoice?] = Array(repeating: nil, count: 32)
    private var tickPosition:    Double = 0
    private var renderBpm:       Double = 90
    private var renderGrit:      Float  = 0
    private var _pattern:        DrumPattern = DrumPattern.all[0]
    private var renderCustomHits: [DrumHit]?
    private var renderIsPlaying:    Bool   = false
    private var renderMasterVolume: Float  = 0.8
    private var beatCounter:        Int    = 0
    private var shuffleBag:         [Int]  = []

    // MARK: Init

    init() {
        renderBpm = bpm
        _pattern  = DrumPattern.all[0]
        loadSamples()
        setupAudio()
    }

    // MARK: Playback

    func play() {
        tickPosition    = 0
        renderIsPlaying = true
        DispatchQueue.main.async { self.isPlaying = true }
    }

    func stop() {
        renderIsPlaying = false
        DispatchQueue.main.async {
            self.isPlaying    = false
            self.beatFraction = 0
        }
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func randomize() {
        // Shuffle-bag: refill when empty so every pattern plays before any repeats
        if shuffleBag.isEmpty {
            shuffleBag = Array(0..<DrumPattern.all.count).shuffled()
        }
        // Skip the current pattern if it happens to be next in the bag
        if shuffleBag.count > 1 && shuffleBag.last == patternIndex {
            let last = shuffleBag.removeLast()
            let next = shuffleBag.removeLast()
            shuffleBag.append(last)
            patternIndex = next
        } else {
            patternIndex = shuffleBag.removeLast()
        }
    }

    // MARK: Step sequencer

    func toggleStep(voice: DrumVoiceID, step: Int) {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        var hits = customHits ?? Array(pat.hits)
        let ticksPerStep = Int(pat.ticksPerBeat) / 4   // 16th-note grid
        let tick = Int32(step * ticksPerStep)
        if let idx = hits.firstIndex(where: { $0.voice == voice && $0.tick == tick }) {
            hits.remove(at: idx)
        } else {
            hits.append(DrumHit(tick: tick, voice: voice, velocity: 0.85))
            hits.sort { $0.tick < $1.tick }
        }
        customHits       = hits
        renderCustomHits = hits
    }

    func resetPattern() {
        customHits       = nil
        renderCustomHits = nil
    }

    func activeSteps(for voice: DrumVoiceID) -> Set<Int> {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        let hits = customHits ?? pat.hits
        let ticksPerStep = Int(pat.ticksPerBeat) / 4
        return Set(hits.filter { $0.voice == voice }.map { Int($0.tick) / ticksPerStep })
    }

    // MARK: Sample loading

    private func buildBundleWavMap() {
        guard let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "wav" {
            bundleWavMap[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }

        print("DrumEngine: \(bundleWavMap.count) .wav files found in bundle")
        if bundleWavMap.isEmpty {
            print("DrumEngine: ⚠️  no WAV files found — add MusicRadar samples to the Xcode target")
        }
    }

    private func loadSamples() {
        buildBundleWavMap()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        // Each tuple: (voice, [bundle resource names without extension])
        // Files must be added to the Xcode target from the MusicRadar pack.
        let specs: [(DrumVoiceID, [String])] = [
            (.kick,
             (1...8).map { String(format: "CYCdh_K1close_Kick-%02d", $0) }),

            (.snare,
             (1...5).map { String(format: "CYCdh_K1close_Snr-%02d", $0) }),

            (.hihat,
             (1...9).map { String(format: "CYCdh_K1close_ClHat-%02d", $0) }),

            (.hihatOpen,
             (1...7).map { String(format: "CYCdh_K1close_OpHat-%02d", $0) }),

            (.rideBell,
             ["CYCdh_Kurz01-Ride01", "CYCdh_Kurz01-Ride02"]),

            (.crash,
             (1...7).map { String(format: "CyCdh_K3Crash-%02d", $0) }),

            (.tomHi,
             ["CYCdh_K5-Tom01a", "CYCdh_K5-Tom01b", "CYCdh_K5-Tom01c"]),

            (.tomMid,
             ["CYCdh_K5-Tom02a", "CYCdh_K5-Tom02b", "CYCdh_K5-Tom02c"]),

            (.tomLo,
             ["CYCdh_K5-Tom03a", "CYCdh_K5-Tom03b", "CYCdh_K5-Tom03c"]),
        ]

        for (voice, names) in specs {
            sampleBuffers[voice] = names.compactMap { loadSample(name: $0, targetFormat: fmt) }
            if let loaded = sampleBuffers[voice] {
                print("DrumEngine: \(voice) – \(loaded.count)/\(names.count) samples loaded")
            }
        }
    }

    private func loadSample(name: String, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = bundleWavMap[name.lowercased()] else {
            print("DrumEngine: missing \(name).wav")
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            print("DrumEngine: can't open \(name).wav")
            return nil
        }

        let fileFmt = file.processingFormat
        let frames  = AVAudioFrameCount(file.length)
        guard let src = AVAudioPCMBuffer(pcmFormat: fileFmt, frameCapacity: frames),
              (try? file.read(into: src)) != nil else { return nil }

        // Fast path: sample rate already matches — SampleVoice handles mono natively
        // (mirrors ch[0] to both L and R), so skip any channel-count conversion.
        if fileFmt.sampleRate == targetFormat.sampleRate { return src }

        // Only convert when sample rate differs; keep the file's native channel count
        // to avoid the AVAudioConverter mono→stereo failure mode.
        let nativeFmt = AVAudioFormat(standardFormatWithSampleRate: targetFormat.sampleRate,
                                      channels: fileFmt.channelCount)!
        let dstFrames = AVAudioFrameCount(
            Double(frames) * targetFormat.sampleRate / fileFmt.sampleRate
        ) + 1
        guard let dst       = AVAudioPCMBuffer(pcmFormat: nativeFmt, frameCapacity: dstFrames),
              let converter = AVAudioConverter(from: fileFmt, to: nativeFmt) else { return nil }

        var err: NSError?
        var done = false
        converter.convert(to: dst, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; done = true; return src
        }
        return err == nil ? dst : nil
    }

    // MARK: Audio graph setup

    private func setupAudio() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        sourceNode = AVAudioSourceNode(format: fmt) { [weak self] isSilence, _, frameCount, abl in
            guard let self else { isSilence.pointee = true; return noErr }
            self.renderBlock(isSilence: isSilence, frameCount: Int(frameCount), abl: abl)
            return noErr
        }

        audioEngine.attach(sourceNode)
        audioEngine.attach(delayNode)
        audioEngine.attach(reverbNode)

        audioEngine.connect(sourceNode, to: delayNode,                format: fmt)
        audioEngine.connect(delayNode,  to: reverbNode,               format: fmt)
        audioEngine.connect(reverbNode, to: audioEngine.mainMixerNode, format: fmt)

        delayNode.delayTime     = 60.0 / renderBpm * 0.75
        delayNode.feedback      = 28
        delayNode.lowPassCutoff = 5500
        delayNode.wetDryMix     = delayMix * 100

        reverbNode.loadFactoryPreset(.largeHall)
        reverbNode.wetDryMix = shimmer * 100

        do { try audioEngine.start() }
        catch { print("DrumEngine: engine start failed – \(error)") }
    }

    private func updateDelayTime() {
        delayNode.delayTime = 60.0 / renderBpm * 0.75
    }

    // MARK: Render block

    private func renderBlock(isSilence: UnsafeMutablePointer<ObjCBool>,
                             frameCount: Int,
                             abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        for buf in bufList { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        guard renderIsPlaying else { isSilence.pointee = true; return }
        guard let lPtr = bufList[0].mData?.assumingMemoryBound(to: Float.self),
              let rPtr = (bufList.count > 1 ? bufList[1].mData : bufList[0].mData)?
                .assumingMemoryBound(to: Float.self)
        else { return }

        let loopTicks      = Double(_pattern.loopTicks)
        let tpb            = Double(_pattern.ticksPerBeat)
        let ticksPerSample = (renderBpm / 60.0) * tpb / 44100.0
        let grit           = renderGrit

        for frame in 0 ..< frameCount {
            let prev = tickPosition
            tickPosition += ticksPerSample

            let prevMod = prev.truncatingRemainder(dividingBy: loopTicks)
            let currMod = tickPosition.truncatingRemainder(dividingBy: loopTicks)

            for hit in renderCustomHits ?? _pattern.hits {
                let ht    = Double(hit.tick)
                let fired = currMod > prevMod
                    ? (ht >= prevMod && ht < currMod)
                    : (ht >= prevMod || ht < currMod)
                if fired { spawnVoice(type: hit.voice, velocity: hit.velocity) }
            }

            var l: Float = 0
            var r: Float = 0
            for i in 0 ..< voicePool.count {
                guard voicePool[i] != nil else { continue }
                if voicePool[i]!.done { voicePool[i] = nil; continue }
                let (sl, sr) = voicePool[i]!.nextStereo()
                l += sl; r += sr
            }

            if grit > 0 {
                let d = Float(1.0 + Double(grit) * 9.0)
                l = tanh(l * d) / d
                r = tanh(r * d) / d
            }

            lPtr[frame] = l * renderMasterVolume
            rPtr[frame] = r * renderMasterVolume
        }

        beatCounter += frameCount
        if beatCounter >= 512 {
            beatCounter = 0
            let frac = tickPosition.truncatingRemainder(dividingBy: loopTicks) / loopTicks
            DispatchQueue.main.async { [weak self] in self?.beatFraction = frac }
        }
    }

    // MARK: Voice pool (render thread only)

    private func spawnVoice(type: DrumVoiceID, velocity: Float) {
        guard let bufs = sampleBuffers[type], !bufs.isEmpty else { return }
        let idx = rrIndex[type.rawValue] % bufs.count
        rrIndex[type.rawValue] = idx + 1
        let voice = SampleVoice(buffer: bufs[idx], velocity: velocity)
        for i in 0 ..< voicePool.count {
            if voicePool[i] == nil || voicePool[i]!.done { voicePool[i] = voice; return }
        }
        voicePool[0] = voice  // pool full: steal oldest slot
    }
}
