#pragma once
#include <JuceHeader.h>
#include "Presets.h"
#include "Effects/LeslieEffect.h"
#include <atomic>

class OmniSound : public juce::SynthesiserSound {
public:
    bool appliesToNote    (int) override { return true; }
    bool appliesToChannel (int) override { return true; }
};

// ─────────────────────────────────────────────────────────────────────────────
// Single polyphonic voice — synth, church organ, Hammond B3, or Rhodes.
// Hammond renders stereo (Leslie); others render mono (same L+R).
// ─────────────────────────────────────────────────────────────────────────────
class OmniVoice : public juce::SynthesiserVoice
{
public:
    OmniVoice();

    void setPreset (const SynthPreset& p) { preset = p; leslie.reset(); }

    // Pointers written from the message thread, read on the audio thread
    std::atomic<float>* xyX          = nullptr;  // filter brightness 0-1
    std::atomic<float>* xyY          = nullptr;  // mod depth 0-1
    std::atomic<float>* modWheelPtr  = nullptr;  // CC1  0-1
    std::atomic<float>* expressionPtr= nullptr;  // CC11 0-1
    std::atomic<float>* leslieSpeedPtr = nullptr;// CC3  0=slow 1=fast

    // ── JUCE overrides ────────────────────────────────────────────────────────
    bool canPlaySound (juce::SynthesiserSound*) override;
    void startNote    (int midiNote, float velocity,
                       juce::SynthesiserSound*, int pitchWheelPos) override;
    void stopNote     (float velocity, bool allowTailOff) override;
    void pitchWheelMoved (int newValue) override;
    void controllerMoved (int cc, int value) override;
    void renderNextBlock (juce::AudioBuffer<float>&, int startSample, int numSamples) override;

private:
    SynthPreset  preset;
    LeslieEffect leslie;

    // ── Oscillator / LFO ─────────────────────────────────────────────────────
    double   phase1 = 0, phase2 = 0, lfoPhase = 0;
    uint32_t noiseState = 98765;
    float    pitchBendST = 0.0f;   // semitones from pitch wheel

    // ── Organ / Hammond partials ──────────────────────────────────────────────
    static constexpr int kNP = 9;
    static const double kRatios [kNP];
    static const float  kChurchLvl [kNP];  // church pipe organ
    static const float  kHammondLvl[kNP];  // Hammond B3 888000000
    static const double kDetunes[kNP];
    double organPhases[kNP] = {};
    double tremPhase   = 0.0;
    int    clickLeft   = 0;

    // ── Hammond percussion (2nd harmonic decay) ───────────────────────────────
    double percPhase = 0.0;
    double percEnv   = 0.0;     // decays quickly after note-on

    // ── Rhodes FM synthesis ───────────────────────────────────────────────────
    double rhCarPhase = 0.0;    // carrier
    double rhModPhase = 0.0;    // modulator (≈same freq)
    double rhDecayEnv = 0.0;    // natural decay (independent of key hold)
    double rhDecayTime = 1.8;

    // ── Envelope ─────────────────────────────────────────────────────────────
    enum class Stage { Idle, Attack, Decay, Sustain, Release };
    Stage  envStage = Stage::Idle;
    double envValue = 0.0;

    // ── Biquad LP filter ─────────────────────────────────────────────────────
    double bq_x1 = 0, bq_x2 = 0, bq_y1 = 0, bq_y2 = 0;

    float noteFreq    = 440.0f;
    float noteVelocity= 1.0f;

    // ── DSP helpers ───────────────────────────────────────────────────────────
    double synthSample  (double dt, float xMod, float yMod, float mod, float expr);
    double organSample  (double dt, float yMod);
    double hammondSample(double dt, float yMod);
    double rhodesSample (double dt);
    double advanceEnv   (double dt);
    double biquadLP     (double input, double cutoff, double resonance);
    double waveform     (double phase, Waveform w);
};
