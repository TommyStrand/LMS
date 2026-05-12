import AVFoundation

// Per-layer gain — written from main thread, read from render thread.
// A class so the render closure can hold a strong reference that stays valid
// even after the layer is removed from the active set.
private final class GainBox { var value: Float = 1.0 }

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

    // MARK: - Layer mode
    @Published var isLayeringMode    = false
    @Published var activeLayerIndices: [Int] = []   // preset indices that are ON
    @Published var primaryLayerIndex: Int?          // controls panel follows this one

    // Gain boxes keyed by preset index; captured strongly by layer render closures.
    private var layerGainBoxes:     [Int: GainBox] = [:]
    // Tracks which preset indices were layered at each noteOn, for correct noteOff cleanup.
    private var noteOnLayerIndices: [Int: [Int]]   = [:]

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

        // Main path: delay first, then reverb — echoes are placed inside the room,
        // and the reverb's diffuse tail is never itself fed back into the delay.
        engine.connect(delay,  to: reverb,                format: nil)
        engine.connect(reverb, to: engine.mainMixerNode,  format: nil)

        // Shimmer path
        engine.connect(shimmerReverb, to: timePitch,            format: nil)
        engine.connect(timePitch,     to: shimmerMixer,         format: nil)
        engine.connect(shimmerMixer,  to: engine.mainMixerNode, format: nil)

        // Fan-out voiceMixer → delay + shimmerReverb (multi-destination)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(voiceMixer, to: [
            AVAudioConnectionPoint(node: delay,        bus: 0),
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
        observeAudioSession()
    }

    // MARK: - Route / interruption recovery

    private func observeAudioSession() {
        // AVAudioEngine stops automatically when the hardware route changes (AirPlay
        // connect/disconnect, headphone insert/remove). We must restart it ourselves.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in self?.restartEngineIfNeeded() }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard
                let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: v) == .ended
            else { return }
            self?.restartEngineIfNeeded()
        }

        // Belt-and-suspenders: if a route change silently stopped the engine, recover.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.restartEngineIfNeeded()
        }
    }

    private func restartEngineIfNeeded() {
        // Re-apply session settings — category/rate can drift after an AirPlay handoff.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)
        // Reset clears stale delay/reverb buffers accumulated during AirPlay;
        // without this the echo tail plays back corrupted and sounds 8-bit/crunchy.
        if engine.isRunning { engine.stop() }
        engine.reset()
        try? engine.start()
        applyPreset(currentPreset)
    }

    // MARK: - Layer management

    func enterLayerMode(startingWith presetIndex: Int) {
        isLayeringMode    = true
        activeLayerIndices = [presetIndex]
        primaryLayerIndex  = presetIndex
        ensureGainBox(presetIndex)
    }

    func exitLayerMode() {
        isLayeringMode    = false
        activeLayerIndices = []
        primaryLayerIndex  = nil
    }

    func toggleLayer(presetIndex: Int) {
        if let pos = activeLayerIndices.firstIndex(of: presetIndex) {
            activeLayerIndices.remove(at: pos)
            if primaryLayerIndex == presetIndex {
                primaryLayerIndex = activeLayerIndices.last
            }
            if activeLayerIndices.isEmpty { exitLayerMode() }
        } else {
            ensureGainBox(presetIndex)
            activeLayerIndices.append(presetIndex)
            primaryLayerIndex = presetIndex
        }
        objectWillChange.send()
    }

    func layerGain(for presetIndex: Int) -> Float {
        layerGainBoxes[presetIndex]?.value ?? 1.0
    }

    func setLayerGain(_ gain: Float, for presetIndex: Int) {
        layerGainBoxes[presetIndex]?.value = max(0.05, min(1, gain))
        objectWillChange.send()
    }

    @discardableResult
    private func ensureGainBox(_ presetIndex: Int) -> GainBox {
        if let box = layerGainBoxes[presetIndex] { return box }
        let box = GainBox()
        layerGainBoxes[presetIndex] = box
        return box
    }

    // MARK: - Preset

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset

        reverb.loadFactoryPreset(preset.isOrgan ? .cathedral : .largeChamber)
        reverb.wetDryMix = preset.reverbMix * 100

        delay.wetDryMix     = preset.delayMix * 100
        delay.delayTime     = Double(preset.delayTime)
        delay.feedback      = 28
        // Roll off high frequencies in echoes — keeps repeats warm and masks
        // any transient content (key clicks, attack edges) from clicking.
        delay.lowPassCutoff = 4000

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
        if isLayeringMode && !activeLayerIndices.isEmpty {
            noteOnLayer(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        } else {
            noteOnSingle(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        }
    }

    private func noteOnSingle(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        if let existing = voiceNodes[touchID] {
            engine.detach(existing)
            voiceNodes.removeValue(forKey: touchID)
            voices.removeValue(forKey: touchID)
            voiceMods.removeValue(forKey: touchID)
        }
        spawnVoice(id: touchID, preset: currentPreset, note: note, velocity: velocity,
                   x: x, y: y, gainBox: nil)
    }

    private func noteOnLayer(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        // Tear down any layer voices from a previous tap on this touch ID.
        if let prev = noteOnLayerIndices[touchID] {
            for presetIdx in prev {
                let cid = touchID * 1000 + presetIdx
                if let n = voiceNodes[cid] { engine.detach(n) }
                voiceNodes.removeValue(forKey: cid)
                voices.removeValue(forKey: cid)
                voiceMods.removeValue(forKey: cid)
            }
        }

        for presetIdx in activeLayerIndices {
            let preset    = SynthPreset.presets[presetIdx]
            let gainBox   = ensureGainBox(presetIdx)
            let cid       = touchID * 1000 + presetIdx
            spawnVoice(id: cid, preset: preset, note: note, velocity: velocity,
                       x: x, y: y, gainBox: gainBox)
        }
        noteOnLayerIndices[touchID] = activeLayerIndices
    }

    // Shared voice-creation core. `gainBox` nil → single mode (gain = 1.0 always).
    // `gainBox` non-nil → layer mode (gain read live from box each audio buffer).
    private func spawnVoice(id: Int, preset: SynthPreset, note: Int, velocity: Float,
                            x: Float, y: Float, gainBox: GainBox?) {
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
        voices[id] = voice

        let mod = ModulationProcessor(sampleRate: sampleRate)
        voiceMods[id] = mod

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let sr     = sampleRate

        // Fresh effect instances per voice — state is per-voice, not shared.
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

        // For single mode: read self.currentPreset each callback (live knob updates).
        // For layer mode:  read capturedPreset (snapshot) + gainBox (live gain).
        let capturedPreset = preset
        let isLayer        = gainBox != nil

        let node = AVAudioSourceNode(format: format) { [weak self, weak voice] _, _, frameCount, audioBufferList in
            guard let self, let voice else { return noErr }
            let p = isLayer ? capturedPreset : self.currentPreset

            if let ov = voice as? OrganVoice { ov.tremulantDepth = p.tremulantDepth }

            let abl   = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left  = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl[1].mData!.assumingMemoryBound(to: Float.self)
            let gain  = gainBox?.value ?? 1.0   // read once per buffer for smooth fades

            for i in 0..<Int(frameCount) {
                var (l, r) = voice.nextStereoSample()

                l = autoWahRef.0.process(l, amount: p.autoWahAmount)
                r = autoWahRef.1.process(r, amount: p.autoWahAmount)

                l = gritRef.process(l, amount: p.gritAmount)
                r = gritRef.process(r, amount: p.gritAmount)

                l = lofiRef.0.process(l, amount: p.lofiAmount)
                r = lofiRef.1.process(r, amount: p.lofiAmount)

                l = spaceEchoRef.0.process(l, amount: p.spaceEchoAmount)
                r = spaceEchoRef.1.process(r, amount: p.spaceEchoAmount)

                let btAmt = p.brokenTape
                l = tapeRef.0.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                r = tapeRef.1.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)

                let blAmt = p.bloomAmount
                if blAmt > 0.005 {
                    let (bl, br) = bloomRef.process((l + r) * 0.5, amount: blAmt)
                    l = l * (1.0 - blAmt * 0.3) + bl
                    r = r * (1.0 - blAmt * 0.3) + br
                }

                let (ml, mr) = mod.process(l: l, r: r,
                                           tremDepth: p.tremulantDepth,
                                           chorusMix: p.chorusMix)
                l = ml; r = mr

                l = tubeSaturate(l, drive: p.distortionAmount)
                r = tubeSaturate(r, drive: p.distortionAmount)

                l = phaserRef.0.process(l, amount: p.phaserAmount)
                r = phaserRef.1.process(r, amount: p.phaserAmount)

                l = modDelayRef.0.process(l, amount: p.modDelayAmount)
                r = modDelayRef.1.process(r, amount: p.modDelayAmount)

                left[i]  = l * gain
                right[i] = r * gain
                self.feedAnalysis((l + r) * 0.5)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: voiceMixer, format: format)
        voiceNodes[id] = node
        voice.start()
    }

    func noteOff(touchID: Int) {
        if isLayeringMode, let layerIndices = noteOnLayerIndices[touchID] {
            for presetIdx in layerIndices {
                let cid    = touchID * 1000 + presetIdx
                let preset = SynthPreset.presets[presetIdx]
                releaseVoice(id: cid, preset: preset)
            }
            noteOnLayerIndices.removeValue(forKey: touchID)
        } else {
            releaseVoice(id: touchID, preset: currentPreset)
        }
    }

    private func releaseVoice(id: Int, preset: SynthPreset) {
        voices[id]?.release()
        let tail: Double
        switch preset.voiceMode {
        case .hammondB3:   tail = 0.1
        case .organChurch: tail = 0.15
        case .rhodes:      tail = 3.0
        case .synth:       tail = Double(preset.release) + 0.1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self else { return }
            if let node = self.voiceNodes[id] {
                self.engine.detach(node)
                self.voiceNodes.removeValue(forKey: id)
                self.voices.removeValue(forKey: id)
                self.voiceMods.removeValue(forKey: id)
            }
        }
    }

    func updateTouch(touchID: Int, x: Float, y: Float) {
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                let v = voices[touchID * 1000 + presetIdx]
                v?.filterCutoffMod = x; v?.lfoDepthMod = y
            }
        } else {
            voices[touchID]?.filterCutoffMod = x
            voices[touchID]?.lfoDepthMod     = y
        }
    }

    func updateGlissando(touchID: Int, semitones: Float, x: Float, y: Float) {
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                let v = voices[touchID * 1000 + presetIdx]
                v?.pitchBendSemitones = semitones
                v?.filterCutoffMod    = x; v?.lfoDepthMod = y
            }
        } else {
            voices[touchID]?.pitchBendSemitones = semitones
            voices[touchID]?.filterCutoffMod    = x
            voices[touchID]?.lfoDepthMod        = y
        }
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
