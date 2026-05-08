import Foundation

struct SynthPreset: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let color: String

    // Oscillator
    var osc1Waveform: Waveform
    var osc2Waveform: Waveform
    var osc2Detune: Float       // semitones
    var oscMix: Float           // 0=osc1 only, 1=osc2 only

    // Filter
    var filterCutoff: Float     // 20–20000 Hz
    var filterResonance: Float  // 0–1
    var filterEnvAmount: Float  // -1 to 1

    // Envelope
    var attack: Float
    var decay: Float
    var sustain: Float
    var release: Float

    // LFO
    var lfoRate: Float
    var lfoDepth: Float
    var lfoTarget: LFOTarget

    // Effects
    var reverbMix: Float
    var delayMix: Float
    var delayTime: Float
    var chorusMix: Float

    enum Waveform: Int, CaseIterable {
        case sine, triangle, sawtooth, square, noise
    }

    enum LFOTarget: Int {
        case pitch, filter, amplitude
    }
}

extension SynthPreset {
    static let presets: [SynthPreset] = [
        SynthPreset(
            name: "Mystic Pad",
            color: "#8B5CF6",
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 7, oscMix: 0.5,
            filterCutoff: 800, filterResonance: 0.3, filterEnvAmount: 0.5,
            attack: 1.2, decay: 0.5, sustain: 0.8, release: 2.0,
            lfoRate: 0.3, lfoDepth: 0.15, lfoTarget: .filter,
            reverbMix: 0.7, delayMix: 0.3, delayTime: 0.375, chorusMix: 0.4
        ),
        SynthPreset(
            name: "Dark Matter",
            color: "#1E1B4B",
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: -5, oscMix: 0.4,
            filterCutoff: 400, filterResonance: 0.6, filterEnvAmount: 0.7,
            attack: 0.05, decay: 0.8, sustain: 0.5, release: 1.5,
            lfoRate: 0.8, lfoDepth: 0.2, lfoTarget: .pitch,
            reverbMix: 0.5, delayMix: 0.4, delayTime: 0.5, chorusMix: 0.2
        ),
        SynthPreset(
            name: "Celestial",
            color: "#06B6D4",
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.6,
            filterCutoff: 2000, filterResonance: 0.1, filterEnvAmount: 0.3,
            attack: 2.0, decay: 1.0, sustain: 0.9, release: 3.0,
            lfoRate: 0.15, lfoDepth: 0.1, lfoTarget: .amplitude,
            reverbMix: 0.85, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.6
        ),
        SynthPreset(
            name: "Pulse Drive",
            color: "#F59E0B",
            osc1Waveform: .square, osc2Waveform: .square,
            osc2Detune: 0, oscMix: 0.5,
            filterCutoff: 1200, filterResonance: 0.8, filterEnvAmount: 0.9,
            attack: 0.01, decay: 0.3, sustain: 0.6, release: 0.4,
            lfoRate: 4.0, lfoDepth: 0.4, lfoTarget: .filter,
            reverbMix: 0.3, delayMix: 0.5, delayTime: 0.25, chorusMix: 0.1
        ),
        SynthPreset(
            name: "Void Walker",
            color: "#059669",
            osc1Waveform: .noise, osc2Waveform: .sawtooth,
            osc2Detune: 2, oscMix: 0.3,
            filterCutoff: 600, filterResonance: 0.4, filterEnvAmount: 0.6,
            attack: 0.8, decay: 1.2, sustain: 0.4, release: 2.5,
            lfoRate: 0.5, lfoDepth: 0.25, lfoTarget: .pitch,
            reverbMix: 0.6, delayMix: 0.35, delayTime: 0.333, chorusMix: 0.5
        ),
        SynthPreset(
            name: "Solar Wind",
            color: "#EF4444",
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 3, oscMix: 0.45,
            filterCutoff: 1500, filterResonance: 0.5, filterEnvAmount: 0.4,
            attack: 0.4, decay: 0.6, sustain: 0.7, release: 1.8,
            lfoRate: 1.2, lfoDepth: 0.3, lfoTarget: .filter,
            reverbMix: 0.55, delayMix: 0.25, delayTime: 0.4, chorusMix: 0.35
        ),
    ]
}
