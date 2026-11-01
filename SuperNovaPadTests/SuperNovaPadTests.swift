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

    func testLateTickAtLoopEndStillFiresTheOldTail() {
        // Event at t=0.995 in a 1 s loop; ticks at 0.99 and then 1.001 (8 ms late).
        // The 0.995 event belongs to pass 0 and must fire as the TAIL of that pass,
        // not be skipped because the cursor resets for pass 1.
        var s = LoopSchedule.State()
        let times = [0.10, 0.995]
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 0.99).fire, [0])
        let step = LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 1.001)
        XCTAssertEqual(step.tail, [1])
        XCTAssertTrue(step.wrapped)
        XCTAssertEqual(step.fire, [])
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: times, loopDuration: 1, elapsed: 1.15).fire, [0])
    }

    func testFirstPassHasNoTail() {
        var s = LoopSchedule.State()
        XCTAssertEqual(LoopSchedule.advance(&s, eventTimes: [0.5], loopDuration: 1, elapsed: 0.2).tail, [])
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

    // MARK: - Finger vibrato

    func testFingerVibratoBendsAroundLockedTarget() {
        // At the anchor: exactly the locked pitch.
        XCTAssertEqual(FingerVibrato.bend(lockedTarget: 2, anchorX: 100, x: 100, keyWidth: 40)!, 2, accuracy: 1e-12)
        // Small wiggle (0.1 key): 0.1 × 12/7 × 2.5 ≈ 0.4286 semitones, symmetric.
        let up   = FingerVibrato.bend(lockedTarget: 2, anchorX: 100, x: 104, keyWidth: 40)!
        let down = FingerVibrato.bend(lockedTarget: 2, anchorX: 100, x: 96,  keyWidth: 40)!
        XCTAssertEqual(up - 2,   0.1 * 12.0 / 7.0 * 2.5, accuracy: 1e-12)
        XCTAssertEqual(2 - down, 0.1 * 12.0 / 7.0 * 2.5, accuracy: 1e-12)
    }

    func testFingerVibratoDepthIsClamped() {
        // 0.3 key → raw 1.29 semitones → clamped to maxDepth.
        let b = FingerVibrato.bend(lockedTarget: 0, anchorX: 0, x: 12, keyWidth: 40)!
        XCTAssertEqual(b, FingerVibrato.maxDepth, accuracy: 1e-12)
    }

    func testLeavingCaptureRadiusBreaksTheLock() {
        // Radius is 0.4 keys = 16 pt on a 40 pt key.
        XCTAssertNotNil(FingerVibrato.bend(lockedTarget: 0, anchorX: 0, x: 16,  keyWidth: 40))
        XCTAssertNil(FingerVibrato.bend(lockedTarget: 0, anchorX: 0, x: 16.5, keyWidth: 40))
        XCTAssertNil(FingerVibrato.bend(lockedTarget: 0, anchorX: 0, x: -17,  keyWidth: 40))
        XCTAssertNil(FingerVibrato.bend(lockedTarget: 0, anchorX: 0, x: 1,    keyWidth: 0))
    }

    // MARK: - Pitch colour

    func testPitchColorWalksTheWheelByPitchClass() {
        XCTAssertEqual(PitchColor.hue(for: 60), 0, accuracy: 1e-12)            // C
        XCTAssertEqual(PitchColor.hue(for: 72), 0, accuracy: 1e-12)            // C, next octave
        XCTAssertEqual(PitchColor.hue(for: 61), 1.0 / 12, accuracy: 1e-12)     // C#
        XCTAssertEqual(PitchColor.hue(for: 60.5), 0.5 / 12, accuracy: 1e-12)   // mid-glide
        XCTAssertEqual(PitchColor.hue(for: -1), 11.0 / 12, accuracy: 1e-12)    // negative wraps
        for p in stride(from: -24.0, through: 140.0, by: 0.37) {
            let h = PitchColor.hue(for: p)
            XCTAssertTrue(h >= 0 && h < 1, "hue \(h) out of range for pitch \(p)")
        }
    }

    // MARK: - Wave morph

    func testWaveMorphHitsTheFourShapesAtTheirStops() {
        let p = 0.1
        XCTAssertEqual(WaveMorph.sample(phase: p, morph: 0),       sin(0.2 * .pi), accuracy: 1e-9)  // sine
        XCTAssertEqual(WaveMorph.sample(phase: p, morph: 1.0 / 3), -0.6,           accuracy: 1e-9)  // triangle
        XCTAssertEqual(WaveMorph.sample(phase: p, morph: 2.0 / 3), -0.8,           accuracy: 1e-9)  // saw
        XCTAssertEqual(WaveMorph.sample(phase: p, morph: 1),        1.0,           accuracy: 1e-9)  // square
    }

    func testWaveMorphCrossfadesLinearlyBetweenNeighbours() {
        let p = 0.1
        let halfway = WaveMorph.sample(phase: p, morph: 0.5)   // midway triangle → saw
        XCTAssertEqual(halfway, (-0.6 + -0.8) / 2, accuracy: 1e-9)
    }

    func testWaveMorphClampsAndStaysInRange() {
        XCTAssertEqual(WaveMorph.sample(phase: 0.3, morph: -2), WaveMorph.sample(phase: 0.3, morph: 0))
        XCTAssertEqual(WaveMorph.sample(phase: 0.3, morph: 9),  WaveMorph.sample(phase: 0.3, morph: 1))
        for m in stride(from: 0.0, through: 1.0, by: 0.05) {
            for ph in stride(from: 0.0, to: 1.0, by: 0.01) {
                let v = WaveMorph.sample(phase: ph, morph: m)
                XCTAssertTrue(v >= -1.0000001 && v <= 1.0000001, "morph \(m) phase \(ph) → \(v)")
            }
        }
    }

    // MARK: - Drum scheduling (DrumSchedule)

    private func scheduled(_ hits: [DrumHit], start: Double, tpf: Double,
                           frames: Int, loop: Double) -> [[Int]] {
        var out: [[Int]] = []
        DrumSchedule.forEachHit(hits, startTick: start, ticksPerFrame: tpf,
                                frameCount: frames, loopTicks: loop) { out.append([$0, $1]) }
        return out
    }

    func testDrumHitLandsOnItsExactFrame() {
        let hits = [DrumHit(tick: 0, voice: .kick, velocity: 1),
                    DrumHit(tick: 10, voice: .snare, velocity: 1)]
        // 0.5 ticks/frame: tick 0 → frame 0, tick 10 → frame 20.
        XCTAssertEqual(scheduled(hits, start: 0, tpf: 0.5, frames: 64, loop: 480), [[0, 0], [1, 20]])
    }

    func testDrumHitOutsideBufferDoesNotFire() {
        let hits = [DrumHit(tick: 100, voice: .kick, velocity: 1)]
        XCTAssertEqual(scheduled(hits, start: 0, tpf: 0.5, frames: 64, loop: 480), [])   // span 0..<32
        // The hit exactly at the buffer's end belongs to the NEXT buffer.
        XCTAssertEqual(scheduled([DrumHit(tick: 32, voice: .kick, velocity: 1)],
                                 start: 0, tpf: 0.5, frames: 64, loop: 480), [])
    }

    func testDrumHitAcrossLoopWrap() {
        // Buffer starts 5 ticks before the loop end; tick 0 is 5 ticks in → frame 10.
        let hits = [DrumHit(tick: 0, voice: .kick, velocity: 1)]
        XCTAssertEqual(scheduled(hits, start: 475, tpf: 0.5, frames: 64, loop: 480), [[0, 10]])
        // A start beyond one loop is normalised the same way.
        XCTAssertEqual(scheduled(hits, start: 475 + 480 * 3, tpf: 0.5, frames: 64, loop: 480), [[0, 10]])
    }

    func testDrumScheduleMatchesThePerSampleRule() {
        // Parity with the old per-sample scan: hit fires on frame f when its tick is
        // in [start + f·tpf, start + (f+1)·tpf) modulo the loop. Brute-force check
        // every frame of many buffers across a loop wrap, at an awkward tempo.
        let loop = 1920.0                                  // 1 bar at 480 tpb
        let tpf  = (97.0 / 60.0) * 480.0 / 44100.0         // 97 BPM
        let hits = (0..<64).map { DrumHit(tick: Int32($0 * 30 + 7), voice: .hihat, velocity: 1) }
        var start = 1700.0
        for _ in 0..<40 {
            var expected: [[Int]] = []
            for f in 0..<441 {
                let a = (start + Double(f) * tpf).truncatingRemainder(dividingBy: loop)
                let b = a + tpf
                for (i, h) in hits.enumerated() {
                    let t = Double(h.tick)
                    if (t >= a && t < b) || (b > loop && t < b - loop) { expected.append([i, f]) }
                }
            }
            let got = scheduled(hits, start: start, tpf: tpf, frames: 441, loop: loop)
            XCTAssertEqual(got.sorted { ($0[1], $0[0]) < ($1[1], $1[0]) },
                           expected.sorted { ($0[1], $0[0]) < ($1[1], $1[0]) },
                           "mismatch for buffer starting at tick \(start)")
            start = (start + tpf * 441).truncatingRemainder(dividingBy: loop)
        }
    }

    func testDrumScheduleRejectsDegenerateInput() {
        let hits = [DrumHit(tick: 0, voice: .kick, velocity: 1)]
        XCTAssertEqual(scheduled(hits, start: 0, tpf: 0,   frames: 64, loop: 480), [])
        XCTAssertEqual(scheduled(hits, start: 0, tpf: 0.5, frames: 0,  loop: 480), [])
        XCTAssertEqual(scheduled(hits, start: 0, tpf: 0.5, frames: 64, loop: 0),   [])
    }

    // MARK: - Mood drum grooves

    func testEveryMoodGridLineIsExactly32Steps() {
        for spec in MoodGrooves.specs {
            for (voice, line) in spec.lines {
                XCTAssertEqual(MoodGrooves.cells(line).count, 32, "\(spec.name) \(voice) grid length")
            }
        }
    }

    func testMoodHitsStayInsideTheirOwnStep() {
        // Swing + humanisation only ever push a hit LATER, and never past its 16th
        // step — so the step sequencer lights the step you actually hear.
        for spec in MoodGrooves.specs {
            let pattern = MoodGrooves.build(spec, seed: 1)
            var expected: [Int: Set<Int>] = [:]          // voice raw → steps
            for (voice, line) in spec.lines {
                for (step, v) in MoodGrooves.cells(line).enumerated() where v != nil {
                    expected[voice.rawValue, default: []].insert(step)
                }
            }
            var actual: [Int: Set<Int>] = [:]
            for hit in pattern.hits {
                XCTAssertTrue((0..<pattern.loopTicks).contains(hit.tick), "\(spec.name) tick out of loop")
                actual[hit.voice.rawValue, default: []].insert(Int(hit.tick) / MoodGrooves.stepTicks)
            }
            XCTAssertEqual(actual, expected, "\(spec.name) hits drifted out of their steps")
        }
    }

    func testMoodPatternsAreTwoBarsAtTheirOwnPlayableTempo() throws {
        XCTAssertEqual(MoodGrooves.all.count, MoodGrooves.specs.count)
        for p in MoodGrooves.all {
            XCTAssertEqual(p.collection, .mood)
            XCTAssertEqual(p.bars, 2, "\(p.name) must match the 32-step sequencer grid")
            XCTAssertEqual(p.loopTicks, 76800)
            let bpm = try XCTUnwrap(p.suggestedBPM)
            XCTAssertTrue((50...180).contains(bpm), "\(p.name) BPM outside the slider range")
            XCTAssertTrue(p.hits.allSatisfy { (0.05...1).contains($0.velocity) })
        }
    }

    func testMoodBuildIsDeterministic() {
        // Same seed → identical pattern on every launch (no Swift hashValue randomness).
        let a = MoodGrooves.build(MoodGrooves.specs[5], seed: 6).hits
        let b = MoodGrooves.build(MoodGrooves.specs[5], seed: 6).hits
        XCTAssertEqual(a.map(\.tick), b.map(\.tick))
        XCTAssertEqual(a.map(\.velocity), b.map(\.velocity))
    }

    func testSwingDelaysOnlyTheOffbeats() {
        // 16th swing at 0.62 → odd steps 576 ticks late; even steps untouched.
        XCTAssertEqual(MoodGrooves.swingTicks(step: 1, swing: 0.62, eighthSwing: false), 576)
        XCTAssertEqual(MoodGrooves.swingTicks(step: 2, swing: 0.62, eighthSwing: false), 0)
        // 8th swing at 0.6 → steps ≡ 2 (mod 4) 960 ticks late.
        XCTAssertEqual(MoodGrooves.swingTicks(step: 2, swing: 0.6, eighthSwing: true), 960)
        XCTAssertEqual(MoodGrooves.swingTicks(step: 1, swing: 0.6, eighthSwing: true), 0)
        XCTAssertEqual(MoodGrooves.swingTicks(step: 3, swing: 0.5, eighthSwing: false), 0)
    }

    func testMoodCollectionComesFirstAndNamesAreUnique() {
        // The default pattern (index 0) must be a calm one.
        XCTAssertEqual(DrumPattern.all.first?.collection, .mood)
        let builtIn = DrumPattern.all.filter { $0.collection != .imported }.map(\.name)
        XCTAssertEqual(Set(builtIn).count, builtIn.count, "favourites are keyed by name")
    }

    // MARK: - Sampler root discovery (imported instruments)

    func testDiscoverRootsKeepsOnlyCompleteRootsInTheRightFolder() {
        let layers = SamplerInstrument.pipeOrgan.velocityLayers          // 64 + 110
        let keys = [
            "pipe_organ/36_64", "pipe_organ/36_110",                       // complete
            "pipe_organ/48_110", "pipe_organ/48_64",                       // complete, unordered
            "pipe_organ/60_64",                                            // missing 110 → dropped
            "grand_piano/72_64", "grand_piano/72_110",                     // other folder
            "pipe_organ/readme", "pipe_organ/x_64",                        // not {root}_{vel}
        ]
        XCTAssertEqual(SamplerSelection.discoverRoots(keys: keys, folder: "pipe_organ", layers: layers),
                       [36, 48])
    }

    func testDiscoverRootsMatchesTheUsersLocalOrganImport() {
        // The reported crash: 46 organ files on disk (23 complete roots) vs a
        // descriptor declaring 25 roots → "loaded 46/50" assert. With discovery,
        // expected is derived from the files, so it is 46 by construction.
        let layers = SamplerInstrument.pipeOrgan.velocityLayers
        let roots  = Array(stride(from: 30, through: 96, by: 3))          // 23 roots
        let keys   = roots.flatMap { ["pipe_organ/\($0)_64", "pipe_organ/\($0)_110"] }
        let found  = SamplerSelection.discoverRoots(keys: keys, folder: "pipe_organ", layers: layers)
        XCTAssertEqual(found.count * layers.count, 46)
        XCTAssertTrue(SamplerInstrument.pipeOrgan.discoversRoots)
        XCTAssertFalse(SamplerInstrument.grandPiano.discoversRoots, "generated instruments keep the strict check")
    }

    func testDiscoverRootsWithNoFilesIsEmpty() {
        XCTAssertEqual(SamplerSelection.discoverRoots(keys: [], folder: "pipe_organ",
                                                      layers: SamplerInstrument.pipeOrgan.velocityLayers), [])
    }

    // MARK: - MIDI parsing (groove length)

    private func be(_ v: UInt32, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) })
    }

    /// Minimal format-1 MIDI file, 480 tpb: one kick on beat 1, End-of-Track at
    /// 2 bars (3840 ticks = VLQ 0x9E 0x00). Optionally a non-track chunk first.
    private func twoBarKickFile(withForeignChunk: Bool = false) -> Data {
        let track: [UInt8] = [0x00, 0x99, 36, 100,          // note-on ch10, kick
                              0x9E, 0x00, 0xFF, 0x2F, 0x00] // +3840 ticks: end of track
        var d = Data("MThd".utf8) + be(6, bytes: 4) + be(1, bytes: 2) + be(1, bytes: 2) + be(480, bytes: 2)
        if withForeignChunk { d += Data("XFIH".utf8) + be(3, bytes: 4) + Data([1, 2, 3]) }
        d += Data("MTrk".utf8) + be(UInt32(track.count), bytes: 4) + Data(track)
        return d
    }

    func testMidiLengthComesFromEndOfTrackNotTheLastNote() throws {
        // The only note is at tick 0; the groove is 2 bars long. Using the last
        // note as the length imported this as a 1-bar loop.
        let midi = try XCTUnwrap(MidiParser.parse(twoBarKickFile()))
        XCTAssertEqual(midi.ticksPerBeat, 480)
        XCTAssertEqual(midi.durationTicks, 3840)
        XCTAssertEqual(midi.notes.count, 1)
    }

    func testMidiParserSkipsUnknownChunks() throws {
        let midi = try XCTUnwrap(MidiParser.parse(twoBarKickFile(withForeignChunk: true)))
        XCTAssertEqual(midi.notes.map(\.note), [36])
        XCTAssertEqual(midi.durationTicks, 3840)
    }

    // MARK: - Looper touch-ID isolation

    func testLooperPlaybackIDsNeverCollideWithLiveTouches() {
        // Looper playback is flagged with `fromLooper: true` (never re-recorded) and
        // uses its own NEGATIVE ID space. On-screen IDs are UITouch hashes (heap
        // addresses, huge and positive) and MIDI IDs are 0x10000 + note, so a looped
        // note can never collide with — or release — a note someone is holding.
        // (The old rule "record only if touchID < 90000" silently dropped every
        // on-screen touch, because heap addresses are always above 90000.)
        let liveIDs = [0x10000, 0x10000 + 127, 0x1_0A3C_5F10, Int.max / 2]
        let mapped  = liveIDs.map(LooperEngine.playbackID(for:))
        XCTAssertTrue(mapped.allSatisfy { $0 < 0 }, "playback IDs must be negative")
        XCTAssertEqual(Set(mapped).count, liveIDs.count, "distinct touches → distinct playback IDs")
        XCTAssertTrue(Set(mapped).isDisjoint(with: Set(liveIDs)))
        // Layer mode builds touchID*1000 + presetIndex; must not overflow for real hashes.
        XCTAssertFalse(LooperEngine.playbackID(for: 0x7FFF_FFFF_FFF0)
                           .multipliedReportingOverflow(by: 1000).overflow)
    }
}
