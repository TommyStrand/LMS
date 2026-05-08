#pragma once
#include <cmath>
#include <array>

// Stereo doubler — two slightly detuned + delayed copies panned L/R.
// Similar to NeuralDSP doubler: thickens single notes with stereo width.
class DoublerEffect
{
public:
    static constexpr int kBuf = 8192;

    void prepare (double sampleRate) { sr = float (sampleRate); }

    void reset()
    {
        bufA.fill (0.0f); bufB.fill (0.0f);
        writePos = 0;
        lfoA = 0.0f; lfoB = 0.25f;   // 90° offset
    }

    struct Out { float L, R; };

    // in: mono or average of stereo input, amount 0-1, dt = 1/sampleRate
    Out process (float in, float amount, float dt)
    {
        if (amount < 0.005f) return { in, in };

        bufA[writePos & (kBuf - 1)] = in;
        bufB[writePos & (kBuf - 1)] = in;

        // Two slow LFOs (~0.2 Hz, slightly different rates)
        lfoA += 0.20f * dt;
        lfoB += 0.23f * dt;

        // Base delay 12 ms / 18 ms; LFO adds ±8 samples of modulation
        const float modDepth = amount * 8.0f;
        const float delA = sr * 0.012f + std::sin (lfoA * 6.2832f) * modDepth;
        const float delB = sr * 0.018f + std::sin (lfoB * 6.2832f) * modDepth;

        auto read = [&](std::array<float, kBuf>& b, float delay) -> float
        {
            float rp = float (writePos) - delay;
            if (rp < 0) rp += kBuf;
            const int   i0 = int (rp) & (kBuf - 1);
            const int   i1 = (i0 + 1) & (kBuf - 1);
            const float fr = rp - std::floor (rp);
            return b[i0] * (1.0f - fr) + b[i1] * fr;
        };

        const float voiceL = read (bufA, delA);
        const float voiceR = read (bufB, delB);

        ++writePos;

        // Amount 0: dry, 1: wide stereo
        const float dry = 1.0f - amount * 0.35f;
        return { in * dry + voiceL * amount,
                 in * dry + voiceR * amount };
    }

private:
    std::array<float, kBuf> bufA{}, bufB{};
    int   writePos = 0;
    float lfoA = 0.0f, lfoB = 0.25f;
    float sr   = 44100.0f;
};
