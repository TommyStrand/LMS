import AVFoundation
import CoreAudio
import Foundation
import Observation
import QuartzCore
import os

// MARK: - Sample voice (value type, pool-allocated, no ARC in hot path)

struct SampleVoice {
    private let leftData:  UnsafeMutablePointer<Float>
    private let rightData: UnsafeMutablePointer<Float>
    private let frameLen:  Int
    let velocity: Float
    var position: Int = 0
    /// Frames of silence before the sample starts. Lets a whole buffer's hits be
    /// spawned up front, each starting on its exact frame (sample-accurate).
    var delay: Int = 0

    init(buffer: AVAudioPCMBuffer, velocity: Float, delay: Int = 0) {
        let ch    = buffer.floatChannelData!
        leftData  = ch[0]
        rightData = buffer.format.channelCount > 1 ? ch[1] : ch[0]
        frameLen  = Int(buffer.frameLength)
        self.velocity = velocity
        self.delay    = max(0, delay)
    }

    var done: Bool { position >= frameLen }

    mutating func nextStereo() -> (Float, Float) {
        if delay > 0 { delay -= 1; return (0, 0) }
        guard position < frameLen else { return (0, 0) }
        let l = leftData[position]  * velocity
        let r = rightData[position] * velocity
        position += 1
        return (l, r)
    }
}

// MARK: - Pure hit scheduling (no AVFoundation — unit-tested in SuperNovaPadTests)

/// Finds which pattern hits fall inside one render buffer, and on which frame.
/// Replaces a per-SAMPLE scan of every hit (44 100 × hits/sec) with one pass
/// per buffer. A hit fires on frame f when its tick lies in
/// [start + f·tpf, start + (f+1)·tpf) modulo the loop — the same rule the old
/// per-sample loop applied, so timing is unchanged.
enum DrumSchedule {
    /// Calls `body(hitIndex, frame)` for every hit in this buffer. Non-escaping
    /// closure, no allocation — safe on the render thread.
    static func forEachHit(_ hits: [DrumHit], startTick: Double, ticksPerFrame: Double,
                           frameCount: Int, loopTicks: Double,
                           _ body: (Int, Int) -> Void) {
        guard ticksPerFrame > 0, loopTicks > 0, frameCount > 0 else { return }
        let span = ticksPerFrame * Double(frameCount)
        var s = startTick.truncatingRemainder(dividingBy: loopTicks)
        if s < 0 { s += loopTicks }
        for i in hits.indices {
            var off = (Double(hits[i].tick) - s).truncatingRemainder(dividingBy: loopTicks)
            if off < 0 { off += loopTicks }
            guard off < span else { continue }
            body(i, min(frameCount - 1, Int(off / ticksPerFrame)))
        }
    }
}

// MARK: - Render state hand-off

/// Everything the drum render thread reads, published as one immutable value by
/// the main thread (same try-lock pattern as AudioEngine's RenderSnapshot).
private struct DrumRenderState {
    /// Sample buffers per voice (index = DrumVoiceID.rawValue). Empty until the
    /// background load finishes; then published like any other render state, so
    /// the render thread never reads a bank that is still being filled in.
    var bank: [[AVAudioPCMBuffer]] = []
    var hits: [DrumHit] = []
    var loopTicks: Double = 1
    var ticksPerBeat: Double = 1
    var bpm: Double = 90
    var grit: Float = 0
    var masterVolume: Float = 0.8
    var isPlaying = false
    /// Bumped by the main thread to ask the render thread to restart the loop
    /// (play, pattern change). The render thread owns tickPosition outright.
    var resetGeneration = 0
}

// MARK: - DrumEngine

// @Observable: the UI-facing properties below are tracked; everything the render
// thread reads is @ObservationIgnored so the audio callback never enters the
// observation registrar (see AudioEngine for the full rationale).
//
// THREADING: the observed properties are main-thread only. The render thread
// never reads them — it reads a DrumRenderState snapshot through a non-blocking
// try-lock, and owns tickPosition / the voice pool outright. Every setter below
// republishes the snapshot.
@Observable
final class DrumEngine {

    // MARK: Observed (UI-facing, main thread only)

    var isPlaying   = false {
        didSet { publishRenderState() }
    }
    var bpm: Double = 90 {
        didSet { updateDelayTime(); publishRenderState() }
    }
    var patternIndex: Int = 0 {
        didSet {
            // Keep the stored value in range, so views that read patternIndex
            // directly (e.g. DrumPattern.all[patternIndex]) can't index out of
            // bounds. Whether this assignment re-enters didSet under @Observable
            // doesn't matter: the work below is idempotent (an extra generation
            // bump / publish is harmless).
            let idx = max(0, min(patternIndex, DrumPattern.all.count - 1))
            if patternIndex != idx { patternIndex = idx }
            resetGeneration &+= 1          // render thread restarts the loop
            customHits = nil               // publishes via customHits.didSet
            // Mood patterns are written for a tempo (a heartbeat at 120 BPM isn't
            // calm). Post-rock / imported patterns have none and keep the tempo.
            if let suggested = DrumPattern.all[idx].suggestedBPM, suggested != bpm {
                bpm = suggested            // publishes via bpm.didSet
            }
        }
    }
    /// Which collection RANDOM and ‹ › browse within. nil = all patterns.
    var collectionFilter: DrumCollection? = .mood {
        didSet { shuffleBag = [] }         // bag was built for the old filter
    }
    var delayMix: Float = 0.22 {
        didSet { delayNode.wetDryMix = delayMix * 100 }
    }
    var shimmer: Float = 0.32 {
        didSet { reverbNode.wetDryMix = shimmer * 100 }
    }
    var grit: Float = 0.0 {
        didSet { publishRenderState() }
    }
    var masterVolume: Float = 0.8 {
        didSet { publishRenderState() }
    }
    /// Loop position 0..<1 for the step highlight. Copied from the render thread
    /// by a main-thread display timer while playing (no audio-thread dispatch).
    var beatFraction: Double = 0
    var customHits: [DrumHit]? = nil {
        didSet { publishRenderState() }
    }

    // MARK: Audio graph

    private let audioEngine = AVAudioEngine()
    var avEngine: AVAudioEngine { audioEngine }
    private let delayNode   = AVAudioUnitDelay()
    private let reverbNode  = AVAudioUnitReverb()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode!

    // MARK: Sample bank (main-thread write before engine start, audio-thread read only)

    // Main-thread copy of the loaded bank. Buffers are retained for the engine's
    // lifetime so SampleVoice's raw pointers into them stay valid.
    @ObservationIgnored private var sampleBank: [[AVAudioPCMBuffer]] = []
    // Round-robin position per voice — render thread only.
    @ObservationIgnored private var rrIndex: [Int] = Array(repeating: 0, count: DrumVoiceID.allCases.count)

    // MARK: Render hand-off

    // Heap-allocated so the lock has a stable address (an os_unfair_lock must
    // never be copied). Guards publishedState only.
    private let stateLock: os_unfair_lock_t = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    @ObservationIgnored private var publishedState = DrumRenderState()   // guarded by stateLock
    @ObservationIgnored private var retiredStates: [DrumRenderState] = []  // main thread only
    @ObservationIgnored private var resetGeneration = 0                  // main thread only
    @ObservationIgnored private var beatTimer: Timer?                    // main thread only

    // MARK: Render-thread-only state (never touched by the main thread)

    @ObservationIgnored private var cachedState      = DrumRenderState()
    @ObservationIgnored private var seenGeneration   = 0
    @ObservationIgnored private var wasPlaying       = false
    @ObservationIgnored private var voicePool:       [SampleVoice?] = Array(repeating: nil, count: 32)
    @ObservationIgnored private var tickPosition:    Double = 0
    // Written by the render thread, read by the beat timer. A plain aligned
    // Double: a torn read is impossible on arm64 and the worst case is a
    // one-frame-stale step highlight.
    @ObservationIgnored private var renderBeatFraction: Double = 0
    // Beat clock for the looper (see beatsNow()). `totalTicks` is render-thread
    // only: ticks since the loop last (re)started, NOT wrapped at the loop end.
    // `renderBeatZeroTime` is written by the render thread and read by the main
    // thread (same single-aligned-Double hand-off as renderBeatFraction): the
    // host time, in seconds, at which beat 0 reached the output at the current
    // tempo. NaN = no valid clock (stopped, or not rendered since play()).
    @ObservationIgnored private var totalTicks: Double = 0
    @ObservationIgnored private var renderBeatZeroTime: Double = .nan
    private let hostTimeToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()
    @ObservationIgnored private var shuffleBag:         [Int]  = []

    // MARK: Init

    init() {
        // Start on the first pattern at its own tempo (didSet doesn't fire in init).
        if let suggested = DrumPattern.all.first?.suggestedBPM { bpm = suggested }
        publishRenderState()   // didSet doesn't fire during init
        loadSamplesInBackground()
        setupAudio()
    }

    deinit {
        beatTimer?.invalidate()
        stateLock.deinitialize(count: 1)
        stateLock.deallocate()
    }

    /// Rebuilds the render snapshot from the observed properties and swaps it in.
    /// Main thread only; holds the lock just long enough to assign one struct.
    private func publishRenderState() {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        let state = DrumRenderState(
            bank:            sampleBank,
            hits:            customHits ?? pat.hits,
            loopTicks:       Double(max(1, pat.loopTicks)),
            ticksPerBeat:    Double(pat.ticksPerBeat),
            bpm:             bpm,
            grit:            grit,
            masterVolume:    masterVolume,
            isPlaying:       isPlaying,
            resetGeneration: resetGeneration
        )
        os_unfair_lock_lock(stateLock)
        let previous = publishedState
        publishedState = state
        os_unfair_lock_unlock(stateLock)
        // Keep recent states alive on the main thread so the render thread never
        // performs the final release (free) of a hits array — see AudioEngine.retire.
        retiredStates.append(previous)
        if retiredStates.count > 8 { retiredStates.removeFirst() }
    }

    // MARK: Playback

    /// Every pattern is in 4/4 (see DrumPatterns.swift).
    static let beatsPerBar = 4.0

    /// The drum clock: beats since the loop last (re)started — continuous, not
    /// wrapped at the loop end, and bar lines fall on multiples of `beatsPerBar`.
    /// nil while stopped. Derived from the audio output's own timestamps, so it
    /// tracks what is actually heard rather than a UI timer. Main thread.
    func beatsNow() -> Double? {
        guard isPlaying else { return nil }
        let zero = renderBeatZeroTime
        guard zero.isFinite else { return nil }
        return max(0, (CACurrentMediaTime() - zero) * bpm / 60.0)
    }

    func play() {
        renderBeatZeroTime = .nan  // old clock is void; the first new buffer sets it
        resetGeneration &+= 1      // render thread restarts the loop from tick 0
        isPlaying = true           // publishes
        beatTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.beatFraction = self.renderBeatFraction
        }
        RunLoop.main.add(t, forMode: .common)
        beatTimer = t
    }

    func stop() {
        isPlaying = false          // publishes
        renderBeatZeroTime = .nan
        beatTimer?.invalidate()
        beatTimer = nil
        beatFraction = 0
    }

    func togglePlay() { isPlaying ? stop() : play() }

    /// Pattern indices in the current collection filter (all patterns if the
    /// filter is nil or the filtered collection is empty, e.g. no imported MIDI).
    var browsableIndices: [Int] {
        let all = Array(DrumPattern.all.indices)
        guard let filter = collectionFilter else { return all }
        let filtered = all.filter { DrumPattern.all[$0].collection == filter }
        return filtered.isEmpty ? all : filtered
    }

    /// Select a collection; jumps to its first pattern if the current one isn't in it.
    func selectCollection(_ collection: DrumCollection?) {
        collectionFilter = collection
        let pool = browsableIndices
        if !pool.contains(patternIndex), let first = pool.first { patternIndex = first }
    }

    /// Step to the previous (-1) / next (+1) pattern within the current filter, wrapping.
    func stepPattern(by delta: Int) {
        let pool = browsableIndices
        guard !pool.isEmpty else { return }
        let pos = pool.firstIndex(of: patternIndex) ?? (delta > 0 ? -1 : 0)
        patternIndex = pool[((pos + delta) % pool.count + pool.count) % pool.count]
    }

    func randomize() {
        // Shuffle-bag within the current filter: every pattern plays before any repeats.
        let pool = browsableIndices
        if shuffleBag.isEmpty || !shuffleBag.allSatisfy(pool.contains) {
            shuffleBag = pool.shuffled()
        }
        // Skip the current pattern if it happens to be next in the bag
        if shuffleBag.count > 1 && shuffleBag.last == patternIndex {
            let last = shuffleBag.removeLast()
            let next = shuffleBag.removeLast()
            shuffleBag.append(last)
            patternIndex = next
        } else if let next = shuffleBag.popLast() {
            patternIndex = next
        }
    }

    // MARK: Step sequencer

    func toggleStep(voice: DrumVoiceID, step: Int) {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        var hits = customHits ?? Array(pat.hits)
        let ticksPerStep = Int(pat.ticksPerBeat) / 4   // 16th-note grid
        let tick = Int32(step * ticksPerStep)
        // Match by STEP, not exact tick: humanised hits sit slightly late inside
        // their step, so an exact-tick match never found them and tapping a lit
        // cell added a duplicate instead of removing the hit.
        let inStep = { (h: DrumHit) in h.voice == voice && Int(h.tick) / ticksPerStep == step }
        if hits.contains(where: inStep) {
            hits.removeAll(where: inStep)
        } else {
            hits.append(DrumHit(tick: tick, voice: voice, velocity: 0.85))
            hits.sort { $0.tick < $1.tick }
        }
        customHits = hits          // publishes
    }

    func resetPattern() {
        customHits = nil           // publishes
    }

    func activeSteps(for voice: DrumVoiceID) -> Set<Int> {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        let hits = customHits ?? pat.hits
        let ticksPerStep = Int(pat.ticksPerBeat) / 4
        return Set(hits.filter { $0.voice == voice }.map { Int($0.tick) / ticksPerStep })
    }

    // MARK: Sample loading

    /// Reads and converts the kit on a background queue (it used to block the main
    /// thread at launch), then hands the bank to the render thread via the state
    /// snapshot. Until then the drums simply render silence.
    private func loadSamplesInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bank = DrumEngine.loadBank()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampleBank = bank
                self.publishRenderState()
            }
        }
    }

    /// Thread-safe: touches only the immutable BundleIndex and local values.
    private static func loadBank() -> [[AVAudioPCMBuffer]] {
        let index = BundleIndex.shared
        print("DrumEngine: \(index.wavByLowercasedName.count) .wav files found in bundle")
        if index.wavByLowercasedName.isEmpty {
            print("DrumEngine: ⚠️  no WAV files found — add MusicRadar samples to the Xcode target")
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        // Each tuple: (voice, [bundle resource names without extension])
        // Files must be added to the Xcode target from the MusicRadar pack.
        let specs: [(DrumVoiceID, [String])] = [
            (.kick,
             (1...8).map { String(format: "CYCdh_K1close_Kick-%02d", $0) }),

            (.snare,
             (1...5).map { String(format: "CYCdh_K1close_Snr-%02d", $0) }),

            (.hihat,
             (1...9).map { String(format: "CYCdh_K1close_ClHat-%02d", $0) }),

            (.hihatOpen,
             (1...7).map { String(format: "CYCdh_K1close_OpHat-%02d", $0) }),

            (.rideBell,
             ["CYCdh_Kurz01-Ride01", "CYCdh_Kurz01-Ride02"]),

            (.crash,
             (1...7).map { String(format: "CyCdh_K3Crash-%02d", $0) }),

            (.tomHi,
             ["CYCdh_K5-Tom01a", "CYCdh_K5-Tom01b", "CYCdh_K5-Tom01c"]),

            (.tomMid,
             ["CYCdh_K5-Tom02a", "CYCdh_K5-Tom02b", "CYCdh_K5-Tom02c"]),

            (.tomLo,
             ["CYCdh_K5-Tom03a", "CYCdh_K5-Tom03b", "CYCdh_K5-Tom03c"]),
        ]

        var bank = [[AVAudioPCMBuffer]](repeating: [], count: DrumVoiceID.allCases.count)
        for (voice, names) in specs {
            let loaded = names.compactMap { loadSample(name: $0, targetFormat: fmt) }
            bank[voice.rawValue] = loaded
            print("DrumEngine: \(voice) – \(loaded.count)/\(names.count) samples loaded")
        }
        return bank
    }

    private static func loadSample(name: String, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = BundleIndex.shared.wavByLowercasedName[name.lowercased()] else {
            print("DrumEngine: missing \(name).wav")
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            print("DrumEngine: can't open \(name).wav")
            return nil
        }

        let fileFmt = file.processingFormat
        let frames  = AVAudioFrameCount(file.length)
        guard let src = AVAudioPCMBuffer(pcmFormat: fileFmt, frameCapacity: frames),
              (try? file.read(into: src)) != nil else { return nil }

        // Fast path: sample rate already matches — SampleVoice handles mono natively
        // (mirrors ch[0] to both L and R), so skip any channel-count conversion.
        if fileFmt.sampleRate == targetFormat.sampleRate { return src }

        // Only convert when sample rate differs; keep the file's native channel count
        // to avoid the AVAudioConverter mono→stereo failure mode.
        let nativeFmt = AVAudioFormat(standardFormatWithSampleRate: targetFormat.sampleRate,
                                      channels: fileFmt.channelCount)!
        let dstFrames = AVAudioFrameCount(
            Double(frames) * targetFormat.sampleRate / fileFmt.sampleRate
        ) + 1
        guard let dst       = AVAudioPCMBuffer(pcmFormat: nativeFmt, frameCapacity: dstFrames),
              let converter = AVAudioConverter(from: fileFmt, to: nativeFmt) else { return nil }

        var err: NSError?
        var done = false
        converter.convert(to: dst, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; done = true; return src
        }
        return err == nil ? dst : nil
    }

    // MARK: Audio graph setup

    private func setupAudio() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        sourceNode = AVAudioSourceNode(format: fmt) { [weak self] isSilence, timestamp, frameCount, abl in
            guard let self else { isSilence.pointee = true; return noErr }
            self.renderBlock(isSilence: isSilence, hostTime: timestamp.pointee.mHostTime,
                             frameCount: Int(frameCount), abl: abl)
            return noErr
        }

        audioEngine.attach(sourceNode)
        audioEngine.attach(delayNode)
        audioEngine.attach(reverbNode)

        audioEngine.connect(sourceNode, to: delayNode,                format: fmt)
        audioEngine.connect(delayNode,  to: reverbNode,               format: fmt)
        audioEngine.connect(reverbNode, to: audioEngine.mainMixerNode, format: fmt)

        delayNode.delayTime     = 60.0 / bpm * 0.75
        delayNode.feedback      = 28
        delayNode.lowPassCutoff = 5500
        delayNode.wetDryMix     = delayMix * 100

        reverbNode.loadFactoryPreset(.largeHall)
        reverbNode.wetDryMix = shimmer * 100

        do { try audioEngine.start() }
        catch { print("DrumEngine: engine start failed – \(error)") }

        observeAudioSession()
    }

    // MARK: - Route / interruption recovery

    private func observeAudioSession() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: .main
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

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.audioEngine.isRunning else { return }
            self.restartEngineIfNeeded()
        }
    }

    private func restartEngineIfNeeded() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()
        do { try audioEngine.start() }
        catch { print("DrumEngine: restart failed – \(error)"); return }
        // Restore effect parameters cleared by reset()
        delayNode.delayTime     = 60.0 / bpm * 0.75
        delayNode.feedback      = 28
        delayNode.lowPassCutoff = 5500
        delayNode.wetDryMix     = delayMix * 100
        reverbNode.wetDryMix    = shimmer * 100
    }

    private func updateDelayTime() {
        delayNode.delayTime = 60.0 / bpm * 0.75
    }

    // MARK: Render block

    private func renderBlock(isSilence: UnsafeMutablePointer<ObjCBool>,
                             hostTime: UInt64,
                             frameCount: Int,
                             abl: UnsafeMutablePointer<AudioBufferList>) {
        // Non-blocking read of the published state; if the main thread is
        // mid-publish, keep last buffer's copy. The audio thread never waits.
        if os_unfair_lock_trylock(stateLock) {
            cachedState = publishedState
            os_unfair_lock_unlock(stateLock)
        }
        let st = cachedState

        // Restart requests (play, pattern change) — the render thread is the only
        // writer of tickPosition, so this can't race the main thread.
        if st.resetGeneration != seenGeneration {
            seenGeneration = st.resetGeneration
            tickPosition   = 0
            totalTicks     = 0
        }
        // Starting from stopped: drop any tail left over from the last run so it
        // doesn't resume mid-sample. (A pattern change while playing keeps tails.)
        if st.isPlaying && !wasPlaying {
            for i in 0 ..< voicePool.count { voicePool[i] = nil }
        }
        wasPlaying = st.isPlaying

        let bufList = UnsafeMutableAudioBufferListPointer(abl)
        for buf in bufList { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }

        guard st.isPlaying else { isSilence.pointee = true; return }
        guard let lPtr = bufList[0].mData?.assumingMemoryBound(to: Float.self),
              let rPtr = (bufList.count > 1 ? bufList[1].mData : bufList[0].mData)?
                .assumingMemoryBound(to: Float.self)
        else { return }

        let loopTicks     = st.loopTicks
        let ticksPerFrame = (st.bpm / 60.0) * st.ticksPerBeat / 44100.0
        let grit          = st.grit
        let volume        = st.masterVolume

        // Schedule this whole buffer's hits ONCE (was: scan every hit every
        // sample). Each voice is delayed to start on its exact frame.
        DrumSchedule.forEachHit(st.hits, startTick: tickPosition, ticksPerFrame: ticksPerFrame,
                                frameCount: frameCount, loopTicks: loopTicks) { i, frame in
            spawnVoice(type: st.hits[i].voice, velocity: st.hits[i].velocity, delay: frame, bank: st.bank)
        }
        // Beat clock: when did beat 0 reach the output, at this tempo? `hostTime`
        // is when this buffer's first frame plays (0 if the host didn't stamp it).
        if st.ticksPerBeat > 0, st.bpm > 0 {
            let bufferStart = Double(hostTime != 0 ? hostTime : mach_absolute_time()) * hostTimeToSeconds
            renderBeatZeroTime = bufferStart - (totalTicks / st.ticksPerBeat) * 60.0 / st.bpm
        }
        totalTicks  += ticksPerFrame * Double(frameCount)
        tickPosition = (tickPosition + ticksPerFrame * Double(frameCount))
            .truncatingRemainder(dividingBy: loopTicks)
        renderBeatFraction = tickPosition / loopTicks

        for frame in 0 ..< frameCount {
            var l: Float = 0
            var r: Float = 0
            for i in 0 ..< voicePool.count {
                guard voicePool[i] != nil else { continue }
                if voicePool[i]!.done { voicePool[i] = nil; continue }
                let (sl, sr) = voicePool[i]!.nextStereo()
                l += sl; r += sr
            }

            if grit > 0 {
                let d = Float(1.0 + Double(grit) * 9.0)
                l = tanh(l * d) / d
                r = tanh(r * d) / d
            }

            lPtr[frame] = l * volume
            rPtr[frame] = r * volume
        }
    }

    // MARK: Voice pool (render thread only)

    private func spawnVoice(type: DrumVoiceID, velocity: Float, delay: Int, bank: [[AVAudioPCMBuffer]]) {
        guard type.rawValue < bank.count else { return }      // bank still loading
        let bufs = bank[type.rawValue]
        guard !bufs.isEmpty else { return }
        let idx = rrIndex[type.rawValue] % bufs.count
        rrIndex[type.rawValue] = idx + 1
        let voice = SampleVoice(buffer: bufs[idx], velocity: velocity, delay: delay)
        for i in 0 ..< voicePool.count {
            if voicePool[i] == nil || voicePool[i]!.done { voicePool[i] = voice; return }
        }
        voicePool[0] = voice  // pool full: steal oldest slot
    }
}
