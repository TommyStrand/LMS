import Foundation

final class SynthVoice: AnyVoice {
    let note: Int
    let velocity: Float
    let preset: SynthPreset
    let sampleRate: Double

    // Real-time modifiable
    var filterCutoffMod: Float = 0.5  // 0–1, mapped from touch X
    var lfoDepthMod: Float = 0.5      // 0–1, mapped from touch Y
    var pitchBendSemitones: Float = 0

    // Smooth pitch glide (audio-thread only)
    private var smoothPitchBend: Double = 0

    // Smooth filter cutoff — prevents biquad instability from rapid LFO jumps
    private var smoothCutoff: Double = 0

    // Oscillator state — random start phase prevents polyphonic voices from
    // firing at the same phase simultaneously, which would create a loud
    // constructive-interference spike that feeds into the delay line.
    private var phase1: Double = .random(in: 0..<1)
    private var phase2: Double = .random(in: 0..<1)
    private var lfoPhase: Double = 0
    private var noiseState: UInt32 = 1

    // Long-press vibrato
    private var noteAge:  Double = 0
    private var vibPhase: Double = 0

    // Envelope state
    private var envStage: EnvStage = .idle
    private var envValue: Double = 0
    private var envTime: Double = 0

    // Biquad filter state (low-pass)
    private var bq_x1: Double = 0, bq_x2: Double = 0
    private var bq_y1: Double = 0, bq_y2: Double = 0

    // Cached, normalised biquad coefficients. Recomputing cos/sin and the full
    // coefficient set every sample (per voice) is the single most expensive thing
    // in the render loop; under a held polyphonic chord it overloads the audio
    // thread and causes dropouts that sound like notes cutting out. We update the
    // coefficients once per BIQUAD_UPDATE samples instead — at 44.1 kHz that is a
    // ~2.8 kHz update rate, far faster than the smoothed cutoff actually moves, so
    // there is no audible stepping.
    private var cb0 = 0.0, cb1 = 0.0, cb2 = 0.0, ca1 = 0.0, ca2 = 0.0
    private var coefCounter = 0
    private static let BIQUAD_UPDATE = 16

    private let freq: Double

    var isFinished: Bool { envStage == .idle }

    enum EnvStage { case idle, attack, decay, sustain, release }

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.note = note
        self.velocity = velocity
        self.preset = preset
        self.sampleRate = sampleRate
        self.freq = 440.0 * pow(2.0, Double(note - 69) / 12.0)
        self.smoothCutoff = Double(preset.filterCutoff)
    }

    func start() { envStage = .attack; envTime = 0 }

    func release() {
        if envStage != .idle { envStage = .release; envTime = 0 }
    }

    func nextStereoSample() -> (Float, Float) {
        let dt = 1.0 / sampleRate

        // LFO
        lfoPhase += Double(preset.lfoRate) * dt
        if lfoPhase > 1 { lfoPhase -= 1 }
        let lfoVal = sin(lfoPhase * 2 * .pi) * Double(preset.lfoDepth * lfoDepthMod * 2)

        // Expression-wheel vibrato driven by the pad Y axis (lfoDepthMod): deeper and
        // a little faster as you press up — like leaning into a mod/expression wheel.
        // Quick onset so short taps don't warble.
        noteAge += dt
        vibPhase += (5.0 + Double(lfoDepthMod) * 1.8) * dt
        if vibPhase > 1 { vibPhase -= 1 }
        let vibRamp  = max(0.0, min(1.0, (noteAge - 0.05) / 0.2))
        let vibCents = sin(vibPhase * 2 * .pi) * vibRamp * Double(lfoDepthMod) * 45.0
        // Skip the pow() while vibrato is effectively silent (Y near zero / pre-onset).
        let vibFactor = abs(vibCents) > 0.01 ? pow(2.0, vibCents / 1200.0) : 1.0

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        // Skip the pow() unless a glissando bend is actually in effect.
        let bendFactor = abs(smoothPitchBend) > 1e-6 ? pow(2.0, smoothPitchBend / 12.0) : 1.0

        // Frequency with detune + LFO pitch mod + vibrato + glissando bend
        var f1 = freq * vibFactor * bendFactor
        var f2 = freq * pow(2.0, Double(preset.osc2Detune) / 12.0) * vibFactor * bendFactor
        if preset.lfoTarget == .pitch {
            f1 *= pow(2.0, lfoVal / 12.0)
            f2 *= pow(2.0, lfoVal / 12.0)
        }

        // Oscillators
        phase1 = (phase1 + f1 * dt).truncatingRemainder(dividingBy: 1.0)
        phase2 = (phase2 + f2 * dt).truncatingRemainder(dividingBy: 1.0)

        let s1 = waveformSample(phase: phase1, waveform: preset.osc1Waveform)
        let s2 = waveformSample(phase: phase2, waveform: preset.osc2Waveform)
        var raw = s1 * Double(1 - preset.oscMix) + s2 * Double(preset.oscMix)

        // Envelope
        let env = advanceEnvelope(dt: dt)
        if preset.lfoTarget == .amplitude {
            raw *= env * (1.0 + lfoVal * 0.5)
        } else {
            raw *= env
        }

        // Filter — smooth cutoff to prevent biquad instability from rapid LFO changes
        var targetCutoff = Double(preset.filterCutoff) * Double(filterCutoffMod * 1.8 + 0.1)
        targetCutoff = max(30, min(targetCutoff, 18000))
        if preset.lfoTarget == .filter {
            targetCutoff *= pow(2.0, lfoVal)
            targetCutoff = max(30, min(targetCutoff, 18000))
        }
        smoothCutoff += (targetCutoff - smoothCutoff) * 0.05
        let filtered = applyBiquadLP(input: raw, cutoff: smoothCutoff, resonance: Double(preset.filterResonance))

        let s = Float(filtered * Double(velocity))
        return (s, s)
    }

    private func waveformSample(phase: Double, waveform: SynthPreset.Waveform) -> Double {
        switch waveform {
        case .sine:
            return sin(phase * 2 * .pi)
        case .triangle:
            return phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
        case .sawtooth:
            return 2 * phase - 1
        case .square:
            return phase < 0.5 ? 1.0 : -1.0
        case .noise:
            // Fast LCG white noise
            noiseState = noiseState &* 1664525 &+ 1013904223
            return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
        }
    }

    private func advanceEnvelope(dt: Double) -> Double {
        // Anti-click: enforce minimum attack/release times so steep ADSR
        // values can't produce sub-millisecond amplitude jumps.
        let minAttack:  Double = 0.004    // 4 ms
        let minRelease: Double = 0.012    // 12 ms
        switch envStage {
        case .idle:
            return 0
        case .attack:
            let a = max(Double(preset.attack), minAttack)
            envValue = min(envValue + dt / a, 1.0)
            if envValue >= 1.0 { envStage = .decay; envTime = 0 }
        case .decay:
            let target = Double(preset.sustain)
            let d = max(Double(preset.decay), 0.005)
            envValue = max(envValue - (1.0 - target) * dt / d, target)
            if envValue <= target { envStage = .sustain }
        case .sustain:
            envValue = Double(preset.sustain)
        case .release:
            let r = max(Double(preset.release), minRelease)
            envValue = max(envValue - envValue * dt / r, 0.0)
            if envValue <= 0.0001 { envStage = .idle }
        }
        return envValue
    }

    private func applyBiquadLP(input: Double, cutoff: Double, resonance: Double) -> Double {
        // Recompute coefficients only every BIQUAD_UPDATE samples (counter starts at
        // 0 so the very first sample always computes a valid set).
        if coefCounter == 0 {
            let w0 = 2.0 * .pi * cutoff / sampleRate
            let cosW = cos(w0)
            let sinW = sin(w0)
            let q = max(0.5, Double(1.0 / (1.0 - resonance * 0.95)))
            let alpha = sinW / (2.0 * q)

            let b0 = (1.0 - cosW) / 2.0
            let b1 = 1.0 - cosW
            let b2 = (1.0 - cosW) / 2.0
            let a0 = 1.0 + alpha
            let a1 = -2.0 * cosW
            let a2 = 1.0 - alpha

            cb0 = b0 / a0; cb1 = b1 / a0; cb2 = b2 / a0
            ca1 = a1 / a0; ca2 = a2 / a0
        }
        coefCounter += 1
        if coefCounter >= SynthVoice.BIQUAD_UPDATE { coefCounter = 0 }

        let y = cb0 * input + cb1 * bq_x1 + cb2 * bq_x2 - ca1 * bq_y1 - ca2 * bq_y2

        bq_x2 = bq_x1; bq_x1 = input
        bq_y2 = bq_y1; bq_y1 = y
        return y
    }
}
