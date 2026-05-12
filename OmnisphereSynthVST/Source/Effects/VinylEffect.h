#pragma once
#include <cmath>
#include <cstdint>
#include <array>
#include <limits>

// Vinyl wow/flutter + crackle.  Call prepare() once, then process() per-sample.
class VinylEffect
{
public:
    static constexpr int kBuf = 8192;

    void prepare (double sampleRate) { sr = float (sampleRate); }

    void reset()
    {
        buf.fill (0.0f);
        writePos = 0;
        wowPhase = flutterPhase = 0.0f;
    }

    float process (float in, float amount)
    {
        if (amount < 0.005f) return in;

        buf[writePos & (kBuf - 1)] = in;

        // Wow ~0.3 Hz, Flutter ~4.2 Hz
        wowPhase     += 0.30f / sr;
        flutterPhase += 4.20f / sr;

        const float wow     = std::sin (wowPhase     * 6.2832f) * amount * 32.0f;
        const float flutter = std::sin (flutterPhase * 6.2832f) * amount *  9.0f;
        const float offset  = 120.0f + wow + flutter;

        float rpos = float (writePos) - offset;
        if (rpos < 0) rpos += kBuf;

        const int   r0   = int (rpos)       & (kBuf - 1);
        const int   r1   = (r0 + 1)         & (kBuf - 1);
        const float frac = rpos - std::floor (rpos);
        float out = buf[r0] * (1.0f - frac) + buf[r1] * frac;

        ++writePos;

        // Crackle
        rng = rng * 1664525u + 1013904223u;
        const float n = float (int32_t (rng)) / float (std::numeric_limits<int32_t>::max());
        if (std::abs (n) > 1.0f - amount * 0.004f)
            out += n * 0.22f;

        return out;
    }

private:
    std::array<float, kBuf> buf {};
    int      writePos    = 0;
    float    wowPhase    = 0.0f;
    float    flutterPhase= 0.0f;
    float    sr          = 44100.0f;
    uint32_t rng         = 54321u;
};
