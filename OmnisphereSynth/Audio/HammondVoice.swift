import Foundation

// Hammond B3 — 9-partial additive + percussion + Leslie rotary speaker.
// Returns true stereo from Leslie (different L/R).
final class HammondVoice: AnyVoice {

    // Drawbar ratios (footage) and classic "888000000" rock levels
    private static let ratios:     [Double] = [0.5,1.0,1.5,2.0,3.0,4.0,5.0,6.0,8.0]
    private static let levels:     [Float]  = [0.8,0.8,0.8,0.0,0.0,0.0,0.0,0.0,0.0]
    private static let detunes:    [Double] = [0.0,0.0,1.2,-0.8,0.5,-1.1,0.9,-0.6,0.3]
    private static let totalLevel: Double   = levels.reduce(0) { $0 + Double($1) }

    var filterCutoffMod: Float = 0.5  // unused (organ), kept for protocol
    var lfoDepthMod:     Float = 0.5  // → Leslie speed (high = fast/tremolo)
    var pitchBendSemitones: Float = 0
    var isFinished: Bool { envStage == .idle }

    private let freq:       Double
    private let velocity:   Float
    private let sampleRate: Double

    // Partials
    private var phases: [Double]
    private var clickLeft: Int

    // Percussion (2nd harmonic, fast 40 ms decay)
    private var percPhase: Double = 0
    private var percEnv:   Double = 1.0

    // Leslie
    private var hornPhase:  Double = 0
    private var curSpeed:   Double = 0.7   // Hz
    private var targetSpeed:Double = 0.7
    private let leslieBuffer: UnsafeMutablePointer<Float>
    private let lesliBufSize = 4096
    private var leslieWrite = 0

    // Envelope (instant on/off like a real Hammond)
    private enum EnvStage { case idle, attack, sustain, release }
    private var envStage: EnvStage = .idle
    private var envValue: Double   = 0

    private var noiseState: UInt32 = 44444
    private var clickLpf:   Double = 0   // smooths the key-click noise
    private var smoothPitchBend: Double = 0

    init(note: Int, velocity: Float, sampleRate: Double) {
        self.freq       = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity   = velocity
        self.sampleRate = sampleRate
        self.phases     = Array(repeating: 0, count: Self.ratios.count)
        self.clickLeft  = Int(sampleRate * 0.012)
        leslieBuffer    = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        leslieBuffer.initialize(repeating: 0, count: 4096)
    }

    deinit { leslieBuffer.deallocate() }

    func start() { envStage = .attack }

    func release() {
        if envStage != .idle { envStage = .release }
    }

    // Returns (left, right) Leslie stereo
    func nextStereoSample() -> (Float, Float) {
        let dt = 1.0 / sampleRate

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        let bendFactor = pow(2.0, smoothPitchBend / 12.0)

        // Additive synthesis
        var sum: Double = 0
        for k in 0..<Self.ratios.count {
            let df = pow(2.0, Self.detunes[k] / 1200.0)
            let f  = freq * Self.ratios[k] * df * bendFactor
            phases[k] = (phases[k] + f * dt).truncatingRemainder(dividingBy: 1.0)
            sum += sin(phases[k] * 2 * .pi) * Double(Self.levels[k])
        }
        sum /= Self.totalLevel

        // Percussion (2nd harmonic)
        percPhase = (percPhase + freq * 2.0 * bendFactor * dt).truncatingRemainder(dividingBy: 1.0)
        percEnv   = max(0, percEnv - dt / 0.04)
        sum      += sin(percPhase * 2 * .pi) * percEnv * 0.35

        // Key click — softer + lowpassed so a flurry of note-ons doesn't
        // pile high-frequency transients into the reverb/delay tail.
        var click: Double = 0
        if clickLeft > 0 {
            noiseState = noiseState &* 1664525 &+ 1013904223
            let n = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            click = n * (Double(clickLeft) / (sampleRate * 0.012)) * 0.035
            clickLeft -= 1
        }
        // One-pole LPF on the click only (≈2.5 kHz)
        clickLpf = clickLpf * 0.7 + click * 0.3
        click = clickLpf

        let env = advanceEnv(dt: dt)
        let mono = Float((sum + click) * env * Double(velocity) * 0.55)

        // Leslie: speed follows lfoDepthMod (0=slow chorale, 1=fast tremolo)
        targetSpeed = lfoDepthMod > 0.5 ? 6.7 : 0.7
        curSpeed   += (targetSpeed - curSpeed) * min(dt * 1.5, 1.0)
        hornPhase  += curSpeed * dt
        if hornPhase >= 1.0 { hornPhase -= 1.0 }

        // Write to Leslie buffer
        leslieBuffer[leslieWrite & (lesliBufSize - 1)] = mono

        let angle = hornPhase * 2 * Double.pi
        let dA = Float(8 * (1 + sin(angle)))
        let dB = Float(8 * (1 + cos(angle)))

        func readAt(_ delay: Float) -> Float {
            var rp = Float(leslieWrite) - delay - 1
            if rp < 0 { rp += Float(lesliBufSize) }
            let i0 = Int(rp) & (lesliBufSize - 1)
            let i1 = (i0 + 1) & (lesliBufSize - 1)
            let fr = rp - rp.rounded(.down)
            return leslieBuffer[i0] * (1 - fr) + leslieBuffer[i1] * fr
        }

        let amL = 0.72 + 0.28 * sin(angle)
        let amR = 0.72 + 0.28 * cos(angle)

        leslieWrite = (leslieWrite + 1) & (lesliBufSize - 1)
        return (readAt(dA) * Float(amL), readAt(dB) * Float(amR))
    }

    private func advanceEnv(dt: Double) -> Double {
        switch envStage {
        case .idle:    return 0
        case .attack:
            envValue = min(envValue + dt / 0.005, 1.0)
            if envValue >= 1.0 { envStage = .sustain }
        case .sustain: envValue = 1.0
        case .release:
            envValue = max(envValue - dt / 0.05, 0.0)
            if envValue <= 0 { envStage = .idle }
        }
        return envValue
    }
}
