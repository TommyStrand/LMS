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
// Vinyl: wow/flutter + crackle
// ─────────────────────────────────────────────────────────────────────────────
final class VinylProcessor {
    private let bufSize = 8192
    private var buf: [Float]
    private var writePos = 0
    private var wowPhase:     Double = 0
    private var flutterPhase: Double = 0
    private var rng: UInt32 = 54321
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        buf = Array(repeating: 0, count: 8192)
    }

    func process(_ input: Float, amount: Float) -> Float {
        guard amount > 0.005 else { return input }
        buf[writePos & (bufSize - 1)] = input
        wowPhase     += 0.30 / sampleRate
        flutterPhase += 4.20 / sampleRate
        let wow     = sin(wowPhase     * 2 * .pi) * Double(amount) * 32
        let flutter = sin(flutterPhase * 2 * .pi) * Double(amount) *  9
        var rpos    = Float(writePos) - Float(120 + wow + flutter)
        if rpos < 0 { rpos += Float(bufSize) }
        let r0 = Int(rpos) & (bufSize - 1)
        let r1 = (r0 + 1)  & (bufSize - 1)
        let fr = rpos - rpos.rounded(.down)
        var out = buf[r0] * (1 - fr) + buf[r1] * fr
        writePos = (writePos + 1) & (bufSize - 1)
        // Crackle
        rng = rng &* 1664525 &+ 1013904223
        let n = Float(Int32(bitPattern: rng)) / Float(Int32.max)
        if abs(n) > 1 - amount * 0.004 { out += n * 0.22 }
        return out
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

// ─────────────────────────────────────────────────────────────────────────────
// Doubler: two detuned + delayed copies, hard-panned L/R (NeuralDSP style)
// ─────────────────────────────────────────────────────────────────────────────
final class DoublerProcessor {
    private let bufSize = 8192
    private var bufA: [Float]
    private var bufB: [Float]
    private var writePos = 0
    private var lfoA: Float = 0
    private var lfoB: Float = 0.25
    private let sampleRate: Float

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        bufA = Array(repeating: 0, count: 8192)
        bufB = Array(repeating: 0, count: 8192)
    }

    func process(_ input: Float, amount: Float) -> (Float, Float) {
        guard amount > 0.005 else { return (input, input) }
        bufA[writePos & (bufSize - 1)] = input
        bufB[writePos & (bufSize - 1)] = input
        let dt = 1 / sampleRate
        lfoA += 0.20 * dt
        lfoB += 0.23 * dt
        let mod = amount * 8
        let dA = sampleRate * 0.012 + sin(lfoA * 2 * .pi) * mod
        let dB = sampleRate * 0.018 + sin(lfoB * 2 * .pi) * mod

        func read(_ buf: [Float], _ delay: Float) -> Float {
            var rp = Float(writePos) - delay
            if rp < 0 { rp += Float(bufSize) }
            let i0 = Int(rp) & (bufSize - 1)
            let i1 = (i0 + 1) & (bufSize - 1)
            let fr = rp - rp.rounded(.down)
            return buf[i0] * (1 - fr) + buf[i1] * fr
        }

        writePos = (writePos + 1) & (bufSize - 1)
        let dry = 1 - amount * 0.35
        return (input * dry + read(bufA, dA) * amount,
                input * dry + read(bufB, dB) * amount)
    }
}

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
