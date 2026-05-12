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

    enum VoiceMode: Equatable {
        case synth, organChurch, hammondB3, rhodes
        case sampler(SamplerInstrument)
    }

    var isOrgan: Bool {
        voiceMode == .organChurch || voiceMode == .hammondB3
    }

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
        case pianoKeys
        case stringBow
        case fluteShape
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

// MARK: - Sampler instrument descriptor

struct SamplerInstrument: Equatable, Hashable {
    let id:          String   // folder name under Resources/Samples/
    let displayName: String
    let rootNotes:   [Int]    // MIDI note numbers of recorded root samples
    let velocityLayers: [VelocityLayer]

    struct VelocityLayer: Equatable, Hashable {
        let midiValue: Int   // velocity used when generating the sample (file suffix)
        let loVel:     Int   // lowest MIDI velocity mapped to this zone
        let hiVel:     Int   // highest MIDI velocity mapped to this zone
    }

    static let grandPiano = SamplerInstrument(
        id: "grand_piano", displayName: "Grand Piano",
        rootNotes: Array(stride(from: 24, through: 96, by: 3)),
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ]
    )
    static let stringEnsemble = SamplerInstrument(
        id: "string_ensemble", displayName: "String Ensemble",
        rootNotes: Array(stride(from: 36, through: 84, by: 3)),
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ]
    )
    static let concertFlute = SamplerInstrument(
        id: "concert_flute", displayName: "Concert Flute",
        rootNotes: Array(stride(from: 60, through: 96, by: 3)),
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ]
    )
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
            tremulantDepth: 0.55,
            iconStyle: .solarRadial
        ),

        // ── String ensembles ──────────────────────────────────────────────

        SynthPreset(
            name: "Solina Strings",
            color: "#C8A44A",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 0.08, oscMix: 0.5,          // ~8 cents sharp → ensemble beat
            filterCutoff: 3500, filterResonance: 0.05, filterEnvAmount: 0.0,
            attack: 0.55, decay: 0.3, sustain: 0.9, release: 1.8,
            lfoRate: 5.0, lfoDepth: 0.08, lfoTarget: .amplitude,
            reverbMix: 0.55, delayMix: 0.08, delayTime: 0.375, chorusMix: 0.7,
            shimmerAmount: 0.2,
            iconStyle: .solarRadial
        ),

        SynthPreset(
            name: "Mellotron Flutes",
            color: "#7BA7BC",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.35,            // octave blend for flute body
            filterCutoff: 5000, filterResonance: 0.0, filterEnvAmount: 0.0,
            attack: 0.4, decay: 0.2, sustain: 0.9, release: 1.2,
            lfoRate: 0.2, lfoDepth: 0.05, lfoTarget: .amplitude,
            reverbMix: 0.65, delayMix: 0.06, delayTime: 0.5, chorusMix: 0.15,
            brokenTape: 0.08,
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Tape Strings",
            color: "#8B6347",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 0.5, oscMix: 0.4,
            filterCutoff: 2200, filterResonance: 0.15, filterEnvAmount: 0.1,
            attack: 0.6, decay: 0.4, sustain: 0.85, release: 2.0,
            lfoRate: 0.4, lfoDepth: 0.06, lfoTarget: .amplitude,
            reverbMix: 0.65, delayMix: 0.08, delayTime: 0.5, chorusMix: 0.35,
            spaceEchoAmount: 0.15, brokenTape: 0.22, bloomAmount: 0.2,
            iconStyle: .mysticWave
        ),

        SynthPreset(
            name: "Bowed Psaltery",
            color: "#D4A843",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sine,
            osc2Detune: 7, oscMix: 0.3,              // fifth above adds overtone layer
            filterCutoff: 2800, filterResonance: 0.2, filterEnvAmount: 0.1,
            attack: 0.7, decay: 0.4, sustain: 0.8, release: 2.2,
            lfoRate: 5.5, lfoDepth: 0.1, lfoTarget: .amplitude,
            reverbMix: 0.6, delayMix: 0.1, delayTime: 0.4, chorusMix: 0.25,
            shimmerAmount: 0.25, bloomAmount: 0.2,
            iconStyle: .solarRadial
        ),

        // ── Resonant / glass ──────────────────────────────────────────────

        SynthPreset(
            name: "Glass Harmonica",
            color: "#A8D8EA",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .sine,
            osc2Detune: 12, oscMix: 0.4,             // octave sine for glassy shimmer
            filterCutoff: 4000, filterResonance: 0.3, filterEnvAmount: 0.1,
            attack: 1.8, decay: 0.5, sustain: 0.8, release: 3.0,
            lfoRate: 3.5, lfoDepth: 0.12, lfoTarget: .amplitude,
            reverbMix: 0.85, delayMix: 0.15, delayTime: 0.666, chorusMix: 0.3,
            shimmerAmount: 0.45, bloomAmount: 0.35,
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Cristal Baschet",
            color: "#6BBFD4",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 7, oscMix: 0.35,
            filterCutoff: 6000, filterResonance: 0.25, filterEnvAmount: 0.0,
            attack: 1.2, decay: 0.6, sustain: 0.7, release: 2.5,
            lfoRate: 4.0, lfoDepth: 0.15, lfoTarget: .amplitude,
            reverbMix: 0.78, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.2,
            shimmerAmount: 0.35, bloomAmount: 0.3,
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Waterphone",
            color: "#4A6070",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .noise,
            osc2Detune: 0, oscMix: 0.25,             // noise adds metallic overtones
            filterCutoff: 2000, filterResonance: 0.45, filterEnvAmount: 0.3,
            attack: 2.0, decay: 1.0, sustain: 0.6, release: 4.0,
            lfoRate: 0.5, lfoDepth: 0.2, lfoTarget: .pitch,
            reverbMix: 0.9, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.3,
            shimmerAmount: 0.5, bloomAmount: 0.4, phaserAmount: 0.35,
            iconStyle: .voidHole
        ),

        // ── Reeds / winds ────────────────────────────────────────────────

        SynthPreset(
            name: "Harmonium",
            color: "#8B3A3A",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .square,
            osc2Detune: 0.06, oscMix: 0.45,          // ~6 cents → reed-row beating
            filterCutoff: 2500, filterResonance: 0.25, filterEnvAmount: 0.1,
            attack: 0.05, decay: 0.2, sustain: 0.9, release: 0.4,
            lfoRate: 0.0, lfoDepth: 0.0, lfoTarget: .amplitude,
            reverbMix: 0.35, delayMix: 0.08, delayTime: 0.375, chorusMix: 0.15,
            tremulantDepth: 0.35, gritAmount: 0.12,
            iconStyle: .churchPipes
        ),

        SynthPreset(
            name: "Musette Accordion",
            color: "#CC4444",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 0.14, oscMix: 0.5,           // ~14 cents → classic musette beating
            filterCutoff: 3000, filterResonance: 0.1, filterEnvAmount: 0.0,
            attack: 0.03, decay: 0.1, sustain: 0.95, release: 0.3,
            lfoRate: 0.0, lfoDepth: 0.0, lfoTarget: .amplitude,
            reverbMix: 0.25, delayMix: 0.05, delayTime: 0.25, chorusMix: 0.55,
            iconStyle: .pulseBolt
        ),

        SynthPreset(
            name: "Hurdy-Gurdy",
            color: "#7B5C3A",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .square,
            osc2Detune: 7, oscMix: 0.35,             // fifth drone buzz
            filterCutoff: 1800, filterResonance: 0.35, filterEnvAmount: 0.2,
            attack: 0.04, decay: 0.2, sustain: 0.9, release: 0.5,
            lfoRate: 0.0, lfoDepth: 0.0, lfoTarget: .amplitude,
            reverbMix: 0.3, delayMix: 0.08, delayTime: 0.375, chorusMix: 0.2,
            tremulantDepth: 0.3, gritAmount: 0.25,
            iconStyle: .hammondTonewheel
        ),

        // ── Choir / vocal ────────────────────────────────────────────────

        SynthPreset(
            name: "Choir Ahs",
            color: "#9B7FD4",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 7, oscMix: 0.45,
            filterCutoff: 1800, filterResonance: 0.15, filterEnvAmount: 0.2,
            attack: 1.4, decay: 0.5, sustain: 0.85, release: 2.5,
            lfoRate: 0.8, lfoDepth: 0.12, lfoTarget: .amplitude,
            reverbMix: 0.8, delayMix: 0.1, delayTime: 0.666, chorusMix: 0.55,
            shimmerAmount: 0.3, bloomAmount: 0.35,
            iconStyle: .mysticWave
        ),

        SynthPreset(
            name: "Vox Humana",
            color: "#E8A060",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .triangle,
            osc2Detune: 3, oscMix: 0.4,
            filterCutoff: 1200, filterResonance: 0.4, filterEnvAmount: 0.3,
            attack: 0.2, decay: 0.3, sustain: 0.8, release: 1.0,
            lfoRate: 5.0, lfoDepth: 0.08, lfoTarget: .amplitude,
            reverbMix: 0.5, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.4,
            tremulantDepth: 0.25,
            iconStyle: .churchPipes
        ),

        // ── Electronic / unique ──────────────────────────────────────────

        SynthPreset(
            name: "Ondes Martenot",
            color: "#2D9E8F",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .sine,
            osc2Detune: 0, oscMix: 0.0,              // pure single-oscillator sine
            filterCutoff: 8000, filterResonance: 0.0, filterEnvAmount: 0.0,
            attack: 0.08, decay: 0.1, sustain: 1.0, release: 0.8,
            lfoRate: 5.5, lfoDepth: 0.18, lfoTarget: .amplitude,
            reverbMix: 0.45, delayMix: 0.1, delayTime: 0.5, chorusMix: 0.0,
            tremulantDepth: 0.55,
            iconStyle: .voidHole
        ),

        // MARK: – Sample-based instruments

        SynthPreset(
            name: "Grand Piano",
            color: "#E8DCC8",
            voiceMode: .sampler(.grandPiano),
            attack: 0.002, decay: 0.5, sustain: 0.7, release: 0.8,
            reverbMix: 0.18, delayMix: 0.04, delayTime: 0.375,
            iconStyle: .pianoKeys
        ),
        SynthPreset(
            name: "Str. Ensemble",
            color: "#7B3B1A",
            voiceMode: .sampler(.stringEnsemble),
            attack: 0.12, decay: 0.3, sustain: 0.9, release: 1.2,
            reverbMix: 0.45, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.15,
            iconStyle: .stringBow
        ),
        SynthPreset(
            name: "Concert Flute",
            color: "#8FB8C8",
            voiceMode: .sampler(.concertFlute),
            attack: 0.03, decay: 0.2, sustain: 0.85, release: 0.4,
            reverbMix: 0.32, delayMix: 0.08, delayTime: 0.375,
            iconStyle: .fluteShape
        ),
    ]
}
