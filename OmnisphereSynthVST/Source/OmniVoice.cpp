#include "OmniVoice.h"
#include <cmath>
#include <limits>

// ── Drawbar ratios (footage) ──────────────────────────────────────────────────
//        16'  8'   5⅓'  4'   2⅔' 2'   1⅗' 1⅓' 1'
const double OmniVoice::kRatios[kNP]    = {0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0};
// Church pipe organ (principal chorus, heavy fundamentals)
const float  OmniVoice::kChurchLvl[kNP] = {0.55f,1.0f,0.7f,0.8f,0.5f,0.35f,0.15f,0.1f,0.05f};
// Hammond B3 "888000000" — full 16', 8', and quint
const float  OmniVoice::kHammondLvl[kNP]= {0.8f,0.8f,0.8f,0.0f,0.0f,0.0f,0.0f,0.0f,0.0f};
// Per-partial micro-detuning (cents) for tonewheel leakage warmth
const double OmniVoice::kDetunes[kNP]   = {0.0, 0.0, 1.2,-0.8, 0.5,-1.1, 0.9,-0.6, 0.3};

// ─────────────────────────────────────────────────────────────────────────────

OmniVoice::OmniVoice()
{
    leslie.prepare (44100.0);
}

bool OmniVoice::canPlaySound (juce::SynthesiserSound* s)
{
    return dynamic_cast<OmniSound*> (s) != nullptr;
}

void OmniVoice::startNote (int midiNote, float velocity,
                             juce::SynthesiserSound*, int pitchWheelPos)
{
    noteFreq     = float (440.0 * std::pow (2.0, (midiNote - 69) / 12.0));
    noteVelocity = velocity;
    pitchBendST  = (pitchWheelPos - 8192) / 8192.0f * 2.0f;

    phase1 = phase2 = lfoPhase = tremPhase = 0.0;
    for (auto& ph : organPhases) ph = 0.0;
    bq_x1 = bq_x2 = bq_y1 = bq_y2 = 0.0;

    clickLeft   = int (getSampleRate() * 0.012);  // 12 ms click
    noiseState  = 98765;

    // Hammond percussion: 2nd harmonic, fast decay
    percPhase = 0.0;
    percEnv   = 1.0;

    // Rhodes: carrier + modulator from scratch, velocity sets FM index
    rhCarPhase = rhModPhase = 0.0;
    rhDecayEnv  = 1.0;
    rhDecayTime = 1.2 + double (velocity) * 1.5;   // 1.2–2.7 s

    envStage = Stage::Attack;
    envValue = 0.0;
}

void OmniVoice::stopNote (float, bool allowTailOff)
{
    if (allowTailOff) envStage = Stage::Release;
    else { envStage = Stage::Idle; envValue = 0.0; clearCurrentNote(); }
}

void OmniVoice::pitchWheelMoved (int v) { pitchBendST = (v - 8192) / 8192.0f * 2.0f; }

// MIDI CC routing — delegates to atomic pointers so the audio thread reads safely
void OmniVoice::controllerMoved (int cc, int value)
{
    const float v = float (value) / 127.0f;
    if (cc == 1  && modWheelPtr)   modWheelPtr->store (v);
    if (cc == 11 && expressionPtr) expressionPtr->store (v);
    if (cc == 3  && leslieSpeedPtr) {
        leslieSpeedPtr->store (v > 0.5f ? 1.0f : 0.0f);
        leslie.setFast (v > 0.5f);
    }
}

void OmniVoice::renderNextBlock (juce::AudioBuffer<float>& buf,
                                   int startSample, int numSamples)
{
    if (envStage == Stage::Idle) return;

    const double sr   = getSampleRate();
    const double dt   = 1.0 / sr;
    const float xMod  = xyX          ? xyX->load()           : 0.5f;
    const float yMod  = xyY          ? xyY->load()           : 0.5f;
    const float mod   = modWheelPtr  ? modWheelPtr->load()   : 0.0f;
    const float expr  = expressionPtr? expressionPtr->load()  : 1.0f;

    // Leslie speed from mod wheel for Hammond
    if (leslieSpeedPtr && preset.voiceMode == VoiceMode::HammondB3)
        leslie.setFast (leslieSpeedPtr->load() > 0.5f);

    const bool stereo = buf.getNumChannels() >= 2;
    auto* left  = buf.getWritePointer (0, startSample);
    auto* right = stereo ? buf.getWritePointer (1, startSample) : nullptr;

    for (int i = 0; i < numSamples; ++i)
    {
        double s = 0.0;
        float outL, outR;

        switch (preset.voiceMode)
        {
            case VoiceMode::HammondB3: {
                s = hammondSample (dt, yMod) * double (expr);
                auto lr = leslie.process (float (s), float (dt));
                outL = lr.L;  outR = lr.R;
                break;
            }
            case VoiceMode::OrganChurch:
                s = organSample (dt, yMod) * double (expr);
                outL = outR = float (s);
                break;
            case VoiceMode::Rhodes:
                s = rhodesSample (dt) * double (expr);
                outL = outR = float (s);
                break;
            default:
                s = synthSample (dt, xMod, yMod, mod, expr);
                outL = outR = float (s);
                break;
        }

        left[i] += outL;
        if (right) right[i] += outR;

        if (envStage == Stage::Idle) { clearCurrentNote(); break; }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Synth mode: dual oscillator + biquad LPF + ADSR + LFO
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::synthSample (double dt, float xMod, float yMod, float mod, float expr)
{
    lfoPhase += preset.lfoRate * dt;
    if (lfoPhase > 1.0) lfoPhase -= 1.0;
    // Mod wheel adds to LFO depth (capped at 1)
    const double lfoDpth = std::min (1.0, double (preset.lfoDepth * yMod * 2.0f + mod * 0.4f));
    const double lfoVal  = std::sin (lfoPhase * 6.2832) * lfoDpth;

    const double bend = std::pow (2.0, double (pitchBendST) / 12.0);
    double f1 = double (noteFreq) * bend;
    double f2 = f1 * std::pow (2.0, double (preset.osc2Detune) / 12.0);
    if (preset.lfoTarget == LFOTarget::Pitch) {
        f1 *= std::pow (2.0, lfoVal / 12.0);
        f2 *= std::pow (2.0, lfoVal / 12.0);
    }

    phase1 = std::fmod (phase1 + f1 * dt, 1.0);
    phase2 = std::fmod (phase2 + f2 * dt, 1.0);

    double raw = waveform (phase1, preset.osc1Wave) * double (1.0f - preset.oscMix)
               + waveform (phase2, preset.osc2Wave) * double (preset.oscMix);

    const double env = advanceEnv (dt);
    raw *= (preset.lfoTarget == LFOTarget::Amplitude) ? env * (1.0 + lfoVal * 0.5) : env;

    double cutoff = double (preset.filterCutoff) * double (xMod * 1.8f + 0.1f);
    if (preset.lfoTarget == LFOTarget::Filter) cutoff *= std::pow (2.0, lfoVal);
    cutoff = juce::jlimit (30.0, 18000.0, cutoff);

    return biquadLP (raw, cutoff, double (preset.filterResonance))
           * double (noteVelocity) * double (expr) * 0.4;
}

// ─────────────────────────────────────────────────────────────────────────────
// Church organ: 9-partial additive + tremulant + key click
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::organSample (double dt, float yMod)
{
    tremPhase += 5.5 * dt;
    if (tremPhase > 1.0) tremPhase -= 1.0;
    const double tremD = double (preset.tremulantDepth * yMod * 2.0f);
    const double trem  = std::sin (tremPhase * 6.2832) * tremD * 0.04;

    double click = 0.0;
    if (clickLeft > 0) {
        noiseState = noiseState * 1664525u + 1013904223u;
        const double n = double (int32_t (noiseState)) / double (std::numeric_limits<int32_t>::max());
        click = n * (double (clickLeft) / (getSampleRate() * 0.012)) * 0.06;
        --clickLeft;
    }

    const double bend = std::pow (2.0, double (pitchBendST) / 12.0);
    double sum = 0.0;
    for (int k = 0; k < kNP; ++k) {
        const double f = double (noteFreq) * bend * kRatios[k]
                       * std::pow (2.0, kDetunes[k] / 1200.0)
                       * (1.0 + trem * 0.3);
        organPhases[k] = std::fmod (organPhases[k] + f * dt, 1.0);
        sum += std::sin (organPhases[k] * 6.2832) * double (kChurchLvl[k]);
    }

    static const float kTotalCh = [] { float t = 0; for (auto v : kChurchLvl) t += v; return t; }();
    sum /= double (kTotalCh);
    sum *= (1.0 + trem);

    return (sum + click) * advanceEnv (dt) * double (noteVelocity) * 0.5;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hammond B3: 9-partial additive, 888 registration, percussion, → Leslie
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::hammondSample (double dt, float /*yMod*/)
{
    const double bend = std::pow (2.0, double (pitchBendST) / 12.0);
    double sum = 0.0;
    for (int k = 0; k < kNP; ++k) {
        const double f = double (noteFreq) * bend * kRatios[k]
                       * std::pow (2.0, kDetunes[k] / 1200.0);
        organPhases[k] = std::fmod (organPhases[k] + f * dt, 1.0);
        sum += std::sin (organPhases[k] * 6.2832) * double (kHammondLvl[k]);
    }

    static const float kTotalH = [] { float t = 0; for (auto v : kHammondLvl) t += v; return t; }();
    sum /= double (kTotalH);

    // Percussion: 2nd harmonic, decays in ~40 ms
    percPhase = std::fmod (percPhase + double (noteFreq) * 2.0 * bend * dt, 1.0);
    percEnv   = std::max (0.0, percEnv - dt / 0.04);
    sum += std::sin (percPhase * 6.2832) * percEnv * 0.35;

    // Key click
    double click = 0.0;
    if (clickLeft > 0) {
        noiseState = noiseState * 1664525u + 1013904223u;
        const double n = double (int32_t (noiseState)) / double (std::numeric_limits<int32_t>::max());
        click = n * (double (clickLeft) / (getSampleRate() * 0.012)) * 0.07;
        --clickLeft;
    }

    return (sum + click) * advanceEnv (dt) * double (noteVelocity) * 0.55;
}

// ─────────────────────────────────────────────────────────────────────────────
// Rhodes Mk1: 2-operator FM + natural decay
// Modulator index is velocity-sensitive (bright attack → sine-like sustain)
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::rhodesSample (double dt)
{
    const double bend = std::pow (2.0, double (pitchBendST) / 12.0);
    const double f    = double (noteFreq) * bend;

    // Natural exponential decay (not key-gated — decays even while held)
    rhDecayEnv = std::max (0.0, rhDecayEnv - dt / rhDecayTime);

    // FM: modulator freq ≈ carrier (slight inharmonicity +0.5 Hz gives warmth)
    rhModPhase = std::fmod (rhModPhase + (f + 0.5) * dt, 1.0);
    const double modIndex = double (noteVelocity) * 1.6 * rhDecayEnv;
    const double modSig   = std::sin (rhModPhase * 6.2832) * modIndex;

    rhCarPhase = std::fmod (rhCarPhase + f * dt, 1.0);
    double out = std::sin (rhCarPhase * 6.2832 + modSig);

    // Key-gated envelope (governs the sustain/release response)
    const double env = advanceEnv (dt);

    // If natural decay finishes while key held, idle the voice
    if (rhDecayEnv < 0.0001 && envStage == Stage::Sustain) {
        envStage = Stage::Release;
    }

    return out * env * rhDecayEnv * double (noteVelocity) * 0.45;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────
double OmniVoice::advanceEnv (double dt)
{
    switch (envStage) {
        case Stage::Idle: return 0.0;
        case Stage::Attack: {
            const double r = preset.attack > 0 ? 1.0 / double (preset.attack) : 1000.0;
            envValue = juce::jmin (envValue + r * dt, 1.0);
            if (envValue >= 1.0) envStage = Stage::Decay;
            break;
        }
        case Stage::Decay: {
            const double t = double (preset.sustain);
            const double r = preset.decay > 0 ? (1.0 - t) / double (preset.decay) : 1000.0;
            envValue = juce::jmax (envValue - r * dt, t);
            if (envValue <= t) envStage = Stage::Sustain;
            break;
        }
        case Stage::Sustain:
            envValue = double (preset.sustain);
            break;
        case Stage::Release: {
            const double r = preset.release > 0 ? envValue / double (preset.release) : 1000.0;
            envValue = juce::jmax (envValue - r * dt, 0.0);
            if (envValue < 0.0001) { envStage = Stage::Idle; envValue = 0.0; }
            break;
        }
    }
    return envValue;
}

double OmniVoice::biquadLP (double input, double cutoff, double resonance)
{
    const double w0    = 6.2832 * cutoff / getSampleRate();
    const double cosW  = std::cos (w0);
    const double sinW  = std::sin (w0);
    const double q     = juce::jmax (0.5, 1.0 / (1.0 - double (resonance) * 0.95));
    const double alpha = sinW / (2.0 * q);
    const double b0 = (1.0 - cosW) * 0.5, b1 = 1.0 - cosW, b2 = b0;
    const double a0 = 1.0 + alpha, a1 = -2.0 * cosW, a2 = 1.0 - alpha;

    const double y = (b0/a0)*input + (b1/a0)*bq_x1 + (b2/a0)*bq_x2
                   - (a1/a0)*bq_y1 - (a2/a0)*bq_y2;
    bq_x2 = bq_x1; bq_x1 = input;
    bq_y2 = bq_y1; bq_y1 = y;
    return y;
}

double OmniVoice::waveform (double phase, Waveform w)
{
    switch (w) {
        case Waveform::Sine:     return std::sin (phase * 6.2832);
        case Waveform::Triangle: return phase < 0.5 ? 4.0*phase-1.0 : 3.0-4.0*phase;
        case Waveform::Sawtooth: return 2.0*phase - 1.0;
        case Waveform::Square:   return phase < 0.5 ? 1.0 : -1.0;
        case Waveform::Noise: {
            noiseState = noiseState * 1664525u + 1013904223u;
            return double (int32_t (noiseState)) / double (std::numeric_limits<int32_t>::max());
        }
    }
    return 0.0;
}
