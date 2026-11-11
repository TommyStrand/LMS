import Foundation

// Electric piano — FM synthesis, in the manner of the classic DX "E. Piano".
//
// Two FM pairs share one carrier pitch:
//   • the BODY: a modulator at (almost) the same frequency, whose index falls as
//     the note decays — the mellow bark that gets brighter the harder you play;
//   • the TINE: a modulator at a high ratio (14×) with a short, bright burst —
//     the bell-like "ting" at the start of every Rhodes note. (This was missing:
//     without it the voice was a plain FM tone with no attack character.)
// The note decays EXPONENTIALLY (it used to fade in a straight line, which sounds
// like a volume fader, not a struck tine), faster for high notes than low ones.
//
// The three electric pianos differ through the preset: `fmIndex` (body bite),
// `fmRatio` (tine ratio; ≤ 1 = no tine, i.e. a reed piano like the Wurlitzer)
// and `fmDecay` (decay length).
final class RhodesVoice: AnyVoice {
    var filterCutoffMod: Float = 0.5  // → brightness (pad Y): one-pole tone LPF
    var lfoDepthMod:     Float = 0.5  // → tremolo depth
    var pitchBendSemitones: Float = 0

    var isFinished: Bool { envStage == .idle && decayEnv < 0.0001 }

    private var briState: Double = 0   // brightness LPF state (pad Y)

    private let freq:       Double
    private let velocity:   Float
    private let sampleRate: Double

    // FM synthesis
    private var carPhase:  Double = 0   // carrier
    private var modPhase:  Double = 0   // body modulator (≈ carrier + 0.5 Hz)
    private var tinePhase: Double = 0   // tine modulator (carrier × tineRatio)
    private let bodyIndex: Double
    private let tineRatio: Double
    private let hasTine:   Bool

    // Natural decay (key-independent), exponential
    private var decayEnv: Double = 1.0
    private let decayCoef: Double
    private var tineEnv:  Double = 1.0
    private let tineCoef: Double

    // Tremolo
    private var tremoloPhase: Double = 0

    // Long-press vibrato
    private var noteAge:  Double = 0
    private var vibPhase: Double = 0

    private var smoothPitchBend: Double = 0

    // Key-gated envelope (fast attack, short release)
    private enum EnvStage { case idle, attack, sustain, release }
    private var envStage: EnvStage = .idle
    private var envValue: Double   = 0

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.freq       = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity   = velocity
        self.sampleRate = sampleRate

        self.bodyIndex = preset.fmIndex > 0.001 ? Double(preset.fmIndex) : 1.6
        self.tineRatio = Double(preset.fmRatio)
        self.hasTine   = preset.fmRatio > 1.5

        // Decay: harder notes ring a little longer; each octave up halves-ish the
        // ring time (√2 per octave), as on the real instrument.
        let keyScale = pow(2.0, -Double(note - 60) / 24.0)
        let length   = Double(preset.fmDecay > 0.001 ? preset.fmDecay : 1.0)
        let tau      = (0.9 + Double(velocity) * 1.1) * length * keyScale
        self.decayCoef = exp(-1.0 / (tau * sampleRate))
        self.tineCoef  = exp(-1.0 / (0.22 * keyScale * sampleRate))
    }

    func start() { envStage = .attack }

    func release() {
        if envStage != .idle { envStage = .release }
    }

    func nextStereoSample() -> (Float, Float) {
        let dt = 1.0 / sampleRate

        // Natural decay — continues even while the key is held
        decayEnv *= decayCoef
        tineEnv  *= tineCoef

        // Kick voice to release when natural decay finishes
        if decayEnv < 0.0001 && envStage == .sustain { envStage = .release }

        // Expression vibrato from pad Y (lfoDepthMod): deeper/faster as you press up,
        // with a quick onset so short notes don't warble.
        noteAge  += dt
        vibPhase += (5.0 + Double(lfoDepthMod) * 1.8) * dt
        if vibPhase > 1 { vibPhase -= 1 }
        let vibRamp  = max(0.0, min(1.0, (noteAge - 0.05) / 0.2))
        let vibCents = sin(vibPhase * 2 * .pi) * vibRamp * Double(lfoDepthMod) * 42.0
        let vibFreq  = freq * pow(2.0, vibCents / 1200.0)

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        let bendedFreq = vibFreq * pow(2.0, smoothPitchBend / 12.0)

        // Body: modulator at carrier + 0.5 Hz (slight inharmonicity), index falls
        // with the decay — velocity-sensitive brightness.
        modPhase = (modPhase + (bendedFreq + 0.5) * dt).truncatingRemainder(dividingBy: 1.0)
        carPhase = (carPhase + bendedFreq * dt).truncatingRemainder(dividingBy: 1.0)
        let carrier = carPhase * 2 * .pi
        let bodyIdx = Double(velocity) * bodyIndex * decayEnv
        var out = sin(carrier + sin(modPhase * 2 * .pi) * bodyIdx)

        // Tine: short bright partial at the strike, stronger when played hard.
        if hasTine && tineEnv > 0.001 {
            tinePhase = (tinePhase + bendedFreq * tineRatio * dt).truncatingRemainder(dividingBy: 1.0)
            let tineIdx = 0.9 * Double(velocity) * tineEnv
            out += 0.42 * Double(velocity) * tineEnv * sin(carrier + sin(tinePhase * 2 * .pi) * tineIdx)
        }

        // Tremolo (~5 Hz, depth from lfoDepthMod)
        tremoloPhase += 5.0 * dt
        if tremoloPhase > 1.0 { tremoloPhase -= 1.0 }
        let trem = 1.0 + sin(tremoloPhase * 2 * .pi) * Double(lfoDepthMod * 0.2)
        out *= trem

        let env = advanceEnv(dt: dt)

        // Brightness from the pad's vertical axis (filterCutoffMod): one-pole LPF.
        let coef = Double(0.08 + filterCutoffMod * 0.92)
        briState += coef * (out * env * decayEnv * Double(velocity) * 0.45 - briState)
        let s = Float(briState)
        return (s, s)
    }

    private func advanceEnv(dt: Double) -> Double {
        switch envStage {
        case .idle:    return 0
        case .attack:
            envValue = min(envValue + dt / 0.004, 1.0)   // 4 ms anti-click ramp
            if envValue >= 1.0 { envStage = .sustain }
        case .sustain: envValue = 1.0
        case .release:
            envValue = max(envValue - dt / 0.5, 0.0)
            if envValue <= 0 { envStage = .idle }
        }
        return envValue
    }
}
