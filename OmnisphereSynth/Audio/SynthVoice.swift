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

    // Oscillator state
    private var phase1: Double = 0
    private var phase2: Double = 0
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

    private let freq: Double

    var isFinished: Bool { envStage == .idle }

    enum EnvStage { case idle, attack, decay, sustain, release }

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.note = note
        self.velocity = velocity
        self.preset = preset
        self.sampleRate = sampleRate
        self.freq = 440.0 * pow(2.0, Double(note - 69) / 12.0)
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

        // Long-press vibrato — silent for the first 400 ms, then ramps in
        // over another 400 ms. ~5.5 Hz, ±22 cents at full depth.
        noteAge += dt
        vibPhase += 5.5 * dt
        if vibPhase > 1 { vibPhase -= 1 }
        let vibRamp = max(0.0, min(1.0, (noteAge - 0.4) / 0.4))
        let vibCents = sin(vibPhase * 2 * .pi) * vibRamp * 22.0
        let vibFactor = pow(2.0, vibCents / 1200.0)

        // Smooth pitch glide
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0003
        let bendFactor = pow(2.0, smoothPitchBend / 12.0)

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

        // Filter
        var cutoff = Double(preset.filterCutoff) * Double(filterCutoffMod * 1.8 + 0.1)
        cutoff = max(30, min(cutoff, 18000))
        if preset.lfoTarget == .filter {
            cutoff *= pow(2.0, lfoVal)
            cutoff = max(30, min(cutoff, 18000))
        }
        let filtered = applyBiquadLP(input: raw, cutoff: cutoff, resonance: Double(preset.filterResonance))

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

        let y = (b0 / a0) * input + (b1 / a0) * bq_x1 + (b2 / a0) * bq_x2
                - (a1 / a0) * bq_y1 - (a2 / a0) * bq_y2

        bq_x2 = bq_x1; bq_x1 = input
        bq_y2 = bq_y1; bq_y1 = y
        return y
    }
}
