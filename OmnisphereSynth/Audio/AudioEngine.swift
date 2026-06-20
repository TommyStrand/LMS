import AVFoundation
import CoreAudio

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

    // voices / voiceGainBoxes are keyed by a unique, monotonically increasing
    // voiceID — NOT the touchID. UIKit recycles UITouch objects, so a rapid re-tap
    // of the same key reuses its touchID; keying voices by touchID meant a re-tap
    // hard-removed the still-sounding previous voice (a one-sample amplitude drop =
    // click, fed straight into the delay), and a stale removal timer could then kill
    // the new voice. A unique id lets the old voice ring out its release tail next to
    // the new one. controlToVoiceID maps a control id (touchID, or touchID*1000+
    // presetIdx in layer mode) to its current live voiceID. Main-thread only.
    private var nextVoiceID = 1
    private var controlToVoiceID: [Int: Int] = [:]

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

    // Serialises audio-session activation and engine start/restart off the main
    // thread. AVAudioSession.setActive(_:) can block long enough to stall the UI,
    // and a serial queue prevents overlapping route-change restarts from racing.
    private let sessionQueue = DispatchQueue(label: "audio.session.control", qos: .userInitiated)

    init() { setupEngine() }

    // MARK: - Setup

    private func setupEngine() {
        // Build the node graph first — attach/connect are object wiring with no
        // blocking I/O, so they're fast and safe on the main thread. Session
        // activation and engine start happen afterwards, off the main thread.
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

        // Activate the session and start the engine off the main thread, then
        // register the route/interruption observers (after start, so the initial
        // configuration-change notification can't trigger a redundant restart).
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 10 ms IO buffer: halves render-callback overhead vs 5 ms (fewer
            // callbacks → less fixed per-buffer cost) while staying low-latency
            // enough for a touch instrument.
            self.configureSession(bufferDuration: 0.01)
            try? self.engine.start()
            DispatchQueue.main.async { self.observeAudioSession() }
        }
    }

    /// Applies category, preferred rate/buffer and activates the session. Must be
    /// called off the main thread — `setActive(_:)` can block long enough to stall
    /// the UI (and logs a main-thread warning).
    private func configureSession(bufferDuration: Double) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(bufferDuration)
        try? session.setActive(true)
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

            let p   = self.currentPreset
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let ld = abl[0].mData, let rd = abl[1].mData else { return noErr }
            let left  = ld.assumingMemoryBound(to: Float.self)
            let right = rd.assumingMemoryBound(to: Float.self)

            // Decide which effects are active ONCE per buffer. Skipping disabled
            // effects is what keeps idle/light CPU low — previously every one of
            // these custom per-sample processors ran 44 100×/sec regardless of its
            // amount, which pinned the audio thread even in silence.
            let doAutoWah  = p.autoWahAmount    > 0.001
            let doGrit     = p.gritAmount       > 0.001
            let doLofi     = p.lofiAmount       > 0.001
            let doSpace    = p.spaceEchoAmount  > 0.001
            let doTape     = p.brokenTape       > 0.001
            let doBloom    = p.bloomAmount      > 0.005
            let doMod      = p.tremulantDepth   > 0.001 || p.chorusMix > 0.001
            let doDist     = p.distortionAmount > 0.001
            let doPhaser   = p.phaserAmount     > 0.001
            let doModDelay = p.modDelayAmount   > 0.001

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

                // Effects chain applied ONCE on the summed signal — each gated by
                // whether it's actually enabled for the current preset.
                if doAutoWah {
                    l = self.masterAutoWahL.process(l, amount: p.autoWahAmount)
                    r = self.masterAutoWahR.process(r, amount: p.autoWahAmount)
                }
                if doGrit {
                    l = self.masterGrit.process(l, amount: p.gritAmount)
                    r = self.masterGrit.process(r, amount: p.gritAmount)
                }
                if doLofi {
                    l = self.masterLofiL.process(l, amount: p.lofiAmount)
                    r = self.masterLofiR.process(r, amount: p.lofiAmount)
                }
                if doSpace {
                    l = self.masterSpaceEchoL.process(l, amount: p.spaceEchoAmount)
                    r = self.masterSpaceEchoR.process(r, amount: p.spaceEchoAmount)
                }
                if doTape {
                    let btAmt = p.brokenTape
                    l = self.masterTapeL.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                    r = self.masterTapeR.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                }
                if doBloom {
                    let blAmt = p.bloomAmount
                    let (bl, br) = self.masterBloom.process((l + r) * 0.5, amount: blAmt)
                    l = l * (1.0 - blAmt * 0.3) + bl
                    r = r * (1.0 - blAmt * 0.3) + br
                }
                if doMod {
                    let (ml, mr) = self.masterMod.process(l: l, r: r,
                                                          tremDepth: p.tremulantDepth,
                                                          chorusMix: p.chorusMix)
                    l = ml; r = mr
                }
                if doDist {
                    l = tubeSaturate(l, drive: p.distortionAmount)
                    r = tubeSaturate(r, drive: p.distortionAmount)
                }
                if doPhaser {
                    l = self.masterPhaserL.process(l, amount: p.phaserAmount)
                    r = self.masterPhaserR.process(r, amount: p.phaserAmount)
                }
                if doModDelay {
                    l = self.masterModDelayL.process(l, amount: p.modDelayAmount)
                    r = self.masterModDelayR.process(r, amount: p.modDelayAmount)
                }

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
        ) { [weak self] _ in
            Diagnostics.shared.log("Audio config changed (hardware/route)")
            self?.restartEngineIfNeeded()
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: v)
            else { return }
            // Interruptions (calls, Siri, other audio) stop the engine and are a
            // common cause of "audio just died" — record both edges.
            if type == .began {
                Diagnostics.shared.log("⚠︎ Audio interrupted (call/Siri/other app)")
            } else {
                Diagnostics.shared.log("Audio interruption ended — restarting engine")
                self?.restartEngineIfNeeded()
            }
        }

        // Belt-and-suspenders: if a route change silently stopped the engine, recover.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard let self else { return }
            if let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reason = AVAudioSession.RouteChangeReason(rawValue: raw) {
                Diagnostics.shared.log("Output route changed (\(self.routeReasonName(reason)))")
            }
            guard !self.engine.isRunning else { return }
            self.restartEngineIfNeeded()
        }
    }

    private func routeReasonName(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .newDeviceAvailable:       return "device connected"
        case .oldDeviceUnavailable:     return "device removed"
        case .categoryChange:           return "category change"
        case .override:                 return "override"
        case .wakeFromSleep:            return "wake"
        case .noSuitableRouteForCategory: return "no route"
        case .routeConfigurationChange: return "config change"
        case .unknown:                  return "unknown"
        @unknown default:               return "other"
        }
    }

    private func restartEngineIfNeeded() {
        // All session + graph work runs on the serial session queue: setActive(_:)
        // must stay off the main thread, and serialising prevents overlapping
        // route-change restarts from racing each other.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Re-apply session settings — category/rate can drift after an AirPlay handoff.
            self.configureSession(bufferDuration: 0.01)
            if self.engine.isRunning { self.engine.stop() }
            // Detach old master node before reset so stale render callbacks are not called.
            if let old = self.masterNode { self.engine.detach(old); self.masterNode = nil }
            // Reset clears stale delay/reverb buffers accumulated during AirPlay;
            // without this the echo tail plays back corrupted and sounds 8-bit/crunchy.
            self.engine.reset()
            self.setupMasterNode()
            try? self.engine.start()
            // Re-apply node parameters only — do NOT touch the @Published currentPreset
            // from a background thread.
            self.applyPresetToNodes(self.currentPreset)
            Diagnostics.shared.log("Audio engine restarted (route/interruption recovery)")
        }
    }

    // MARK: - Layer management

    func enterLayerMode(startingWith presetIndex: Int) {
        isLayeringMode     = true
        activeLayerIndices = [presetIndex]
        primaryLayerIndex  = presetIndex
        ensureGainBox(presetIndex)
    }

    func exitLayerMode() {
        // Release any voices that were left active from layer-mode note-ons whose
        // noteOff never fired (e.g. sustain held when mode is toggled off).
        for (touchID, layerIndices) in noteOnLayerIndices {
            for presetIdx in layerIndices {
                let cid    = touchID * 1000 + presetIdx
                let preset = SynthPreset.presets[presetIdx]
                if case .sampler = preset.voiceMode {
                    if let info = samplerTouches[cid] {
                        samplerEngines[info.instrumentID]?.noteOff(UInt8(info.note))
                    }
                    samplerTouches.removeValue(forKey: cid)
                } else {
                    retireVoice(controlID: cid, preset: preset)
                }
            }
        }
        noteOnLayerIndices.removeAll()

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

    /// Total sampler slots producing audio across all loaded instruments.
    var samplerActiveVoiceCount: Int {
        samplerEngines.values.reduce(0) { $0 + $1.activeVoiceCount }
    }

    func applyPreset(_ preset: SynthPreset) {
        currentPreset = preset   // @Published — callers must invoke this on main
        Diagnostics.shared.log("Preset → \(preset.name)")
        applyPresetToNodes(preset)
    }

    /// Applies a preset's reverb/delay/shimmer settings to the audio-unit nodes.
    /// Separate from `applyPreset` so it can run on the session queue during an
    /// engine restart without mutating the `@Published` currentPreset off-main.
    private func applyPresetToNodes(_ preset: SynthPreset) {
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
        setShimmerPathActive(preset.shimmerAmount > 0.001)
    }

    /// Bypass the shimmer reverb + pitch-shifter when shimmer is off. The
    /// AVAudioUnitTimePitch runs a phase vocoder continuously otherwise — a real
    /// idle-CPU cost for a path whose output is muted anyway on most presets.
    private func setShimmerPathActive(_ active: Bool) {
        timePitch.auAudioUnit.shouldBypassEffect     = !active
        shimmerReverb.auAudioUnit.shouldBypassEffect = !active
    }

    // MARK: - Live knob updates

    func setDistortion(_ v: Float) { currentPreset.distortionAmount = v }
    func setShimmer(_ v: Float)    { currentPreset.shimmerAmount = v; shimmerMixer.outputVolume = v * 0.45; setShimmerPathActive(v > 0.001) }
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
        se.attach(to: engine)
        engine.connect(se.outputNode, to: voiceMixer, format: nil)
        samplerEngines[instrument.id] = se
        se.load()
        return se
    }

    // MARK: - Looper hook (weak — owned by ContentView's @StateObject)
    weak var looper: LooperEngine?

    // MARK: - Touch Events

    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        // Don't capture playback-originating events back into the looper (they
        // use touchIDs >= 90000 so the looper can skip re-recording its own output).
        if touchID < 90000 { looper?.recordOn(touchID: touchID, note: note,
                                               velocity: velocity, x: x, y: y) }
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
        // Retire any voice still sounding on this touch (e.g. a rapid re-tap that
        // reuses a recycled UITouch id) by RELEASING it — letting its envelope fade
        // out — never by hard-removing it, which would click.
        retireVoice(controlID: touchID, preset: currentPreset)
        spawnVoice(controlID: touchID, preset: currentPreset, note: note, velocity: velocity,
                   x: x, y: y, gainBox: nil)
    }

    private func noteOnLayer(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        // Retire any layer voices from a previous tap on this touch ID (release, not
        // hard-remove — same anti-click reasoning as noteOnSingle).
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
                    retireVoice(controlID: cid, preset: p)
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
                spawnVoice(controlID: cid, preset: preset, note: note, velocity: velocity,
                           x: x, y: y, gainBox: gainBox)
            }
        }
        noteOnLayerIndices[touchID] = activeLayerIndices
    }

    // Shared voice-creation core. `gainBox` nil → single mode (gain = 1.0 always).
    // `gainBox` non-nil → layer mode (gain read live from box each audio buffer).
    // `controlID` is the touch/layer key the caller uses; the voice itself is stored
    // under a fresh unique voiceID so retriggers never collide.
    private func spawnVoice(controlID: Int, preset: SynthPreset, note: Int, velocity: Float,
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
            assertionFailure("spawnVoice reached .sampler — caller must handle sampler notes before this point")
            return
        }

        // Pad Y drives brightness (filter) and modulation intensity uniformly across
        // every voice type; X only selects which note (handled in the view). Feeding
        // the same vertical value to both gives one intuitive "open up" expression
        // axis. (Previously X→filter, Y→LFO depth, so Y did almost nothing on organ/
        // Rhodes/Hammond voices, which ignore the LFO-depth knob.)
        voice.filterCutoffMod = y
        voice.lfoDepthMod     = y
        // Start before inserting into the shared dict so the render thread never
        // sees a voice that hasn't begun generating samples yet.
        voice.start()

        let voiceID = nextVoiceID
        nextVoiceID += 1
        voicesLock.lock()
        voices[voiceID] = voice
        if let gb = gainBox { voiceGainBoxes[voiceID] = gb }
        voicesLock.unlock()
        controlToVoiceID[controlID] = voiceID
    }

    func noteOff(touchID: Int) {
        if touchID < 90000 { looper?.recordOff(touchID: touchID) }
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
                    retireVoice(controlID: cid, preset: preset)
                }
            }
            noteOnLayerIndices.removeValue(forKey: touchID)
        } else if case .sampler = currentPreset.voiceMode {
            if let info = samplerTouches[touchID] {
                samplerEngines[info.instrumentID]?.noteOff(UInt8(info.note))
            }
            samplerTouches.removeValue(forKey: touchID)
        } else {
            retireVoice(controlID: touchID, preset: currentPreset)
        }
    }

    /// Releases the voice currently bound to `controlID` (if any) and schedules its
    /// removal. Clears the control→voice mapping so the control id is free to bind a
    /// fresh voice immediately. No-op when nothing is bound (e.g. first tap).
    private func retireVoice(controlID: Int, preset: SynthPreset) {
        guard let voiceID = controlToVoiceID.removeValue(forKey: controlID) else { return }

        voicesLock.lock()
        let voice = voices[voiceID]
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
            self.voices.removeValue(forKey: voiceID)
            self.voiceGainBoxes.removeValue(forKey: voiceID)
            self.voicesLock.unlock()
        }
    }

    func updateTouch(touchID: Int, x: Float, y: Float) {
        // Y → brightness + modulation (see spawnVoice); X is note-only.
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                let v = liveVoice(controlID: touchID * 1000 + presetIdx)
                v?.filterCutoffMod = y; v?.lfoDepthMod = y
            }
        } else {
            let v = liveVoice(controlID: touchID)
            v?.filterCutoffMod = y
            v?.lfoDepthMod     = y
        }
    }

    func updateGlissando(touchID: Int, semitones: Float, x: Float, y: Float) {
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                let v = liveVoice(controlID: touchID * 1000 + presetIdx)
                v?.pitchBendSemitones = semitones
                v?.filterCutoffMod    = y; v?.lfoDepthMod = y
            }
        } else {
            let v = liveVoice(controlID: touchID)
            v?.pitchBendSemitones = semitones
            v?.filterCutoffMod    = y
            v?.lfoDepthMod        = y
        }
    }

    /// The currently-bound (non-retired) voice for a control id, or nil.
    private func liveVoice(controlID: Int) -> (any AnyVoice)? {
        guard let voiceID = controlToVoiceID[controlID] else { return nil }
        return voices[voiceID]
    }

    // MARK: - Waveform Analysis

    private func feedAnalysis(_ sample: Float) {
        analysisBuffer[analysisIndex % 128] = sample
        analysisIndex += 1
        // Publish at ~30 Hz, NOT every 64 samples (~689 Hz). waveformSamples is
        // @Published, so every update invalidates every view observing the engine;
        // at 689 Hz that re-rendered the whole UI continuously and was a major
        // idle-CPU sink. 30 Hz is smooth for any visualiser and keeps the header's
        // voice-activity indicators live.
        if analysisIndex % 1470 == 0 {
            let snap = analysisBuffer
            DispatchQueue.main.async { [weak self] in self?.waveformSamples = snap }
        }
    }
}
