import Foundation

struct SynthPreset: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let color: String

    // Voice type
    var voiceMode: VoiceMode

    // Oscillator
    var osc1Waveform: Waveform
    var osc2Waveform: Waveform
    var osc2Detune: Float
    var oscMix: Float

    // Filter
    var filterCutoff: Float
    var filterResonance: Float
    var filterEnvAmount: Float

    // Envelope
    var attack: Float
    var decay: Float
    var sustain: Float
    var release: Float

    // LFO
    var lfoRate: Float
    var lfoDepth: Float
    var lfoTarget: LFOTarget

    // Classic effects
    var reverbMix: Float
    var delayMix: Float
    var delayTime: Float
    var chorusMix: Float

    // Organ / shimmer FX
    var distortionAmount: Float
    var shimmerAmount: Float
    var tremulantDepth: Float

    // Texture effects
    var lofiAmount: Float
    var vinylAmount: Float
    var brokenTape: Float
    var gritAmount: Float
    var doublerAmount: Float

    var isOrgan: Bool { voiceMode == .organChurch || voiceMode == .hammondB3 }

    enum VoiceMode { case synth, organChurch, hammondB3, rhodes }

    enum Waveform: Int, CaseIterable {
        case sine, triangle, sawtooth, square, noise
    }

    enum LFOTarget: Int {
        case pitch, filter, amplitude
    }

    init(
        name: String, color: String,
        voiceMode: VoiceMode = .synth,
        osc1Waveform: Waveform = .sawtooth, osc2Waveform: Waveform = .sawtooth,
        osc2Detune: Float = 0, oscMix: Float = 0.5,
        filterCutoff: Float = 2000, filterResonance: Float = 0.2, filterEnvAmount: Float = 0.3,
        attack: Float = 0.05, decay: Float = 0.5, sustain: Float = 0.7, release: Float = 1.0,
        lfoRate: Float = 0.5, lfoDepth: Float = 0.1, lfoTarget: LFOTarget = .filter,
        reverbMix: Float = 0.4, delayMix: Float = 0.2, delayTime: Float = 0.375, chorusMix: Float = 0.2,
        distortionAmount: Float = 0,
        shimmerAmount: Float = 0,
        tremulantDepth: Float = 0,
        lofiAmount: Float = 0,
        vinylAmount: Float = 0,
        brokenTape: Float = 0,
        gritAmount: Float = 0,
        doublerAmount: Float = 0
    ) {
        self.name = name; self.color = color
        self.voiceMode = voiceMode
        self.osc1Waveform = osc1Waveform; self.osc2Waveform = osc2Waveform
        self.osc2Detune = osc2Detune; self.oscMix = oscMix
        self.filterCutoff = filterCutoff; self.filterResonance = filterResonance
        self.filterEnvAmount = filterEnvAmount
        self.attack = attack; self.decay = decay; self.sustain = sustain; self.release = release
        self.lfoRate = lfoRate; self.lfoDepth = lfoDepth; self.lfoTarget = lfoTarget
        self.reverbMix = reverbMix; self.delayMix = delayMix
        self.delayTime = delayTime; self.chorusMix = chorusMix
        self.distortionAmount = distortionAmount
        self.shimmerAmount = shimmerAmount
        self.tremulantDepth = tremulantDepth
        self.lofiAmount = lofiAmount
        self.vinylAmount = vinylAmount
        self.brokenTape = brokenTape
        self.gritAmount = gritAmount
        self.doublerAmount = doublerAmount
    }

    static func == (lhs: SynthPreset, rhs: SynthPreset) -> Bool { lhs.id == rhs.id }
}

extension SynthPreset {
    static let presets: [SynthPreset] = [
        SynthPreset(
            name: "Hammond B3",
            color: "#B45309",
            voiceMode: .hammondB3,
            reverbMix: 0.25, delayMix: 0.05, delayTime: 0.25,
            tremulantDepth: 0.5,
            gritAmount: 0.18
        ),
        SynthPreset(
            name: "Rhodes Mk1",
            color: "#92400E",
            voiceMode: .rhodes,
            reverbMix: 0.35, delayMix: 0.2, delayTime: 0.375, chorusMix: 0.25,
            tremulantDepth: 0.3
        ),
        SynthPreset(
            name: "Church Organ",
            color: "#C4A35A",
            voiceMode: .organChurch,
            filterCutoff: 8000, filterResonance: 0,
            attack: 0.005, decay: 0, sustain: 1.0, release: 0.04,
            lfoRate: 0, lfoDepth: 0, lfoTarget: .amplitude,
            reverbMix: 0.65, delayMix: 0.1, delayTime: 0.5,
            tremulantDepth: 0.25
        ),
        SynthPreset(
            name: "Mystic Pad",
            color: "#8B5CF6",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 7, oscMix: 0.5,
            filterCutoff: 800, filterResonance: 0.3, filterEnvAmount: 0.5,
            attack: 1.2, decay: 0.5, sustain: 0.8, release: 2.0,
            lfoRate: 0.3, lfoDepth: 0.15, lfoTarget: .filter,
            reverbMix: 0.7, delayMix: 0.3, delayTime: 0.375, chorusMix: 0.4
        ),
        SynthPreset(
            name: "Dark Matter",
            color: "#1E3A5F",
            voiceMode: .synth,
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
            voiceMode: .synth,
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
            voiceMode: .synth,
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
            voiceMode: .synth,
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
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 3, oscMix: 0.45,
            filterCutoff: 1500, filterResonance: 0.5, filterEnvAmount: 0.4,
            attack: 0.4, decay: 0.6, sustain: 0.7, release: 1.8,
            lfoRate: 1.2, lfoDepth: 0.3, lfoTarget: .filter,
            reverbMix: 0.55, delayMix: 0.25, delayTime: 0.4, chorusMix: 0.35
        ),
    ]
}
