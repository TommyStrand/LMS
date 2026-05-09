import AVFoundation

final class AudioEngine: ObservableObject {

    // MARK: - Nodes
    private let engine        = AVAudioEngine()
    private let voiceMixer    = AVAudioMixerNode()
    private let distortion    = AVAudioUnitDistortion()
    private let reverb        = AVAudioUnitReverb()
    private let delay         = AVAudioUnitDelay()

    // Shimmer path
    private let shimmerReverb = AVAudioUnitReverb()
    private let timePitch     = AVAudioUnitTimePitch()
    private let shimmerMixer  = AVAudioMixerNode()

    // MARK: - Per-instance texture effects (L+R channels)
    private var lofi   = (LofiProcessor(),   LofiProcessor())
    private var vinyl  = (VinylProcessor(sampleRate: 44100), VinylProcessor(sampleRate: 44100))
    private var grit   = GritProcessor()
    private var tape   = (BrokenTapeDelay(sampleRate: 44100), BrokenTapeDelay(sampleRate: 44100))
    private var doubler = DoublerProcessor(sampleRate: 44100)

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

        // Main path
        engine.connect(distortion,   to: reverb,              format: nil)
        engine.connect(reverb,       to: delay,               format: nil)
        engine.connect(delay,        to: engine.mainMixerNode, format: nil)

        // Shimmer path
        engine.connect(shimmerReverb, to: timePitch,          format: nil)
        engine.connect(timePitch,     to: shimmerMixer,       format: nil)
        engine.connect(shimmerMixer,  to: engine.mainMixerNode, format: nil)

        // Fan-out voiceMixer → both chains (must use multi-destination API)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(voiceMixer, to: [
            AVAudioConnectionPoint(node: distortion,   bus: 0),
            AVAudioConnectionPoint(node: shimmerReverb, bus: 0)
        ], fromBus: 0, format: stereo)

        timePitch.pitch  = 1200
        timePitch.rate   = 1.0
        shimmerMixer.outputVolume = 0

        applyPreset(currentPreset)
        try? engine.start()
    }

    // MARK: - Preset

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset

        reverb.loadFactoryPreset(preset.isOrgan ? .cathedral : .largeChamber)
        reverb.wetDryMix = preset.reverbMix * 100

        delay.wetDryMix  = preset.delayMix * 100
        delay.delayTime  = Double(preset.delayTime)
        delay.feedback   = 28

        distortion.loadFactoryPreset(.multiDistortedFunk)
        distortion.preGain   = preset.distortionAmount * 18
        distortion.wetDryMix = preset.distortionAmount > 0 ? 40 + preset.distortionAmount * 55 : 0

        shimmerReverb.loadFactoryPreset(.plate)
        shimmerReverb.wetDryMix = 80
        shimmerMixer.outputVolume = preset.shimmerAmount * 0.45
    }

    // MARK: - Live knob updates

    func setDistortion(_ v: Float) { currentPreset.distortionAmount = v; distortion.preGain = v * 18; distortion.wetDryMix = v > 0.01 ? 40 + v * 55 : 0 }
    func setShimmer(_ v: Float)    { currentPreset.shimmerAmount = v; shimmerMixer.outputVolume = v * 0.45 }
    func setReverb(_ v: Float)     { currentPreset.reverbMix = v; reverb.wetDryMix = v * 100 }
    func setDelay(_ v: Float)      { currentPreset.delayMix = v; delay.wetDryMix = v * 100 }
    func setLofi(_ v: Float)       { currentPreset.lofiAmount = v }
    func setVinyl(_ v: Float)      { currentPreset.vinylAmount = v }
    func setBrokenTape(_ v: Float) { currentPreset.brokenTape = v }
    func setGrit(_ v: Float)       { currentPreset.gritAmount = v }
    func setDoubler(_ v: Float)    { currentPreset.doublerAmount = v }

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        guard voiceNodes[touchID] == nil else { return }
        let preset = currentPreset

        let voice: any AnyVoice
        switch preset.voiceMode {
        case .organChurch:
            voice = OrganVoice(note: note, velocity: velocity, preset: preset, sampleRate: sampleRate)
        case .hammondB3:
            voice = HammondVoice(note: note, velocity: velocity, sampleRate: sampleRate)
        case .rhodes:
            voice = RhodesVoice(note: note, velocity: velocity, sampleRate: sampleRate)
        case .synth:
            voice = SynthVoice(note: note, velocity: velocity, preset: preset, sampleRate: sampleRate)
        }

        voice.filterCutoffMod = x
        voice.lfoDepthMod     = y
        voices[touchID] = voice

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Capture effect state by value at note-on time so render callback reads consistent params
        let lofiRef   = lofi
        let vinylRef  = vinyl
        let gritRef   = grit
        let tapeRef   = tape
        let doublerRef = doubler

        let node = AVAudioSourceNode(format: format) { [weak self, weak voice] _, _, frameCount, audioBufferList in
            guard let self, let voice else { return noErr }
            let preset = self.currentPreset
            let abl    = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left   = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right  = abl[1].mData!.assumingMemoryBound(to: Float.self)

            for i in 0..<Int(frameCount) {
                var (l, r) = voice.nextStereoSample()

                // Grit (mono before doubler)
                let gAmt = preset.gritAmount
                l = gritRef.process(l, amount: gAmt)
                r = gritRef.process(r, amount: gAmt)

                // Lo-Fi
                let lfAmt = preset.lofiAmount
                l = lofiRef.0.process(l, amount: lfAmt)
                r = lofiRef.1.process(r, amount: lfAmt)

                // Vinyl
                let viAmt = preset.vinylAmount
                l = vinylRef.0.process(l, amount: viAmt)
                r = vinylRef.1.process(r, amount: viAmt)

                // Broken tape delay
                let btAmt = preset.brokenTape
                l = tapeRef.0.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                r = tapeRef.1.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)

                // Doubler
                let dAmt = preset.doublerAmount
                let (dl, dr) = doublerRef.process(l, amount: dAmt)
                l = dl; r = dr

                left[i]  = l
                right[i] = r
                self.feedAnalysis((l + r) * 0.5)
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
        let tail: Double
        switch currentPreset.voiceMode {
        case .hammondB3:  tail = 0.1
        case .organChurch: tail = 0.15
        case .rhodes:     tail = 3.0
        case .synth:      tail = Double(currentPreset.release) + 0.1
        }
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
