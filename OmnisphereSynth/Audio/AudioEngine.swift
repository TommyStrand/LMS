import AVFoundation
import Accelerate

final class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let delay = AVAudioUnitDelay()

    private(set) var voices: [Int: SynthVoice] = [:]  // touchID → voice
    private var voiceNodes: [Int: AVAudioSourceNode] = [:]

    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 128)
    @Published var currentPreset: SynthPreset = SynthPreset.presets[0]

    private let sampleRate: Double = 44100
    private var analysisBuffer: [Float] = Array(repeating: 0, count: 128)
    private var analysisIndex = 0
    private let analysisQueue = DispatchQueue(label: "audio.analysis", qos: .userInteractive)

    init() {
        setupEngine()
    }

    private func setupEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)

        engine.attach(mixer)
        engine.attach(reverb)
        engine.attach(delay)

        engine.connect(mixer, to: reverb, format: nil)
        engine.connect(reverb, to: delay, format: nil)
        engine.connect(delay, to: engine.mainMixerNode, format: nil)

        applyPreset(currentPreset)
        try? engine.start()
    }

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset
        reverb.wetDryMix = preset.reverbMix * 100
        reverb.loadFactoryPreset(.largeChamber)
        delay.wetDryMix = preset.delayMix * 100
        delay.delayTime = Double(preset.delayTime)
        delay.feedback = 30
    }

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        guard voiceNodes[touchID] == nil else { return }
        let preset = currentPreset
        let voice = SynthVoice(note: note, velocity: velocity, preset: preset, sampleRate: sampleRate)
        voice.filterCutoffMod = x
        voice.lfoDepthMod = y
        voices[touchID] = voice

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self, weak voice] _, _, frameCount, audioBufferList in
            guard let voice else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frameCount = Int(frameCount)
            let leftBuf = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightBuf = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)

            for i in 0..<frameCount {
                let sample = voice.nextSample()
                leftBuf[i] = sample
                rightBuf[i] = sample
                self?.feedAnalysis(sample)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: mixer, format: format)
        voiceNodes[touchID] = node
        voice.start()
    }

    func noteOff(touchID: Int) {
        voices[touchID]?.release()
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(currentPreset.release) + 0.1) { [weak self] in
            guard let self else { return }
            if let node = self.voiceNodes[touchID] {
                self.engine.detach(node)
                self.voiceNodes.removeValue(forKey: touchID)
                self.voices.removeValue(forKey: touchID)
            }
        }
    }

    func updateTouch(touchID: Int, x: Float, y: Float) {
        voices[touchID]?.filterCutoffMod = x
        voices[touchID]?.lfoDepthMod = y
    }

    // MARK: - Analysis

    private func feedAnalysis(_ sample: Float) {
        analysisBuffer[analysisIndex % 128] = sample
        analysisIndex += 1
        if analysisIndex % 64 == 0 {
            let snapshot = analysisBuffer
            DispatchQueue.main.async { [weak self] in
                self?.waveformSamples = snapshot
            }
        }
    }
}
