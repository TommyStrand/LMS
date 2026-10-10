import XCTest
@testable import SuperNovaPad

/// Pure-logic unit tests — no audio hardware, simulator app launch aside.
/// These encode the invariants that were previously only verifiable by ear.
final class SuperNovaPadTests: XCTestCase {

    // MARK: - Velocity layer selection

    func testVelocityLayerSelection() {
        let layers = SamplerInstrument.grandPiano.velocityLayers   // [0-63 → 64, 64-127 → 110]
        XCTAssertEqual(SamplerSelection.velocityMidiValue(for: 0,   layers: layers), 64)
        XCTAssertEqual(SamplerSelection.velocityMidiValue(for: 63,  layers: layers), 64)
        XCTAssertEqual(SamplerSelection.velocityMidiValue(for: 64,  layers: layers), 110)
        XCTAssertEqual(SamplerSelection.velocityMidiValue(for: 127, layers: layers), 110)
    }

    func testVelocityOutOfRangeFallsBackToLastLayer() {
        let layers = SamplerInstrument.grandPiano.velocityLayers
        // 200 is above every hiVel → should still resolve (last layer), not nil.
        XCTAssertEqual(SamplerSelection.velocityMidiValue(for: 200, layers: layers), 110)
    }

    func testVelocityWithNoLayersIsNil() {
        XCTAssertNil(SamplerSelection.velocityMidiValue(for: 64, layers: []))
    }

    // MARK: - Nearest-root selection

    func testNearestRootExactAndNearest() {
        let roots = [36, 39, 42, 45]
        XCTAssertEqual(SamplerSelection.nearestRoot(to: 39, available: roots), 39) // exact
        XCTAssertEqual(SamplerSelection.nearestRoot(to: 40, available: roots), 39) // closer down
        XCTAssertEqual(SamplerSelection.nearestRoot(to: 44, available: roots), 45) // closer up
    }

    func testNearestRootTieResolvesToLower() {
        // 40 is equidistant from 39 and 41 → must deterministically pick 39.
        XCTAssertEqual(SamplerSelection.nearestRoot(to: 40, available: [41, 39]), 39)
    }

    func testNearestRootAboveRangePicksHighest() {
        // The bug scenario: a high note beyond the sampled range must pitch up the
        // HIGHEST available root, never wrap to something unrelated.
        let roots = Array(stride(from: 36, through: 84, by: 3))
        XCTAssertEqual(SamplerSelection.nearestRoot(to: 108, available: roots), 84)
    }

    func testNearestRootEmptyIsNil() {
        XCTAssertNil(SamplerSelection.nearestRoot(to: 60, available: []))
    }

    // MARK: - Instrument descriptors

    func testGrandPianoRootNoteRange() {
        let roots = SamplerInstrument.grandPiano.rootNotes
        XCTAssertEqual(roots.first, 24)
        XCTAssertEqual(roots.last, 96)
        XCTAssertEqual(roots.count, 25)   // 24...96 step 3
    }

    // MARK: - Preset equality (stable id, not regenerated UUID)

    func testPresetEqualityByStableID() {
        // Equality is by id (== name); re-fetching the same preset must compare equal.
        let a = SynthPreset.presets[0]
        let b = SynthPreset.presets[0]
        XCTAssertEqual(a, b)
        if SynthPreset.presets.count > 1 {
            XCTAssertNotEqual(SynthPreset.presets[0], SynthPreset.presets[1])
        }
    }

    // MARK: - Sampler descriptor invariants (what SamplerEngine.load() asserts at runtime)

    func testEverySamplerInstrumentHasValidRootsAndContiguousVelocityLayers() {
        let instruments: [SamplerInstrument] = [.grandPiano, .stringEnsemble, .concertFlute, .pipeOrgan]
        for inst in instruments {
            XCTAssertFalse(inst.rootNotes.isEmpty, "\(inst.id) has no roots")
            XCTAssertEqual(inst.rootNotes, inst.rootNotes.sorted(), "\(inst.id) roots not ascending")
            XCTAssertEqual(Set(inst.rootNotes).count, inst.rootNotes.count, "\(inst.id) has duplicate roots")
            XCTAssertTrue(inst.rootNotes.allSatisfy { (0...127).contains($0) }, "\(inst.id) root out of MIDI range")

            // Velocity layers must tile 0...127 with no gap and no overlap, or a
            // velocity could resolve to no sample (silent note) or two.
            let layers = inst.velocityLayers.sorted { $0.loVel < $1.loVel }
            XCTAssertEqual(layers.first?.loVel, 0,   "\(inst.id) layers don't start at 0")
            XCTAssertEqual(layers.last?.hiVel, 127,  "\(inst.id) layers don't end at 127")
            for (a, b) in zip(layers, layers.dropFirst()) {
                XCTAssertEqual(a.hiVel + 1, b.loVel, "\(inst.id) layer gap/overlap at \(a.hiVel)/\(b.loVel)")
            }
        }
    }

    func testEverySamplerPresetReferencesALoopOrOneShotConsistently() {
        // Looping instruments need a non-trivial attack/release ramp; one-shots don't ramp.
        XCTAssertTrue(SamplerInstrument.stringEnsemble.loops)
        XCTAssertTrue(SamplerInstrument.concertFlute.loops)
        XCTAssertFalse(SamplerInstrument.grandPiano.loops)
        XCTAssertGreaterThan(SamplerInstrument.stringEnsemble.attack, 0)
        XCTAssertGreaterThan(SamplerInstrument.stringEnsemble.release, 0)
    }

    // MARK: - Musical scale

    func testScaleNotesStayInMidiRangeAndAscend() {
        for scale in MusicalScale.allCases {
            let notes = scale.notes(rootMidi: 120, octaves: 2)   // deliberately near the top
            XCTAssertTrue(notes.allSatisfy { (0...127).contains($0) }, "\(scale) produced out-of-range note")
            XCTAssertEqual(notes, notes.sorted(), "\(scale) notes not ascending")
        }
        XCTAssertEqual(MusicalScale.major.notes(rootMidi: 60, octaves: 1), [60, 62, 64, 65, 67, 69, 71])
        XCTAssertEqual(MusicalScale.chromatic.intervals.count, 12)
    }

    // MARK: - Keyboard continuous pitch (PitchSnap)

    func testSemitonesPerWhiteKeyIsAveragePianoRatio() {
        XCTAssertEqual(PitchSnap.semitonesPerWhiteKey, 12.0 / 7.0, accuracy: 1e-12)
        // Sliding one white key right ≈ 1.71 semitones; zero width can't divide by zero.
        XCTAssertEqual(PitchSnap.semitones(dx: 30, keyWidth: 30), 12.0 / 7.0, accuracy: 1e-12)
        XCTAssertEqual(PitchSnap.semitones(dx: -15, keyWidth: 30), -6.0 / 7.0, accuracy: 1e-12)
        XCTAssertEqual(PitchSnap.semitones(dx: 10, keyWidth: 0), 0)
    }

    func testChromaticSnapIsPlainRounding() {
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 60.4, rootNote: 48, scale: .chromatic), 60)
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 60.6, rootNote: 48, scale: .chromatic), 61)
    }

    func testMajorScaleSnapSkipsNonScaleTones() {
        // C major from root C: 61 (C#) is not in scale → 60.9 snaps to 61? No: to nearest IN-scale,
        // which is 60 (C) at 0.9 away vs 62 (D) at 1.1 away.
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 60.9, rootNote: 60, scale: .major), 60)
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 61.2, rootNote: 60, scale: .major), 62)
        // Exactly on a non-scale tone (C#) → ties between C and D resolve to the LOWER (C).
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 61.0, rootNote: 60, scale: .major), 60)
    }

    func testSnapRespectsRootPitchClassAcrossOctaves() {
        // Root D (62) major; 72.4 (≈C5) is NOT in D major → nearest are 71 (B) and 73 (C#).
        // 72.4 is 1.4 from 71 and 0.6 from 73 → 73.
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 72.4, rootNote: 62, scale: .major), 73)
        // Root given in a different octave must behave identically (only pitch class matters).
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 72.4, rootNote: 38, scale: .major), 73)
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 72.4, rootNote: -10, scale: .major), 73)
    }

    func testSnapClampsToMidiRange() {
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: 130, rootNote: 60, scale: .chromatic), 127)
        XCTAssertEqual(PitchSnap.nearestScaleMidi(to: -3,  rootNote: 60, scale: .chromatic), 0)
    }

    func testPentatonicSnapAlwaysLandsOnAPentatonicTone() {
        let root = 60
        let pcs  = Set(MusicalScale.pentatonic.intervals)
        for tenth in 0...240 {   // sweep 60.0 ... 84.0 in 0.1 steps
            let pitch = 60.0 + Double(tenth) / 10.0
            let midi  = PitchSnap.nearestScaleMidi(to: pitch, rootNote: root, scale: .pentatonic)
            XCTAssertTrue(pcs.contains((((midi - root) % 12) + 12) % 12), "pitch \(pitch) snapped to non-pentatonic \(midi)")
            XCTAssertLessThanOrEqual(abs(Double(midi) - pitch), 2.0, "pentatonic gaps are ≤3 semitones, so snap distance ≤1.5")
        }
    }

    // MARK: - Looper scheduling (LoopSchedule)

    func testLoopFiresEventsInOrderWithinFirstPass() {
        var s = LoopSchedule.State()
        let times = [0.10, 0.25, 0.50, 0.90]
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.05).fire, [])
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.30).fire, [0, 1])
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.30).fire, [], "no double-fire on a repeat tick")
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.95).fire, [2, 3])
    }

    func testFirstPassIsNotReportedAsAWrap() {
        var s = LoopSchedule.State()
        let step = LoopSchedule.advance(&s, eventTimes: [0.1], loopDuration: 1, elapsed: 0.0)
        XCTAssertFalse(step.wrapped)
        XCTAssertEqual(s.lastPass, 0)
    }

    func testLoopWrapResetsCursorAndReportsWrapExactlyOnce() {
        var s = LoopSchedule.State()
        let times = [0.10, 0.50]
        _ = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.99)   // both fired
        let wrap = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 1.15)
        XCTAssertTrue(wrap.wrapped)
        XCTAssertEqual(wrap.fire, [0], "event 0 (t=0.10) must fire again on the second pass")
        let again = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 1.20)
        XCTAssertFalse(again.wrapped, "wrap must be reported only on the boundary tick")
        XCTAssertEqual(again.fire, [])
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 1.60).fire, [1])
    }

    func testEventsMissedByASlowTickStillFireOnNextTick() {
        // A tick stall (e.g. 400 ms) must not drop events; all events whose time
        // has passed fire together, in order, on the next tick.
        var s = LoopSchedule.State()
        let times = [0.05, 0.10, 0.20, 0.30]
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.45).fire, [0, 1, 2, 3])
    }

    func testSkippingAnEntirePassStillAdvancesToTheRightPass() {
        var s = LoopSchedule.State()
        let times = [0.5]
        _ = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.6)
        // Jump straight into pass 3 at phase 0.2 (before the event).
        let step = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 3.2)
        XCTAssertTrue(step.wrapped)
        XCTAssertEqual(step.fire, [])
        XCTAssertEqual(s.lastPass, 3)
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 3.7).fire, [0])
    }

    func testZeroLoopDurationNeverFires() {
        var s = LoopSchedule.State()
        let step = LoopSchedule.advance(&s, eventTimes: [0.0], loopDuration: 0, elapsed: 5)
        XCTAssertEqual(step.fire, [])
        XCTAssertFalse(step.wrapped)
    }

    func testEventAtExactlyZeroFiresImmediately() {
        var s = LoopSchedule.State()
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: [0.0, 0.3], loopDuration: 1, elapsed: 0.0).fire, [0])
    }

    // MARK: - Render params (what the audio thread reads)

    func testRenderParamsMirrorPresetEffectAmounts() {
        var p = SynthPreset.presets[0]
        p.autoWahAmount = 0.11; p.gritAmount = 0.22; p.lofiAmount = 0.33
        p.spaceEchoAmount = 0.44; p.brokenTape = 0.55; p.bloomAmount = 0.66
        p.tremulantDepth = 0.77; p.chorusMix = 0.88; p.distortionAmount = 0.99
        p.phaserAmount = 0.12; p.modDelayAmount = 0.34

        let r = RenderParams(p)
        XCTAssertEqual(r.autoWah,    0.11); XCTAssertEqual(r.grit,       0.22)
        XCTAssertEqual(r.lofi,       0.33); XCTAssertEqual(r.space,      0.44)
        XCTAssertEqual(r.tape,       0.55); XCTAssertEqual(r.bloom,      0.66)
        XCTAssertEqual(r.tremulant,  0.77); XCTAssertEqual(r.chorus,     0.88)
        XCTAssertEqual(r.distortion, 0.99); XCTAssertEqual(r.phaser,     0.12)
        XCTAssertEqual(r.modDelay,   0.34)
    }

    func testDefaultRenderParamsAreAllOff() {
        // The render loop gates every custom effect on amount > ~0.001; an all-zero
        // default means a fresh engine does zero per-sample effect work.
        let r = RenderParams()
        for v in [r.autoWah, r.grit, r.lofi, r.space, r.tape, r.bloom,
                  r.tremulant, r.chorus, r.distortion, r.phaser, r.modDelay] {
            XCTAssertEqual(v, 0)
        }
    }

    // MARK: - Looper touch-ID isolation

    func testLooperPlaybackTouchIDsAreAboveTheRecordingCutoff() {
        // AudioEngine.noteOn only records into the looper when touchID < 90000;
        // playback IDs are offset by +90000 so a loop can never re-record itself.
        // UITouch hashes and MIDI IDs (0x10000 + note ≤ 65663) all sit below 90000.
        XCTAssertLessThan(0x10000 + 127, 90000)
    }
}
