import Foundation

/// The general-purpose synth voice (23 of the presets).
///
/// Signal path: up to three oscillators (osc 1, an optional detuned unison copy of
/// osc 1, osc 2) → amp envelope → resonant low-pass per channel → stereo out.
///
/// What makes it sound less "cheap digital" than a plain 2-oscillator voice:
/// - **Band-limited saw and square (PolyBLEP).** Naive saw/square waveforms fold
///   their upper harmonics back into the audible range as inharmonic hash,
///   worst on high notes — the classic harsh, metallic digital edge.
/// - **Stereo unison.** `unisonCents` plays osc 1 as two copies a few cents apart,
///   one to each side, so pads and strings are wide and slowly moving instead
///   of a static mono tone. Every voice also drifts ±1.5 cents, like an
///   analogue oscillator bank.
/// - **A filter that moves and follows the keyboard.** `filterEnvAmount` opens the
///   filter at the start of the note and lets it close with the decay (plucks,
///   mallets, brass swells); `keyTrack` raises the cutoff with the note so high
///   notes are not dull and low notes not buzzy; harder notes are brighter.
/// - **2-operator FM** (`fmIndex`) on a sine osc 1, with an index that decays —
///   the inharmonic "ting" of bells, celesta, vibraphone and glass.
/// - **Exponential decay and release**, which is how real instruments fade.
///
/// Slow-moving values (LFO, vibrato, pitch, filter coefficients, FM index) are
/// computed once every `controlInterval` samples; the per-sample loop is just
/// phase accumulation, waveforms, the envelope and the two filters.
final class SynthVoice: AnyVoice {
    let note: Int
    let velocity: Float
    let preset: SynthPreset
    let sampleRate: Double

    // Real-time modifiable
    var filterCutoffMod: Float = 0.5  // 0–1, mapped from touch X
    var lfoDepthMod: Float = 0.5      // 0–1, mapped from touch Y
    var pitchBendSemitones: Float = 0
    /// Wave-morph position 0…1 (sine → triangle → saw → square), or < 0 for off
    /// (the preset's own waveforms). Set from the pad's vertical axis when the
    /// user picks "Wave Morph" in Settings.
    var waveMorph: Float = -1

    var isFinished: Bool { envStage == .idle }

    enum EnvStage { case idle, attack, decay, sustain, release }

    // MARK: Constants fixed at note-on

    private static let controlInterval = 16
    private let dt: Double
    private let freq: Double            // includes this voice's drift
    private let osc2Ratio: Double
    private let unisonUp: Double        // osc-1 copy A / copy B frequency ratios
    private let unisonDown: Double
    private let hasUnison: Bool
    private let useFM: Bool
    private let stereo: Bool            // false → one filter, identical L/R
    private let panNear: Double         // unison copy gain on its own side…
    private let panFar: Double          // …and on the opposite side
    private let osc1Gain: Double
    private let osc2Gain: Double
    private let cutoffScale: Double     // key tracking × velocity brightness
    private let filterQ: Double
    private let outGain: Double

    private let attackInc: Double
    private let decayCoef: Double
    private let releaseCoef: Double
    private let sustainLevel: Double
    private let filterEnvCoef: Double   // per control step
    private let fmEnvCoef: Double       // per control step

    // MARK: Running state (audio thread only)

    private var phase1a: Double = .random(in: 0..<1)   // random start phases: no
    private var phase1b: Double = .random(in: 0..<1)   // constructive spike when a
    private var phase2:  Double = .random(in: 0..<1)   // chord starts together
    private var phaseM:  Double = 0                    // FM modulator
    private var inc1a = 0.0, inc1b = 0.0, inc2 = 0.0, incM = 0.0
    private var noiseState: UInt32 = .random(in: 1...UInt32.max)

    private var lfoPhase: Double = 0
    private var lfoVal: Double = 0
    private var noteAge: Double = 0
    private var vibPhase: Double = 0
    private var smoothPitchBend: Double = 0
    private var smoothMorph: Double = -1
    private var smoothCutoff: Double
    private var filterEnv: Double = 1      // 1 at note-on, decays toward 0
    private var fmEnv: Double = 1
    private var fmIndexNow: Double = 0
    private var ampLfoGain: Double = 1

    private var envStage: EnvStage = .idle
    private var envValue: Double = 0

    private var controlCounter = 0
    private var cb0 = 0.0, cb1 = 0.0, cb2 = 0.0, ca1 = 0.0, ca2 = 0.0
    private var lx1 = 0.0, lx2 = 0.0, ly1 = 0.0, ly2 = 0.0     // left filter
    private var rx1 = 0.0, rx2 = 0.0, ry1 = 0.0, ry2 = 0.0     // right filter

    init(note: Int, velocity: Float, preset: SynthPreset, sampleRate: Double) {
        self.note = note
        self.velocity = velocity
        self.preset = preset
        self.sampleRate = sampleRate
        let dt = 1.0 / sampleRate
        self.dt = dt

        let driftCents = Double.random(in: -1.5...1.5)
        self.freq = 440.0 * pow(2.0, Double(note - 69) / 12.0) * pow(2.0, driftCents / 1200.0)
        self.osc2Ratio = pow(2.0, Double(preset.osc2Detune) / 12.0)

        // (Locals first: a class may not read its own properties until all are set.)
        let cents  = Double(max(0, preset.unisonCents))
        let unison = cents > 0.01
        let up     = pow(2.0, cents / 1200.0)
        self.hasUnison  = unison
        self.unisonUp   = up
        self.unisonDown = 1.0 / up
        self.useFM = preset.fmIndex > 0.001 && preset.osc1Waveform == .sine

        let width = Double(min(1, max(0, preset.stereoWidth)))
        self.stereo  = unison && width > 0.01
        self.panNear = (1 + width) / 2
        self.panFar  = (1 - width) / 2
        self.osc1Gain = Double(1 - preset.oscMix)
        self.osc2Gain = Double(preset.oscMix)

        // Key tracking around middle C; harder notes up to ~¾ octave brighter.
        let track = pow(2.0, Double(note - 60) / 12.0 * Double(preset.keyTrack))
        let bright = pow(2.0, (Double(velocity) - 0.75) * 0.9)
        self.cutoffScale = track * bright
        self.filterQ = max(0.5, 1.0 / (1.0 - Double(min(preset.filterResonance, 0.98)) * 0.95))
        // A resonant filter adds level at the peak; pull the voice down a little
        // so high-resonance presets are not louder than the rest.
        self.outGain = Double(velocity) * Double(preset.level) / (1.0 + Double(preset.filterResonance) * 0.8)

        // Envelope. Attack is linear; decay and release are exponential, reaching
        // ~95 % of the way in the preset's time (time constant = time / 3).
        self.attackInc    = dt / max(Double(preset.attack), 0.004)             // ≥ 4 ms: no click
        self.decayCoef    = 1 - exp(-dt / (max(Double(preset.decay), 0.005) / 3))
        self.releaseCoef  = 1 - exp(-dt / (max(Double(preset.release), 0.015) / 3))
        self.sustainLevel = Double(preset.sustain)
        let controlDt = dt * Double(SynthVoice.controlInterval)
        self.filterEnvCoef = 1 - exp(-controlDt / (max(Double(preset.decay), 0.02) / 3))
        self.fmEnvCoef     = 1 - exp(-controlDt / (max(Double(preset.fmDecay), 0.02) / 3))

        self.smoothCutoff = Double(preset.filterCutoff)
    }

    func start() { envStage = .attack }

    func release() {
        if envStage != .idle { envStage = .release }
    }

    // MARK: - Render

    func nextStereoSample() -> (Float, Float) {
        if controlCounter == 0 { updateControl() }
        controlCounter += 1
        if controlCounter >= SynthVoice.controlInterval { controlCounter = 0 }

        // Oscillators
        phase1a += inc1a; if phase1a >= 1 { phase1a -= 1 }
        phase2  += inc2;  if phase2  >= 1 { phase2  -= 1 }
        var fm = 0.0
        if useFM {
            phaseM += incM; if phaseM >= 1 { phaseM -= 1 }
            fm = fmIndexNow * sin(phaseM * 2 * .pi)
        }
        let a  = oscillator1(phase: phase1a, inc: inc1a, fm: fm)
        let s2 = oscillator(phase: phase2, inc: inc2, waveform: preset.osc2Waveform) * osc2Gain

        var l: Double, r: Double
        if hasUnison {
            phase1b += inc1b; if phase1b >= 1 { phase1b -= 1 }
            let b = oscillator1(phase: phase1b, inc: inc1b, fm: fm)
            l = (a * panNear + b * panFar) * osc1Gain + s2
            r = (a * panFar + b * panNear) * osc1Gain + s2
        } else {
            l = a * osc1Gain + s2
            r = l
        }

        // Amplitude envelope (+ amplitude LFO)
        let amp = advanceEnvelope() * ampLfoGain
        l *= amp

        // Resonant low-pass (direct-form-I biquad; coefficients from updateControl)
        let yl = cb0 * l + cb1 * lx1 + cb2 * lx2 - ca1 * ly1 - ca2 * ly2
        lx2 = lx1; lx1 = l; ly2 = ly1; ly1 = yl
        guard stereo else {
            let out = Float(yl * outGain)
            return (out, out)
        }
        r *= amp
        let yr = cb0 * r + cb1 * rx1 + cb2 * rx2 - ca1 * ry1 - ca2 * ry2
        rx2 = rx1; rx1 = r; ry2 = ry1; ry1 = yr
        return (Float(yl * outGain), Float(yr * outGain))
    }

    /// Everything that moves slowly, once per `controlInterval` samples (~2.8 kHz).
    private func updateControl() {
        let cdt = dt * Double(SynthVoice.controlInterval)

        // LFO
        lfoPhase += Double(preset.lfoRate) * cdt
        if lfoPhase >= 1 { lfoPhase -= 1 }
        lfoVal = sin(lfoPhase * 2 * .pi) * Double(preset.lfoDepth * lfoDepthMod * 2)
        ampLfoGain = preset.lfoTarget == .amplitude ? 1.0 + lfoVal * 0.5 : 1.0

        // Expression vibrato from the pad's vertical axis: deeper and a little
        // faster as you press up; quick onset so short taps don't warble.
        noteAge += cdt
        vibPhase += (5.0 + Double(lfoDepthMod) * 1.8) * cdt
        if vibPhase >= 1 { vibPhase -= 1 }
        let vibRamp  = max(0.0, min(1.0, (noteAge - 0.05) / 0.2))
        let vibCents = sin(vibPhase * 2 * .pi) * vibRamp * Double(lfoDepthMod) * 45.0

        // Glide toward the requested bend (same ~75 ms feel as before).
        smoothPitchBend += (Double(pitchBendSemitones) - smoothPitchBend) * 0.0048

        var semitones = smoothPitchBend + vibCents / 100.0
        if preset.lfoTarget == .pitch { semitones += lfoVal }
        let pitch = abs(semitones) > 1e-6 ? pow(2.0, semitones / 12.0) : 1.0
        let f = freq * pitch
        inc1a = min(0.45, f * (hasUnison ? unisonUp : 1.0) * dt)
        inc1b = min(0.45, f * unisonDown * dt)
        inc2  = min(0.45, f * osc2Ratio * dt)
        incM  = min(0.45, f * Double(preset.fmRatio) * dt)

        // FM index: bright at the strike, settling to a soft sustain; harder = brighter.
        fmEnv += (0 - fmEnv) * fmEnvCoef
        fmIndexNow = Double(preset.fmIndex) * (0.35 + 0.65 * Double(velocity)) * (0.12 + 0.88 * fmEnv)

        // Wave morph glide
        if waveMorph >= 0 {
            if smoothMorph < 0 { smoothMorph = Double(waveMorph) }   // no glide-in from "off"
            smoothMorph += (Double(waveMorph) - smoothMorph) * 0.0315
        } else {
            smoothMorph = -1
        }

        // Filter cutoff: preset × pad X × key tracking × velocity × envelope (× LFO)
        filterEnv += (0 - filterEnv) * filterEnvCoef
        var cutoff = Double(preset.filterCutoff) * Double(filterCutoffMod * 1.8 + 0.1) * cutoffScale
        cutoff *= pow(2.0, Double(preset.filterEnvAmount) * 4.0 * filterEnv)
        if preset.lfoTarget == .filter { cutoff *= pow(2.0, lfoVal) }
        cutoff = max(30, min(cutoff, min(18000, sampleRate * 0.45)))
        smoothCutoff += (cutoff - smoothCutoff) * 0.56

        let w0 = 2.0 * .pi * smoothCutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2.0 * filterQ)
        let a0 = 1.0 + alpha
        cb1 = (1.0 - cosW) / a0
        cb0 = cb1 / 2
        cb2 = cb0
        ca1 = -2.0 * cosW / a0
        ca2 = (1.0 - alpha) / a0
    }

    /// Osc 1: FM sine, the wave morph, or the preset's waveform.
    @inline(__always)
    private func oscillator1(phase: Double, inc: Double, fm: Double) -> Double {
        if smoothMorph >= 0 {
            let m = min(1, max(0, smoothMorph)) * 3
            let i = min(2, Int(m))
            let f = m - Double(i)
            return SynthVoice.bandLimited(i, phase, inc) * (1 - f)
                 + SynthVoice.bandLimited(i + 1, phase, inc) * f
        }
        if useFM { return sin(phase * 2 * .pi + fm) }
        return oscillator(phase: phase, inc: inc, waveform: preset.osc1Waveform)
    }

    @inline(__always)
    private func oscillator(phase: Double, inc: Double, waveform: SynthPreset.Waveform) -> Double {
        if waveform == .noise {
            noiseState = noiseState &* 1664525 &+ 1013904223       // fast LCG white noise
            return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
        }
        // With the wave morph on, osc 2 follows it too (as before).
        if smoothMorph >= 0 {
            let m = min(1, max(0, smoothMorph)) * 3
            let i = min(2, Int(m))
            let f = m - Double(i)
            return SynthVoice.bandLimited(i, phase, inc) * (1 - f)
                 + SynthVoice.bandLimited(i + 1, phase, inc) * f
        }
        return SynthVoice.bandLimited(waveform.rawValue, phase, inc)
    }

    private func advanceEnvelope() -> Double {
        switch envStage {
        case .idle:
            return 0
        case .attack:
            envValue += attackInc
            if envValue >= 1.0 { envValue = 1.0; envStage = .decay }
        case .decay:
            envValue += (sustainLevel - envValue) * decayCoef
            if abs(envValue - sustainLevel) < 0.0005 { envValue = sustainLevel; envStage = .sustain }
        case .sustain:
            envValue = sustainLevel
            // A percussive preset (sustain 0) is over once it has decayed: free
            // the voice instead of holding a silent one until the key is lifted.
            if sustainLevel <= 0.0005 { envStage = .idle }
        case .release:
            envValue -= envValue * releaseCoef
            if envValue <= 0.001 { envValue = 0; envStage = .idle }   // −60 dB
        }
        return envValue
    }

    // MARK: - Band-limited waveforms (pure — unit-tested)

    /// PolyBLEP residual: smooths the step at a waveform discontinuity over one
    /// sample either side. `t` = phase 0..<1, `dt` = phase increment per sample.
    @inline(__always)
    static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    /// Waveform by index — 0 sine, 1 triangle, 2 saw, 3 square (the order of both
    /// `SynthPreset.Waveform` and `WaveMorph`) — with the saw and square
    /// band-limited. `inc` = phase increment per sample (frequency / sample rate).
    @inline(__always)
    static func bandLimited(_ index: Int, _ phase: Double, _ inc: Double) -> Double {
        switch index {
        case 0:
            return sin(phase * 2 * .pi)
        case 1:
            return phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
        case 2:
            return 2 * phase - 1 - polyBLEP(phase, inc)
        default:
            var half = phase + 0.5
            if half >= 1 { half -= 1 }
            return (phase < 0.5 ? 1.0 : -1.0) + polyBLEP(phase, inc) - polyBLEP(half, inc)
        }
    }
}

// MARK: - Wave morph (pure — unit-tested in SuperNovaPadTests)

/// MorphWiz-style timbre morph: one continuous control walks the oscillator
/// through sine → triangle → saw → square, linearly crossfading between
/// neighbouring shapes. 0 = sine, 1/3 = triangle, 2/3 = saw, 1 = square.
enum WaveMorph {
    static func sample(phase: Double, morph: Double) -> Double {
        let m = min(1, max(0, morph)) * 3
        let i = min(2, Int(m))
        let f = m - Double(i)
        return shape(i, phase) * (1 - f) + shape(i + 1, phase) * f
    }

    static func shape(_ index: Int, _ phase: Double) -> Double {
        switch index {
        case 0:  return sin(phase * 2 * .pi)
        case 1:  return phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
        case 2:  return 2 * phase - 1
        default: return phase < 0.5 ? 1.0 : -1.0
        }
    }
}
