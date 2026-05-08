import Foundation

// Rhodes Mk1 electric piano — 2-operator FM synthesis.
// Velocity controls FM modulation index (brightness).
// Natural exponential decay regardless of key state.
final class RhodesVoice: AnyVoice {

    var filterCutoffMod: Float = 0.5
    var lfoDepthMod:     Float = 0.5  // → tremolo depth
    var isFinished: Bool { envStage == .idle && decayEnv < 0.0001 }

    private let freq:       Double
    private let velocity:   Float
    private let sampleRate: Double

    // FM synthesis
    private var carPhase: Double = 0   // carrier
    private var modPhase: Double = 0   // modulator (≈ carrier + 0.5 Hz)

    // Natural decay (key-independent)
    private var decayEnv:  Double
    private let decayTime: Double

    // Tremolo
    private var tremoloPhase: Double = 0

    // Key-gated envelope (fast attack, instant release)
    private enum EnvStage { case idle, attack, sustain, release }
    private var envStage: EnvStage = .idle
    private var envValue: Double   = 0

    init(note: Int, velocity: Float, sampleRate: Double) {
        self.freq       = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity   = velocity
        self.sampleRate = sampleRate
        // Higher velocity → slightly longer, brighter decay
        self.decayTime  = 1.2 + Double(velocity) * 1.5
        self.decayEnv   = 1.0
    }

    func start() { envStage = .attack }

    func release() {
        if envStage != .idle { envStage = .release }
    }

    func nextStereoSample() -> (Float, Float) {
        let dt = 1.0 / sampleRate

        // Natural decay — continues even while key is held
        decayEnv = max(0, decayEnv - dt / decayTime)

        // Kick voice to release when natural decay finishes
        if decayEnv < 0.0001 && envStage == .sustain { envStage = .release }

        // FM: modulator at carrier + 0.5 Hz (slight inharmonicity)
        modPhase = (modPhase + (freq + 0.5) * dt).truncatingRemainder(dividingBy: 1.0)
        let modIdx = Double(velocity) * 1.6 * decayEnv    // velocity-sensitive brightness
        let modSig = sin(modPhase * 2 * .pi) * modIdx

        carPhase = (carPhase + freq * dt).truncatingRemainder(dividingBy: 1.0)
        var out = sin(carPhase * 2 * .pi + modSig)

        // Tremolo (~5 Hz, depth from lfoDepthMod)
        tremoloPhase += 5.0 * dt
        if tremoloPhase > 1.0 { tremoloPhase -= 1.0 }
        let trem = 1.0 + sin(tremoloPhase * 2 * .pi) * Double(lfoDepthMod * 0.2)
        out *= trem

        let env = advanceEnv(dt: dt)
        let s   = Float(out * env * decayEnv * Double(velocity) * 0.45)
        return (s, s)
    }

    private func advanceEnv(dt: Double) -> Double {
        switch envStage {
        case .idle:    return 0
        case .attack:
            envValue = min(envValue + dt / 0.002, 1.0)
            if envValue >= 1.0 { envStage = .sustain }
        case .sustain: envValue = 1.0
        case .release:
            envValue = max(envValue - dt / 0.5, 0.0)
            if envValue <= 0 { envStage = .idle }
        }
        return envValue
    }
}
