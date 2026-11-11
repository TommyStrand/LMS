import Foundation

// Hammond B3 — 9-partial additive + percussion + Leslie rotary speaker.
// Returns true stereo from Leslie (different L/R).
final class HammondVoice: AnyVoice {

    // Drawbar ratios in footage order: 16' 8' 5⅓' 4' 2⅔' 2' 1⅗' 1⅓' 1'.
    //
    // Registration: a warm, full "all-round" setting. It used to be only the first
    // three drawbars at equal level — sub-octave, fundamental and a FIFTH as loud
    // as the fundamental — which is hollow on single notes and puts a parallel
    // fifth on every note of a chord. The fifth is now a colour, and the 4', 2'
    // and 1' drawbars add the body and the shine.
    private static let ratios:     [Double] = [0.5,1.0,1.5,2.0,3.0,4.0,5.0,6.0,8.0]
    private static let levels:     [Float]  = [0.70,0.80,0.35,0.60,0.22,0.30,0.0,0.0,0.14]
    private static let detunes:    [Double] = [0.0,0.0,1.2,-0.8,0.5,-1.1,0.9,-0.6,0.3]
    // Constant per-drawbar detune ratios. (These were recomputed with pow() for
    // every partial of every voice on every sample — nine pow() calls per sample.)
    private static let detuneRatios: [Double] = detunes.map { pow(2.0, $0 / 1200.0) }
    private static let totalLevel: Double   = levels.reduce(0) { $0 + Double($1) }

    var filterCutoffMod: Float = 0.5  // → brightness (pad Y): one-pole tone LPF
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
    private let percDecay: Double

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
    private var briL: Double = 0, briR: Double = 0   // brightness LPF state (pad Y)
    private var vibPhase: Double = 0, vibRamp: Double = 0   // expression vibrato (pad Y)

    init(note: Int, velocity: Float, sampleRate: Double) {
        self.freq       = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity   = velocity
        self.sampleRate = sampleRate
        self.phases     = Array(repeating: 0, count: Self.ratios.count)
        self.clickLeft  = Int(sampleRate * 0.012)
        self.percDecay  = exp(-1.0 / (0.07 * sampleRate))
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

        // Expression vibrato from pad Y (lfoDepthMod) — deeper/faster as you press up.
        vibPhase += (5.2 + Double(lfoDepthMod) * 1.4) * dt
        if vibPhase >= 1 { vibPhase -= 1 }
        vibRamp += (1.0 - vibRamp) * min(dt / 0.18, 1.0)
        let vibFactor = pow(2.0, sin(vibPhase * 2 * .pi) * Double(lfoDepthMod) * 40.0 * vibRamp / 1200.0)
        let pitch = bendFactor * vibFactor

        // Additive synthesis
        var sum: Double = 0
        for k in 0..<Self.ratios.count {
            let level = Self.levels[k]
            if level == 0 { continue }                    // drawbar pushed in
            let f  = freq * Self.ratios[k] * Self.detuneRatios[k] * pitch
            phases[k] = (phases[k] + f * dt).truncatingRemainder(dividingBy: 1.0)
            sum += sin(phases[k] * 2 * .pi) * Double(level)
        }
        sum /= Self.totalLevel

        // Percussion (2nd harmonic)
        percPhase = (percPhase + freq * 2.0 * pitch * dt).truncatingRemainder(dividingBy: 1.0)
        // "Fast" percussion: an exponential ping of roughly 200 ms. (It was a
        // 40 ms straight-line blip, closer to a click than to the B3's percussion.)
        percEnv  *= percDecay
        sum      += sin(percPhase * 2 * .pi) * percEnv * 0.30

        // Key click — softer + lowpassed so a flurry of note-ons doesn't
        // pile high-frequency transients into the reverb/delay tail.
        var click: Double = 0
        if clickLeft > 0 {
            noiseState = noiseState &* 1664525 &+ 1013904223
            let n = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            click = n * (Double(clickLeft) / (sampleRate * 0.012)) * 0.016
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
        let outL = readAt(dA) * Float(amL)
        let outR = readAt(dB) * Float(amR)

        // Brightness from the pad's vertical axis: a one-pole low-pass that opens
        // up as filterCutoffMod rises, so playing higher sounds brighter/more open.
        let coef = Double(0.08 + filterCutoffMod * 0.92)
        briL += coef * (Double(outL) - briL)
        briR += coef * (Double(outR) - briR)
        return (Float(briL), Float(briR))
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
