import Foundation
import Combine

/// MIDI-event looper. Records note-on/off events (with timestamps) as the user
/// plays and plays them back on a repeating timer. Wire-up:
///   looper.audioEngine = engine
///   engine.looper      = looper   ← engine calls recordOn/Off from noteOn/Off
///
/// Looper-originated playback uses touchIDs ≥ 90000 so noteOn/Off skips
/// re-recording those events (preventing exponential note accumulation).
final class LooperEngine: ObservableObject {

    @Published var isRecording = false
    @Published var isPlaying   = false
    @Published var progress: Double = 0   // 0–1, position within the loop

    weak var audioEngine: AudioEngine?

    // MARK: - Internal event store

    private struct Event {
        let t: Double        // seconds from loop start
        let touchID: Int     // already offset by +90000 for playback
        let noteOn: Bool
        let note: Int
        let velocity: Float
        let x: Float
        let y: Float
    }

    private var events: [Event] = []
    private var loopDuration: Double = 0
    private var recordStart: Date?

    private var eventCursor  = 0
    private var lastLoopPass = -1
    private var playbackStart: Date?
    private var tickTimer:     AnyCancellable?
    private var progressTimer: AnyCancellable?

    // MARK: - Recording (called from AudioEngine.noteOn/Off)

    func recordOn(touchID: Int, note: Int, velocity: Float, x: Float, y: Float) {
        guard isRecording, let start = recordStart else { return }
        events.append(Event(t: Date().timeIntervalSince(start),
                            touchID: touchID + 90000,
                            noteOn: true, note: note,
                            velocity: velocity, x: x, y: y))
    }

    func recordOff(touchID: Int) {
        guard isRecording, let start = recordStart else { return }
        events.append(Event(t: Date().timeIntervalSince(start),
                            touchID: touchID + 90000,
                            noteOn: false, note: 0,
                            velocity: 0, x: 0, y: 0))
    }

    // MARK: - Public controls

    func startRecording() {
        guard !isRecording else { return }
        if isPlaying { stopPlayback() }
        events = []
        loopDuration = 0
        recordStart = Date()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, let start = recordStart else { return }
        loopDuration = Date().timeIntervalSince(start)
        recordStart = nil
        isRecording = false
        if !events.isEmpty { startPlayback() }
    }

    func togglePlayback() {
        if isPlaying { stopPlayback() } else if hasLoop { startPlayback() }
    }

    func clear() {
        stopPlayback()
        events = []
        loopDuration = 0
    }

    var hasLoop: Bool { !events.isEmpty }

    // MARK: - Playback

    private func startPlayback() {
        guard loopDuration > 0, !events.isEmpty else { return }
        isPlaying = true
        playbackStart = Date()
        lastLoopPass = -1
        eventCursor = 0

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
        // Release any looper-held notes
        let ids = Set(events.filter { $0.noteOn }.map { $0.touchID })
        ids.forEach { audioEngine?.noteOff(touchID: $0) }
    }

    private func tick() {
        guard let start = playbackStart, loopDuration > 0 else { return }
        let elapsed   = Date().timeIntervalSince(start)
        let loopPass  = Int(elapsed / loopDuration)
        let loopPhase = elapsed.truncatingRemainder(dividingBy: loopDuration)

        if loopPass > lastLoopPass {
            // Loop wrapped — silence any held notes, then restart event cursor
            if lastLoopPass >= 0 {
                let ids = Set(events.filter { $0.noteOn }.map { $0.touchID })
                ids.forEach { audioEngine?.noteOff(touchID: $0) }
            }
            lastLoopPass = loopPass
            eventCursor  = 0
        }

        while eventCursor < events.count, events[eventCursor].t <= loopPhase {
            fire(events[eventCursor])
            eventCursor += 1
        }
    }

    private func fire(_ ev: Event) {
        guard let eng = audioEngine else { return }
        if ev.noteOn {
            eng.noteOn(touchID: ev.touchID, note: ev.note,
                       velocity: ev.velocity, x: ev.x, y: ev.y)
        } else {
            eng.noteOff(touchID: ev.touchID)
        }
    }

    private func updateProgress() {
        guard let start = playbackStart, loopDuration > 0 else { progress = 0; return }
        let elapsed = Date().timeIntervalSince(start)
        progress = (elapsed / loopDuration).truncatingRemainder(dividingBy: 1.0)
    }
}
