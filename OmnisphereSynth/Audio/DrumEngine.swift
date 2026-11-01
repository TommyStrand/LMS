import AVFoundation
import CoreAudio
import Foundation
import Observation
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
        }
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

    // Buffers are retained here for the engine's lifetime so SampleVoice raw pointers stay valid
    @ObservationIgnored private var sampleBuffers: [DrumVoiceID: [AVAudioPCMBuffer]] = [:]
    @ObservationIgnored private var rrIndex: [Int] = Array(repeating: 0, count: DrumVoiceID.allCases.count)

    // Lowercased filename (no extension) → URL, built by scanning the entire bundle tree.
    // Handles both flat resources and folder-reference subdirectories added in Xcode.
    @ObservationIgnored private var bundleWavMap: [String: URL] = [:]

    // MARK: Render hand-off

    // Heap-allocated so the lock has a stable address (an os_unfair_lock must
    // never be copied). Guards publishedState only.
    private let stateLock: os_unfair_lock_t = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    @ObservationIgnored private var publishedState = DrumRenderState()   // guarded by stateLock
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
    @ObservationIgnored private var shuffleBag:         [Int]  = []

    // MARK: Init

    init() {
        loadSamples()
        publishRenderState()   // didSet doesn't fire during init
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
        publishedState = state
        os_unfair_lock_unlock(stateLock)
    }

    // MARK: Playback

    func play() {
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
        beatTimer?.invalidate()
        beatTimer = nil
        beatFraction = 0
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func randomize() {
        // Shuffle-bag: refill when empty so every pattern plays before any repeats
        if shuffleBag.isEmpty {
            shuffleBag = Array(0..<DrumPattern.all.count).shuffled()
        }
        // Skip the current pattern if it happens to be next in the bag
        if shuffleBag.count > 1 && shuffleBag.last == patternIndex {
            let last = shuffleBag.removeLast()
            let next = shuffleBag.removeLast()
            shuffleBag.append(last)
            patternIndex = next
        } else {
            patternIndex = shuffleBag.removeLast()
        }
    }

    // MARK: Step sequencer

    func toggleStep(voice: DrumVoiceID, step: Int) {
        let pat = DrumPattern.all[max(0, min(patternIndex, DrumPattern.all.count - 1))]
        var hits = customHits ?? Array(pat.hits)
        let ticksPerStep = Int(pat.ticksPerBeat) / 4   // 16th-note grid
        let tick = Int32(step * ticksPerStep)
        if let idx = hits.firstIndex(where: { $0.voice == voice && $0.tick == tick }) {
            hits.remove(at: idx)
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

    private func buildBundleWavMap() {
        guard let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "wav" {
            bundleWavMap[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }

        print("DrumEngine: \(bundleWavMap.count) .wav files found in bundle")
        if bundleWavMap.isEmpty {
            print("DrumEngine: ⚠️  no WAV files found — add MusicRadar samples to the Xcode target")
        }
    }

    private func loadSamples() {
        buildBundleWavMap()
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

        for (voice, names) in specs {
            sampleBuffers[voice] = names.compactMap { loadSample(name: $0, targetFormat: fmt) }
            if let loaded = sampleBuffers[voice] {
                print("DrumEngine: \(voice) – \(loaded.count)/\(names.count) samples loaded")
            }
        }
    }

    private func loadSample(name: String, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = bundleWavMap[name.lowercased()] else {
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

        sourceNode = AVAudioSourceNode(format: fmt) { [weak self] isSilence, _, frameCount, abl in
            guard let self else { isSilence.pointee = true; return noErr }
            self.renderBlock(isSilence: isSilence, frameCount: Int(frameCount), abl: abl)
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
            spawnVoice(type: st.hits[i].voice, velocity: st.hits[i].velocity, delay: frame)
        }
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

    private func spawnVoice(type: DrumVoiceID, velocity: Float, delay: Int) {
        guard let bufs = sampleBuffers[type], !bufs.isEmpty else { return }
        let idx = rrIndex[type.rawValue] % bufs.count
        rrIndex[type.rawValue] = idx + 1
        let voice = SampleVoice(buffer: bufs[idx], velocity: velocity, delay: delay)
        for i in 0 ..< voicePool.count {
            if voicePool[i] == nil || voicePool[i]!.done { voicePool[i] = voice; return }
        }
        voicePool[0] = voice  // pool full: steal oldest slot
    }
}
