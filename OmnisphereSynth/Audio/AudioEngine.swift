import AVFoundation
import CoreAudio
import Observation
import os

// Per-layer gain — written from main thread, read from render thread.
// A class so the render closure can hold a strong reference that stays valid
// even after the layer is removed from the active set.
private final class GainBox { var value: Float = 1.0 }

// Just the per-buffer effect scalars the render thread needs, snapshotted from
// `currentPreset` on the main thread. Reading the whole observed SynthPreset
// struct from the render thread is a data race (knob setters mutate it on main);
// copying these few floats under the render lock makes the read well-defined.
// Internal (not private) so the preset→params mapping is unit-testable.
struct RenderParams {
    var autoWah:    Float = 0, grit:  Float = 0, lofi:     Float = 0
    var space:      Float = 0, tape:  Float = 0, bloom:    Float = 0
    var tremulant:  Float = 0, chorus: Float = 0, distortion: Float = 0
    var phaser:     Float = 0, modDelay: Float = 0
    init() {}
    init(_ p: SynthPreset) {
        autoWah = p.autoWahAmount;  grit = p.gritAmount;     lofi = p.lofiAmount
        space   = p.spaceEchoAmount; tape = p.brokenTape;    bloom = p.bloomAmount
        tremulant = p.tremulantDepth; chorus = p.chorusMix;  distortion = p.distortionAmount
        phaser  = p.phaserAmount;    modDelay = p.modDelayAmount
    }

    // MARK: Smoothing (pure — unit-tested)
    //
    // A preset change or a knob turn used to reach the render loop as a STEP: every
    // effect amount jumped between two buffers, which clicks whenever sound is
    // still ringing. The render thread now glides from the values it is using to
    // the published ones. All three helpers are allocation-free.

    /// Field-wise combination of two parameter sets.
    @inline(__always)
    static func combine(_ a: RenderParams, _ b: RenderParams, _ f: (Float, Float) -> Float) -> RenderParams {
        var r = RenderParams()
        r.autoWah = f(a.autoWah, b.autoWah);          r.grit = f(a.grit, b.grit)
        r.lofi = f(a.lofi, b.lofi);                   r.space = f(a.space, b.space)
        r.tape = f(a.tape, b.tape);                   r.bloom = f(a.bloom, b.bloom)
        r.tremulant = f(a.tremulant, b.tremulant);    r.chorus = f(a.chorus, b.chorus)
        r.distortion = f(a.distortion, b.distortion); r.phaser = f(a.phaser, b.phaser)
        r.modDelay = f(a.modDelay, b.modDelay)
        return r
    }

    /// One smoothing step: each value moves `fraction` of the way to its target,
    /// and lands exactly on it once within 0.0005 (so it really reaches 0 and the
    /// effect can switch off).
    func moved(toward target: RenderParams, fraction: Float) -> RenderParams {
        RenderParams.combine(self, target) { v, t in
            let d = t - v
            return (d > -0.0005 && d < 0.0005) ? t : v + d * fraction
        }
    }

    /// Per-sample increment that takes `from` to `to` across `frames` samples.
    static func increment(from: RenderParams, to: RenderParams, frames: Int) -> RenderParams {
        let n = Float(max(1, frames))
        return combine(from, to) { a, b in (b - a) / n }
    }

    mutating func add(_ inc: RenderParams) {
        self = RenderParams.combine(self, inc) { a, b in a + b }
    }
}

// Immutable view of everything the render thread reads, published atomically by
// the main thread. `entries` holds strong refs to the live voices (+ their layer
// gain box); copying it out under the lock is a single array retain.
private struct RenderSnapshot {
    var entries: [(voice: any AnyVoice, gain: GainBox?)] = []
    var params  = RenderParams()
}

// @Observable (iOS 17): SwiftUI tracks exactly which properties a view reads, so
// the 30 Hz `waveformSamples` publish re-renders only the visualiser, not every
// view holding the engine.
//
// REAL-TIME RULE: @Observable synthesises tracking accessors for every stored
// `var`, and those go through the ObservationRegistrar (a lock + possible
// allocation). Anything the audio render thread touches MUST therefore be
// `@ObservationIgnored`, or the render callback would block/allocate. Only the
// handful of UI-facing properties below are left tracked; all are mutated on
// the main thread.
@Observable
final class AudioEngine {

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
    @ObservationIgnored private var masterNode: AVAudioSourceNode?

    // MARK: - Master effect chain (single shared set, not per-voice)
    // Initialised lazily so sampleRate is available; first accessed in setupMasterNode()
    // which always runs before the audio thread starts.
    // Read on the render thread every sample — must stay outside observation tracking.
    @ObservationIgnored private lazy var masterMod        = ModulationProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterLofiL      = LofiProcessor()
    @ObservationIgnored private lazy var masterLofiR      = LofiProcessor()
    @ObservationIgnored private lazy var masterSpaceEchoL = SpaceEchoProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterSpaceEchoR = SpaceEchoProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterGrit       = GritProcessor()
    @ObservationIgnored private lazy var masterTapeL      = BrokenTapeDelay(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterTapeR      = BrokenTapeDelay(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterBloom      = BloomReverbProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterPhaserL    = PhaserProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterPhaserR    = PhaserProcessor(sampleRate: sampleRate, lfoPhaseOffset: 0.5)
    @ObservationIgnored private lazy var masterAutoWahL   = AutoWahProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterAutoWahR   = AutoWahProcessor(sampleRate: sampleRate)
    @ObservationIgnored private lazy var masterModDelayL  = ModulatingDelayProcessor(sampleRate: sampleRate, lfoRate: 0.33)
    @ObservationIgnored private lazy var masterModDelayR  = ModulatingDelayProcessor(sampleRate: sampleRate, lfoRate: 0.37)

    // MARK: - State
    //
    // `voices`, `voiceGainBoxes` and `controlToVoiceID` are MAIN-THREAD ONLY now.
    // Every mutation path (touch, MIDI, looper) dispatches to main, so these need
    // no lock. The render thread never touches them — it reads `renderLock`'s
    // immutable RenderSnapshot instead, which the main thread republishes whenever
    // the voice set or a knob changes.
    private(set) var voices: [Int: any AnyVoice] = [:]

    // Non-nil only for layer-mode voices; single-mode voices use implicit gain 1.0.
    @ObservationIgnored private var voiceGainBoxes: [Int: GainBox] = [:]

    // Voice/param hand-off to the audio thread. The render callback uses a
    // try-lock (os_unfair_lock_trylock) that NEVER blocks: if the main thread is
    // mid-publish, the render thread reuses the snapshot it cached last buffer.
    // So a main-thread publish can't stall the audio thread (no priority inversion,
    // unlike the previous NSLock). os_unfair_lock also participates in priority
    // inheritance, so the brief main-thread critical section can't be preempted
    // away while the audio thread waits.
    //
    // Heap-allocated so the lock has a stable address (an os_unfair_lock must never
    // be copied; storing it inline in the class and taking &self.lock would be UB).
    private let snapshotLock: os_unfair_lock_t = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    // Guarded by snapshotLock; written on main, read (try-lock) on the audio thread.
    @ObservationIgnored private var publishedSnapshot = RenderSnapshot()
    // Render-thread-only cache of the last snapshot read; never touched off-render.
    @ObservationIgnored private var cachedSnapshot = RenderSnapshot()
    // Render-thread only: the effect amounts actually in use (gliding toward the
    // published ones) and which stateful effects ran last buffer (bit per effect).
    @ObservationIgnored private var smoothedParams   = RenderParams()
    // Main thread only: preset → AU-node glide bookkeeping (see applyPresetToNodes).
    @ObservationIgnored private var nodeRampGeneration = 0
    @ObservationIgnored private var loadedReverbPreset: AVAudioUnitReverbPreset? = nil
    @ObservationIgnored private var shimmerPresetLoaded = false
    @ObservationIgnored private var activeEffectMask: UInt16 = 0
    // Main-thread only: recently replaced snapshots, released here (see retire()).
    @ObservationIgnored private var retiredSnapshots: [RenderSnapshot] = []

    // Hard polyphony ceiling. Past this, the oldest voice is stolen so dense
    // playing (or a stuck note-on) can't grow the voice set without bound and
    // pin the audio thread.
    private let maxPolyphony = 32

    // voices / voiceGainBoxes are keyed by a unique, monotonically increasing
    // voiceID — NOT the touchID. UIKit recycles UITouch objects, so a rapid re-tap
    // of the same key reuses its touchID; keying voices by touchID meant a re-tap
    // hard-removed the still-sounding previous voice (a one-sample amplitude drop =
    // click, fed straight into the delay), and a stale removal timer could then kill
    // the new voice. A unique id lets the old voice ring out its release tail next to
    // the new one. controlToVoiceID maps a control id (touchID, or touchID*1000+
    // presetIdx in layer mode) to its current live voiceID. Main-thread only.
    @ObservationIgnored private var nextVoiceID = 1
    @ObservationIgnored private var controlToVoiceID: [Int: Int] = [:]

    // Sampler nodes (one per instrument, lazily created)
    @ObservationIgnored private var samplerEngines: [String: SamplerEngine] = [:]
    // touchID → (instrumentID, midiNote) for single mode; compound ID for layer mode
    // `handle` lets a glide bend exactly this note (nil if the note-on was dropped).
    @ObservationIgnored private var samplerTouches: [Int: (instrumentID: String, note: Int, handle: SamplerEngine.Handle?)] = [:]

    // MARK: - Observed (UI-facing) state — main-thread only
    var waveformSamples: [Float] = Array(repeating: 0, count: 128)
    var currentPreset: SynthPreset = SynthPreset.presets[0]

    // MARK: - Layer mode
    var isLayeringMode    = false
    var activeLayerIndices: [Int] = []
    var primaryLayerIndex: Int?
    // Layer gains live in GainBox class instances (so the render thread can read
    // them live); those aren't observable, so this revision counter is bumped on
    // every setLayerGain and read by layerGain(for:) to make gain edits visible.
    private(set) var layerGainRevision = 0

    // Pitch of the most recently played/bent note (MIDI + bend), nil when nothing
    // is held. Drives the pitch-reactive blob. Only views that read it re-render.
    private(set) var soundingPitch: Double?
    @ObservationIgnored private var touchPitches: [Int: (note: Int, bend: Double)] = [:]

    // Gain boxes keyed by preset index; shared with voiceGainBoxes entries for render.
    @ObservationIgnored private var layerGainBoxes:     [Int: GainBox] = [:]
    // Tracks which preset indices were layered at each noteOn, for correct noteOff cleanup.
    @ObservationIgnored private var noteOnLayerIndices: [Int: [Int]]   = [:]

    private let sampleRate: Double = 44100

    // Visualiser ring buffer. Written by the render thread into raw, uniquely-owned
    // memory (no COW, no allocation on the audio thread) and copied to the
    // observed `waveformSamples` by a main-thread maintenance timer. The
    // cross-thread read of plain Floats is a benign race — at worst the visualiser
    // shows one mixed frame, which is invisible.
    private static let analysisCount = 128
    private let analysisPtr = UnsafeMutableBufferPointer<Float>.allocate(capacity: AudioEngine.analysisCount)
    @ObservationIgnored private var analysisWriteIndex = 0
    @ObservationIgnored private var lastPublishedSilent = false

    // Periodic main-thread housekeeping: publish the visualiser buffer and reap
    // voices that have finished their release tail (via AnyVoice.isFinished).
    @ObservationIgnored private var maintenanceTimer: Timer?
    // Notification observer tokens, removed in deinit.
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []

    // Serialises audio-session activation and engine start/restart off the main
    // thread. AVAudioSession.setActive(_:) can block long enough to stall the UI,
    // and a serial queue prevents overlapping route-change restarts from racing.
    private let sessionQueue = DispatchQueue(label: "audio.session.control", qos: .userInitiated)

    init() {
        analysisPtr.initialize(repeating: 0)
        setupEngine()
        startMaintenanceTimer()
    }

    deinit {
        maintenanceTimer?.invalidate()
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if engine.isRunning { engine.stop() }
        analysisPtr.deallocate()
        snapshotLock.deinitialize(count: 1)
        snapshotLock.deallocate()
    }

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

            // Read the published snapshot with a NON-BLOCKING try-lock; if the main
            // thread is mid-publish, reuse the snapshot we cached last buffer. The
            // audio thread therefore never waits on the main thread.
            if os_unfair_lock_trylock(self.snapshotLock) {
                self.cachedSnapshot = self.publishedSnapshot
                os_unfair_lock_unlock(self.snapshotLock)
            }
            let entries = self.cachedSnapshot.entries
            let frames  = Int(frameCount)

            // Glide the effect amounts toward the published values (~25 ms time
            // constant) and interpolate per sample inside the buffer, so neither a
            // preset change nor a knob turn lands as a step.
            let from = self.smoothedParams
            let to   = from.moved(toward: self.cachedSnapshot.params,
                                  fraction: 1 - expf(-Float(frames) / (0.025 * Float(self.sampleRate))))
            let inc  = RenderParams.increment(from: from, to: to, frames: frames)
            var params = from
            self.smoothedParams = to

            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let ld = abl[0].mData, let rd = abl[1].mData else { return noErr }
            let left  = ld.assumingMemoryBound(to: Float.self)
            let right = rd.assumingMemoryBound(to: Float.self)

            // Decide which effects are active ONCE per buffer. Skipping disabled
            // effects is what keeps idle/light CPU low — previously every one of
            // these custom per-sample processors ran 44 100×/sec regardless of its
            // amount, which pinned the audio thread even in silence.
            // (An effect stays on while it is still fading out: from OR to.)
            let doAutoWah  = from.autoWah    > 0.001 || to.autoWah    > 0.001
            let doGrit     = from.grit       > 0.001 || to.grit       > 0.001
            let doLofi     = from.lofi       > 0.001 || to.lofi       > 0.001
            let doSpace    = from.space      > 0.001 || to.space      > 0.001
            let doTape     = from.tape       > 0.001 || to.tape       > 0.001
            let doBloom    = from.bloom      > 0.005 || to.bloom      > 0.005
            let doMod      = from.tremulant  > 0.001 || to.tremulant  > 0.001
                          || from.chorus     > 0.001 || to.chorus     > 0.001
            let doDist     = from.distortion > 0.001 || to.distortion > 0.001
            let doPhaser   = from.phaser     > 0.001 || to.phaser     > 0.001
            let doModDelay = from.modDelay   > 0.001 || to.modDelay   > 0.001

            // An effect that has just faded out forgets its state. Otherwise its
            // delay line keeps the last echoes frozen and replays them — as a pop —
            // the next time a preset switches that effect on.
            var mask: UInt16 = 0
            if doAutoWah  { mask |= 1 << 0 }
            if doLofi     { mask |= 1 << 1 }
            if doSpace    { mask |= 1 << 2 }
            if doTape     { mask |= 1 << 3 }
            if doBloom    { mask |= 1 << 4 }
            if doMod      { mask |= 1 << 5 }
            if doPhaser   { mask |= 1 << 6 }
            if doModDelay { mask |= 1 << 7 }
            let ended = self.activeEffectMask & ~mask
            if ended != 0 {
                if ended & (1 << 0) != 0 { self.masterAutoWahL.reset();   self.masterAutoWahR.reset() }
                if ended & (1 << 1) != 0 { self.masterLofiL.reset();      self.masterLofiR.reset() }
                if ended & (1 << 2) != 0 { self.masterSpaceEchoL.reset(); self.masterSpaceEchoR.reset() }
                if ended & (1 << 3) != 0 { self.masterTapeL.reset();      self.masterTapeR.reset() }
                if ended & (1 << 4) != 0 { self.masterBloom.reset() }
                if ended & (1 << 5) != 0 { self.masterMod.reset() }
                if ended & (1 << 6) != 0 { self.masterPhaserL.reset();    self.masterPhaserR.reset() }
                if ended & (1 << 7) != 0 { self.masterModDelayL.reset();  self.masterModDelayR.reset() }
            }
            self.activeEffectMask = mask

            // Push the live tremulant depth to organ voices ONCE per buffer rather
            // than re-casting every voice every sample (was 44.1k dynamic casts/sec).
            // Always push, including 0: skipping it when ≤ 0.001 meant turning the
            // tremolo knob down to zero never reached organ notes already held.
            for (voice, _) in entries {
                (voice as? OrganVoice)?.tremulantDepth = to.tremulant
            }

            var widx = self.analysisWriteIndex
            for i in 0..<frames {
                var l: Float = 0.0
                var r: Float = 0.0

                // Sum all active voices (contiguous array, no dictionary hashing)
                // before any effects processing.
                for (voice, gainBox) in entries {
                    let (vl, vr) = voice.nextStereoSample()
                    let gain = gainBox?.value ?? 1.0
                    l += vl * gain
                    r += vr * gain
                }

                // Effects chain applied ONCE on the summed signal — each gated by
                // whether it's actually enabled for the current preset.
                if doAutoWah {
                    l = self.masterAutoWahL.process(l, amount: params.autoWah)
                    r = self.masterAutoWahR.process(r, amount: params.autoWah)
                }
                if doGrit {
                    l = self.masterGrit.process(l, amount: params.grit)
                    r = self.masterGrit.process(r, amount: params.grit)
                }
                if doLofi {
                    l = self.masterLofiL.process(l, amount: params.lofi)
                    r = self.masterLofiR.process(r, amount: params.lofi)
                }
                if doSpace {
                    l = self.masterSpaceEchoL.process(l, amount: params.space)
                    r = self.masterSpaceEchoR.process(r, amount: params.space)
                }
                if doTape {
                    let btAmt = params.tape
                    l = self.masterTapeL.process(l, delayTime: 0.22, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                    r = self.masterTapeR.process(r, delayTime: 0.24, feedback: 0.45, mix: btAmt * 0.7, broken: btAmt)
                }
                if doBloom {
                    let blAmt = params.bloom
                    let (bl, br) = self.masterBloom.process((l + r) * 0.5, amount: blAmt)
                    l = l * (1.0 - blAmt * 0.3) + bl
                    r = r * (1.0 - blAmt * 0.3) + br
                }
                if doMod {
                    let (ml, mr) = self.masterMod.process(l: l, r: r,
                                                          tremDepth: params.tremulant,
                                                          chorusMix: params.chorus)
                    l = ml; r = mr
                }
                if doDist {
                    l = tubeSaturate(l, drive: params.distortion)
                    r = tubeSaturate(r, drive: params.distortion)
                }
                if doPhaser {
                    l = self.masterPhaserL.process(l, amount: params.phaser)
                    r = self.masterPhaserR.process(r, amount: params.phaser)
                }
                if doModDelay {
                    l = self.masterModDelayL.process(l, amount: params.modDelay)
                    r = self.masterModDelayR.process(r, amount: params.modDelay)
                }

                // Flush sub-denormal magnitudes to zero before they reach the AU
                // reverb/delay — denormal floats trigger 10–100× CPU spikes in IIR
                // tails on some hardware (right when many voices are decaying).
                left[i]  = (l > -1e-15 && l < 1e-15) ? 0 : l
                right[i] = (r > -1e-15 && r < 1e-15) ? 0 : r

                // Visualiser ring write — plain store into uniquely-owned memory.
                self.analysisPtr[widx & (Self.analysisCount - 1)] = (l + r) * 0.5
                widx &+= 1
                params.add(inc)
            }
            self.analysisWriteIndex = widx
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
        let configObs = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            Diagnostics.shared.log("Audio config changed (hardware/route)")
            self?.restartEngineIfNeeded()
        }

        let interruptObs = NotificationCenter.default.addObserver(
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
        let routeObs = NotificationCenter.default.addObserver(
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

        sessionObservers = [configObs, interruptObs, routeObs]
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
        // Session work (setActive can block) runs on the serial session queue, so
        // overlapping route-change restarts still serialise. The GRAPH surgery then
        // hops to the main thread: every other graph mutation (attaching sampler
        // nodes) and every currentPreset access happen there, and doing them from
        // the session queue raced both — AVAudioEngine isn't safe for concurrent
        // graph changes, and reading the observed struct off-main could tear.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Re-apply session settings — category/rate can drift after an AirPlay handoff.
            self.configureSession(bufferDuration: 0.01)
            DispatchQueue.main.async { self.rebuildGraphAndStart() }
        }
    }

    /// Main thread only.
    private func rebuildGraphAndStart() {
        if engine.isRunning { engine.stop() }
        // Detach old master node before reset so stale render callbacks are not called.
        if let old = masterNode { engine.detach(old); masterNode = nil }
        // Reset clears stale delay/reverb buffers accumulated during AirPlay;
        // without this the echo tail plays back corrupted and sounds 8-bit/crunchy.
        engine.reset()
        setupMasterNode()
        try? engine.start()
        applyPresetToNodes(currentPreset)
        Diagnostics.shared.log("Audio engine restarted (route/interruption recovery)")
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
                        releaseSampler(info)
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
    }

    func layerGain(for presetIndex: Int) -> Float {
        _ = layerGainRevision   // register a dependency so gain edits re-render callers
        return layerGainBoxes[presetIndex]?.value ?? 1.0
    }

    func setLayerGain(_ gain: Float, for presetIndex: Int) {
        layerGainBoxes[presetIndex]?.value = max(0.05, min(1, gain))
        layerGainRevision &+= 1
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
        currentPreset = preset   // observed — callers must invoke this on main
        // Start decoding a sampler instrument as soon as it is SELECTED (decoding
        // runs in the background), so it's ready by the first note instead of the
        // first note triggering the load.
        if case .sampler(let instrument) = preset.voiceMode { samplerEngine(for: instrument) }
        Diagnostics.shared.log("Preset → \(preset.name)")
        applyPresetToNodes(preset)
    }

    /// Applies a preset's reverb/delay/shimmer settings to the audio-unit nodes
    /// and publishes its per-sample effect amounts. Main thread only.
    ///
    /// While the engine is running the change is made WITHOUT steps, because sound
    /// is usually still ringing when a preset is switched and every step clicks:
    ///   • wet/dry mixes and the shimmer level glide to their new values (~50 ms);
    ///   • the reverb's factory preset is only reloaded when it actually changes
    ///     (it used to be reloaded on every switch, re-initialising the reverb),
    ///     and then only while the reverb's wet level is faded to zero;
    ///   • a new delay time is set, and the delay line cleared, while the delay's
    ///     wet level is at zero (changing it under signal bends and clicks);
    ///   • the shimmer path is bypassed only after its level reached zero.
    /// With the engine stopped (start-up, route-change rebuild) it is applied at once.
    private func applyPresetToNodes(_ preset: SynthPreset) {
        nodeRampGeneration &+= 1
        let generation = nodeRampGeneration

        let reverbPreset: AVAudioUnitReverbPreset = preset.isOrgan ? .cathedral : .largeChamber
        let reverbWet  = preset.reverbMix * 100
        let delayWet   = preset.delayMix * 100
        let delayTime  = Double(preset.delayTime)
        let shimmerVol = preset.shimmerAmount * 0.45
        let shimmerOn  = preset.shimmerAmount > 0.001

        delay.feedback      = 28
        // Roll off high frequencies in echoes — keeps repeats warm and masks
        // any transient content (key clicks, attack edges) from clicking.
        delay.lowPassCutoff = 4000
        if !shimmerPresetLoaded {
            shimmerReverb.loadFactoryPreset(.plate)
            shimmerReverb.wetDryMix = 80
            shimmerPresetLoaded = true
        }

        // Push the new per-sample effect scalars to the render thread (it glides
        // to them itself — see RenderParams smoothing).
        publishParams(from: preset)

        let reverbChanges = loadedReverbPreset != reverbPreset
        let delayChanges  = abs(delay.delayTime - delayTime) > 0.0005

        guard engine.isRunning else {
            if reverbChanges { reverb.loadFactoryPreset(reverbPreset); loadedReverbPreset = reverbPreset }
            reverb.wetDryMix = reverbWet
            delay.delayTime  = delayTime
            delay.wetDryMix  = delayWet
            shimmerMixer.outputVolume = shimmerVol
            setShimmerPathActive(shimmerOn)
            return
        }

        if shimmerOn { setShimmerPathActive(true) }      // un-bypass before fading in
        let reverbFrom  = reverb.wetDryMix
        let delayFrom   = delay.wetDryMix
        let shimmerFrom = shimmerMixer.outputVolume

        // Phase 1: glide to the new levels — or down to silence for a node that
        // has to be reconfigured.
        rampNodes(generation: generation, step: { [weak self] t in
            guard let self else { return }
            self.reverb.wetDryMix = reverbFrom + ((reverbChanges ? 0 : reverbWet) - reverbFrom) * t
            self.delay.wetDryMix  = delayFrom  + ((delayChanges  ? 0 : delayWet)  - delayFrom)  * t
            self.shimmerMixer.outputVolume = shimmerFrom + (shimmerVol - shimmerFrom) * t
        }, completion: { [weak self] in
            guard let self else { return }
            if !shimmerOn { self.setShimmerPathActive(false) }
            guard reverbChanges || delayChanges else { return }
            if reverbChanges {
                self.reverb.loadFactoryPreset(reverbPreset)
                self.loadedReverbPreset = reverbPreset
                self.reverb.wetDryMix = 0          // loading a preset resets the mix
            }
            if delayChanges {
                self.delay.delayTime = delayTime
                self.delay.reset()                 // drop echoes recorded at the old time
            }
            // Phase 2: bring the reconfigured nodes back up.
            self.rampNodes(generation: generation, step: { [weak self] t in
                guard let self else { return }
                if reverbChanges { self.reverb.wetDryMix = reverbWet * t }
                if delayChanges  { self.delay.wetDryMix  = delayWet * t }
            }, completion: {})
        })
    }

    /// Calls `step` with t = 1/6 … 1 at 8 ms intervals on the main queue, then
    /// `completion`. A newer preset change (generation mismatch) abandons the ramp;
    /// the new one starts from wherever the nodes are.
    private func rampNodes(generation: Int, step: @escaping (Float) -> Void,
                           completion: @escaping () -> Void) {
        let steps = 6
        for k in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.008) { [weak self] in
                guard let self, self.nodeRampGeneration == generation else { return }
                step(Float(k) / Float(steps))
                if k == steps { completion() }
            }
        }
    }

    /// Republishes just the render effect scalars (called from knob setters and
    /// preset changes). Thread-safe; takes the snapshot lock only to swap the params.
    private func publishParams(from preset: SynthPreset) {
        let params = RenderParams(preset)
        os_unfair_lock_lock(snapshotLock)
        publishedSnapshot.params = params
        os_unfair_lock_unlock(snapshotLock)
    }

    /// Bypass the shimmer reverb + pitch-shifter when shimmer is off. The
    /// AVAudioUnitTimePitch runs a phase vocoder continuously otherwise — a real
    /// idle-CPU cost for a path whose output is muted anyway on most presets.
    private func setShimmerPathActive(_ active: Bool) {
        timePitch.auAudioUnit.shouldBypassEffect     = !active
        shimmerReverb.auAudioUnit.shouldBypassEffect = !active
    }

    // MARK: - Live knob updates

    // Each knob setter mutates the observed currentPreset (for the UI) and then
    // republishes the render params so the audio thread sees the change. Reverb/
    // delay/shimmer are AU-node params and don't go through RenderParams, so they
    // skip the republish.
    func setDistortion(_ v: Float) { currentPreset.distortionAmount = v; publishParams(from: currentPreset) }
    func setShimmer(_ v: Float)    { currentPreset.shimmerAmount = v; shimmerMixer.outputVolume = v * 0.45; setShimmerPathActive(v > 0.001) }
    func setReverb(_ v: Float)     { currentPreset.reverbMix = v;     reverb.wetDryMix = v * 100 }
    func setDelay(_ v: Float)      { currentPreset.delayMix = v;      delay.wetDryMix = v * 100 }
    func setTremolo(_ v: Float)    { currentPreset.tremulantDepth = v;  publishParams(from: currentPreset) }
    func setChorus(_ v: Float)     { currentPreset.chorusMix = v;       publishParams(from: currentPreset) }
    func setLofi(_ v: Float)       { currentPreset.lofiAmount = v;      publishParams(from: currentPreset) }
    func setSpaceEcho(_ v: Float)  { currentPreset.spaceEchoAmount = v; publishParams(from: currentPreset) }
    func setBrokenTape(_ v: Float) { currentPreset.brokenTape = v;      publishParams(from: currentPreset) }
    func setGrit(_ v: Float)       { currentPreset.gritAmount = v;      publishParams(from: currentPreset) }
    func setBloom(_ v: Float)      { currentPreset.bloomAmount = v;     publishParams(from: currentPreset) }
    func setPhaser(_ v: Float)     { currentPreset.phaserAmount = v;    publishParams(from: currentPreset) }
    func setAutoWah(_ v: Float)    { currentPreset.autoWahAmount = v;   publishParams(from: currentPreset) }
    func setModDelay(_ v: Float)   { currentPreset.modDelayAmount = v;  publishParams(from: currentPreset) }

    // MARK: - Sampler helpers

    /// Returns the SamplerEngine for an instrument, creating + wiring it on first use.
    ///
    /// Lifecycle (#9): sampler engines are retained for the app's lifetime once
    /// created. This is deliberate — the set is bounded to the handful of sampler
    /// presets (piano/strings/flute/organ), and detaching an AVAudioNode from a
    /// *running* engine triggers an AVAudioEngineConfigurationChange, which our own
    /// observer treats as a route change and restarts the graph (an audible gap).
    /// Tearing them down mid-session would cost more than the few MB of buffers it
    /// reclaims. The whole graph is released in `deinit`.
    ///
    /// Routing (#10): sampler output is wired to `voiceMixer`, so it shares the AU
    /// reverb/delay/shimmer chain but NOT the boutique per-sample effects (lofi,
    /// tape, phaser, …). Those live inside the master source-node render loop, which
    /// only sums synth voices — AVAudioPlayerNodes are pull-based graph nodes, not
    /// sample generators we can call per-frame, so they can't be fed through that
    /// loop without rendering them manually. Intentional limitation, not a bug.
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

    // MARK: - Looper hook (weak — the App owns the LooperEngine)
    @ObservationIgnored weak var looper: LooperEngine?

    // MARK: - Touch Events

    /// `fromLooper` marks the looper's own playback so it is never re-recorded into
    /// the loop. (This used to be inferred from `touchID < 90000`, but on-screen
    /// touch IDs are UITouch hashes — heap addresses, always far above 90000 — so
    /// nothing played on screen was ever recorded; only MIDI was.)
    func noteOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float,
                fromLooper: Bool = false) {
        if !fromLooper { looper?.recordOn(touchID: touchID, note: note,
                                          velocity: velocity, x: x, y: y) }
        touchPitches[touchID] = (note, 0)
        soundingPitch = Double(note)
        if isLayeringMode && !activeLayerIndices.isEmpty {
            noteOnLayer(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        } else {
            noteOnSingle(touchID: touchID, note: note, velocity: velocity, x: x, y: y)
        }
    }

    private func noteOnSingle(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        if case .sampler(let instrument) = currentPreset.voiceMode {
            releaseSingle(touchID: touchID)
            let se = samplerEngine(for: instrument)
            let handle = se.noteOn(UInt8(clamping: note), velocity: UInt8(velocity * 127))
            samplerTouches[touchID] = (instrument.id, note, handle)
            return
        }
        // Retire any note still sounding on this touch (e.g. a rapid re-tap that
        // reuses a recycled UITouch id) by RELEASING it — letting its envelope fade
        // out — never by hard-removing it, which would click.
        releaseSingle(touchID: touchID)
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
                        releaseSampler(info)
                    }
                    samplerTouches.removeValue(forKey: cid)
                } else {
                    retireVoice(controlID: cid, preset: p)
                }
            }
        }

        for presetIdx in activeLayerIndices {
            // The voice/filter knobs edit `currentPreset`, which IS the primary
            // layer's preset (the controls follow the primary). Using the stock
            // preset here meant knob edits never reached any layered voice.
            let preset = presetIdx == primaryLayerIndex ? currentPreset : SynthPreset.presets[presetIdx]
            let cid    = touchID * 1000 + presetIdx
            if case .sampler(let instrument) = preset.voiceMode {
                let se = samplerEngine(for: instrument)
                let handle = se.noteOn(UInt8(clamping: note), velocity: UInt8(velocity * 127))
                samplerTouches[cid] = (instrument.id, note, handle)
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
        applyY(y, to: voice)
        // Start before publishing so the render thread never sees a voice that
        // hasn't begun generating samples yet.
        voice.start()

        // Polyphony ceiling, so the set can't grow without bound under dense playing
        // or a stuck note. Steal the oldest RELEASED voice (a fading tail) first —
        // only if every voice is still held, the oldest held one. Stealing the oldest
        // voice regardless used to cut off notes the player was still holding.
        if voices.count >= maxPolyphony {
            let held = Set(controlToVoiceID.values)
            if let victim = voices.keys.filter({ !held.contains($0) }).min() ?? voices.keys.min() {
                voices.removeValue(forKey: victim)
                voiceGainBoxes.removeValue(forKey: victim)
                controlToVoiceID = controlToVoiceID.filter { $0.value != victim }
            }
        }

        let voiceID = nextVoiceID
        nextVoiceID += 1
        voices[voiceID] = voice
        if let gb = gainBox { voiceGainBoxes[voiceID] = gb }
        controlToVoiceID[controlID] = voiceID
        publishSnapshot()
    }

    func noteOff(touchID: Int, fromLooper: Bool = false) {
        if !fromLooper { looper?.recordOff(touchID: touchID) }
        touchPitches.removeValue(forKey: touchID)
        soundingPitch = touchPitches.values.first.map { Double($0.note) + $0.bend }
        if isLayeringMode, let layerIndices = noteOnLayerIndices[touchID] {
            for presetIdx in layerIndices {
                let cid    = touchID * 1000 + presetIdx
                let preset = SynthPreset.presets[presetIdx]
                if case .sampler = preset.voiceMode {
                    if let info = samplerTouches[cid] {
                        releaseSampler(info)
                    }
                    samplerTouches.removeValue(forKey: cid)
                } else {
                    retireVoice(controlID: cid, preset: preset)
                }
            }
            noteOnLayerIndices.removeValue(forKey: touchID)
        } else {
            releaseSingle(touchID: touchID)
        }
    }

    /// Releases whatever a single-mode touch started — sampler note and/or synth
    /// voice — decided by how the note was STARTED, not by the current preset.
    /// (Choosing by `currentPreset` left notes stuck forever when the preset was
    /// switched while they were held: a synth note took the sampler path, found
    /// nothing, and was never released — and vice versa.)
    private func releaseSingle(touchID: Int) {
        if let info = samplerTouches.removeValue(forKey: touchID) {
            releaseSampler(info)
        }
        retireVoice(controlID: touchID, preset: currentPreset)   // no-op if no synth voice
    }

    /// Releases the voice currently bound to `controlID` (if any). Clears the
    /// control→voice mapping so the id is free to bind a fresh voice immediately.
    /// The voice keeps sounding its release tail and is reaped by the maintenance
    /// timer once `isFinished` reports true — no hardcoded per-voice tail times,
    /// and no audio-thread work. No-op when nothing is bound (e.g. first tap).
    private func retireVoice(controlID: Int, preset: SynthPreset) {
        guard let voiceID = controlToVoiceID.removeValue(forKey: controlID) else { return }
        voices[voiceID]?.release()
    }

    // MARK: - Render snapshot publishing

    /// Rebuilds the immutable render snapshot (voice list + params) and swaps it
    /// in under the render lock. Main-thread only.
    private func publishSnapshot() {
        var entries: [(voice: any AnyVoice, gain: GainBox?)] = []
        entries.reserveCapacity(voices.count)
        for (id, v) in voices { entries.append((v, voiceGainBoxes[id])) }
        let params = RenderParams(currentPreset)
        os_unfair_lock_lock(snapshotLock)
        let previous = publishedSnapshot
        publishedSnapshot = RenderSnapshot(entries: entries, params: params)
        os_unfair_lock_unlock(snapshotLock)
        retire(previous)
    }

    /// Keeps the last few published snapshots alive HERE, on the main thread. When
    /// the render thread swaps its cached copy it then only drops a reference; the
    /// final release — which frees the entries array and any reaped voices (e.g.
    /// HammondVoice's Leslie buffer) — happens when they fall off this ring, on the
    /// main thread, never on the audio thread. 8 publishes ≫ the one render buffer
    /// (~10 ms) the render thread can lag behind.
    private func retire(_ snapshot: RenderSnapshot) {
        retiredSnapshots.append(snapshot)
        // 64, not 8: a three-finger chord over four layers is 12 publishes inside
        // one render buffer, which would push the snapshot the render thread still
        // holds out of an 8-slot ring and leave IT to do the final free.
        if retiredSnapshots.count > 64 { retiredSnapshots.removeFirst() }
    }

    /// When true the pad's vertical axis morphs the synth waveform (MorphWiz
    /// style) instead of driving brightness + modulation. Mirrored from
    /// ThemeManager.yAxisMorph by ContentView. Main-thread only.
    @ObservationIgnored var yAxisMorph = false

    /// Single place the vertical axis is applied to a voice. In morph mode, synth
    /// voices morph sine→triangle→saw→square with a fixed, moderately open filter
    /// (so the timbre change is audible) and no Y-driven vibrato. Organ / Hammond /
    /// Rhodes have no morphable oscillator, so they always keep expression mode.
    private func applyY(_ y: Float, to voice: any AnyVoice) {
        if yAxisMorph, let synth = voice as? SynthVoice {
            synth.waveMorph       = y
            synth.filterCutoffMod = 0.7
            synth.lfoDepthMod     = 0
        } else {
            voice.filterCutoffMod = y
            voice.lfoDepthMod     = y
        }
    }

    func updateTouch(touchID: Int, x: Float, y: Float) {
        // Y → brightness + modulation, or wave morph (see applyY); X is note-only.
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                if let v = liveVoice(controlID: touchID * 1000 + presetIdx) { applyY(y, to: v) }
            }
        } else if let v = liveVoice(controlID: touchID) {
            applyY(y, to: v)
        }
    }

    func updateGlissando(touchID: Int, semitones: Float, x: Float, y: Float) {
        if let note = touchPitches[touchID]?.note {
            touchPitches[touchID] = (note, Double(semitones))
            soundingPitch = Double(note) + Double(semitones)
        }
        if isLayeringMode, let indices = noteOnLayerIndices[touchID] {
            for presetIdx in indices {
                let cid = touchID * 1000 + presetIdx
                bendSampler(controlID: cid, semitones: semitones)
                guard let v = liveVoice(controlID: cid) else { continue }
                v.pitchBendSemitones = semitones
                applyY(y, to: v)
            }
        } else {
            bendSampler(controlID: touchID, semitones: semitones)
            if let v = liveVoice(controlID: touchID) {
                v.pitchBendSemitones = semitones
                applyY(y, to: v)
            }
        }
    }

    /// Releases one sampler note — by its handle when we have one, so only THIS
    /// note is released (not every slot playing the same MIDI number).
    private func releaseSampler(_ info: (instrumentID: String, note: Int, handle: SamplerEngine.Handle?)) {
        guard let se = samplerEngines[info.instrumentID] else { return }
        if let handle = info.handle { se.noteOff(handle) } else { se.noteOff(UInt8(clamping: info.note)) }
    }

    /// Sampler presets (piano, strings, flute, organ) bend by re-tuning the note's
    /// varispeed — so glides, finger vibrato and glissando work on them too.
    private func bendSampler(controlID: Int, semitones: Float) {
        guard let info = samplerTouches[controlID], let handle = info.handle else { return }
        samplerEngines[info.instrumentID]?.bend(handle, semitones: semitones)
    }

    /// The currently-bound (non-retired) voice for a control id, or nil.
    private func liveVoice(controlID: Int) -> (any AnyVoice)? {
        guard let voiceID = controlToVoiceID[controlID] else { return nil }
        return voices[voiceID]
    }

    // MARK: - Maintenance timer (visualiser publish + voice reaping)

    /// Runs at ~30 Hz on the main run loop. Does two cheap jobs that used to be
    /// done from the audio thread (a dispatch per visualiser frame) or by a
    /// per-voice asyncAfter timer:
    ///   1. Copy the visualiser ring buffer into the observed `waveformSamples`,
    ///      skipping the publish entirely while silent so SwiftUI isn't re-rendered
    ///      30×/sec during idle.
    ///   2. Reap voices that have finished their release tail (AnyVoice.isFinished),
    ///      then republish the render snapshot if any were removed.
    private func startMaintenanceTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.runMaintenance()
        }
        // .common so the visualiser keeps updating during scroll/gesture tracking.
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    private func runMaintenance() {
        // 1. Visualiser — copy the ring and publish only when it changes audibly.
        var snap = [Float](repeating: 0, count: Self.analysisCount)
        var peak: Float = 0
        for i in 0..<Self.analysisCount {
            let v = analysisPtr[i]
            snap[i] = v
            let a = v < 0 ? -v : v
            if a > peak { peak = a }
        }
        let silent = peak < 0.0003
        if !(silent && lastPublishedSilent) {
            waveformSamples = snap          // skip republishing zeros over zeros
            lastPublishedSilent = silent
        }

        // 2. Reap finished voices.
        guard !voices.isEmpty else { return }
        let finished = voices.filter { $0.value.isFinished }.map { $0.key }
        guard !finished.isEmpty else { return }
        for id in finished {
            voices.removeValue(forKey: id)
            voiceGainBoxes.removeValue(forKey: id)
        }
        controlToVoiceID = controlToVoiceID.filter { voices[$0.value] != nil }
        publishSnapshot()
    }
}
