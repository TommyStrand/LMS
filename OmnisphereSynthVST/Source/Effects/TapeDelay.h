#pragma once
#include <cmath>
#include <cstdint>
#include <vector>
#include <limits>

// Broken-tape delay: wow/flutter + random dropouts + tape saturation + HF bleed.
class TapeDelay
{
public:
    void prepare (double sampleRate, int /*blockSize*/)
    {
        sr = float (sampleRate);
        buf.assign (int (sr * 2.5f) + 1, 0.0f);   // 2.5 s max
        writePos     = 0;
        wowPhase     = 0.0f;
        flutterPhase = 0.0f;
        dropGain     = 1.0f;
        dropTimer    = 0;
        lpState      = 0.0f;
    }

    // delayTime seconds, feedback 0-1, mix 0-1, brokenAmount 0-1
    float process (float in, float delayTime, float feedback, float mix, float broken)
    {
        if (mix < 0.005f) return in;

        const int maxSamp  = int (buf.size()) - 1;
        const int baseSamp = int (delayTime * sr);

        // Wow ~0.5 Hz, flutter ~5 Hz
        wowPhase     += 0.5f / sr;
        flutterPhase += 5.0f / sr;
        const float wow  = std::sin (wowPhase     * 6.2832f) * broken * 90.0f;
        const float flut = std::sin (flutterPhase * 6.2832f) * broken * 22.0f;

        float modSamp = float (baseSamp) + wow + flut;
        modSamp = std::max (4.0f, std::min (modSamp, float (maxSamp)));

        // Interpolated read
        float rpos = float (writePos) - modSamp;
        if (rpos < 0) rpos += float (buf.size());
        const int   r0   = int (rpos) % int (buf.size());
        const int   r1   = (r0 + 1)  % int (buf.size());
        const float frac = rpos - std::floor (rpos);
        float delayed = buf[r0] * (1.0f - frac) + buf[r1] * frac;

        // Random dropout (tape tear)
        rng = rng * 1664525u + 1013904223u;
        if (broken > 0.1f && (rng % int (sr * 8.0f) == 0)) {
            dropGain  = 0.0f;
            dropTimer = int (sr * (0.03f + broken * 0.06f));
        }
        if (dropTimer > 0) {
            dropGain += 1.0f / float (dropTimer);
            dropGain  = std::min (dropGain, 1.0f);
            --dropTimer;
        }
        delayed *= dropGain;

        // Tape saturation on feedback
        const float sat   = std::tanh (delayed * (1.0f + broken * 2.0f)) * feedback;

        // HF rolloff bleed on feedback (1-pole LP, fc ~4 kHz)
        lpState = lpState * 0.72f + sat * 0.28f;

        buf[writePos % int (buf.size())] = in + lpState;
        writePos = (writePos + 1) % int (buf.size());

        return in * (1.0f - mix) + delayed * mix;
    }

private:
    std::vector<float> buf;
    int      writePos    = 0;
    float    sr          = 44100.0f;
    float    wowPhase    = 0.0f;
    float    flutterPhase= 0.0f;
    float    lpState     = 0.0f;
    float    dropGain    = 1.0f;
    int      dropTimer   = 0;
    uint32_t rng         = 77777u;
};
