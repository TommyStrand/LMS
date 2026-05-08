#include "OmniVoice.h"
#include <cmath>

// Church organ drawbar configuration
const double OmniVoice::kRatios[kNumPartials]  = { 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0 };
const float  OmniVoice::kLevels[kNumPartials]  = { 0.55f, 1.0f, 0.7f, 0.8f, 0.5f, 0.35f, 0.15f, 0.1f, 0.05f };
const double OmniVoice::kDetunes[kNumPartials] = { 0.0, 0.0, 1.2, -0.8, 0.5, -1.1, 0.9, -0.6, 0.3 };

// ─────────────────────────────────────────────────────────────────────────────

bool OmniVoice::canPlaySound (juce::SynthesiserSound* s)
{
    return dynamic_cast<OmniSound*> (s) != nullptr;
}

void OmniVoice::startNote (int midiNote, float velocity,
                            juce::SynthesiserSound*, int pitchWheelPos)
{
    noteFreq = float (440.0 * std::pow (2.0, (midiNote - 69) / 12.0));
    noteVelocity = velocity;
    pitchBendSemitones = (pitchWheelPos - 8192) / 8192.0f * 2.0f;

    phase1 = phase2 = lfoPhase = tremPhase = 0.0;
    for (auto& ph : organPhases) ph = 0.0;
    bq_x1 = bq_x2 = bq_y1 = bq_y2 = 0.0;

    clickSamplesLeft = int (getSampleRate() * 0.012);  // 12 ms click
    noiseState = 98765;

    envStage = Stage::Attack;
    envValue = 0.0;
}

void OmniVoice::stopNote (float, bool allowTailOff)
{
    if (allowTailOff)
        envStage = Stage::Release;
    else {
        envStage = Stage::Idle;
        envValue = 0.0;
        clearCurrentNote();
    }
}

void OmniVoice::pitchWheelMoved (int newValue)
{
    pitchBendSemitones = (newValue - 8192) / 8192.0f * 2.0f;
}

void OmniVoice::renderNextBlock (juce::AudioBuffer<float>& buffer,
                                  int startSample, int numSamples)
{
    if (envStage == Stage::Idle)
        return;

    const double sr  = getSampleRate();
    const double dt  = 1.0 / sr;
    const float  xMod = xyX ? xyX->load() : 0.5f;
    const float  yMod = xyY ? xyY->load() : 0.5f;

    auto* left  = buffer.getWritePointer (0, startSample);
    auto* right = buffer.getNumChannels() > 1
                ? buffer.getWritePointer (1, startSample)
                : nullptr;

    for (int i = 0; i < numSamples; ++i)
    {
        double s = preset.isOrgan ? organSample (dt, xMod, yMod)
                                  : synthSample (dt, xMod, yMod);

        left[i] += float (s);
        if (right) right[i] += float (s);

        if (envStage == Stage::Idle) {
            clearCurrentNote();
            break;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Synth mode: dual oscillator + biquad LPF + ADSR + LFO
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::synthSample (double dt, float xMod, float yMod)
{
    // LFO
    lfoPhase += preset.lfoRate * dt;
    if (lfoPhase > 1.0) lfoPhase -= 1.0;
    const double lfoVal = std::sin (lfoPhase * 2.0 * M_PI)
                        * double (preset.lfoDepth * yMod * 2.0f);

    // Frequencies with pitch bend + LFO
    const double bendFactor = std::pow (2.0, double (pitchBendSemitones) / 12.0);
    double f1 = double (noteFreq) * bendFactor;
    double f2 = f1 * std::pow (2.0, double (preset.osc2Detune) / 12.0);
    if (preset.lfoTarget == LFOTarget::Pitch) {
        f1 *= std::pow (2.0, lfoVal / 12.0);
        f2 *= std::pow (2.0, lfoVal / 12.0);
    }

    // Oscillators
    phase1 = std::fmod (phase1 + f1 * dt, 1.0);
    phase2 = std::fmod (phase2 + f2 * dt, 1.0);

    double raw = waveform (phase1, preset.osc1Wave) * double (1.0f - preset.oscMix)
               + waveform (phase2, preset.osc2Wave) * double (preset.oscMix);

    // Envelope
    const double env = advanceEnv (dt);
    raw *= (preset.lfoTarget == LFOTarget::Amplitude)
         ? env * (1.0 + lfoVal * 0.5)
         : env;

    // Filter — X-pad maps 0→1 to 0.1→1.9 of base cutoff
    double cutoff = double (preset.filterCutoff) * double (xMod * 1.8f + 0.1f);
    if (preset.lfoTarget == LFOTarget::Filter)
        cutoff *= std::pow (2.0, lfoVal);
    cutoff = juce::jlimit (30.0, 18000.0, cutoff);

    raw = biquadLP (raw, cutoff, double (preset.filterResonance));

    return raw * double (noteVelocity) * 0.4;
}

// ─────────────────────────────────────────────────────────────────────────────
// Organ mode: 9-partial additive + tremulant + key click
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::organSample (double dt, float /*xMod*/, float yMod)
{
    // Tremulant (~5.5 Hz)
    tremPhase += 5.5 * dt;
    if (tremPhase > 1.0) tremPhase -= 1.0;
    const double tremDepth = double (preset.tremulantDepth * yMod * 2.0f);
    const double tremVal   = std::sin (tremPhase * 2.0 * M_PI) * tremDepth * 0.04;

    // Key click
    double click = 0.0;
    if (clickSamplesLeft > 0) {
        noiseState = noiseState * 1664525u + 1013904223u;
        const double n = double (int32_t (noiseState)) / double (std::numeric_limits<int32_t>::max());
        click = n * (double (clickSamplesLeft) / (getSampleRate() * 0.012)) * 0.06;
        --clickSamplesLeft;
    }

    // Additive synthesis
    double sum = 0.0;
    const double bendFactor = std::pow (2.0, double (pitchBendSemitones) / 12.0);
    for (int k = 0; k < kNumPartials; ++k) {
        const double detuneFactor = std::pow (2.0, kDetunes[k] / 1200.0);
        const double f = double (noteFreq) * bendFactor * kRatios[k] * detuneFactor
                       * (1.0 + tremVal * 0.3);
        organPhases[k] = std::fmod (organPhases[k] + f * dt, 1.0);
        sum += std::sin (organPhases[k] * 2.0 * M_PI) * double (kLevels[k]);
    }

    // Normalise by total drawbar level
    static const float kTotalLevel = []{ float t = 0; for (auto v : kLevels) t += v; return t; }();
    sum /= double (kTotalLevel);
    sum *= (1.0 + tremVal);

    const double env = advanceEnv (dt);
    return (sum + click) * env * double (noteVelocity) * 0.5;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared DSP helpers
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::advanceEnv (double dt)
{
    const auto& p = preset;
    switch (envStage)
    {
        case Stage::Idle:    return 0.0;
        case Stage::Attack: {
            const double rate = p.attack > 0 ? 1.0 / double (p.attack) : 1000.0;
            envValue = juce::jmin (envValue + rate * dt, 1.0);
            if (envValue >= 1.0) envStage = Stage::Decay;
            break;
        }
        case Stage::Decay: {
            const double target = double (p.sustain);
            const double rate   = p.decay > 0 ? (1.0 - target) / double (p.decay) : 1000.0;
            envValue = juce::jmax (envValue - rate * dt, target);
            if (envValue <= target) envStage = Stage::Sustain;
            break;
        }
        case Stage::Sustain:
            envValue = double (p.sustain);
            break;
        case Stage::Release: {
            const double rate = p.release > 0 ? envValue / double (p.release) : 1000.0;
            envValue = juce::jmax (envValue - rate * dt, 0.0);
            if (envValue < 0.0001) { envStage = Stage::Idle; envValue = 0.0; }
            break;
        }
    }
    return envValue;
}

double OmniVoice::biquadLP (double input, double cutoff, double resonance)
{
    const double w0    = 2.0 * M_PI * cutoff / getSampleRate();
    const double cosW  = std::cos (w0);
    const double sinW  = std::sin (w0);
    const double q     = juce::jmax (0.5, 1.0 / (1.0 - double (resonance) * 0.95));
    const double alpha = sinW / (2.0 * q);

    const double b0 = (1.0 - cosW) * 0.5;
    const double b1 = 1.0 - cosW;
    const double b2 = (1.0 - cosW) * 0.5;
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * cosW;
    const double a2 = 1.0 - alpha;

    const double y = (b0 / a0) * input  + (b1 / a0) * bq_x1 + (b2 / a0) * bq_x2
                   - (a1 / a0) * bq_y1  - (a2 / a0) * bq_y2;

    bq_x2 = bq_x1;  bq_x1 = input;
    bq_y2 = bq_y1;  bq_y1 = y;
    return y;
}

double OmniVoice::waveform (double phase, Waveform w)
{
    switch (w) {
        case Waveform::Sine:
            return std::sin (phase * 2.0 * M_PI);
        case Waveform::Triangle:
            return phase < 0.5 ? 4.0 * phase - 1.0 : 3.0 - 4.0 * phase;
        case Waveform::Sawtooth:
            return 2.0 * phase - 1.0;
        case Waveform::Square:
            return phase < 0.5 ? 1.0 : -1.0;
        case Waveform::Noise: {
            noiseState = noiseState * 1664525u + 1013904223u;
            return double (int32_t (noiseState)) / double (std::numeric_limits<int32_t>::max());
        }
    }
    return 0.0;
}
