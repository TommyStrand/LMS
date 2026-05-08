import AVFoundation

final class AudioEngine: ObservableObject {

    // MARK: - Nodes
    private let engine        = AVAudioEngine()
    private let voiceMixer    = AVAudioMixerNode()   // collects all voice source nodes
    private let distortion    = AVAudioUnitDistortion()
    private let reverb        = AVAudioUnitReverb()
    private let delay         = AVAudioUnitDelay()

    // Shimmer path: long reverb → pitch shift (+1 octave) → shimmer gain mixer
    private let shimmerReverb = AVAudioUnitReverb()
    private let timePitch     = AVAudioUnitTimePitch()
    private let shimmerMixer  = AVAudioMixerNode()

    // MARK: - State
    private(set) var voices: [Int: any AnyVoice] = [:]
    private var voiceNodes: [Int: AVAudioSourceNode] = [:]

    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 128)
    @Published var currentPreset: SynthPreset = SynthPreset.presets[0]

    private let sampleRate: Double = 44100
    private var analysisBuffer: [Float] = Array(repeating: 0, count: 128)
    private var analysisIndex = 0

    init() { setupEngine() }

    // MARK: - Setup

    private func setupEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)

        [voiceMixer, distortion, reverb, delay,
         shimmerReverb, timePitch, shimmerMixer].forEach { engine.attach($0) }

        // Main path: voiceMixer → distortion → reverb → delay → mainMixer
        engine.connect(voiceMixer,  to: distortion,  format: nil)
        engine.connect(distortion,  to: reverb,      format: nil)
        engine.connect(reverb,      to: delay,        format: nil)
        engine.connect(delay,       to: engine.mainMixerNode, format: nil)

        // Shimmer path: voiceMixer → shimmerReverb → timePitch → shimmerMixer → mainMixer
        // voiceMixer already connected to distortion; tap separately via shimmerReverb input bus
        engine.connect(voiceMixer,   to: shimmerReverb, format: nil)
        engine.connect(shimmerReverb, to: timePitch,    format: nil)
        engine.connect(timePitch,    to: shimmerMixer,  format: nil)
        engine.connect(shimmerMixer, to: engine.mainMixerNode, format: nil)

        timePitch.pitch  = 1200  // +1 octave (cents)
        timePitch.rate   = 1.0
        shimmerMixer.outputVolume = 0

        applyPreset(currentPreset)
        try? engine.start()
    }

    // MARK: - Preset

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset

        // Reverb
        reverb.loadFactoryPreset(preset.isOrgan ? .cathedral : .largeChamber)
        reverb.wetDryMix = preset.reverbMix * 100

        // Delay
        delay.wetDryMix  = preset.delayMix * 100
        delay.delayTime  = Double(preset.delayTime)
        delay.feedback   = 28

        // Distortion (organic soft saturation)
        distortion.loadFactoryPreset(.multiCellulux)
        distortion.preGain   = preset.distortionAmount * 18   // 0–18 dB drive
        distortion.wetDryMix = preset.distortionAmount > 0 ? 40 + preset.distortionAmount * 55 : 0

        // Shimmer
        shimmerReverb.loadFactoryPreset(.plate)
        shimmerReverb.wetDryMix = 80
        shimmerMixer.outputVolume = preset.shimmerAmount * 0.45
    }

    // Live knob updates (called from UI without rebuilding voices)
    func setDistortion(_ amount: Float) {
        currentPreset.distortionAmount = amount
        distortion.preGain   = amount * 18
        distortion.wetDryMix = amount > 0.01 ? 40 + amount * 55 : 0
    }

    func setShimmer(_ amount: Float) {
        currentPreset.shimmerAmount = amount
        shimmerMixer.outputVolume = amount * 0.45
    }

    func setReverb(_ mix: Float) {
        currentPreset.reverbMix = mix
        reverb.wetDryMix = mix * 100
    }

    func setDelay(_ mix: Float) {
        currentPreset.delayMix = mix
        delay.wetDryMix = mix * 100
    }

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        guard voiceNodes[touchID] == nil else { return }
        let preset = currentPreset

        let voice: any AnyVoice = preset.isOrgan
            ? OrganVoice(note: note, velocity: velocity, preset: preset, sampleRate: sampleRate)
            : SynthVoice(note: note, velocity: velocity, preset: preset, sampleRate: sampleRate)

        voice.filterCutoffMod = x
        voice.lfoDepthMod     = y
        voices[touchID] = voice

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self, weak voice] _, _, frameCount, audioBufferList in
            guard let voice else { return noErr }
            let abl   = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left  = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl[1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frameCount) {
                let s = voice.nextSample()
                left[i] = s; right[i] = s
                self?.feedAnalysis(s)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: voiceMixer, format: format)
        voiceNodes[touchID] = node
        voice.start()
    }

    func noteOff(touchID: Int) {
        voices[touchID]?.release()
        let tail = currentPreset.isOrgan ? 0.15 : Double(currentPreset.release) + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
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
        voices[touchID]?.lfoDepthMod     = y
    }

    // MARK: - Waveform Analysis

    private func feedAnalysis(_ sample: Float) {
        analysisBuffer[analysisIndex % 128] = sample
        analysisIndex += 1
        if analysisIndex % 64 == 0 {
            let snap = analysisBuffer
            DispatchQueue.main.async { [weak self] in self?.waveformSamples = snap }
        }
    }
}
