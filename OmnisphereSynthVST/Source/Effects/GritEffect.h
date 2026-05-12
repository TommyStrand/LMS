#pragma once
#include <cmath>

// Asymmetric waveshaper — adds even harmonics (tube/tape character).
// amount 0-1.
class GritEffect
{
public:
    float process (float in, float amount)
    {
        if (amount < 0.005f) return in;

        const float drive = 1.0f + amount * 14.0f;
        const float x     = in * drive;

        // Asymmetric: positive half = smooth saturation, negative = slightly harder
        const float shaped = (x >= 0.0f) ? x / (1.0f + x)
                                          : std::tanh (x * 1.4f);

        // Blend wet/dry and compensate for loudness
        return in + (shaped - in) * amount * 0.65f;
    }
};
