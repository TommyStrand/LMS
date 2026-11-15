import Foundation

struct SynthPreset: Identifiable, Equatable {
    let id: String   // = name; stable across instantiations so == works after re-creation
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

    // Synth-voice character (SynthVoice only)
    /// > 0: osc 1 is played as two copies this many cents either side of pitch,
    /// one to each stereo side — width and slow movement for pads and strings.
    var unisonCents: Float
    /// How far apart the unison copies sit (0 = both centre, 1 = hard left/right).
    var stereoWidth: Float
    /// Filter key tracking: 0 = same cutoff for every note, 1 = cutoff follows pitch.
    var keyTrack: Float
    /// 2-operator FM on a SINE osc 1: peak modulation index (0 = off), modulator
    /// frequency ratio, and how fast the brightness settles (seconds).
    var fmIndex: Float
    var fmRatio: Float
    var fmDecay: Float
    /// Loudness trim so presets sit at a similar level (measured on a held chord).
    var level: Float

    /// Non-empty → this is a HYBRID preset: it has no voice of its own; every note
    /// plays all of these parts together (recordings and synth patches blended —
    /// the Omnisphere idea). The preset's own effect settings (reverb, delay,
    /// shimmer, chorus…) apply to the blend; its oscillator/filter fields are unused.
    var hybrid: [HybridPart]

    // Preset chip icon style
    var iconStyle: IconStyle

    /// One layer of a hybrid preset: another preset, by name, at a level and octave.
    struct HybridPart: Equatable {
        let preset: String
        var gain: Float = 1
        var octave: Int = 0
    }

    var isHybrid: Bool { !hybrid.isEmpty }

    enum VoiceMode: Equatable {
        case synth, organChurch, hammondB3, rhodes
        case sampler(SamplerInstrument)
    }

    /// Organs get the cathedral reverb. (The church and pipe organs are sampler
    /// presets now, so the voice mode alone no longer says "organ".)
    var isOrgan: Bool {
        if case .sampler(let instrument) = voiceMode {
            return instrument.id == "church_organ" || instrument.id == "pipe_organ"
        }
        return voiceMode == .organChurch || voiceMode == .hammondB3
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
        unisonCents: Float = 0, stereoWidth: Float = 0.7, keyTrack: Float = 0.5,
        fmIndex: Float = 0, fmRatio: Float = 1, fmDecay: Float = 0.5, level: Float = 1,
        hybrid: [HybridPart] = [],
        iconStyle: IconStyle = .mysticWave
    ) {
        self.id = name; self.name = name; self.color = color
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
        self.unisonCents = unisonCents; self.stereoWidth = stereoWidth; self.keyTrack = keyTrack
        self.fmIndex = fmIndex; self.fmRatio = fmRatio; self.fmDecay = fmDecay; self.level = level
        self.hybrid = hybrid
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

    // Sustaining instruments (strings/flute) loop their buffer so a held note
    // rings indefinitely instead of dying when the recording ends. Their WAVs
    // are generated as seamless loops (no baked attack/release); the engine
    // applies a note-on attack ramp and a note-off release ramp of these lengths.
    // One-shot instruments (piano, and real recorded imports) leave loops=false
    // and ring out for the sample's natural length.
    var loops:   Bool   = false
    var attack:  Double = 0.004   // note-on volume fade (seconds), looping voices
    var release: Double = 0.20    // note-off volume fade (seconds), looping voices
    /// true → SamplerEngine ignores `rootNotes` and loads whatever complete roots
    /// it finds in the folder. For IMPORTED instruments, whose samples live only on
    /// the machine that ran import_samples.py while this descriptor lives in git.
    var discoversRoots = false
    /// true → when `loops` is false (real recordings), SamplerEngine finds each
    /// recording's steady part and loops it seamlessly after the attack, so the
    /// note sustains while the key is held instead of stopping when the recording
    /// ends. Ignored for synthesised `loops` instruments (they loop whole).
    var sustainLoop = false
    /// true → a one-shot note is DAMPED when the key is released: it fades out
    /// over `release` instead of ringing for the whole recording. A piano without
    /// this behaves as if the sustain pedal were held down for ever, and real
    /// piano recordings (6–8 s of tail) pile up into mud.
    var damps = false
    /// Length (seconds) of the crossfade at the sustain-loop seam. 80 ms suits a
    /// steady pipe; ensembles and vibrato need longer (see `SustainLoop`).
    var loopCrossfade = 0.08

    struct VelocityLayer: Equatable, Hashable {
        let midiValue: Int   // velocity used when generating the sample (file suffix)
        let loVel:     Int   // lowest MIDI velocity mapped to this zone
        let hiVel:     Int   // highest MIDI velocity mapped to this zone
    }

    // Strings and flute are REAL RECORDINGS installed by Scripts/fetch_free_samples.py
    // (VSCO 2 Community Edition, CC0). They are in git, so `rootNotes` is exact.
    // (There is no piano: the sampled grand was removed at the owner's request.)
    static let stringEnsemble = SamplerInstrument(
        id: "string_ensemble", displayName: "String Ensemble",
        rootNotes: [36, 40, 43, 47, 50, 53, 55, 59, 62, 66, 69, 72, 76, 79, 83],
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ],
        loops: false, attack: 0.09, release: 0.35,  // slow bow swell + smooth release
        sustainLoop: true,                          // attack once, then the steady bowing loops
        loopCrossfade: 0.25
    )
    static let concertFlute = SamplerInstrument(
        id: "concert_flute", displayName: "Concert Flute",
        rootNotes: [60, 64, 69, 72, 76, 81, 84, 88, 93, 96],
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ],
        loops: false, attack: 0.04, release: 0.18,   // breath onset + gentle release
        sustainLoop: true,                          // attack once, then the held tone loops
        loopCrossfade: 0.2
    )
    // ── Instruments built from the GeneralUser GS SoundFont ──────────────────────
    // (Scripts/build_soundfont_instruments.py; in git.) Short real recordings —
    // attack + loop — of accordion reeds, a choir and voices. They
    // replaced two-oscillator synth patches that sounded nothing like the
    // instruments. One velocity layer each: these instruments don't change
    // character with touch, and one layer halves the memory.
    static let oneLayer = [VelocityLayer(midiValue: 64, loVel: 0, hiVel: 127)]

    static let reedOrgan = SamplerInstrument(
        id: "reed_organ", displayName: "Harmonium",
        rootNotes: [54, 58, 62, 66, 70, 74, 78, 82, 86, 90],
        velocityLayers: oneLayer,
        attack: 0.06, release: 0.14,      // bellows speak softly and stop quickly
        sustainLoop: true
    )
    static let musetteAccordion = SamplerInstrument(
        id: "musette_accordion", displayName: "Musette Accordion",
        rootNotes: [54, 58, 62, 66, 70, 74, 78, 82, 86, 90],
        velocityLayers: oneLayer,
        attack: 0.03, release: 0.12,
        sustainLoop: true,
        loopCrossfade: 0.2                // three beating reeds: not a steady tone
    )
    static let concertChoir = SamplerInstrument(
        id: "concert_choir", displayName: "Choir",
        rootNotes: [45, 49, 51, 55, 59, 61, 65, 69, 71, 73, 77, 78],
        velocityLayers: oneLayer,
        attack: 0.12, release: 0.5,
        sustainLoop: true,
        loopCrossfade: 0.25
    )
    static let voiceOohs = SamplerInstrument(
        id: "voice_oohs", displayName: "Voices",
        rootNotes: [63, 69, 73, 77, 80, 83],
        velocityLayers: oneLayer,
        attack: 0.08, release: 0.4,
        sustainLoop: true,
        loopCrossfade: 0.25
    )

    static let celesta = SamplerInstrument(
        id: "celesta", displayName: "Celesta",
        rootNotes: [63, 69, 78, 87],
        velocityLayers: oneLayer          // one-shot: the dying-away is in the recording
    )

    // ── Instruments from the Versilian Community Sample Library (VCSL, CC0) ──────
    // (Scripts/fetch_free_samples.py; in git.) Full-length real recordings.
    static let vibraphone = SamplerInstrument(
        id: "vibraphone", displayName: "Vibraphone",
        rootNotes: [53, 57, 60, 64, 67, 71, 74, 77, 81, 84, 88],
        velocityLayers: oneLayer          // one-shot: struck bars ring and die away
    )
    static let wineGlasses = SamplerInstrument(
        id: "wine_glasses", displayName: "Wine Glasses",
        rootNotes: [75, 78, 83, 86],
        velocityLayers: oneLayer,
        attack: 0.15, release: 0.6,       // a rubbed rim speaks and stops slowly
        sustainLoop: true,
        loopCrossfade: 0.25
    )
    static let bowedPsaltery = SamplerInstrument(
        id: "bowed_psaltery", displayName: "Bowed Psaltery",
        rootNotes: [70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90],
        velocityLayers: oneLayer,
        attack: 0.05, release: 0.4,
        sustainLoop: true,
        loopCrossfade: 0.25
    )
    static let churchOrgan = SamplerInstrument(
        id: "church_organ", displayName: "Church Organ",
        rootNotes: [36, 39, 42, 45, 48, 51, 54, 57, 60, 63, 66, 69, 72, 75, 78, 81, 84, 87, 90, 93, 96],
        velocityLayers: oneLayer,
        attack: 0.01, release: 0.25,      // the pipe stops quickly; the reverb carries the tail
        sustainLoop: true,
        loopCrossfade: 0.1
    )

    // More VCSL / VSCO 2 recordings — sources for blends as much as instruments.
    static let bowedVibraphone = SamplerInstrument(
        id: "bowed_vibraphone", displayName: "Bowed Vibraphone",
        rootNotes: [64, 67, 74, 81, 88],
        velocityLayers: oneLayer          // one-shot: a bowed bar swells and rings on
    )
    static let concertHarp = SamplerInstrument(
        id: "concert_harp", displayName: "Concert Harp",
        rootNotes: [31, 35, 38, 41, 45, 48, 52, 55, 59, 62, 65, 69, 72, 76, 79, 83, 86, 89, 93],
        velocityLayers: oneLayer
    )
    static let kalimba = SamplerInstrument(
        id: "kalimba", displayName: "Kalimba",
        rootNotes: [44, 46, 49, 51, 53, 56, 59, 61, 64, 65, 67, 70, 73, 74, 75, 77, 79, 82, 83, 85, 88, 90, 92, 97],
        velocityLayers: oneLayer
    )
    static let tubularBells = SamplerInstrument(
        id: "tubular_bells", displayName: "Tubular Bells",
        rootNotes: [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77],
        velocityLayers: oneLayer
    )
    static let handChimes = SamplerInstrument(
        id: "hand_chimes", displayName: "Hand Chimes",
        rootNotes: [60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 81, 84, 86, 88, 90, 92, 94, 96],
        velocityLayers: oneLayer
    )
    static let ocarina = SamplerInstrument(
        id: "ocarina", displayName: "Ocarina",
        rootNotes: [69, 71, 73, 74, 76, 78, 80, 81, 82, 84, 85],
        velocityLayers: oneLayer,
        attack: 0.03, release: 0.25,
        sustainLoop: true,
        loopCrossfade: 0.2
    )
    static let frenchHorn = SamplerInstrument(
        id: "french_horn", displayName: "French Horn",
        rootNotes: [33, 36, 39, 43, 46, 50, 53, 57, 60, 74, 77],
        velocityLayers: oneLayer,
        attack: 0.05, release: 0.3,
        sustainLoop: true,
        loopCrossfade: 0.2
    )
    static let tremoloStrings = SamplerInstrument(
        id: "tremolo_strings", displayName: "Tremolo Strings",
        rootNotes: [36, 40, 43, 47, 50, 53, 55, 59, 62, 66, 69, 72, 76, 79, 83, 86],
        velocityLayers: oneLayer,
        attack: 0.08, release: 0.4,
        sustainLoop: true,
        loopCrossfade: 0.25
    )
    static let clarinet = SamplerInstrument(
        id: "clarinet", displayName: "Clarinet",
        rootNotes: [50, 53, 58, 62, 65, 70, 74, 77, 82, 86, 89],
        velocityLayers: oneLayer,
        attack: 0.03, release: 0.2,
        sustainLoop: true,
        loopCrossfade: 0.2
    )

    // A 1958 Otto Rubner double bass, bowed (D. Smolken, CC0).
    static let bowedBass = SamplerInstrument(
        id: "bowed_bass", displayName: "Bowed Double Bass",
        rootNotes: [24, 27, 29, 31, 34, 36, 38, 41, 45, 48, 52, 55, 57, 60, 64, 69],
        velocityLayers: oneLayer,
        attack: 0.06, release: 0.35,
        sustainLoop: true,
        loopCrossfade: 0.2
    )

    // Real recorded pipe organ (imported from an SFZ library via
    // Scripts/import_samples.py --source sfz). The samples are NOT in git — they
    // exist only where the importer ran — so roots are discovered from the folder
    // at load time (`discoversRoots`). `rootNotes` below is informational only (the
    // importer still rewrites it). Pipe organs aren't velocity-sensitive, so the
    // importer writes the same recording into both velocity layers.
    static let pipeOrgan = SamplerInstrument(
        id: "pipe_organ", displayName: "Pipe Organ",
        rootNotes: Array(stride(from: 24, through: 96, by: 3)),
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ],
        release: 0.3,          // pipe speech stops quickly; the reverb carries the tail
        discoversRoots: true,
        sustainLoop: true      // hold the pipe for as long as the key is down
    )
}

extension SynthPreset {
    /// Presets shown in the app. Imported-only sampler instruments (pipe organ) are
    /// hidden when their samples aren't in this build — their WAVs aren't in git, so
    /// on any machine that hasn't run import_samples.py the preset would be silent.
    static let presets: [SynthPreset] = {
        let playable = catalog.filter { preset in
            guard !preset.isHybrid else { return false }
            guard case .sampler(let instrument) = preset.voiceMode,
                  instrument.discoversRoots else { return true }
            return bundleHasSamples(folder: instrument.id)
        }
        // A hybrid is shown only if every one of its parts is.
        let names = Set(playable.map(\.name))
        return catalog.filter { preset in
            preset.isHybrid ? preset.hybrid.allSatisfy { names.contains($0.preset) }
                            : names.contains(preset.name)
        }
    }()

    /// Position of each shown preset by name (hybrid parts are looked up by name).
    static let indexByName: [String: Int] =
        Dictionary(uniqueKeysWithValues: presets.enumerated().map { ($1.name, $0) })

    /// True if the app bundle contains at least one WAV inside a folder named `folder`.
    private static func bundleHasSamples(folder: String) -> Bool {
        BundleIndex.shared.foldersWithWavs.contains(folder)
    }

    private static let catalog: [SynthPreset] = [
        // ── Hybrids ─────────────────────────────────────────────────────────────
        // What the app is for: real recordings blended with synthesis into one
        // slowly moving sound, in a large space. Original blends, first in the list.
        SynthPreset(
            name: "Glass Cathedral",
            color: "#7FC8E8",
            reverbMix: 0.8, delayMix: 0.15, delayTime: 0.666, chorusMix: 0.3,
            shimmerAmount: 0.35, bloomAmount: 0.25,
            hybrid: [
                HybridPart(preset: "Glass Harmonica", gain: 1.0),
                HybridPart(preset: "Choir Ahs", gain: 0.7),
                HybridPart(preset: "Celestial", gain: 0.5),
            ],
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Bowed Dawn",
            color: "#E0B060",
            reverbMix: 0.65, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.3,
            shimmerAmount: 0.25, bloomAmount: 0.2,
            hybrid: [
                HybridPart(preset: "Bowed Psaltery", gain: 1.0),
                HybridPart(preset: "Str. Ensemble", gain: 0.7),
                HybridPart(preset: "Mystic Pad", gain: 0.45, octave: -1),
            ],
            iconStyle: .solarRadial
        ),
        SynthPreset(
            name: "Breath of Voices",
            color: "#C99BE0",
            reverbMix: 0.7, delayMix: 0.2, delayTime: 0.5, chorusMix: 0.25,
            shimmerAmount: 0.2, modDelayAmount: 0.2,
            hybrid: [
                HybridPart(preset: "Vox Humana", gain: 0.9),
                HybridPart(preset: "Concert Flute", gain: 0.6),
                HybridPart(preset: "Solar Wind", gain: 0.4),
            ],
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Deep Reliquary",
            color: "#5A6FA8",
            reverbMix: 0.75, delayMix: 0.1, delayTime: 0.666, chorusMix: 0.2,
            spaceEchoAmount: 0.15,
            hybrid: [
                HybridPart(preset: "Church Organ", gain: 0.8, octave: -1),
                HybridPart(preset: "Choir Ahs", gain: 0.6),
                HybridPart(preset: "Dark Matter", gain: 0.5),
            ],
            iconStyle: .darkVortex
        ),
        SynthPreset(
            name: "Frozen Bells",
            color: "#9FE0F0",
            reverbMix: 0.8, delayMix: 0.3, delayTime: 0.666, chorusMix: 0.2,
            shimmerAmount: 0.4,
            hybrid: [
                HybridPart(preset: "Vibraphone", gain: 0.9),
                HybridPart(preset: "Celesta", gain: 0.6, octave: 1),
                HybridPart(preset: "Glass Harmonica", gain: 0.5),
                HybridPart(preset: "Celestial", gain: 0.35),
            ],
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Tape Garden",
            color: "#B08860",
            reverbMix: 0.55, delayMix: 0.1, delayTime: 0.5, chorusMix: 0.3,
            lofiAmount: 0.1, brokenTape: 0.2,
            hybrid: [
                HybridPart(preset: "Str. Ensemble", gain: 0.8),
                HybridPart(preset: "Mellotron Flutes", gain: 0.6),
                HybridPart(preset: "Tape Strings", gain: 0.5),
            ],
            iconStyle: .mysticWave
        ),

        SynthPreset(
            name: "Horn Horizon",
            color: "#D08A4A",
            reverbMix: 0.7, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.25,
            shimmerAmount: 0.15, bloomAmount: 0.2,
            hybrid: [
                HybridPart(preset: "French Horn", gain: 0.9),
                HybridPart(preset: "Tremolo Strings", gain: 0.6),
                HybridPart(preset: "Mystic Pad", gain: 0.4, octave: -1),
            ],
            iconStyle: .solarRadial
        ),
        SynthPreset(
            name: "Glass Kalimba",
            color: "#8FD8C8",
            reverbMix: 0.65, delayMix: 0.3, delayTime: 0.375, chorusMix: 0.2,
            shimmerAmount: 0.3,
            hybrid: [
                HybridPart(preset: "Kalimba", gain: 1.0),
                HybridPart(preset: "Hand Chimes", gain: 0.5),
                HybridPart(preset: "Celestial", gain: 0.4),
            ],
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Bowed Metal",
            color: "#8AA0B8",
            reverbMix: 0.8, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.3,
            shimmerAmount: 0.35, phaserAmount: 0.2,
            hybrid: [
                HybridPart(preset: "Bowed Vibes", gain: 1.0),
                HybridPart(preset: "Glass Harmonica", gain: 0.5),
                HybridPart(preset: "Void Walker", gain: 0.35),
            ],
            iconStyle: .voidHole
        ),
        SynthPreset(
            name: "Harp Lagoon",
            color: "#6FB8A0",
            reverbMix: 0.7, delayMix: 0.25, delayTime: 0.5, chorusMix: 0.25,
            shimmerAmount: 0.2, modDelayAmount: 0.15,
            hybrid: [
                HybridPart(preset: "Concert Harp", gain: 1.0),
                HybridPart(preset: "Ocarina", gain: 0.4),
                HybridPart(preset: "Solar Wind", gain: 0.35),
            ],
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Bell Tower Fog",
            color: "#7A6FA0",
            reverbMix: 0.85, delayMix: 0.15, delayTime: 0.666, chorusMix: 0.2,
            shimmerAmount: 0.25,
            hybrid: [
                HybridPart(preset: "Tubular Bells", gain: 0.9),
                HybridPart(preset: "Church Organ", gain: 0.4, octave: -1),
                HybridPart(preset: "Dark Matter", gain: 0.4),
            ],
            iconStyle: .darkVortex
        ),
        SynthPreset(
            name: "Wood and Breath",
            color: "#A88A60",
            reverbMix: 0.6, delayMix: 0.1, delayTime: 0.5, chorusMix: 0.25,
            brokenTape: 0.12,
            hybrid: [
                HybridPart(preset: "Clarinet", gain: 0.8),
                HybridPart(preset: "Concert Flute", gain: 0.5),
                HybridPart(preset: "Tape Strings", gain: 0.45),
            ],
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Undertow",
            color: "#3F5A78",
            reverbMix: 0.75, delayMix: 0.12, delayTime: 0.666, chorusMix: 0.2,
            bloomAmount: 0.25,
            hybrid: [
                HybridPart(preset: "Bowed Bass", gain: 0.9),
                HybridPart(preset: "Tremolo Strings", gain: 0.5, octave: 1),
                HybridPart(preset: "Void Walker", gain: 0.35),
            ],
            iconStyle: .voidHole
        ),

        SynthPreset(
            name: "Hammond B3",
            color: "#B45309",
            voiceMode: .hammondB3,
            reverbMix: 0.22, delayMix: 0.04, delayTime: 0.25, chorusMix: 0.25,
            distortionAmount: 0.12,                        // a little valve warmth
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
            fmIndex: 1.6, fmRatio: 14, fmDecay: 1.0,       // body bite, tine "ting", decay length
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Church Organ",
            color: "#C4A35A",
            voiceMode: .sampler(.churchOrgan),    // a real church organ, open registration
            attack: 0.01, decay: 0, sustain: 1.0, release: 0.25,
            reverbMix: 0.6, delayMix: 0.05, delayTime: 0.5, chorusMix: 0.0,
            iconStyle: .churchPipes
        ),
        SynthPreset(
            name: "Mystic Pad",
            color: "#8B5CF6",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 12, oscMix: 0.3,             // octave above (was a parallel fifth)
            filterCutoff: 900, filterResonance: 0.25, filterEnvAmount: 0.25,
            attack: 1.0, decay: 1.5, sustain: 0.8, release: 2.4,
            lfoRate: 0.3, lfoDepth: 0.15, lfoTarget: .filter,
            reverbMix: 0.7, delayMix: 0.3, delayTime: 0.375, chorusMix: 0.35,
            unisonCents: 12,
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Dark Matter",
            color: "#1E3A5F",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: -12, oscMix: 0.45,           // sub octave (was a fourth below)
            filterCutoff: 380, filterResonance: 0.4, filterEnvAmount: 0.55,
            attack: 0.06, decay: 0.9, sustain: 0.5, release: 1.8,
            lfoRate: 0.8, lfoDepth: 0.06, lfoTarget: .pitch,
            reverbMix: 0.5, delayMix: 0.3, delayTime: 0.5, chorusMix: 0.2,
            unisonCents: 6, keyTrack: 0.6,
            iconStyle: .darkVortex
        ),
        SynthPreset(
            name: "Celestial",
            color: "#06B6D4",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.4,
            filterCutoff: 2600, filterResonance: 0.1, filterEnvAmount: 0.15,
            attack: 1.6, decay: 1.2, sustain: 0.85, release: 3.4,
            lfoRate: 0.15, lfoDepth: 0.1, lfoTarget: .amplitude,
            reverbMix: 0.85, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.5,
            unisonCents: 7, fmIndex: 1.2, fmRatio: 2, fmDecay: 2.5,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Pulse Drive",
            color: "#F59E0B",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: -12, oscMix: 0.35,
            filterCutoff: 900, filterResonance: 0.5, filterEnvAmount: 0.75,
            attack: 0.01, decay: 0.28, sustain: 0.55, release: 0.4,
            lfoRate: 4.0, lfoDepth: 0.4, lfoTarget: .filter,
            reverbMix: 0.3, delayMix: 0.38, delayTime: 0.25, chorusMix: 0.1,
            unisonCents: 9, keyTrack: 0.6,
            iconStyle: .pulseBolt
        ),
        SynthPreset(
            name: "Void Walker",
            color: "#059669",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .noise,
            osc2Detune: 0, oscMix: 0.18,             // a breath of noise over the saws (was 70 % noise)
            filterCutoff: 550, filterResonance: 0.4, filterEnvAmount: 0.45,
            attack: 0.9, decay: 1.4, sustain: 0.5, release: 2.8,
            lfoRate: 0.25, lfoDepth: 0.25, lfoTarget: .filter,
            reverbMix: 0.6, delayMix: 0.35, delayTime: 0.333, chorusMix: 0.4,
            unisonCents: 16,
            level: 1.25,
            iconStyle: .voidHole
        ),
        SynthPreset(
            name: "Solar Wind",
            color: "#EF4444",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.3,             // octave (was a minor third on every note)
            filterCutoff: 1400, filterResonance: 0.45, filterEnvAmount: 0.35,
            attack: 0.35, decay: 0.7, sustain: 0.7, release: 2.0,
            lfoRate: 1.2, lfoDepth: 0.3, lfoTarget: .filter,
            reverbMix: 0.55, delayMix: 0.25, delayTime: 0.4, chorusMix: 0.3,
            unisonCents: 10,
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
            fmIndex: 2.8, fmRatio: 1, fmDecay: 0.6,        // reed bark, no tine, shorter decay
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Suitcase '73",
            color: "#A16207",
            voiceMode: .rhodes,
            reverbMix: 0.45, delayMix: 0.18, chorusMix: 0.40,
            tremulantDepth: 0.05,
            fmIndex: 1.2, fmRatio: 14, fmDecay: 1.3,       // mellower, longer
            iconStyle: .rhodesTine
        ),
        SynthPreset(
            name: "Clavinet",
            color: "#7C2D12",
            voiceMode: .synth,
            osc1Waveform: .square, osc2Waveform: .sawtooth,
            osc2Detune: 0, oscMix: 0.35,
            filterCutoff: 1800, filterResonance: 0.4, filterEnvAmount: 0.7,   // pluck: opens, then closes
            attack: 0.001, decay: 0.35, sustain: 0.25, release: 0.12,
            reverbMix: 0.18, delayMix: 0.05, chorusMix: 0.0,
            distortionAmount: 0.25,                        // tube-warm bite
            gritAmount: 0.12,
            keyTrack: 0.7,
            iconStyle: .pulseBolt
        ),
        SynthPreset(
            name: "Mellotron",
            color: "#6B4423",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.3,
            filterCutoff: 1900, filterResonance: 0.15, filterEnvAmount: 0.1,
            attack: 0.35, decay: 0.6, sustain: 0.8, release: 1.6,
            reverbMix: 0.55, delayMix: 0.10, chorusMix: 0.25,
            tremulantDepth: 0.12,
            spaceEchoAmount: 0.2, brokenTape: 0.18,
            unisonCents: 7,
            iconStyle: .mysticWave
        ),
        SynthPreset(
            name: "Celesta",
            color: "#7DD3FC",
            voiceMode: .sampler(.celesta),        // a real celesta
            attack: 0.001, decay: 1.3, sustain: 0.0, release: 0.9,
            reverbMix: 0.6, delayMix: 0.15, chorusMix: 0.0,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Vibraphone",
            color: "#FCD34D",
            voiceMode: .sampler(.vibraphone),     // a real vibraphone, hard mallets
            attack: 0.002, decay: 2.2, sustain: 0.0, release: 1.4,
            reverbMix: 0.5, delayMix: 0.08,
            iconStyle: .solarRadial
        ),

        // ── String ensembles ──────────────────────────────────────────────

        SynthPreset(
            name: "Solina Strings",
            color: "#C8A44A",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .sawtooth,
            osc2Detune: 12, oscMix: 0.3,
            filterCutoff: 3200, filterResonance: 0.05, filterEnvAmount: 0.0,
            attack: 0.45, decay: 0.3, sustain: 0.9, release: 1.8,
            lfoRate: 5.0, lfoDepth: 0.08, lfoTarget: .amplitude,
            reverbMix: 0.55, delayMix: 0.08, delayTime: 0.375, chorusMix: 0.7,
            shimmerAmount: 0.2,
            unisonCents: 9,                           // ensemble beat, now in stereo
            level: 0.8,
            iconStyle: .solarRadial
        ),

        SynthPreset(
            name: "Mellotron Flutes",
            color: "#7BA7BC",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.3,             // octave blend for flute body
            filterCutoff: 2600, filterResonance: 0.0, filterEnvAmount: 0.2,   // brighter "chiff" at the start
            attack: 0.12, decay: 0.3, sustain: 0.9, release: 1.0,
            lfoRate: 5.0, lfoDepth: 0.04, lfoTarget: .pitch,                  // gentle flute vibrato
            reverbMix: 0.65, delayMix: 0.06, delayTime: 0.5, chorusMix: 0.15,
            brokenTape: 0.08,
            fmIndex: 0.5, fmRatio: 2, fmDecay: 0.4,
            level: 0.55,
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Tape Strings",
            color: "#8B6347",
            voiceMode: .synth,
            osc1Waveform: .sawtooth, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.3,
            filterCutoff: 2000, filterResonance: 0.15, filterEnvAmount: 0.1,
            attack: 0.6, decay: 0.4, sustain: 0.85, release: 2.0,
            lfoRate: 0.4, lfoDepth: 0.06, lfoTarget: .amplitude,
            reverbMix: 0.65, delayMix: 0.08, delayTime: 0.5, chorusMix: 0.3,
            spaceEchoAmount: 0.15, brokenTape: 0.22, bloomAmount: 0.2,
            unisonCents: 11,
            iconStyle: .mysticWave
        ),

        SynthPreset(
            name: "Bowed Psaltery",
            color: "#D4A843",
            voiceMode: .sampler(.bowedPsaltery),  // a real bowed psaltery, long bow strokes
            attack: 0.05, decay: 0.4, sustain: 0.8, release: 0.4,
            reverbMix: 0.55, delayMix: 0.1, delayTime: 0.4, chorusMix: 0.0,
            shimmerAmount: 0.15,
            iconStyle: .solarRadial
        ),

        // ── Resonant / glass ──────────────────────────────────────────────

        SynthPreset(
            name: "Glass Harmonica",
            color: "#A8D8EA",
            voiceMode: .sampler(.wineGlasses),    // real wine glasses, rubbed on the rim
            attack: 0.15, decay: 0.5, sustain: 0.8, release: 0.6,
            reverbMix: 0.75, delayMix: 0.12, delayTime: 0.666, chorusMix: 0.0,
            shimmerAmount: 0.3,
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Cristal Baschet",
            color: "#6BBFD4",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .triangle,
            osc2Detune: 12, oscMix: 0.2,
            filterCutoff: 6000, filterResonance: 0.25, filterEnvAmount: 0.0,
            attack: 0.9, decay: 0.6, sustain: 0.7, release: 2.5,
            lfoRate: 4.0, lfoDepth: 0.15, lfoTarget: .amplitude,
            reverbMix: 0.78, delayMix: 0.12, delayTime: 0.5, chorusMix: 0.2,
            shimmerAmount: 0.35, bloomAmount: 0.3,
            unisonCents: 5, fmIndex: 1.0, fmRatio: 2.76, fmDecay: 2.5,   // inharmonic: struck metal and glass
            iconStyle: .celestialDots
        ),

        SynthPreset(
            name: "Waterphone",
            color: "#4A6070",
            voiceMode: .synth,
            osc1Waveform: .sine, osc2Waveform: .noise,
            osc2Detune: 0, oscMix: 0.08,             // a little bow noise
            filterCutoff: 2400, filterResonance: 0.45, filterEnvAmount: 0.3,
            attack: 1.6, decay: 1.0, sustain: 0.6, release: 4.0,
            lfoRate: 0.5, lfoDepth: 0.12, lfoTarget: .pitch,
            reverbMix: 0.9, delayMix: 0.2, delayTime: 0.666, chorusMix: 0.3,
            shimmerAmount: 0.5, bloomAmount: 0.4, phaserAmount: 0.35,
            unisonCents: 9, fmIndex: 2.0, fmRatio: 1.41, fmDecay: 4.0,   // clangorous, slowly settling
            iconStyle: .voidHole
        ),

        // ── Reeds / winds ────────────────────────────────────────────────

        SynthPreset(
            name: "Harmonium",
            color: "#8B3A3A",
            voiceMode: .sampler(.reedOrgan),      // real reeds: 8' + 16' bank, a faint beat
            attack: 0.06, decay: 0.2, sustain: 0.9, release: 0.14,
            reverbMix: 0.22, delayMix: 0.0, delayTime: 0.375, chorusMix: 0.0,
            iconStyle: .churchPipes
        ),

        SynthPreset(
            name: "Musette Accordion",
            color: "#CC4444",
            voiceMode: .sampler(.musetteAccordion),   // three real reeds, tuned apart: the musette beat
            attack: 0.03, decay: 0.1, sustain: 0.95, release: 0.12,
            reverbMix: 0.2, delayMix: 0.04, delayTime: 0.25, chorusMix: 0.0,
            iconStyle: .pulseBolt
        ),

        // ── Choir / vocal ────────────────────────────────────────────────

        SynthPreset(
            name: "Choir Ahs",
            color: "#9B7FD4",
            voiceMode: .sampler(.concertChoir),   // a real mixed choir singing "aah"
            attack: 0.12, decay: 0.5, sustain: 0.85, release: 0.5,
            reverbMix: 0.75, delayMix: 0.08, delayTime: 0.666, chorusMix: 0.0,
            shimmerAmount: 0.15,
            iconStyle: .mysticWave
        ),

        SynthPreset(
            name: "Vox Humana",
            color: "#E8A060",
            voiceMode: .sampler(.voiceOohs),      // real voices singing "ooh"
            attack: 0.08, decay: 0.3, sustain: 0.8, release: 0.4,
            reverbMix: 0.55, delayMix: 0.08, delayTime: 0.5, chorusMix: 0.0,
            iconStyle: .churchPipes
        ),

        // ── Electronic / unique ──────────────────────────────────────────

        // MARK: – Sample-based instruments

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
        SynthPreset(
            name: "Bowed Vibes",
            color: "#9FB4C8",
            voiceMode: .sampler(.bowedVibraphone),   // a vibraphone bar drawn with a bow
            attack: 0.05, decay: 2.0, sustain: 0.0, release: 1.5,
            reverbMix: 0.7, delayMix: 0.15, delayTime: 0.666,
            shimmerAmount: 0.2,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Concert Harp",
            color: "#D8B870",
            voiceMode: .sampler(.concertHarp),   // a real concert harp
            attack: 0.001, decay: 2.0, sustain: 0.0, release: 1.5,
            reverbMix: 0.5, delayMix: 0.1, delayTime: 0.375,
            iconStyle: .solarRadial
        ),
        SynthPreset(
            name: "Kalimba",
            color: "#C89060",
            voiceMode: .sampler(.kalimba),   // a Tanzanian kalimba, in its own tuning
            attack: 0.001, decay: 1.2, sustain: 0.0, release: 0.8,
            reverbMix: 0.45, delayMix: 0.2, delayTime: 0.375,
            iconStyle: .pulseBolt
        ),
        SynthPreset(
            name: "Tubular Bells",
            color: "#B8A070",
            voiceMode: .sampler(.tubularBells),   // real tubular bells
            attack: 0.001, decay: 3.0, sustain: 0.0, release: 2.0,
            reverbMix: 0.65, delayMix: 0.1, delayTime: 0.666,
            iconStyle: .churchPipes
        ),
        SynthPreset(
            name: "Hand Chimes",
            color: "#A8D0D8",
            voiceMode: .sampler(.handChimes),   // real hand chimes
            attack: 0.001, decay: 2.5, sustain: 0.0, release: 1.5,
            reverbMix: 0.6, delayMix: 0.15, delayTime: 0.5,
            iconStyle: .celestialDots
        ),
        SynthPreset(
            name: "Ocarina",
            color: "#7FB890",
            voiceMode: .sampler(.ocarina),   // a real ocarina
            attack: 0.03, decay: 0.2, sustain: 0.9, release: 0.25,
            reverbMix: 0.45, delayMix: 0.1, delayTime: 0.375,
            iconStyle: .fluteShape
        ),
        SynthPreset(
            name: "French Horn",
            color: "#C88838",
            voiceMode: .sampler(.frenchHorn),   // a real French horn
            attack: 0.05, decay: 0.3, sustain: 0.9, release: 0.3,
            reverbMix: 0.55, delayMix: 0.06, delayTime: 0.5,
            iconStyle: .solarRadial
        ),
        SynthPreset(
            name: "Tremolo Strings",
            color: "#8A4A2A",
            voiceMode: .sampler(.tremoloStrings),   // string sections playing tremolo
            attack: 0.08, decay: 0.3, sustain: 0.9, release: 0.4,
            reverbMix: 0.55, delayMix: 0.08, delayTime: 0.5,
            iconStyle: .stringBow
        ),
        SynthPreset(
            name: "Clarinet",
            color: "#6A5040",
            voiceMode: .sampler(.clarinet),   // a real clarinet
            attack: 0.03, decay: 0.2, sustain: 0.9, release: 0.2,
            reverbMix: 0.4, delayMix: 0.06, delayTime: 0.375,
            iconStyle: .fluteShape
        ),
        SynthPreset(
            name: "Bowed Bass",
            color: "#5A4030",
            voiceMode: .sampler(.bowedBass),   // a real 1958 double bass, bowed
            attack: 0.06, decay: 0.3, sustain: 0.9, release: 0.35,
            reverbMix: 0.45, delayMix: 0.04, delayTime: 0.5,
            iconStyle: .stringBow
        ),
        SynthPreset(
            name: "Pipe Organ",
            color: "#9A8047",
            voiceMode: .sampler(.pipeOrgan),
            attack: 0.01, decay: 0.0, sustain: 1.0, release: 0.12,
            reverbMix: 0.6, delayMix: 0.08, delayTime: 0.5,
            iconStyle: .churchPipes
        ),
    ]
}
