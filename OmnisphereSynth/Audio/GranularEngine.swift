import AVFoundation
import os

// MARK: - Settings (pure)

/// How a recording is turned into a GRAIN CLOUD: instead of playing the note
/// from its start, many short overlapping slices ("grains") are taken from
/// random places in the held part of the recording, each faded in and out, each
/// slightly detuned and placed somewhere in the stereo field. The instrument's
/// colour stays; its attack and its fixed shape go, and what is left is a
/// texture that never repeats — a rubbed glass becomes a slowly moving haze.
struct GrainCloud: Equatable, Hashable {
    /// Length of one grain (seconds). Long grains are smooth, short ones shimmer.
    var size = 0.28
    /// Grains started per second, per note. size × density = how many overlap.
    var density = 18.0
    /// How far from the sweep position a grain may start (0 = none, 1 = anywhere
    /// in the held part). More spray = more diffuse.
    var spray = 0.6
    /// Speed (Hz) at which the reading position sweeps back and forth through
    /// the held part, so the cloud keeps changing under a held note.
    var drift = 0.05
    /// Random detune per grain (± cents): the width of the cloud.
    var pitchJitter = 5.0
    /// Share of grains played an octave up / down (octaves only: any other
    /// interval would put a parallel harmony on every chord).
    var octaveUp = 0.0
    var octaveDown = 0.0
    /// Stereo spread of the grains (0 = centre, 1 = full width).
    var spread = 0.8
    /// Fade-in and fade-out of a note (seconds).
    var attack = 0.4
    var release = 1.5
    /// Loudness trim.
    var level = 1.0

    /// Average number of grains sounding at once on one note.
    var overlap: Double { size * density }
    /// Gain that keeps the cloud's level independent of `overlap`: unrelated
    /// grains add in power, and a Hann window's mean square is 3/8.
    var normalisation: Float { Float(level / (max(1, overlap) * 0.375).squareRoot()) }
}

// MARK: - Sources (pure)

/// Where in a recording grains may be taken from.
enum GrainRegion {
    static let window = 0.05

    /// The held part of a sustaining recording (the same steady region the
    /// sampler loops). For a struck or plucked one — no steady part — the ring
    /// after the strike, down to 15 % of its loudest level.
    static func find(_ x: [Float], sampleRate: Double) -> Range<Int> {
        if let steady = SustainLoop.find(x, sampleRate: sampleRate) { return steady }
        let win = Int(sampleRate * window)
        guard win > 0, x.count >= win * 4 else { return 0..<x.count }
        let nw = x.count / win
        var rms = [Float](repeating: 0, count: nw)
        for w in 0..<nw {
            var sum: Float = 0
            for i in (w * win)..<((w + 1) * win) { sum += x[i] * x[i] }
            rms[w] = (sum / Float(win)).squareRoot()
        }
        guard let peak = rms.max(), peak > 1e-5,
              let loudest = rms.firstIndex(of: peak),
              let last = rms.lastIndex(where: { $0 >= 0.15 * peak }) else { return 0..<x.count }
        let start = min(loudest + 1, nw - 1) * win
        let end   = (last + 1) * win
        return end - start >= Int(sampleRate * 0.2) ? start..<end : 0..<x.count
    }

    /// Scale that brings the region to the same RMS for every recording, so a
    /// quiet low note and a loud high one make equally loud clouds.
    static func gain(_ x: [Float], region: Range<Int>, target: Float = 0.18) -> Float {
        guard !region.isEmpty else { return 1 }
        var sum: Float = 0
        for i in region { sum += x[i] * x[i] }
        let rms = (sum / Float(region.count)).squareRoot()
        return rms > 1e-6 ? min(6, max(0.25, target / rms)) : 1
    }
}

/// The decoded recordings of one instrument, in memory that never moves, so the
/// render thread can read it without touching Swift arrays. Immutable once built.
final class GrainSources {
    struct Root {
        let midi: Int
        let samples: UnsafeMutablePointer<Float>
        let count: Int
        let lo: Int        // grains start inside lo..<hi
        let hi: Int
        let gain: Float
    }
    let roots: UnsafeMutablePointer<Root>
    let rootCount: Int
    private let midis: [Int]

    init(recordings: [(midi: Int, samples: [Float])], sampleRate: Double) {
        let usable = recordings.filter { $0.samples.count > 64 }.sorted { $0.midi < $1.midi }
        rootCount = usable.count
        roots = UnsafeMutablePointer<Root>.allocate(capacity: max(1, usable.count))
        midis = usable.map(\.midi)
        for (i, rec) in usable.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: rec.samples.count)
            p.initialize(from: rec.samples, count: rec.samples.count)
            let region = GrainRegion.find(rec.samples, sampleRate: sampleRate)
            (roots + i).initialize(to: Root(midi: rec.midi, samples: p, count: rec.samples.count,
                                            lo: region.lowerBound, hi: region.upperBound,
                                            gain: GrainRegion.gain(rec.samples, region: region)))
        }
    }

    deinit {
        for i in 0..<rootCount { roots[i].samples.deallocate() }
        roots.deallocate()
    }

    /// Index of the recording closest to `midi` (ties → the lower one).
    func index(nearest midi: Int) -> Int? {
        guard let root = SamplerSelection.nearestRoot(to: midi, available: midis) else { return nil }
        return midis.firstIndex(of: root)
    }
}

// MARK: - Renderer (no AVFoundation — unit-tested in SuperNovaPadTests)

/// Renders grain clouds. The main thread sends note commands (`send`); the
/// render thread drains them with a try-lock at the start of each buffer and
/// never waits, allocates or frees. All voice and grain state lives in memory
/// allocated once in `init`.
final class GrainCloudCore {
    static let voiceCount     = 10
    static let grainsPerVoice = 14

    struct Command {
        enum Kind: UInt8 { case on, off, bend }
        var kind: Kind
        var voice: Int32
        var token: Int32
        var root: Int32 = 0
        var pitch: Double = 1     // .on: playback ratio from the root; .bend: bend ratio
        var gain: Float = 1
    }

    private struct Grain {
        var active = false
        var pos = 0.0             // read position in the source (samples)
        var ratio = 1.0           // this grain's own detune / octave
        var remaining: Int32 = 0
        var c = 1.0               // cos(2πi/n), advanced by recursion → Hann window
        var cPrev = 1.0
        var k = 2.0
        var gainL: Float = 0
        var gainR: Float = 0
    }

    private struct Voice {
        var active = false
        var held = false
        var stealing = false      // fading fast because a new note wants this voice
        var env: Float = 0
        var gain: Float = 0
        var pitch = 1.0
        var bend = 1.0
        var root: Int32 = 0
        var token: Int32 = -1
        var untilNext: Int32 = 0
        var sweep = 0.0           // 0…1 phase of the position sweep
        var rng: UInt64 = 0
        // The note waiting for this voice to finish its steal fade.
        var hasPending = false
        var pendToken: Int32 = -1
        var pendRoot: Int32 = 0
        var pendPitch = 1.0
        var pendGain: Float = 0
    }

    let cloud: GrainCloud
    let sampleRate: Double

    private let voices: UnsafeMutablePointer<Voice>
    private let grains: UnsafeMutablePointer<Grain>

    private let lock: os_unfair_lock_t = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var pending: [Command] = []            // guarded by `lock`
    private var publishedSources: GrainSources?    // guarded by `lock`
    private var sources: GrainSources?             // render thread only

    // Derived once.
    private let attackInc: Float
    private let releaseMul: Float
    private let stealDec: Float
    private let grainLength: Double
    private let interval: Double
    private let norm: Float

    init(cloud: GrainCloud, sampleRate: Double = 44100) {
        self.cloud = cloud
        self.sampleRate = sampleRate
        let voiceMemory = UnsafeMutablePointer<Voice>.allocate(capacity: Self.voiceCount)
        let grainMemory = UnsafeMutablePointer<Grain>.allocate(capacity: Self.voiceCount * Self.grainsPerVoice)
        grainMemory.initialize(repeating: Grain(), count: Self.voiceCount * Self.grainsPerVoice)
        for i in 0..<Self.voiceCount {
            var v = Voice()
            v.rng = 0x9E37_79B9_7F4A_7C15 &* UInt64(i + 1)
            (voiceMemory + i).initialize(to: v)
        }
        voices = voiceMemory
        grains = grainMemory
        attackInc   = Float(1 / max(1, cloud.attack * sampleRate))
        releaseMul  = Float(exp(-6.9 / max(1, cloud.release * sampleRate)))   // −60 dB over `release`
        stealDec    = Float(1 / (0.006 * sampleRate))
        grainLength = max(64, cloud.size * sampleRate)
        interval    = sampleRate / max(0.5, cloud.density)
        norm        = cloud.normalisation
        pending.reserveCapacity(256)
    }

    deinit {
        voices.deallocate()
        grains.deallocate()
        lock.deallocate()
    }

    // MARK: Main thread

    func setSources(_ s: GrainSources) {
        os_unfair_lock_lock(lock)
        publishedSources = s
        os_unfair_lock_unlock(lock)
    }

    func send(_ command: Command) {
        os_unfair_lock_lock(lock)
        pending.append(command)
        os_unfair_lock_unlock(lock)
    }

    // MARK: Render thread

    /// Writes `frames` samples of the cloud into `left` / `right` (overwriting).
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        for f in 0..<frames { left[f] = 0; right[f] = 0 }

        if os_unfair_lock_trylock(lock) {
            // (Sources are published once per engine and never replaced, so this
            // assignment never releases an old set on the render thread.)
            if sources == nil, let s = publishedSources { sources = s }
            for i in 0..<pending.count { apply(pending[i]) }
            pending.removeAll(keepingCapacity: true)
            os_unfair_lock_unlock(lock)
        }
        guard let src = sources, src.rootCount > 0 else { return }

        for vi in 0..<Self.voiceCount where voices[vi].active {
            var v = voices[vi]
            let g0 = grains + vi * Self.grainsPerVoice
            var root = src.roots[Int(min(v.root, Int32(src.rootCount - 1)))]

            for f in 0..<frames {
                // Envelope.
                if v.stealing {
                    v.env -= stealDec
                    if v.env <= 0 {
                        killGrains(g0)
                        guard v.hasPending else { v.active = false; break }
                        start(&v, token: v.pendToken, root: v.pendRoot, pitch: v.pendPitch, gain: v.pendGain)
                        root = src.roots[Int(min(v.root, Int32(src.rootCount - 1)))]
                    }
                } else if v.held {
                    if v.env < 1 { v.env = min(1, v.env + attackInc) }
                } else {
                    v.env *= releaseMul
                    if v.env < 1e-4 { killGrains(g0); v.active = false; break }
                }

                // New grain?
                v.untilNext -= 1
                if v.untilNext <= 0 {
                    spawn(&v, into: g0, root: root)
                    v.untilNext = Int32(interval * (0.5 + random(&v)))
                }
                v.sweep += cloud.drift / sampleRate
                if v.sweep >= 1 { v.sweep -= 1 }

                // Sum the grains.
                var l: Float = 0, r: Float = 0
                let step = v.pitch * v.bend
                let last = root.count - 2
                for gi in 0..<Self.grainsPerVoice where g0[gi].active {
                    let i = Int(g0[gi].pos)
                    if i >= last || i < 0 { g0[gi].active = false; continue }
                    let frac = Float(g0[gi].pos - Double(i))
                    let s = root.samples[i] + (root.samples[i + 1] - root.samples[i]) * frac
                    let w = Float(0.5 - 0.5 * g0[gi].c) * s
                    l += w * g0[gi].gainL
                    r += w * g0[gi].gainR
                    let next = g0[gi].k * g0[gi].c - g0[gi].cPrev
                    g0[gi].cPrev = g0[gi].c
                    g0[gi].c = next
                    g0[gi].pos += step * g0[gi].ratio
                    g0[gi].remaining -= 1
                    if g0[gi].remaining <= 0 { g0[gi].active = false }
                }
                let amp = v.env * v.gain * root.gain * norm
                left[f]  += l * amp
                right[f] += r * amp
            }
            voices[vi] = v
        }
    }

    // MARK: Render-thread helpers

    private func apply(_ c: Command) {
        let vi = Int(c.voice)
        guard vi >= 0, vi < Self.voiceCount else { return }
        switch c.kind {
        case .on:
            if voices[vi].active && voices[vi].env > 0.001 {
                // Still sounding: fade it out over a few ms, then start the new note.
                voices[vi].stealing   = true
                voices[vi].held       = false
                voices[vi].hasPending = true
                voices[vi].pendToken  = c.token
                voices[vi].pendRoot   = c.root
                voices[vi].pendPitch  = c.pitch
                voices[vi].pendGain   = c.gain
            } else {
                killGrains(grains + vi * Self.grainsPerVoice)
                start(&voices[vi], token: c.token, root: c.root, pitch: c.pitch, gain: c.gain)
            }
        case .off:
            if voices[vi].hasPending && voices[vi].pendToken == c.token {
                voices[vi].hasPending = false            // released before it ever started
            } else if voices[vi].token == c.token {
                voices[vi].held = false
            }
        case .bend:
            if voices[vi].token == c.token && !voices[vi].stealing { voices[vi].bend = c.pitch }
        }
    }

    private func start(_ v: inout Voice, token: Int32, root: Int32, pitch: Double, gain: Float) {
        v.active = true
        v.held = true
        v.stealing = false
        v.hasPending = false
        v.env = 0
        v.gain = gain
        v.pitch = pitch
        v.bend = 1
        v.root = root
        v.token = token
        v.untilNext = 0
        v.sweep = random(&v)
    }

    private func killGrains(_ g0: UnsafeMutablePointer<Grain>) {
        for gi in 0..<Self.grainsPerVoice { g0[gi].active = false }
    }

    private func spawn(_ v: inout Voice, into g0: UnsafeMutablePointer<Grain>, root: GrainSources.Root) {
        var slot = -1
        for gi in 0..<Self.grainsPerVoice where !g0[gi].active { slot = gi; break }
        guard slot >= 0 else { return }                  // all busy: skip this one

        var ratio = pow(2.0, cloud.pitchJitter * (random(&v) * 2 - 1) / 1200)
        let u = random(&v)
        if u < cloud.octaveUp { ratio *= 2 } else if u < cloud.octaveUp + cloud.octaveDown { ratio *= 0.5 }

        let length = grainLength * (0.75 + 0.5 * random(&v))
        let span   = Double(root.hi - root.lo)
        // The sweep moves through the middle of the region; spray scatters around it.
        let tri    = v.sweep < 0.5 ? v.sweep * 2 : 2 - v.sweep * 2
        var pos    = Double(root.lo) + span * (0.5 + (tri - 0.5) * (1 - cloud.spray))
        pos += (random(&v) - 0.5) * cloud.spray * span
        let needed = length * v.pitch * v.bend * ratio + 2
        pos = max(Double(root.lo), min(pos, Double(root.hi) - needed))

        let pan   = 0.5 + (random(&v) - 0.5) * cloud.spread
        let theta = 2 * Double.pi / length
        var g = Grain()
        g.active = true
        g.pos = pos
        g.ratio = ratio
        g.remaining = Int32(length)
        g.c = 1
        g.cPrev = cos(theta)
        g.k = 2 * cos(theta)
        g.gainL = Float(cos(pan * Double.pi / 2))
        g.gainR = Float(sin(pan * Double.pi / 2))
        g0[slot] = g
    }

    /// SplitMix64 → 0..<1. Per voice, so clouds differ from note to note.
    private func random(_ v: inout Voice) -> Double {
        v.rng &+= 0x9E37_79B9_7F4A_7C15
        var z = v.rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / 9_007_199_254_740_992.0
    }
}

// MARK: - Engine

/// What AudioEngine needs from an instrument that plays recordings — the plain
/// sampler and the grain cloud share it, so every sampler code path (single
/// notes, layers, hybrids, bend, the looper) works for both.
protocol RecordedInstrumentEngine: AnyObject {
    var outputNode: AVAudioNode { get }
    var activeVoiceCount: Int { get }
    func attach(to engine: AVAudioEngine)
    func load()
    func noteOn(_ note: UInt8, velocity: UInt8, gain: Float) -> SamplerEngine.Handle?
    func noteOff(_ handle: SamplerEngine.Handle)
    func noteOff(_ note: UInt8)
    func bend(_ handle: SamplerEngine.Handle, semitones: Float)
}

extension SamplerEngine: RecordedInstrumentEngine {}

/// A sampler instrument played as a grain cloud (`SamplerInstrument.grains`).
/// Same graph shape as SamplerEngine: source → mixer (headroom) → peak limiter.
final class GranularEngine: RecordedInstrumentEngine {
    var outputNode: AVAudioNode { limiter }

    private let instrument: SamplerInstrument
    private let core: GrainCloudCore
    private var sourceNode: AVAudioSourceNode?
    private let mixNode = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))

    // Main-thread voice bookkeeping (the render thread has its own copy of what
    // matters to it; the two only meet through commands).
    private var sources: GrainSources?
    private var voiceToken = [Int32](repeating: 0, count: GrainCloudCore.voiceCount)
    private var voiceNote  = [Int?](repeating: nil, count: GrainCloudCore.voiceCount)   // held notes
    private var voiceRoot  = [Int](repeating: 0, count: GrainCloudCore.voiceCount)
    private var voiceFreeAt = [TimeInterval](repeating: 0, count: GrainCloudCore.voiceCount)
    private var stealCursor = 0

    init(instrument: SamplerInstrument) {
        self.instrument = instrument
        self.core = GrainCloudCore(cloud: instrument.grains ?? GrainCloud())
    }

    func attach(to engine: AVAudioEngine) {
        let fmt  = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let core = self.core
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.attach(mixNode)
        engine.attach(limiter)
        mixNode.outputVolume = 0.6
        engine.connect(node, to: mixNode, format: fmt)
        engine.connect(mixNode, to: limiter, format: fmt)
    }

    /// Decodes the instrument's recordings off the main thread (one velocity
    /// layer: the loudest — a cloud has no touch-dependent attack to preserve).
    func load() {
        let instrument = self.instrument
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wavMap = BundleIndex.shared.wavByFolderAndName
            let layer  = instrument.velocityLayers.last?.midiValue ?? 64
            let roots  = instrument.discoversRoots
                ? SamplerSelection.discoverRoots(keys: Array(wavMap.keys), folder: instrument.id,
                                                 layers: instrument.velocityLayers)
                : instrument.rootNotes
            var recordings: [(midi: Int, samples: [Float])] = []
            for root in roots {
                // Keyed by folder — every instrument uses the same file names.
                guard let url  = wavMap["\(instrument.id)/\(root)_\(layer)"],
                      let file = try? AVAudioFile(forReading: url),
                      let buf  = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buf)) != nil,
                      let data = buf.floatChannelData?[0] else { continue }
                assert(url.deletingLastPathComponent().lastPathComponent == instrument.id,
                       "GranularEngine[\(instrument.id)] resolved \(root) to \(url.path) — wrong folder")
                recordings.append((root, Array(UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))))
            }
            let built = GrainSources(recordings: recordings, sampleRate: 44100)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sources = built
                self.core.setSources(built)
                let summary = "GranularEngine[\(instrument.id)]: \(built.rootCount)/\(roots.count) recordings loaded"
                print(summary)
                Diagnostics.shared.log(summary)
                assert(built.rootCount == roots.count || built.rootCount == 0,
                       "GranularEngine[\(instrument.id)] loaded \(built.rootCount)/\(roots.count) recordings")
            }
        }
    }

    func noteOn(_ note: UInt8, velocity: UInt8, gain: Float) -> SamplerEngine.Handle? {
        guard let sources, let rootIndex = sources.index(nearest: Int(note)) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        // An idle voice if there is one; otherwise steal in turn (the core fades
        // the old note out over a few ms first, so stealing does not click).
        var idx = (0..<GrainCloudCore.voiceCount).first { voiceNote[$0] == nil && now >= voiceFreeAt[$0] }
        if idx == nil {
            idx = (0..<GrainCloudCore.voiceCount).first { voiceNote[$0] == nil }   // one already fading
        }
        if idx == nil {
            idx = stealCursor % GrainCloudCore.voiceCount
            stealCursor += 1
        }
        guard let voice = idx else { return nil }

        voiceToken[voice] += 1
        voiceNote[voice] = Int(note)
        voiceRoot[voice] = sources.roots[rootIndex].midi
        let level = max(0.3, Float(velocity) / 127) * max(0, min(1, gain))
        core.send(.init(kind: .on, voice: Int32(voice), token: voiceToken[voice],
                        root: Int32(rootIndex),
                        pitch: pow(2.0, Double(Int(note) - voiceRoot[voice]) / 12.0),
                        gain: level))
        return SamplerEngine.Handle(slot: voice, token: Int(voiceToken[voice]))
    }

    func noteOff(_ handle: SamplerEngine.Handle) {
        guard handle.slot >= 0, handle.slot < GrainCloudCore.voiceCount,
              Int(voiceToken[handle.slot]) == handle.token, voiceNote[handle.slot] != nil else { return }
        release(handle.slot)
    }

    func noteOff(_ note: UInt8) {
        for voice in 0..<GrainCloudCore.voiceCount where voiceNote[voice] == Int(note) { release(voice) }
    }

    private func release(_ voice: Int) {
        voiceNote[voice] = nil
        voiceFreeAt[voice] = ProcessInfo.processInfo.systemUptime + core.cloud.release
        core.send(.init(kind: .off, voice: Int32(voice), token: voiceToken[voice]))
    }

    func bend(_ handle: SamplerEngine.Handle, semitones: Float) {
        guard handle.slot >= 0, handle.slot < GrainCloudCore.voiceCount,
              Int(voiceToken[handle.slot]) == handle.token else { return }
        core.send(.init(kind: .bend, voice: Int32(handle.slot), token: voiceToken[handle.slot],
                        pitch: pow(2.0, Double(semitones) / 12.0)))
    }

    var activeVoiceCount: Int {
        let now = ProcessInfo.processInfo.systemUptime
        return (0..<GrainCloudCore.voiceCount).reduce(0) {
            $0 + ((voiceNote[$1] != nil || now < voiceFreeAt[$1]) ? 1 : 0)
        }
    }
}
