import Foundation

// Additive pipe-organ voice.
// 9 sine-wave partials corresponding to drawbar footages:
// 16'  8'  5⅓'  4'  2⅔'  2'  1⅗'  1⅓'  1'
// ratio: 0.5  1  1.5   2   3    4    5    6   8
final class OrganVoice: AnyVoice {

    // Drawbar levels (0–1). Church cathedral registration by default.
    static let churchLevels: [Float] = [0.55, 1.0, 0.7, 0.8, 0.5, 0.35, 0.15, 0.1, 0.05]
    static let ratios: [Double]      = [0.5,  1.0, 1.5, 2.0, 3.0,  4.0,  5.0, 6.0, 8.0]

    var filterCutoffMod: Float = 0.5  // unused for organ, kept for protocol
    var lfoDepthMod: Float = 0.5      // maps to tremulant depth
    var pitchBendSemitones: Float = 0

    var isFinished: Bool { envStage == .idle }

    private let freq: Double
    private let velocity: Float
    private let sampleRate: Double
    private let tremulantDepth: Float

    private var phases: [Double]
    private var tremPhase: Double = 0
    private var smoothPitchBend: Double = 0
    private var envValue: Double = 0
    private var envStage: EnvStage = .idle

    // Key click: brief noise burst on attack
    private var clickSamplesLeft: Int
    private var noiseState: UInt32 = 98765
    private var clickLpf:   Double = 0

    // Per-partial slight detuning for warmth (cents)
    private static let detuneOffsets: [Double] = [0, 0, 1.2, -0.8, 0.5, -1.1, 0.9, -0.6, 0.3]

    enum EnvStage { case idle, attack, sustain, release }

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.freq = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity = velocity
        self.sampleRate = sampleRate
        self.tremulantDepth = preset.tremulantDepth
        self.phases = Array(repeating: 0, count: Self.ratios.count)
        self.clickSamplesLeft = Int(sampleRate * 0.012)  // 12 ms click
    }

    func start() { envStage = .attack }

    func release() {
        if envStage != .idle { envStage = .release }
    }

    func nextStereoSample() -> (Float, Float) {
        let dt = 1.0 / sampleRate

        // Tremulant LFO (~5.5 Hz, subtle amplitude + pitch wobble)
        tremPhase += 5.5 * dt
        if tremPhase > 1 { tremPhase -= 1 }
        let tremAmp = Double(tremulantDepth * Float(lfoDepthMod) * 2.0)
        let tremVal = sin(tremPhase * 2 * .pi) * tremAmp * 0.04

        // Key click — softer + lowpassed so rapid retriggers don't dump
        // high-frequency transients into the reverb/delay tail.
        var click: Double = 0
        if clickSamplesLeft > 0 {
            noiseState = noiseState &* 1664525 &+ 1013904223
            let n = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            let clickEnv = Double(clickSamplesLeft) / (sampleRate * 0.012)
            click = n * clickEnv * 0.03
            clickSamplesLeft -= 1
        }
        clickLpf = clickLpf * 0.7 + click * 0.3
        click = clickLpf

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        let bendFactor = pow(2.0, smoothPitchBend / 12.0)

        // Sum drawbar partials
        var sum: Double = 0
        for i in 0..<Self.ratios.count {
            let detuneCents = Self.detuneOffsets[i]
            let detuneFactor = pow(2.0, detuneCents / 1200.0)
            let f = freq * Self.ratios[i] * detuneFactor * bendFactor * (1.0 + tremVal * 0.3)
            phases[i] = (phases[i] + f * dt).truncatingRemainder(dividingBy: 1.0)
            sum += sin(phases[i] * 2 * .pi) * Double(Self.churchLevels[i])
        }

        // Normalise (sum of all drawbar levels)
        sum /= Double(Self.churchLevels.reduce(0, +))

        // Tremulant amplitude
        sum *= 1.0 + tremVal

        // Envelope (organ: instant on/off, short fade to avoid clicks)
        let env = advanceEnvelope(dt: dt)
        sum = (sum + click) * env

        let s = Float(sum * Double(velocity))
        return (s, s)
    }

    private func advanceEnvelope(dt: Double) -> Double {
        switch envStage {
        case .idle:
            return 0
        case .attack:
            // 5 ms linear ramp to avoid hard click
            envValue = min(envValue + dt / 0.005, 1.0)
            if envValue >= 1.0 { envStage = .sustain }
        case .sustain:
            envValue = 1.0
        case .release:
            // 40 ms linear fade
            envValue = max(envValue - dt / 0.04, 0.0)
            if envValue <= 0 { envStage = .idle }
        }
        return envValue
    }
}
