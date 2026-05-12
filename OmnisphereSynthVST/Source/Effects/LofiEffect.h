#pragma once
#include <cmath>
#include <cstdint>

// Bit-depth + sample-rate reducer.  amount 0-1.
class LofiEffect
{
public:
    void reset() { counter = 0; held = 0.0f; }

    float process (float in, float amount)
    {
        if (amount < 0.005f) return in;

        // Sample-rate reduction (1× to 16× decimation)
        const int div = 1 + int (amount * 15.0f);
        if (++counter >= div) { counter = 0; held = in; }

        // Bit-depth crush  (16 → 4 bits)
        const float bits  = 16.0f - amount * 12.0f;
        const float steps = std::pow (2.0f, bits) - 1.0f;
        return std::round (held * steps) / steps;
    }

private:
    int   counter = 0;
    float held    = 0.0f;
};
