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
    var lofiAmount:    Float
    var spaceEchoAmount: Float
    var brokenTape:    Float
    var gritAmount:    Float
    var bloomAmount:   Float
    var phaserAmount:  Float
    var autoWahAmount: Float
    var modDelayAmount: Float

    // Preset chip icon style
    var iconStyle: IconStyle

    var isOrgan: Bool { voiceMode == .organChurch || voiceMode == .hammondB3 }

    enum VoiceMode { case synth, organChurch, hammondB3, rhodes }

    enum Waveform: Int, CaseIterable {
        case sine, triangle, sawtooth, square, noise
    }

    enum LFOTarget: Int {
        case pitch, filter, amplitude
    }

    enum IconStyle {
        case hammondTonewheel
        case rhodesTine
        case churchPipes
        case mysticWave
        case darkVortex
        case celestialDots
        case pulseBolt
        case voidHole
        case solarRadial
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
        spaceEchoAmount: Float = 0,
        brokenTape: Float = 0,
        gritAmount: Float = 0,
        bloomAmount: Float = 0,
        phaserAmount: Float = 0,
        autoWahAmount: Float = 0,
        modDelayAmount: Float = 0,
        iconStyle: IconStyle = .mysticWave
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
        self.spaceEchoAmount = spaceEchoAmount
        self.brokenTape = brokenTape
        self.gritAmount = gritAmount
        self.bloomAmount = bloomAmount
        self.phaserAmount = phaserAmount
        self.autoWahAmount = autoWahAmount
        self.modDelayAmount = modDelayAmount
        self.iconStyle = iconStyle
    }

    static func == (lhs: SynthPreset, rhs: SynthPreset) -> Bool { lhs.id == rhs.id }
}

extension SynthPreset {
    static let presets: [SynthPreset] = [
        SynthPreset(
            name: "Hammond B3",
            color: "#B45309",
            voiceMode: .hammondB3,
            reverbMix: 0.22, delayMix: 0.04, delayTime: 0.25,
            // Leslie rotation and key-click are built into HammondVoice —
            // no external tremulo or grit needed here.
            iconStyle: .hammondTonewheel
        ),
        SynthPreset(
            name: "Rhodes Mk1",
            color: "#92400E",
            voiceMode: .rhodes,
            reverbMix: 0.35, delayMix: 0.2, delayTime: 0.375, chorusMix: 0.25,
            tremulantDepth: 0.3,
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Church Organ",
            color: "#C4A35A",
            voiceMode: .organChurch,
            filterCutoff: 8000, filterResonance: 0,
            attack: 0.005, decay: 0, sustain: 1.0, release: 0.04,
            lfoRate: 0, lfoDepth: 0, lfoTarget: .amplitude,
            reverbMix: 0.65, delayMix: 0.1, delayTime: 0.5,
            tremulantDepth: 0.25,
            iconStyle: .churchPipes
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
            reverbMix: 0.7, delayMix: 0.3, delayTime: 0.375, chorusMix: 0.4,
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Dark Matter",
            color: "#1E3A5F",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: -5, oscMix: 0.4,
            filterCutoff: 400, filterResonance: 0.35, filterEnvAmount: 0.7,
            attack: 0.08, decay: 0.8, sustain: 0.5, release: 1.5,
            lfoRate: 0.8, lfoDepth: 0.2, lfoTarget: .pitch,
            reverbMix: 0.5, delayMix: 0.3, delayTime: 0.5, chorusMix: 0.2,
            iconStyle: .darkVortex
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
            reverbMix: 0.85, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.6,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Pulse Drive",
            color: "#F59E0B",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .square,
            osc2Detune: 0, oscMix: 0.5,
            filterCutoff: 1200, filterResonance: 0.55, filterEnvAmount: 0.9,
            attack: 0.02, decay: 0.3, sustain: 0.6, release: 0.4,
            lfoRate: 4.0, lfoDepth: 0.4, lfoTarget: .filter,
            reverbMix: 0.3, delayMix: 0.38, delayTime: 0.25, chorusMix: 0.1,
            iconStyle: .pulseBolt
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
            reverbMix: 0.6, delayMix: 0.35, delayTime: 0.333, chorusMix: 0.5,
            iconStyle: .voidHole
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
            reverbMix: 0.55, delayMix: 0.25, delayTime: 0.4, chorusMix: 0.35,
            iconStyle: .solarRadial
        ),

        // ── Organic / electromechanical additions ──────────────────────
        SynthPreset(
            name: "Wurlitzer",
            color: "#A05A1F",
            voiceMode: .rhodes,
            reverbMix: 0.30, delayMix: 0.08, chorusMix: 0.18,
            distortionAmount: 0.18,
            tremulantDepth: 0.55,                          // Wurly's signature trem
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Suitcase '73",
            color: "#A16207",
            voiceMode: .rhodes,
            reverbMix: 0.45, delayMix: 0.18, chorusMix: 0.40,
            tremulantDepth: 0.05,
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Clavinet",
            color: "#7C2D12",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: 0, oscMix: 0.35,
            filterCutoff: 4500, filterResonance: 0.45, filterEnvAmount: 0.6,
            attack: 0.001, decay: 0.18, sustain: 0.35, release: 0.20,
            reverbMix: 0.18, delayMix: 0.05, chorusMix: 0.0,
            distortionAmount: 0.30,                        // tube-warm bite
            gritAmount: 0.20,
            iconStyle: .pulseBolt
        ),
        SynthPreset(
            name: "Mellotron",
            color: "#6B4423",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 0.4, oscMix: 0.55,
            filterCutoff: 1800, filterResonance: 0.20, filterEnvAmount: 0.2,
            attack: 0.45, decay: 0.5, sustain: 0.75, release: 1.6,
            reverbMix: 0.55, delayMix: 0.10, chorusMix: 0.30,
            tremulantDepth: 0.12,
            spaceEchoAmount: 0.28, brokenTape: 0.18,
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Celesta",
            color: "#7DD3FC",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .sine,
            osc2Detune: 12, oscMix: 0.45,
            filterCutoff: 6000, filterResonance: 0.0, filterEnvAmount: 0.0,
            attack: 0.001, decay: 1.4, sustain: 0.0, release: 1.0,
            reverbMix: 0.72, delayMix: 0.18, chorusMix: 0.0,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Vibraphone",
            color: "#FCD34D",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 5, oscMix: 0.30,
            filterCutoff: 4000, filterResonance: 0.0, filterEnvAmount: 0.0,
            attack: 0.002, decay: 1.6, sustain: 0.20, release: 1.2,
            lfoRate: 6.0, lfoDepth: 0.40, lfoTarget: .amplitude,
            reverbMix: 0.62, delayMix: 0.10,
            tremulantDepth: 0.55,                          // motor-driven trem
            iconStyle: .solarRadial
        ),
    ]
}
