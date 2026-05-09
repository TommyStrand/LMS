import AVFoundation
import Foundation

// MARK: - PRNG (lock-free, no heap allocations — safe on the audio thread)

private struct LCG {
    var state: UInt64 = 2463534242
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(Int64(bitPattern: state)) / Double(Int64.max)
    }
}

// MARK: - Voice synthesiser (value type, stored in pre-allocated pool)

struct DrumVoiceSynth {
    let voiceType: DrumVoiceID
    let velocity: Float
    var samplesElapsed: Int = 0
    var phase1: Double = 0
    var phase2: Double = 0
    var phase3: Double = 0
    var lpf1:   Double = 0
    var prevNoise: Double = 0
    var rng = LCG()
    var done: Bool = false

    mutating func advance(sampleRate: Double) -> Float {
        let t  = Double(samplesElapsed) / sampleRate
        let dt = 1.0 / sampleRate
        let v  = Double(velocity)
        samplesElapsed += 1

        switch voiceType {

        case .kick:
            let pitchEnv = (165.0 - 52.0) * exp(-t / 0.038) + 52.0
            phase1 += pitchEnv * dt * 2.0 * .pi
            let amp   = exp(-t / 0.38) * v
            let click = t < 0.003 ? rng.next() * 0.22 * v : 0.0
            done = t > 1.6
            return Float(sin(phase1) * amp * 0.9 + click)

        case .snare:
            phase1 += 185.0 * dt * 2.0 * .pi
            let body  = sin(phase1) * exp(-t / 0.030) * 0.35
            let raw   = rng.next()
            let hp    = raw - prevNoise * 0.88
            prevNoise = raw
            phase2   += 320.0 * dt * 2.0 * .pi
            let crack  = sin(phase2) * exp(-t / 0.012) * 0.25
            let noise  = hp * exp(-t / 0.17) * 0.60
            done = t > 0.65
            return Float((body + crack + noise) * v * 0.85)

        case .hihat:
            let raw = rng.next()
            let hp  = raw - prevNoise * 0.96
            prevNoise = raw
            lpf1 = lpf1 * 0.15 + hp * 0.85
            done = t > 0.12
            return Float(lpf1 * exp(-t / 0.028) * v * 0.55)

        case .hihatOpen:
            let raw = rng.next()
            let hp  = raw - prevNoise * 0.96
            prevNoise = raw
            lpf1 = lpf1 * 0.15 + hp * 0.85
            done = t > 0.85
            return Float(lpf1 * exp(-t / 0.20) * v * 0.55)

        case .rideBell:
            phase1 += 1290.0 * dt * 2.0 * .pi
            phase2 += 1871.0 * dt * 2.0 * .pi
            phase3 += 3180.0 * dt * 2.0 * .pi
            let attack = t < 0.006 ? rng.next() * 0.25 * v : 0.0
            let amp    = exp(-t / 1.9) * v
            let sig    = sin(phase1) * 0.50 + sin(phase2) * 0.30 + sin(phase3) * 0.20
            done = t > 6.0
            return Float(sig * amp * 0.45 + attack)

        case .tomLo:
            phase1 += (65.0 * (1.0 + 0.65 * exp(-t / 0.055))) * dt * 2.0 * .pi
            let click = t < 0.005 ? rng.next() * 0.18 * v : 0.0
            done = t > 1.6
            return Float((sin(phase1) * 0.88 + click) * exp(-t / 0.50) * v)

        case .tomMid:
            phase1 += (100.0 * (1.0 + 0.55 * exp(-t / 0.048))) * dt * 2.0 * .pi
            let click = t < 0.004 ? rng.next() * 0.18 * v : 0.0
            done = t > 1.4
            return Float((sin(phase1) * 0.88 + click) * exp(-t / 0.42) * v)

        case .tomHi:
            phase1 += (155.0 * (1.0 + 0.50 * exp(-t / 0.042))) * dt * 2.0 * .pi
            let click = t < 0.003 ? rng.next() * 0.18 * v : 0.0
            done = t > 1.2
            return Float((sin(phase1) * 0.88 + click) * exp(-t / 0.34) * v)

        case .crash:
            let raw = rng.next()
            let hp  = raw - prevNoise * 0.88
            prevNoise = raw
            phase1 += 1870.0 * dt * 2.0 * .pi
            phase2 += 3714.0 * dt * 2.0 * .pi
            let metal = (sin(phase1) + sin(phase2)) * 0.5 * exp(-t / 2.20) * v * 0.25
            let noise = hp * exp(-t / 0.50) * v
            done = t > 5.0
            return Float((noise + metal) * 0.55)
        }
    }
}

// MARK: - DrumEngine

final class DrumEngine: ObservableObject {

    // MARK: Published

    @Published var isPlaying   = false
    @Published var bpm: Double = 90 {
        didSet { _bpm = bpm; updateDelayTime() }
    }
    @Published var patternIndex: Int = 0 {
        didSet {
            let idx = max(0, min(patternIndex, DrumPattern.all.count - 1))
            _pattern     = DrumPattern.all[idx]
            tickPosition = 0
        }
    }
    @Published var delayMix: Float = 0.22 {
        didSet { delayNode.wetDryMix = delayMix * 100 }
    }
    @Published var shimmer: Float = 0.32 {
        didSet { reverbNode.wetDryMix = shimmer * 100 }
    }
    @Published var grit: Float = 0.0 {
        didSet { _grit = grit }
    }
    // 0…1 fraction through the current loop bar (drives the beat ring in the UI)
    @Published var beatFraction: Double = 0

    // MARK: Audio graph

    private let audioEngine = AVAudioEngine()
    private let delayNode   = AVAudioUnitDelay()
    private let reverbNode  = AVAudioUnitReverb()
    private var sourceNode: AVAudioSourceNode!

    // MARK: Render-thread shadow vars (written from main, read from audio thread)

    private var voicePool: [DrumVoiceSynth?] = Array(repeating: nil, count: 24)
    private var tickPosition:  Double = 0
    private var _bpm:          Double = 90
    private var _grit:         Float  = 0
    private var _pattern:      DrumPattern = DrumPattern.all[0]
    private var _isPlaying:    Bool   = false
    private var beatCounter:   Int    = 0

    // MARK: Init

    init() {
        _bpm     = bpm
        _pattern = DrumPattern.all[0]
        setupAudio()
    }

    // MARK: Playback

    func play() {
        tickPosition = 0
        _isPlaying   = true
        DispatchQueue.main.async { self.isPlaying = true }
    }

    func stop() {
        _isPlaying = false
        DispatchQueue.main.async {
            self.isPlaying    = false
            self.beatFraction = 0
        }
    }

    func togglePlay() { isPlaying ? stop() : play() }

    // MARK: Audio graph setup

    private func setupAudio() {
        let sr: Double = 44100
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        sourceNode = AVAudioSourceNode(format: fmt) { [weak self] isSilence, _, frameCount, abl in
            guard let self else { isSilence.pointee = true; return noErr }
            self.renderBlock(isSilence: isSilence,
                             frameCount: Int(frameCount),
                             abl: abl,
                             sampleRate: sr)
            return noErr
        }

        audioEngine.attach(sourceNode)
        audioEngine.attach(delayNode)
        audioEngine.attach(reverbNode)

        audioEngine.connect(sourceNode, to: delayNode,            format: fmt)
        audioEngine.connect(delayNode,  to: reverbNode,           format: fmt)
        audioEngine.connect(reverbNode, to: audioEngine.mainMixerNode, format: fmt)

        delayNode.delayTime     = 60.0 / _bpm * 0.75  // dotted-eighth feel
        delayNode.feedback      = 28
        delayNode.lowPassCutoff = 5500
        delayNode.wetDryMix     = delayMix * 100

        reverbNode.loadFactoryPreset(.largeHall)
        reverbNode.wetDryMix = shimmer * 100

        do { try audioEngine.start() }
        catch { print("DrumEngine: engine start failed – \(error)") }
    }

    private func updateDelayTime() {
        delayNode.delayTime = 60.0 / _bpm * 0.75
    }

    // MARK: Render block

    private func renderBlock(isSilence: UnsafeMutablePointer<ObjCBool>,
                             frameCount: Int,
                             abl: UnsafeMutablePointer<AudioBufferList>,
                             sampleRate: Double) {
        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        for buf in bufList { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        guard _isPlaying else { isSilence.pointee = true; return }
        guard let lPtr = bufList[0].mData?.assumingMemoryBound(to: Float.self),
              let rPtr = (bufList.count > 1 ? bufList[1].mData : bufList[0].mData)?
                .assumingMemoryBound(to: Float.self)
        else { return }

        let loopTicks      = Double(_pattern.loopTicks)
        let tpb            = Double(_pattern.ticksPerBeat)
        let ticksPerSample = (_bpm / 60.0) * tpb / sampleRate
        let grit           = _grit

        for frame in 0 ..< frameCount {
            let prev = tickPosition
            tickPosition += ticksPerSample

            // Loop-aware hit detection
            let prevMod = prev.truncatingRemainder(dividingBy: loopTicks)
            let currMod = tickPosition.truncatingRemainder(dividingBy: loopTicks)

            for hit in _pattern.hits {
                let ht = Double(hit.tick)
                let fired = currMod > prevMod
                    ? (ht >= prevMod && ht < currMod)
                    : (ht >= prevMod || ht < currMod)
                if fired { spawnVoice(type: hit.voice, velocity: hit.velocity) }
            }

            // Mix voices
            var s: Float = 0
            for i in 0 ..< voicePool.count {
                guard voicePool[i] != nil else { continue }
                s += voicePool[i]!.advance(sampleRate: sampleRate)
                if voicePool[i]!.done { voicePool[i] = nil }
            }

            // Soft saturation
            if grit > 0 {
                let d = 1.0 + grit * 9.0
                s = tanh(s * d) / d
            }

            lPtr[frame] = s
            rPtr[frame] = s
        }

        // Publish beat fraction (throttled)
        beatCounter += frameCount
        if beatCounter >= 512 {
            beatCounter = 0
            let frac = tickPosition.truncatingRemainder(dividingBy: loopTicks) / loopTicks
            DispatchQueue.main.async { [weak self] in self?.beatFraction = frac }
        }
    }

    // MARK: Voice pool (render thread only)

    private func spawnVoice(type: DrumVoiceID, velocity: Float) {
        for i in 0 ..< voicePool.count {
            if voicePool[i] == nil {
                voicePool[i] = DrumVoiceSynth(voiceType: type, velocity: velocity)
                return
            }
        }
        // Pool full: steal first slot
        voicePool[0] = DrumVoiceSynth(voiceType: type, velocity: velocity)
    }
}
