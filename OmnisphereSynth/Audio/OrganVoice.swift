import Foundation

// Additive pipe-organ voice.
// 9 sine-wave partials corresponding to drawbar footages:
// 16'  8'  5⅓'  4'  2⅔'  2'  1⅗'  1⅓'  1'
// ratio: 0.5  1  1.5   2   3    4    5    6   8
final class OrganVoice: AnyVoice {

    // Drawbar levels (0–1). Church cathedral registration by default.
    //
    // Registration: a principal chorus — 8' foundation, 4' and 2' above it, the
    // 2⅔' twelfth and a little mixture on top, 16' underneath. The 5⅓' quint is
    // OFF: at 0.7 (as it was) it sounded a fifth above every note, as loud as a
    // main stop, so chords were crowded with parallel fifths.
    static let churchLevels: [Float]    = [0.45, 1.0, 0.0, 0.75, 0.35, 0.5, 0.12, 0.2, 0.25]
    // Where each rank sits across the stereo field (0 = left, 1 = right): pipes
    // stand side by side in the case, so the sound has width instead of being mono.
    private static let pans: [Double]   = [0.5, 0.5, 0.5, 0.3, 0.7, 0.2, 0.8, 0.35, 0.65]
    static let ratios: [Double]         = [0.5,  1.0, 1.5, 2.0, 3.0,  4.0,  5.0, 6.0, 8.0]
    private static let churchLevelSum: Double = churchLevels.reduce(0) { $0 + Double($1) }

    var filterCutoffMod: Float = 0.5  // → brightness (pad Y): one-pole tone LPF
    var lfoDepthMod: Float = 0.5      // maps to tremulant depth
    var pitchBendSemitones: Float = 0
    var tremulantDepth: Float         // mutable so AudioEngine can push live knob changes

    var isFinished: Bool { envStage == .idle }

    private let freq: Double
    private let velocity: Float
    private let sampleRate: Double
    private var briL: Double = 0, briR: Double = 0   // brightness LPF state (pad Y)
    // Wind: the pressure is never perfectly steady — a slow ±2.5-cent wander.
    private var windPhase: Double = .random(in: 0..<1)
    private var vibPhase: Double = 0, vibRamp: Double = 0   // expression vibrato (pad Y)

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
    // Constant ratios — were recomputed with pow() per partial per sample.
    private static let detuneRatios: [Double] = detuneOffsets.map { pow(2.0, $0 / 1200.0) }

    enum EnvStage { case idle, attack, sustain, release }

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.freq = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.velocity = velocity
        self.sampleRate = sampleRate
        self.tremulantDepth = preset.tremulantDepth  // initial value; AudioEngine updates this live
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
            click = n * clickEnv * 0.012
            clickSamplesLeft -= 1
        }
        clickLpf = clickLpf * 0.7 + click * 0.3
        click = clickLpf

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        let bendFactor = pow(2.0, smoothPitchBend / 12.0)

        // Expression vibrato from pad Y (lfoDepthMod), independent of the tremulant.
        vibPhase += (5.2 + Double(lfoDepthMod) * 1.4) * dt
        if vibPhase >= 1 { vibPhase -= 1 }
        vibRamp += (1.0 - vibRamp) * min(dt / 0.2, 1.0)
        let vibFactor = pow(2.0, sin(vibPhase * 2 * .pi) * Double(lfoDepthMod) * 38.0 * vibRamp / 1200.0)

        windPhase += 0.63 * dt
        if windPhase >= 1 { windPhase -= 1 }
        let wind = 1.0 + 0.0015 * sin(windPhase * 2 * .pi)

        // Sum drawbar partials, each rank at its place in the stereo field
        var sumL: Double = 0, sumR: Double = 0
        for i in 0..<Self.ratios.count {
            let level = Double(Self.churchLevels[i])
            if level == 0 { continue }                      // stop not drawn
            let detuneFactor = Self.detuneRatios[i]
            let f = freq * Self.ratios[i] * detuneFactor * bendFactor * vibFactor * wind * (1.0 + tremVal * 0.3)
            phases[i] = (phases[i] + f * dt).truncatingRemainder(dividingBy: 1.0)
            let s = sin(phases[i] * 2 * .pi) * level
            sumL += s * 2 * (1 - Self.pans[i])
            sumR += s * 2 * Self.pans[i]
        }

        // Normalise (sum of all drawbar levels), tremulant amplitude, envelope
        let env = advanceEnvelope(dt: dt)
        let scale = (1.0 + tremVal) / Self.churchLevelSum
        sumL = (sumL * scale + click) * env
        sumR = (sumR * scale + click) * env

        // Brightness from the pad's vertical axis (filterCutoffMod): one-pole LPF.
        let coef = Double(0.08 + filterCutoffMod * 0.92)
        briL += coef * (sumL * Double(velocity) - briL)
        briR += coef * (sumR * Double(velocity) - briR)
        return (Float(briL), Float(briR))
    }

    private func advanceEnvelope(dt: Double) -> Double {
        switch envStage {
        case .idle:
            return 0
        case .attack:
            // A pipe takes a moment to speak: ~25 ms (was a 5 ms switch-on).
            envValue = min(envValue + dt / 0.025, 1.0)
            if envValue >= 1.0 { envStage = .sustain }
        case .sustain:
            envValue = 1.0
        case .release:
            // The pipe stops over ~80 ms; the room's reverb carries the rest.
            envValue = max(envValue - dt / 0.08, 0.0)
            if envValue <= 0 { envStage = .idle }
        }
        return envValue
    }
}
