import Foundation
import Combine
import Observation

/// MIDI-event looper. Records note-on/off events (with timestamps) as the user
/// plays and plays them back on a repeating timer. Wire-up:
///   looper.audioEngine = engine
///   engine.looper      = looper   ← engine calls recordOn/Off from noteOn/Off
///
/// Looper playback calls noteOn/Off with `fromLooper: true`, so its own output is
/// never re-recorded (which would accumulate notes exponentially). Playback uses
/// its own touch-ID space (`playbackID`, always negative) so a looped note can
/// never collide with a live finger or MIDI note.
///
/// Sync to drums (`syncToDrums`, the SYNC button): when the drum machine is
/// running while a loop is recorded, the loop is snapped to the drums' bar grid
/// (`LoopSync.align`: starts on a bar line, lasts a whole number of bars) and is
/// then played from the DRUM CLOCK (`DrumEngine.beatsNow()`) instead of the wall
/// clock — so it stays locked to the beat indefinitely and follows tempo changes.
/// With the drums stopped, or SYNC off, it is a free loop exactly as before.
@Observable
final class LooperEngine {

    var isRecording = false
    var isPlaying   = false
    var progress: Double = 0   // 0–1, position within the loop
    /// Length in bars of the current loop if it was recorded in sync with the
    /// drums; 0 for a free loop.
    private(set) var syncedBars = 0
    /// Lock new loops to the drum machine's bars (when it is playing). Persisted.
    var syncToDrums: Bool = (UserDefaults.standard.object(forKey: "looperSyncToDrums") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(syncToDrums, forKey: "looperSyncToDrums") }
    }

    @ObservationIgnored weak var audioEngine: AudioEngine?
    @ObservationIgnored weak var drumEngine: DrumEngine?

    // MARK: - Internal event store

    struct Event {
        let t: Double        // seconds from loop start
        let touchID: Int     // already mapped to the looper's ID space (playbackID)
        let noteOn: Bool
        let note: Int
        let velocity: Float
        let x: Float
        let y: Float

        func at(_ time: Double) -> Event {
            Event(t: time, touchID: touchID, noteOn: noteOn, note: note,
                  velocity: velocity, x: x, y: y)
        }
    }

    /// How a drum-synced loop is tied to the drum clock: the beat its timeline
    /// starts on (a bar line) and the tempo it was recorded at (event times are
    /// seconds at that tempo).
    private struct Sync {
        var originBeat: Double
        let bpm: Double
    }

    @ObservationIgnored private var events: [Event] = []
    @ObservationIgnored private var loopDuration: Double = 0
    @ObservationIgnored private var recordStart: Date?
    @ObservationIgnored private var recordStartBeat: Double?   // drum beat at record start, if syncing
    @ObservationIgnored private var sync: Sync?

    @ObservationIgnored private var schedule = LoopSchedule.State()
    @ObservationIgnored private var playbackStart: Date?
    @ObservationIgnored private var onDrumClock = false        // which clock the last tick used
    @ObservationIgnored private var lastElapsed: Double = 0
    @ObservationIgnored private var tickTimer:     AnyCancellable?
    @ObservationIgnored private var progressTimer: AnyCancellable?

    // MARK: - Recording (called from AudioEngine.noteOn/Off)

    /// The looper's touch-ID space: always NEGATIVE. Live IDs are positive (UITouch
    /// hashes, MIDI 0x10000+note), so playback can't collide with — and release — a
    /// note someone is holding. Distinct inputs map to distinct outputs.
    static func playbackID(for touchID: Int) -> Int { -(touchID & Int.max) - 1 }

    func recordOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        guard isRecording, let start = recordStart else { return }
        events.append(Event(t: Date().timeIntervalSince(start),
                            touchID: Self.playbackID(for: touchID),
                            noteOn: true, note: note,
                            velocity: velocity, x: x, y: y))
    }

    func recordOff(touchID: Int) {
        guard isRecording, let start = recordStart else { return }
        events.append(Event(t: Date().timeIntervalSince(start),
                            touchID: Self.playbackID(for: touchID),
                            noteOn: false, note: 0,
                            velocity: 0, x: 0, y: 0))
    }

    // MARK: - Public controls

    func startRecording() {
        guard !isRecording else { return }
        if isPlaying { stopPlayback() }
        events = []
        loopDuration = 0
        sync = nil
        syncedBars = 0
        recordStart = Date()
        recordStartBeat = syncToDrums ? drumEngine?.beatsNow() : nil
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, let start = recordStart else { return }
        let rawDuration = Date().timeIntervalSince(start)
        recordStart = nil
        isRecording = false

        // Drums were running at both ends of the take (and weren't restarted in
        // between): snap the loop to their bar grid and tie it to their clock.
        if let startBeat = recordStartBeat, let drum = drumEngine,
           let stopBeat = drum.beatsNow(), stopBeat > startBeat, !events.isEmpty {
            let bpm = drum.bpm
            let aligned = LoopSync.align(eventTimes: events.map(\.t),
                                         recordStartBeat: startBeat, stopBeat: stopBeat,
                                         bpm: bpm, beatsPerBar: DrumEngine.beatsPerBar)
            var kept: [Event] = []
            for (event, time) in zip(events, aligned.times) {
                if let time { kept.append(event.at(time)) }
            }
            events       = kept
            loopDuration = aligned.loopDuration
            sync         = Sync(originBeat: aligned.originBeat, bpm: bpm)
            syncedBars   = aligned.bars
        } else {
            loopDuration = rawDuration
        }
        recordStartBeat = nil
        if !events.isEmpty { startPlayback() }
    }

    func togglePlayback() {
        if isPlaying { stopPlayback() } else if hasLoop { startPlayback() }
    }

    func clear() {
        stopPlayback()
        events = []
        loopDuration = 0
        sync = nil
        syncedBars = 0
    }

    var hasLoop: Bool { !events.isEmpty }

    // MARK: - Playback

    /// Position on the loop's own timeline — seconds at the recorded tempo, growing
    /// across passes — and which clock produced it. A synced loop reads the drum
    /// clock whenever the drums are running (and SYNC is on); otherwise, and for
    /// free loops, it is wall-clock time since `playbackStart`.
    private func elapsedNow() -> (elapsed: Double, drumClock: Bool)? {
        guard loopDuration > 0 else { return nil }
        if var tie = sync, syncToDrums, let beats = drumEngine?.beatsNow() {
            if beats < tie.originBeat {
                // The drums restarted (their beat count went back to 0). Move the
                // loop's origin back by whole loops — still on the bar grid — so
                // the timeline keeps growing from here. (Folding the negative time
                // into 0..<loop on every call instead made each loop boundary look
                // like a backward jump, and the resync dropped the downbeat notes.)
                let loopBeats = loopDuration * tie.bpm / 60.0
                tie.originBeat -= ((tie.originBeat - beats) / loopBeats).rounded(.up) * loopBeats
                sync = tie
            }
            return ((beats - tie.originBeat) * 60.0 / tie.bpm, true)
        }
        guard let start = playbackStart else { return nil }
        return (Date().timeIntervalSince(start), false)
    }

    private func startPlayback() {
        guard loopDuration > 0, !events.isEmpty else { return }
        isPlaying = true
        playbackStart = Date()
        if let now = elapsedNow(), now.drumClock {
            // Join the drums mid-bar: skip what "already happened" this pass.
            onDrumClock = true
            lastElapsed = now.elapsed
            // Stopping a take a moment after the bar line must not swallow the
            // downbeat of the first pass: within the grace window those notes are
            // played (slightly late) rather than skipped.
            schedule = LoopSchedule.State(resumingAt: now.elapsed, eventTimes: events.map(\.t),
                                          loopDuration: loopDuration, grace: 0.2)
        } else {
            onDrumClock = false
            lastElapsed = 0
            schedule = LoopSchedule.State()
        }

        // 8 ms tick ≈ ~125 Hz — fine enough resolution for musical timing
        tickTimer = Timer.publish(every: 0.008, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        progressTimer = Timer.publish(every: 0.033, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateProgress() }
    }

    private func stopPlayback() {
        tickTimer?.cancel();    tickTimer = nil
        progressTimer?.cancel(); progressTimer = nil
        isPlaying = false
        progress = 0
        playbackStart = nil
        releaseHeldNotes()
    }

    /// Release every note the looper may be holding.
    private func releaseHeldNotes() {
        let ids = Set(events.filter { $0.noteOn }.map { $0.touchID })
        ids.forEach { audioEngine?.noteOff(touchID: $0, fromLooper: true) }
    }

    /// The timeline jumped (clock switch, drums restarted, tempo change): drop
    /// held notes and carry on from the new position without replaying the past.
    private func resync(at elapsed: Double) {
        releaseHeldNotes()
        // Small grace: a resync that lands a few ms past a bar line still plays
        // the notes on that bar line.
        schedule = LoopSchedule.State(resumingAt: elapsed, eventTimes: events.map(\.t),
                                      loopDuration: loopDuration, grace: 0.03)
    }

    private func tick() {
        guard isPlaying, var now = elapsedNow() else { return }
        if now.drumClock != onDrumClock {
            if !now.drumClock {
                // Drums stopped (or SYNC switched off): keep going from the same
                // place in the loop on the wall clock.
                let phase = lastElapsed.truncatingRemainder(dividingBy: loopDuration)
                playbackStart = Date().addingTimeInterval(-phase)
                now = (phase, false)
            }
            onDrumClock = now.drumClock
            resync(at: now.elapsed)
        } else if now.elapsed < lastElapsed - 0.05 || now.elapsed > lastElapsed + 1.0 {
            resync(at: now.elapsed)
        }
        lastElapsed = now.elapsed

        let step = LoopSchedule.advance(&schedule, eventTimes: events.map(\.t),
                                        loopDuration: loopDuration, elapsed: now.elapsed)
        for i in step.tail { fire(events[i]) }      // end of the previous pass, late
        if step.wrapped {
            // Loop wrapped — silence any notes still held from the previous pass.
            releaseHeldNotes()
        }
        for i in step.fire { fire(events[i]) }
    }

    private func fire(_ ev: Event) {
        guard let eng = audioEngine else { return }
        if ev.noteOn {
            eng.noteOn(touchID: ev.touchID, note: ev.note,
                       velocity: ev.velocity, x: ev.x, y: ev.y, fromLooper: true)
        } else {
            eng.noteOff(touchID: ev.touchID, fromLooper: true)
        }
    }

    private func updateProgress() {
        guard let now = elapsedNow() else { progress = 0; return }
        progress = (now.elapsed / loopDuration).truncatingRemainder(dividingBy: 1.0)
    }
}

// MARK: - Pure drum-sync maths (no timers/Date — unit-tested in SuperNovaPadTests)

/// Snaps a freshly recorded take onto the drum machine's bar grid.
enum LoopSync {
    struct Result {
        /// New time for each event (seconds from the loop start); nil = the event
        /// falls outside the loop and is dropped.
        let times: [Double?]
        /// Drum beat the loop's timeline starts on — always a bar line.
        let originBeat: Double
        let loopDuration: Double    // seconds, a whole number of bars
        let bars: Int
    }

    /// A first note this close before a bar line is an early downbeat, not the
    /// tail of the previous bar.
    static let anticipationBeats = 0.5

    /// - eventTimes: ascending, seconds from the moment record was pressed.
    /// - recordStartBeat / stopBeat: the drum clock when record was pressed / stopped.
    ///
    /// The loop starts on the bar line at or before the FIRST NOTE (pressing
    /// record early costs nothing), or the next bar line if that note anticipated
    /// it. Its length is the take rounded to the nearest whole bar, at least one.
    static func align(eventTimes: [Double], recordStartBeat: Double, stopBeat: Double,
                      bpm: Double, beatsPerBar: Double) -> Result {
        guard bpm > 0, beatsPerBar > 0 else {
            return Result(times: eventTimes.map { Optional($0) }, originBeat: recordStartBeat,
                          loopDuration: max(0, stopBeat - recordStartBeat), bars: 0)
        }
        let secondsPerBeat = 60.0 / bpm
        let firstBeat = recordStartBeat + (eventTimes.first ?? 0) / secondsPerBeat
        var originBar = (firstBeat / beatsPerBar).rounded(.down)
        if firstBeat - originBar * beatsPerBar > beatsPerBar - anticipationBeats { originBar += 1 }
        let originBeat = originBar * beatsPerBar

        let shift = (recordStartBeat - originBeat) * secondsPerBeat
        let lengthBeats = max(0, stopBeat - originBeat)
        let bars = max(1, Int((lengthBeats / beatsPerBar).rounded()))
        let loopDuration = Double(bars) * beatsPerBar * secondsPerBeat

        let times: [Double?] = eventTimes.map { t in
            let moved = max(0, t + shift)          // an anticipated note lands on the downbeat
            return moved < loopDuration ? moved : nil
        }
        return Result(times: times, originBeat: originBeat, loopDuration: loopDuration, bars: bars)
    }
}

// MARK: - Pure loop scheduling (no timers/Date — unit-tested in SuperNovaPadTests)

/// Decides which recorded events fire for a given elapsed playback time. Pulled
/// out of `LooperEngine.tick()` so the wrap-around and cursor logic can be tested
/// deterministically instead of by listening for dropped or doubled notes.
enum LoopSchedule {
    struct State {
        var cursor   = 0    // index of the next event to fire within this pass
        var lastPass = -1   // -1 = playback has not started a pass yet
    }

    struct Step {
        /// Events left over from the PREVIOUS pass that a late tick skipped past
        /// (fire these before handling the wrap). Without this, a tick landing just
        /// after the loop boundary silently dropped every event in the old tail.
        let tail: [Int]
        let fire: [Int]     // indices into eventTimes to fire now, in order
        let wrapped: Bool   // true when a NEW pass began on a loop boundary (pass ≥ 1)
    }

    /// `eventTimes` must be ascending (they're recorded in time order).
    static func advance(_ s: inout State, eventTimes: [Double],
                        loopDuration: Double, elapsed: Double) -> Step {
        guard loopDuration > 0 else { return Step(tail: [], fire: [], wrapped: false) }
        let pass  = Int(elapsed / loopDuration)
        let phase = elapsed.truncatingRemainder(dividingBy: loopDuration)
        // The clock slipped back across a loop boundary (audio dropout, clock
        // adjustment): we are momentarily at the END of the previous pass, whose
        // events have all been handled. Without this, `phase ≈ loopDuration`
        // matched every event after the cursor reset and fired the whole loop at once.
        if pass < s.lastPass { return Step(tail: [], fire: [], wrapped: false) }

        var tail: [Int] = []
        var wrapped = false
        if pass > s.lastPass {
            wrapped = s.lastPass >= 0          // first pass is a start, not a wrap
            if wrapped {
                tail = Array(s.cursor..<eventTimes.count)
            }
            s.lastPass = pass
            s.cursor   = 0
        }

        var fire: [Int] = []
        while s.cursor < eventTimes.count, eventTimes[s.cursor] <= phase {
            fire.append(s.cursor)
            s.cursor += 1
        }
        return Step(tail: tail, fire: fire, wrapped: wrapped)
    }
}

extension LoopSchedule.State {
    /// A state that joins a loop already in progress at `elapsed`: events earlier
    /// in the current pass count as already played (they are NOT fired in a burst),
    /// and the pass under way is not reported as a wrap.
    /// `grace`: when the join lands no more than this many seconds into a pass,
    /// nothing is skipped — the events since the pass began fire on the next
    /// advance (a little late), so a downbeat is not lost to a late join.
    /// (In an extension so the plain `State()` initialiser is kept.)
    init(resumingAt elapsed: Double, eventTimes: [Double], loopDuration: Double, grace: Double = 0) {
        self.init()
        guard loopDuration > 0, elapsed > 0 else { return }
        let phase = elapsed.truncatingRemainder(dividingBy: loopDuration)
        lastPass = Int(elapsed / loopDuration)
        cursor   = phase <= grace ? 0 : (eventTimes.firstIndex { $0 > phase } ?? eventTimes.count)
    }
}
