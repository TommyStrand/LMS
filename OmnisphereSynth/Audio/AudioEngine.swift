import AVFoundation

final class AudioEngine: ObservableObject {

    // MARK: - Nodes
    private let engine        = AVAudioEngine()
    var avEngine: AVAudioEngine { engine }
    private let voiceMixer    = AVAudioMixerNode()
    private let reverb        = AVAudioUnitReverb()
    private let delay         = AVAudioUnitDelay()

    // Shimmer path
    private let shimmerReverb = AVAudioUnitReverb()
    private let timePitch     = AVAudioUnitTimePitch()
    private let shimmerMixer  = AVAudioMixerNode()

    // Effects are created fresh per-voice in noteOn — no shared instances.

    // MARK: - State
    private(set) var voices: [Int: any AnyVoice] = [:]
    private var voiceNodes:    [Int: AVAudioSourceNode] = [:]
    private var voiceMods:     [Int: ModulationProcessor] = [:]

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

        [voiceMixer, reverb, delay,
         shimmerReverb, timePitch, shimmerMixer].forEach { engine.attach($0) }

        // Main path (no more AVAudioUnitDistortion — tube saturation done per-voice)
        engine.connect(reverb, to: delay,                format: nil)
        engine.connect(delay,  to: engine.mainMixerNode, format: nil)

        // Shimmer path
        engine.connect(shimmerReverb, to: timePitch,            format: nil)
        engine.connect(timePitch,     to: shimmerMixer,         format: nil)
        engine.connect(shimmerMixer,  to: engine.mainMixerNode, format: nil)

        // Fan-out voiceMixer → reverb + shimmerReverb (multi-destination)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(voiceMixer, to: [
            AVAudioConnectionPoint(node: reverb,        bus: 0),
            AVAudioConnectionPoint(node: shimmerReverb, bus: 0)
        ], fromBus: 0, format: stereo)

        timePitch.pitch  = 1200
        timePitch.rate   = 1.0
        shimmerMixer.outputVolume = 0

        // Headroom: each voice peaks near 1.0, so several stacked voices can
        // clip the bus. Attenuating here prevents the clipping transients
        // that the delay/reverb tail would otherwise expose as clicks.
        voiceMixer.outputVolume = 0.55

        applyPreset(currentPreset)
        try? engine.start()
    }

    // MARK: - Preset

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset

        reverb.loadFactoryPreset(preset.isOrgan ? .cathedral : .largeChamber)
        reverb.wetDryMix = preset.reverbMix * 100

        delay.wetDryMix = preset.delayMix * 100
        delay.delayTime = Double(preset.delayTime)
        delay.feedback  = 28

        shimmerReverb.loadFactoryPreset(.plate)
        shimmerReverb.wetDryMix = 80
        shimmerMixer.outputVolume = preset.shimmerAmount * 0.45
    }

    // MARK: - Live knob updates

    func setDistortion(_ v: Float) { currentPreset.distortionAmount = v }
    func setShimmer(_ v: Float)    { currentPreset.shimmerAmount = v; shimmerMixer.outputVolume = v * 0.45 }
    func setReverb(_ v: Float)     { currentPreset.reverbMix = v;     reverb.wetDryMix = v * 100 }
    func setDelay(_ v: Float)      { currentPreset.delayMix = v;      delay.wetDryMix = v * 100 }
    func setTremolo(_ v: Float)    { currentPreset.tremulantDepth = v }
    func setChorus(_ v: Float)     { currentPreset.chorusMix = v }
    func setLofi(_ v: Float)       { currentPreset.lofiAmount = v }
    func setSpaceEcho(_ v: Float)  { currentPreset.spaceEchoAmount = v }
    func setBrokenTape(_ v: Float) { currentPreset.brokenTape = v }
    func setGrit(_ v: Float)       { currentPreset.gritAmount = v }
    func setBloom(_ v: Float)      { currentPreset.bloomAmount = v }
    func setPhaser(_ v: Float)     { currentPreset.phaserAmount = v }
    func setAutoWah(_ v: Float)    { currentPreset.autoWahAmount = v }
    func setModDelay(_ v: Float)   { currentPreset.modDelayAmount = v }

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        // Tear down any existing voice for this ID — handles touch-ID reuse (iOS
        // recycles UITouch memory addresses) and rapid re-taps during the tail window.
        if let existing = voiceNodes[touchID] {
            engine.detach(existing)
            voiceNodes.removeValue(forKey: touchID)
            voices.removeValue(forKey: touchID)
            voiceMods.removeValue(forKey: touchID)
        }
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

        let mod = ModulationProcessor(sampleRate: sampleRate)
        voiceMods[touchID] = mod

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Fresh effect instances per voice — every render block gets its own state,
        // preventing data races when multiple voices play concurrently.
        let sr           = sampleRate
        let lofiRef      = (LofiProcessor(), LofiProcessor())
        let spaceEchoRef = (SpaceEchoProcessor(sampleRate: sr), SpaceEchoProcessor(sampleRate: sr))
        let gritRef      = GritProcessor()
        let tapeRef      = (BrokenTapeDelay(sampleRate: sr), BrokenTapeDelay(sampleRate: sr))
        let bloomRef     = BloomReverbProcessor(sampleRate: sr)
        let phaserRef    = (PhaserProcessor(sampleRate: sr),
                            PhaserProcessor(sampleRate: sr, lfoPhaseOffset: 0.5))
        let autoWahRef   = (AutoWahProcessor(sampleRate: sr), AutoWahProcessor(sampleRate: sr))
        let modDelayRef  = (ModulatingDelayProcessor(sampleRate: sr, lfoRate: 0.33),
                            ModulatingDelayProcessor(sampleRate: sr, lfoRate: 0.37))

        // mod is captured strongly so tremolo/chorus persist through the full note tail.
        let node = AVAudioSourceNode(format: format) { [weak self, weak voice] _, _, frameCount, audioBufferList in
            guard let self, let voice else { return noErr }
            let preset = self.currentPreset

            // Sync live-knob param that OrganVoice captures at init time
            if let ov = voice as? OrganVoice { ov.tremulantDepth = preset.tremulantDepth }

            let abl   = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left  = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl[1].mData!.assumingMemoryBound(to: Float.self)

            for i in 0..<Int(frameCount) {
                var (l, r) = voice.nextStereoSample()

                // Auto-Wah (before grit: envelope filter shapes voice before distortion)
                l = autoWahRef.0.process(l, amount: preset.autoWahAmount)
                r = autoWahRef.1.process(r, amount: preset.autoWahAmount)

                // Grit
                l = gritRef.process(l, amount: preset.gritAmount)
                r = gritRef.process(r, amount: preset.gritAmount)

                // Lo-Fi
                l = lofiRef.0.process(l, amount: preset.lofiAmount)
                r = lofiRef.1.process(r, amount: preset.lofiAmount)

                // Space Echo (independent L/R instances for natural stereo spread)
                l = spaceEchoRef.0.process(l, amount: preset.spaceEchoAmount)
                r = spaceEchoRef.1.process(r, amount: preset.spaceEchoAmount)

                // Broken tape delay
                let btAmt = preset.brokenTape
                l = tapeRef.0.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                r = tapeRef.1.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)

                // Bloom Reverb — parallel swell preserves prior-stage stereo width
                let blAmt = preset.bloomAmount
                if blAmt > 0.005 {
                    let (bl, br) = bloomRef.process((l + r) * 0.5, amount: blAmt)
                    l = l * (1.0 - blAmt * 0.3) + bl
                    r = r * (1.0 - blAmt * 0.3) + br
                }

                // Universal modulation: tremolo + chorus
                let (ml, mr) = mod.process(l: l, r: r,
                                           tremDepth: preset.tremulantDepth,
                                           chorusMix: preset.chorusMix)
                l = ml; r = mr

                // Warm tube overdrive
                l = tubeSaturate(l, drive: preset.distortionAmount)
                r = tubeSaturate(r, drive: preset.distortionAmount)

                // Phaser (after saturation: sweeps the harmonically-rich tone)
                l = phaserRef.0.process(l, amount: preset.phaserAmount)
                r = phaserRef.1.process(r, amount: preset.phaserAmount)

                // Modulating Delay (last in chain: warps the full processed signal)
                l = modDelayRef.0.process(l, amount: preset.modDelayAmount)
                r = modDelayRef.1.process(r, amount: preset.modDelayAmount)

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
        case .hammondB3:   tail = 0.1
        case .organChurch: tail = 0.15
        case .rhodes:      tail = 3.0
        case .synth:       tail = Double(currentPreset.release) + 0.1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self else { return }
            if let node = self.voiceNodes[touchID] {
                self.engine.detach(node)
                self.voiceNodes.removeValue(forKey: touchID)
                self.voices.removeValue(forKey: touchID)
                self.voiceMods.removeValue(forKey: touchID)
            }
        }
    }

    func updateTouch(touchID: Int, x: Float, y: Float) {
        voices[touchID]?.filterCutoffMod = x
        voices[touchID]?.lfoDepthMod     = y
    }

    func updateGlissando(touchID: Int, semitones: Float, x: Float, y: Float) {
        voices[touchID]?.pitchBendSemitones = semitones
        voices[touchID]?.filterCutoffMod    = x
        voices[touchID]?.lfoDepthMod        = y
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
