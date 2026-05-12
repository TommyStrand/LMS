#pragma once
#include <cmath>
#include <array>

// Rotary-speaker (Leslie) simulator.
// Treble horn: ~0.7 Hz slow / ~6.7 Hz fast, with Doppler (delay modulation) + AM.
// Outputs stereo from a mono input.
class LeslieEffect
{
public:
    static constexpr int kBuf = 4096;

    void prepare (double sampleRate) { sr = float (sampleRate); }

    void reset()
    {
        buf.fill (0.0f);
        writePos  = 0;
        hornPhase = 0.0f;
        curSpeed  = 0.7f;
        tgtSpeed  = 0.7f;
    }

    // true = fast (tremolo), false = slow (chorale)
    void setFast (bool fast) { tgtSpeed = fast ? 6.7f : 0.7f; }

    struct Out { float L, R; };

    Out process (float in, float dt)
    {
        // Smooth speed change (~1.5 s ramp)
        curSpeed += (tgtSpeed - curSpeed) * std::min (dt * 1.5f, 1.0f);

        hornPhase += curSpeed * dt;
        if (hornPhase >= 1.0f) hornPhase -= 1.0f;

        buf[writePos & (kBuf - 1)] = in;

        const float angle = hornPhase * 6.2832f;

        // Doppler: read head moves ±8 samples as horn rotates
        const float dA = 8.0f * (1.0f + std::sin (angle));
        const float dB = 8.0f * (1.0f + std::cos (angle));

        auto readAt = [&](float delay) -> float
        {
            float rp = float (writePos) - delay - 1.0f;
            if (rp < 0) rp += kBuf;
            const int   i0 = int (rp) & (kBuf - 1);
            const int   i1 = (i0 + 1) & (kBuf - 1);
            const float fr = rp - std::floor (rp);
            return buf[i0] * (1.0f - fr) + buf[i1] * fr;
        };

        // AM (amplitude shimmer from rotor)
        const float amL = 0.72f + 0.28f * std::sin (angle);
        const float amR = 0.72f + 0.28f * std::cos (angle);

        ++writePos;
        return { readAt (dA) * amL, readAt (dB) * amR };
    }

private:
    std::array<float, kBuf> buf {};
    int   writePos = 0;
    float hornPhase = 0.0f;
    float curSpeed  = 0.7f;
    float tgtSpeed  = 0.7f;
    float sr        = 44100.0f;
};
