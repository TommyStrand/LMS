import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Lo-Fi: bit-depth crush + sample-rate reduction
// ─────────────────────────────────────────────────────────────────────────────
final class LofiProcessor {
    private var counter = 0
    private var held: Float = 0

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        let div = 1 + Int(amount * 15)
        counter += 1
        if counter >= div { counter = 0; held = input }
        let bits  = 16 - amount * 12
        let steps = pow(2, bits) - 1
        return (held * steps).rounded() / steps
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Space Echo: Roland RE-201-style multi-head tape echo
// Three heads at increasing delays, wow/flutter pitch modulation,
// bandwidth-limited feedback with tape saturation.
// ─────────────────────────────────────────────────────────────────────────────
final class SpaceEchoProcessor {
    private let bufSize = 65536
    private var buf: [Float]
    private var writePos = 0
    private var wowPhase:     Double = 0
    private var flutterPhase: Double = 0
    private var lpState:      Float  = 0
    private let sampleRate:   Float
    private let headSamples:  [Float]           // three head positions in samples

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        buf = Array(repeating: 0, count: 65536)
        headSamples = [110, 240, 430].map { $0 * Float(sampleRate) / 1000 }
    }

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        let dt = 1.0 / Double(sampleRate)
        wowPhase     += 0.45 * dt
        flutterPhase += 5.20 * dt
        let wobble = Float(sin(wowPhase     * 2 * .pi) * 0.30
                          + sin(flutterPhase * 2 * .pi) * 0.08) * amount

        var wet: Float = 0
        let headGains: [Float] = [0.55, 0.38, 0.22]
        for (i, base) in headSamples.enumerated() {
            wet += readAt(Float(writePos) - (base + wobble * Float(i + 1) * 2.5))
                   * headGains[i]
        }

        // Tape bandwidth LPF + soft saturation on feedback
        lpState = lpState * 0.72 + wet * 0.28
        let fb = tanh(lpState * (1 + amount * 0.8)) * 0.45

        buf[writePos & (bufSize - 1)] = input + fb * amount
        writePos = (writePos + 1) & (bufSize - 1)

        return input * (1 - amount * 0.35) + wet * amount
    }

    private func readAt(_ pos: Float) -> Float {
        var p = pos; if p < 0 { p += Float(bufSize) }
        let i0 = Int(p) & (bufSize - 1)
        let i1 = (i0 + 1) & (bufSize - 1)
        let fr = p - p.rounded(.down)
        return buf[i0] * (1 - fr) + buf[i1] * fr
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bloom Reverb: reverse-reverb character
// Four taps at increasing delays with rising gain (soft-to-loud) creates a
// swell that builds over time, approximating the reverse-reverb effect.
// Alternating L/R panning of taps gives stereo width from a mono source.
// ─────────────────────────────────────────────────────────────────────────────
final class BloomReverbProcessor {
    private let bufSize = 65536
    private var buf: [Float]
    private var writePos = 0
    private var lfoPhase: Double = 0
    private var lpState:  Float  = 0
    private let tapSamples: [Float]
    private let tapGains: [Float] = [0.18, 0.32, 0.54, 0.78]
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        buf = Array(repeating: 0, count: 65536)
        tapSamples = [80, 180, 320, 530].map { $0 * Float(sampleRate) / 1000 }
    }

    // Returns the wet swell only — caller blends dry/wet to preserve prior stereo.
    func process(_ input: Float, amount: Float) -> (Float, Float) {
        guard amount > 0.005 else { return (0, 0) }
        lfoPhase += 0.19 / sampleRate
        if lfoPhase >= 1 { lfoPhase -= 1 }   // wrap to keep float precision over long sessions
        let lfoMod = Float(sin(lfoPhase * 2 * .pi)) * amount * 4

        var outL: Float = 0, outR: Float = 0
        for (i, (samples, gain)) in zip(tapSamples, tapGains).enumerated() {
            let mod = (i % 2 == 0) ? lfoMod : -lfoMod
            let tap = readAt(Float(writePos) - (samples + mod))
            if i % 2 == 0 { outL += tap * gain } else { outR += tap * gain }
        }

        let l = outL * 0.75 + outR * 0.25
        let r = outR * 0.75 + outL * 0.25

        lpState = lpState * 0.68 + (l + r) * 0.14 * amount
        buf[writePos & (bufSize - 1)] = input + lpState
        writePos = (writePos + 1) & (bufSize - 1)

        return (l * amount * 0.65, r * amount * 0.65)
    }

    private func readAt(_ pos: Float) -> Float {
        var p = pos; if p < 0 { p += Float(bufSize) }
        let i0 = Int(p) & (bufSize - 1)
        let i1 = (i0 + 1) & (bufSize - 1)
        let fr = p - p.rounded(.down)
        return buf[i0] * (1 - fr) + buf[i1] * fr
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Grit: asymmetric waveshaper (even harmonics, tube character)
// ─────────────────────────────────────────────────────────────────────────────
struct GritProcessor {
    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        let drive = 1 + amount * 14
        let x = input * drive
        let shaped: Float = x >= 0 ? x / (1 + x) : tanh(x * 1.4)
        return input + (shaped - input) * amount * 0.65
    }
}

// (DoublerProcessor replaced by BloomReverbProcessor above)

// ─────────────────────────────────────────────────────────────────────────────
// Broken Tape Delay: wow/flutter on delay time + random dropouts + tape sat
// ─────────────────────────────────────────────────────────────────────────────
final class BrokenTapeDelay {
    private var buf: [Float]
    private var writePos = 0
    private var wowPhase:     Double = 0
    private var flutterPhase: Double = 0
    private var lpState:  Float = 0
    private var dropGain: Float = 1
    private var dropTimer = 0
    private var rng: UInt32 = 77777
    private let sampleRate: Float
    private let maxSamples: Int

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        maxSamples = Int(sampleRate * 2.5) + 1
        buf = Array(repeating: 0, count: maxSamples)
    }

    func process(_ input: Float,
                 delayTime: Float,
                 feedback: Float,
                 mix: Float,
                 broken: Float) -> Float {
        guard mix > 0.005 else { return input }
        let base = Float(Int(delayTime * sampleRate))
        wowPhase     += 0.5 / Double(sampleRate)
        flutterPhase += 5.0 / Double(sampleRate)
        let wow  = Float(sin(wowPhase     * 2 * .pi)) * broken * 90
        let flut = Float(sin(flutterPhase * 2 * .pi)) * broken * 22
        let modS = max(4, min(base + wow + flut, Float(maxSamples - 1)))
        var rpos = Float(writePos) - modS
        if rpos < 0 { rpos += Float(maxSamples) }
        let r0 = Int(rpos) % maxSamples
        let r1 = (r0 + 1) % maxSamples
        let fr = rpos - rpos.rounded(.down)
        var delayed = buf[r0] * (1 - fr) + buf[r1] * fr
        // Dropout
        rng = rng &* 1664525 &+ 1013904223
        if broken > 0.1, rng % UInt32(sampleRate * 8) == 0 {
            dropGain = 0; dropTimer = Int(sampleRate * (0.03 + broken * 0.06))
        }
        if dropTimer > 0 {
            dropGain = min(dropGain + 1 / Float(dropTimer), 1)
            dropTimer -= 1
        }
        delayed *= dropGain
        let sat = tanh(delayed * (1 + broken * 2)) * feedback
        lpState = lpState * 0.72 + sat * 0.28
        buf[writePos % maxSamples] = input + lpState
        writePos = (writePos + 1) % maxSamples
        return input * (1 - mix) + delayed * mix
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modulation: tremolo (amplitude LFO) + chorus (LFO-modulated short delay)
// ─────────────────────────────────────────────────────────────────────────────
final class ModulationProcessor {
    private let sampleRate: Double
    private var tremPhase: Double = 0
    private let bufSize = 1024
    private var buf: [Float]
    private var writePos = 0
    private var chorusLfoPhase: Double = .random(in: 0...1)   // start at random phase per voice for richness

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.buf = Array(repeating: 0, count: 1024)
    }

    func process(l: Float, r: Float, tremDepth: Float, chorusMix: Float) -> (Float, Float) {
        var lOut = l, rOut = r
        let dt = 1.0 / sampleRate

        // Tremolo: ~4.8 Hz amplitude modulation, sine-shaped
        if tremDepth > 0.001 {
            let trem = 1.0 - Double(tremDepth) * (1.0 - cos(tremPhase * 2 * .pi)) * 0.5
            lOut *= Float(trem)
            rOut *= Float(trem)
            tremPhase += 4.8 * dt
            if tremPhase >= 1.0 { tremPhase -= 1.0 }
        }

        // Always advance the chorus buffer so the delay line has valid history
        // when chorusMix is raised mid-note (avoids a silence burst on onset).
        buf[writePos & (bufSize - 1)] = (lOut + rOut) * 0.5
        writePos = (writePos + 1) & (bufSize - 1)

        // Chorus: LFO-modulated short delay, opposite-phase L/R for stereo width
        if chorusMix > 0.001 {
            chorusLfoPhase += 0.65 * dt
            if chorusLfoPhase >= 1.0 { chorusLfoPhase -= 1.0 }
            let lfo = Float(sin(chorusLfoPhase * 2 * .pi))
            let baseDelay: Float = 14
            let modDepth: Float  = 9
            let chL = readDelay(baseDelay + lfo * modDepth)
            let chR = readDelay(baseDelay - lfo * modDepth)
            let mix = min(chorusMix, 1)
            lOut = lOut * (1 - mix * 0.5) + chL * mix
            rOut = rOut * (1 - mix * 0.5) + chR * mix
        }

        return (lOut, rOut)
    }

    private func readDelay(_ delay: Float) -> Float {
        var rp = Float(writePos) - delay - 1
        if rp < 0 { rp += Float(bufSize) }
        let i0 = Int(rp) & (bufSize - 1)
        let i1 = (i0 + 1) & (bufSize - 1)
        let fr = rp - rp.rounded(.down)
        return buf[i0] * (1 - fr) + buf[i1] * fr
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phaser: 4 first-order all-pass stages with LFO-swept center frequency.
// Feedback around the all-pass chain adds resonant notch depth.
// L and R use 180° offset LFO phases for stereo width.
// ─────────────────────────────────────────────────────────────────────────────
final class PhaserProcessor {
    private var lfoPhase: Double
    private let sampleRate: Float
    private var stateX: [Float] = [0, 0, 0, 0]
    private var stateY: [Float] = [0, 0, 0, 0]
    private var feedbackSample: Float = 0

    init(sampleRate: Double, lfoPhaseOffset: Double = 0) {
        self.sampleRate = Float(sampleRate)
        self.lfoPhase   = lfoPhaseOffset
    }

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        lfoPhase += 0.5 / Double(sampleRate)
        if lfoPhase >= 1.0 { lfoPhase -= 1.0 }

        let lfo = Float(0.5 + 0.5 * sin(lfoPhase * 2 * .pi))
        let fc  = 300.0 + lfo * 1700.0
        let w   = tanf(Float.pi * fc / sampleRate)
        let a   = (1.0 - w) / (1.0 + w)

        var x = input + feedbackSample * amount * 0.35
        for i in 0..<4 {
            let y = a * (x - stateY[i]) + stateX[i]
            stateX[i] = x; stateY[i] = y
            x = y
        }
        feedbackSample = x
        return input * (1.0 - amount * 0.5) + x * (amount * 0.5)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auto-Wah: envelope follower drives a resonant bandpass filter.
// Playing harder opens the filter higher — classic wah/funk character.
// ─────────────────────────────────────────────────────────────────────────────
final class AutoWahProcessor {
    private let sampleRate: Float
    private var envelope: Float = 0
    private var bq_x1: Float = 0, bq_x2: Float = 0
    private var bq_y1: Float = 0, bq_y2: Float = 0

    init(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }

        let absIn = abs(input)
        let atk = Float(1.0 / (0.005 * Double(sampleRate)))
        let rel = Float(1.0 / (0.12  * Double(sampleRate)))
        envelope = absIn > envelope
            ? envelope + (absIn - envelope) * atk
            : max(envelope - envelope * rel, 0)

        let fc = 250.0 + envelope * amount * 3750.0
        let q  = 2.5 + amount * 3.0
        let filtered = bandpass(input, cutoff: fc, q: q)
        return input * (1.0 - amount * 0.75) + filtered * amount * 0.75
    }

    private func bandpass(_ input: Float, cutoff: Float, q: Float) -> Float {
        let w0    = 2.0 * Float.pi * cutoff / sampleRate
        let sinW  = sinf(w0), cosW = cosf(w0)
        let alpha = sinW / (2.0 * q)
        let b0    =  sinW * 0.5
        let b2    = -sinW * 0.5
        let a0    =  1.0 + alpha
        let a1    = -2.0 * cosW
        let a2    =  1.0 - alpha
        let y = (b0/a0)*input + (b2/a0)*bq_x2
              - (a1/a0)*bq_y1 - (a2/a0)*bq_y2
        bq_x2 = bq_x1; bq_x1 = input
        bq_y2 = bq_y1; bq_y1 = y
        return y
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modulating Delay: delay line with LFO-swept read position.
// Creates analog-delay wobble — pitch gently warps in the feedback tail.
// L and R use slightly different LFO rates for natural stereo movement.
// ─────────────────────────────────────────────────────────────────────────────
final class ModulatingDelayProcessor {
    private let bufSize = 65536
    private var buf: [Float]
    private var writePos = 0
    private var lfoPhase: Double
    private var lpState:  Float  = 0
    private let sampleRate: Float
    private let lfoRate:    Double

    init(sampleRate: Double, lfoRate: Double = 0.35) {
        self.sampleRate = Float(sampleRate)
        self.lfoRate    = lfoRate
        self.lfoPhase   = Double.random(in: 0...1)
        buf = Array(repeating: 0, count: 65536)
    }

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        lfoPhase += lfoRate / Double(sampleRate)
        if lfoPhase >= 1.0 { lfoPhase -= 1.0 }
        let lfo = Float(sin(lfoPhase * 2 * .pi))

        let baseDelay = 0.27 * sampleRate
        let modDepth  = amount * 35.0 * sampleRate / 1000.0
        let delayTime = max(4, baseDelay + lfo * modDepth)

        var rpos = Float(writePos) - delayTime
        if rpos < 0 { rpos += Float(bufSize) }
        let i0 = Int(rpos) & (bufSize - 1)
        let i1 = (i0 + 1) & (bufSize - 1)
        let fr = rpos - rpos.rounded(.down)
        let delayed = buf[i0] * (1 - fr) + buf[i1] * fr

        lpState = lpState * 0.72 + delayed * 0.28
        buf[writePos & (bufSize - 1)] = input + lpState * 0.45 * amount
        writePos = (writePos + 1) & (bufSize - 1)
        return input * (1.0 - amount * 0.35) + delayed * amount * 0.80
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tube saturation: warm tanh-based overdrive (no harsh clipping)
// Slight asymmetric bias adds even-harmonic warmth like a class-A tube stage.
// ─────────────────────────────────────────────────────────────────────────────
@inline(__always)
func tubeSaturate(_ sample: Float, drive: Float) -> Float {
    guard drive > 0.001 else { return sample }
    let g           = 1.0 + Double(drive) * 6.0       // 1× → 7×
    let bias        = Double(drive) * 0.08            // small DC bias
    let normalize   = Float(tanh(g))
    let warmed      = tanh(Double(sample) * g + bias) - tanh(bias)
    let outputGain  = 1.0 - Double(drive) * 0.2       // gentle make-up volume drop
    return Float(warmed * outputGain) / normalize
}

