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

    // Single master source node — all synth voices summed here, effects applied once.
    private var masterNode: AVAudioSourceNode?

    // MARK: - Master effect chain (single shared set, not per-voice)
    // Initialised lazily so sampleRate is available; first accessed in setupMasterNode()
    // which always runs before the audio thread starts.
    private lazy var masterMod        = ModulationProcessor(sampleRate: sampleRate)
    private lazy var masterLofiL      = LofiProcessor()
    private lazy var masterLofiR      = LofiProcessor()
    private lazy var masterSpaceEchoL = SpaceEchoProcessor(sampleRate: sampleRate)
    private lazy var masterSpaceEchoR = SpaceEchoProcessor(sampleRate: sampleRate)
    private lazy var masterGrit       = GritProcessor()
    private lazy var masterTapeL      = BrokenTapeDelay(sampleRate: sampleRate)
    private lazy var masterTapeR      = BrokenTapeDelay(sampleRate: sampleRate)
    private lazy var masterBloom      = BloomReverbProcessor(sampleRate: sampleRate)
    private lazy var masterPhaserL    = PhaserProcessor(sampleRate: sampleRate)
    private lazy var masterPhaserR    = PhaserProcessor(sampleRate: sampleRate, lfoPhaseOffset: 0.5)
    private lazy var masterAutoWahL   = AutoWahProcessor(sampleRate: sampleRate)
    private lazy var masterAutoWahR   = AutoWahProcessor(sampleRate: sampleRate)
    private lazy var masterModDelayL  = ModulatingDelayProcessor(sampleRate: sampleRate, lfoRate: 0.33)
    private lazy var masterModDelayR  = ModulatingDelayProcessor(sampleRate: sampleRate, lfoRate: 0.37)

    // MARK: - State
    private(set) var voices: [Int: any AnyVoice] = [:]
    // Protects `voices` and `voiceGainBoxes` between main thread and audio render thread.
    private let voicesLock = NSLock()

    // Non-nil only for layer-mode voices; single-mode voices use implicit gain 1.0.
    private var voiceGainBoxes: [Int: GainBox] = [:]

    // Sampler nodes (one per instrument, lazily created)
    private var samplerEngines: [String: SamplerEngine] = [:]
    // touchID → (instrumentID, midiNote) for single mode; compound ID for layer mode
    private var samplerTouches: [Int: (instrumentID: String, note: Int)] = [:]

    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 128)
    @Published var currentPreset: SynthPreset = SynthPreset.presets[0]

    // MARK: - Layer mode
    @Published var isLayeringMode    = false
    @Published var activeLayerIndices: [Int] = []
    @Published var primaryLayerIndex: Int?

    // Gain boxes keyed by preset index; shared with voiceGainBoxes entries for render.
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
            AVAudioConnectionPoint(node: delay,         bus: 0),
            AVAudioConnectionPoint(node: shimmerReverb, bus: 0)
        ], fromBus: 0, format: stereo)

        timePitch.pitch  = 1200
        timePitch.rate   = 1.0
        shimmerMixer.outputVolume = 0

        // Headroom for sampler nodes; synth voices are summed before voiceMixer so they
        // arrive as one stream regardless of layer count.
        voiceMixer.outputVolume = 0.55

        setupMasterNode()

        applyPreset(currentPreset)
        try? engine.start()
        observeAudioSession()
    }

    private func setupMasterNode() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Touch all lazy effect processors to initialise them on the main thread before
        // the audio thread starts reading them.
        _ = masterMod; _ = masterLofiL; _ = masterLofiR
        _ = masterSpaceEchoL; _ = masterSpaceEchoR; _ = masterGrit
        _ = masterTapeL; _ = masterTapeR; _ = masterBloom
        _ = masterPhaserL; _ = masterPhaserR
        _ = masterAutoWahL; _ = masterAutoWahR
        _ = masterModDelayL; _ = masterModDelayR

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }

            // Snapshot active voices under lock — keeps main-thread add/remove race-free.
            self.voicesLock.lock()
            let voiceSnapshot = self.voices
            let gainSnapshot  = self.voiceGainBoxes
            self.voicesLock.unlock()

            let p     = self.currentPreset
            let abl   = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left  = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl[1].mData!.assumingMemoryBound(to: Float.self)

            for i in 0..<Int(frameCount) {
                var l: Float = 0.0
                var r: Float = 0.0

                // Sum all active voices before any effects processing.
                for (id, voice) in voiceSnapshot {
                    if let ov = voice as? OrganVoice { ov.tremulantDepth = p.tremulantDepth }
                    let (vl, vr) = voice.nextStereoSample()
                    let gain = gainSnapshot[id]?.value ?? 1.0
                    l += vl * gain
                    r += vr * gain
                }

                // Effects chain applied ONCE on the summed signal.
                l = self.masterAutoWahL.process(l, amount: p.autoWahAmount)
                r = self.masterAutoWahR.process(r, amount: p.autoWahAmount)

                l = self.masterGrit.process(l, amount: p.gritAmount)
                r = self.masterGrit.process(r, amount: p.gritAmount)

                l = self.masterLofiL.process(l, amount: p.lofiAmount)
                r = self.masterLofiR.process(r, amount: p.lofiAmount)

                l = self.masterSpaceEchoL.process(l, amount: p.spaceEchoAmount)
                r = self.masterSpaceEchoR.process(r, amount: p.spaceEchoAmount)

                let btAmt = p.brokenTape
                l = self.masterTapeL.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                r = self.masterTapeR.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)

                let blAmt = p.bloomAmount
                if blAmt > 0.005 {
                    let (bl, br) = self.masterBloom.process((l + r) * 0.5, amount: blAmt)
                    l = l * (1.0 - blAmt * 0.3) + bl
                    r = r * (1.0 - blAmt * 0.3) + br
                }

                let (ml, mr) = self.masterMod.process(l: l, r: r,
                                                       tremDepth: p.tremulantDepth,
                                                       chorusMix: p.chorusMix)
                l = ml; r = mr

                l = tubeSaturate(l, drive: p.distortionAmount)
                r = tubeSaturate(r, drive: p.distortionAmount)

                l = self.masterPhaserL.process(l, amount: p.phaserAmount)
                r = self.masterPhaserR.process(r, amount: p.phaserAmount)

                l = self.masterModDelayL.process(l, amount: p.modDelayAmount)
                r = self.masterModDelayR.process(r, amount: p.modDelayAmount)

                left[i]  = l
                right[i] = r
                self.feedAnalysis((l + r) * 0.5)
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: voiceMixer, format: format)
        masterNode = node
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
        if engine.isRunning { engine.stop() }
        // Detach old master node before reset so stale render callbacks are not called.
        if let old = masterNode { engine.detach(old); masterNode = nil }
        // Reset clears stale delay/reverb buffers accumulated during AirPlay;
        // without this the echo tail plays back corrupted and sounds 8-bit/crunchy.
        engine.reset()
        setupMasterNode()
        try? engine.start()
        applyPreset(currentPreset)
    }

    // MARK: - Layer management

    func enterLayerMode(startingWith presetIndex: Int) {
        isLayeringMode     = true
        activeLayerIndices = [presetIndex]
        primaryLayerIndex  = presetIndex
        ensureGainBox(presetIndex)
    }

    func exitLayerMode() {
        isLayeringMode     = false
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

    // MARK: - Sampler helpers

    @discardableResult
    private func samplerEngine(for instrument: SamplerInstrument) -> SamplerEngine {
        if let existing = samplerEngines[instrument.id] { return existing }
        let se = SamplerEngine(instrument: instrument)
        engine.attach(se.samplerNode)
        engine.connect(se.samplerNode, to: voiceMixer, format: nil)
        samplerEngines[instrument.id] = se
        se.load()
        return se
    }

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        if isLayeringMode && !activeLayerIndices.isEmpty {
            noteOnLayer(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        } else {
            noteOnSingle(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        }
    }

    private func noteOnSingle(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        if case .sampler(let instrument) = currentPreset.voiceMode {
            if let prev = samplerTouches[touchID] {
                samplerEngines[prev.instrumentID]?.noteOff(UInt8(prev.note))
            }
            let se = samplerEngine(for: instrument)
            se.noteOn(UInt8(clamping: note), velocity: UInt8(velocity * 127))
            samplerTouches[touchID] = (instrument.id, note)
            return
        }
        // Remove any existing voice on this touch before spawning a fresh one.
        voicesLock.lock()
        voices.removeValue(forKey: touchID)
        voiceGainBoxes.removeValue(forKey: touchID)
        voicesLock.unlock()

        spawnVoice(id: touchID, preset: currentPreset, note: note, velocity: velocity,
                   x: x, y: y, gainBox: nil)
    }

    private func noteOnLayer(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        // Tear down any layer voices from a previous tap on this touch ID.
        if let prev = noteOnLayerIndices[touchID] {
            for presetIdx in prev {
                let cid = touchID * 1000 + presetIdx
                let p   = SynthPreset.presets[presetIdx]
                if case .sampler = p.voiceMode {
                    if let info = samplerTouches[cid] {
                        samplerEngines[info.instrumentID]?.noteOff(UInt8(info.note))
                    }
                    samplerTouches.removeValue(forKey: cid)
                } else {
                    voicesLock.lock()
                    voices.removeValue(forKey: cid)
                    voiceGainBoxes.removeValue(forKey: cid)
                    voicesLock.unlock()
                }
            }
        }

        for presetIdx in activeLayerIndices {
            let preset = SynthPreset.presets[presetIdx]
            let cid    = touchID * 1000 + presetIdx
            if case .sampler(let instrument) = preset.voiceMode {
                let se = samplerEngine(for: instrument)
                se.noteOn(UInt8(clamping: note), velocity: UInt8(velocity * 127))
                samplerTouches[cid] = (instrument.id, note)
            } else {
                let gainBox = ensureGainBox(presetIdx)
                spawnVoice(id: cid, preset: preset, note: note, velocity: velocity,
                           x: x, y: y, gainBox: gainBox)
            }
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
        case .sampler:
            return  // sampler voices are handled before spawnVoice is reached
        }

        voice.filterCutoffMod = x
        voice.lfoDepthMod     = y

        voicesLock.lock()
        voices[id] = voice
        if let gb = gainBox { voiceGainBoxes[id] = gb }
        voicesLock.unlock()

        voice.start()
    }

    func noteOff(touchID: Int) {
        if isLayeringMode, let layerIndices = noteOnLayerIndices[touchID] {
            for presetIdx in layerIndices {
                let cid    = touchID * 1000 + presetIdx
                let preset = SynthPreset.presets[presetIdx]
                if case .sampler = preset.voiceMode {
                    if let info = samplerTouches[cid] {
                        samplerEngines[info.instrumentID]?.noteOff(UInt8(info.note))
                    }
                    samplerTouches.removeValue(forKey: cid)
                } else {
                    releaseVoice(id: cid, preset: preset)
                }
            }
            noteOnLayerIndices.removeValue(forKey: touchID)
        } else if case .sampler = currentPreset.voiceMode {
            if let info = samplerTouches[touchID] {
                samplerEngines[info.instrumentID]?.noteOff(UInt8(info.note))
            }
            samplerTouches.removeValue(forKey: touchID)
        } else {
            releaseVoice(id: touchID, preset: currentPreset)
        }
    }

    private func releaseVoice(id: Int, preset: SynthPreset) {
        voicesLock.lock()
        let voice = voices[id]
        voicesLock.unlock()

        voice?.release()

        let tail: Double
        switch preset.voiceMode {
        case .hammondB3:   tail = 0.1
        case .organChurch: tail = 0.15
        case .rhodes:      tail = 3.0
        case .synth:       tail = Double(preset.release) + 0.1
        case .sampler:     tail = 0.5  // unreachable; sampler noteOff is handled separately
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self else { return }
            self.voicesLock.lock()
            self.voices.removeValue(forKey: id)
            self.voiceGainBoxes.removeValue(forKey: id)
            self.voicesLock.unlock()
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
