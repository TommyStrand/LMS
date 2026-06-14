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
}
