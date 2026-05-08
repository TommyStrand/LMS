#pragma once
#include <JuceHeader.h>
#include "Presets.h"
#include <atomic>

// Accepts all notes on all channels
class OmniSound : public juce::SynthesiserSound {
public:
    bool appliesToNote    (int) override { return true; }
    bool appliesToChannel (int) override { return true; }
};

// ─────────────────────────────────────────────────────────────────────────────
// Single polyphonic voice: runs in either synth or organ mode depending on
// the active preset.  Shared between both modes to keep voice-stealing simple.
// ─────────────────────────────────────────────────────────────────────────────
class OmniVoice : public juce::SynthesiserVoice
{
public:
    OmniVoice() = default;

    // Called from message thread; safe because voice is idle at preset change
    void setPreset (const SynthPreset& p) { preset = p; }

    // Set by XY pad; read from audio thread (atomic)
    std::atomic<float>* xyX = nullptr;
    std::atomic<float>* xyY = nullptr;

    // ── JUCE overrides ────────────────────────────────────────────────────────
    bool canPlaySound (juce::SynthesiserSound* s) override;
    void startNote    (int midiNote, float velocity,
                       juce::SynthesiserSound*, int pitchWheelPos) override;
    void stopNote     (float velocity, bool allowTailOff) override;
    void pitchWheelMoved (int newValue) override;
    void controllerMoved (int, int) override {}
    void renderNextBlock (juce::AudioBuffer<float>&, int startSample, int numSamples) override;

private:
    SynthPreset preset;

    // ── Oscillator / LFO ─────────────────────────────────────────────────────
    double phase1 = 0, phase2 = 0, lfoPhase = 0;
    uint32_t noiseState = 98765;
    float pitchBendSemitones = 0.0f;

    // ── Organ partials ────────────────────────────────────────────────────────
    static constexpr int kNumPartials = 9;
    static const double kRatios   [kNumPartials];
    static const float  kLevels   [kNumPartials];
    static const double kDetunes  [kNumPartials];
    double organPhases[kNumPartials] = {};
    double tremPhase = 0.0;
    int    clickSamplesLeft = 0;

    // ── Envelope ─────────────────────────────────────────────────────────────
    enum class Stage { Idle, Attack, Decay, Sustain, Release };
    Stage  envStage = Stage::Idle;
    double envValue = 0.0;

    // ── Biquad LP filter state ────────────────────────────────────────────────
    double bq_x1 = 0, bq_x2 = 0, bq_y1 = 0, bq_y2 = 0;

    float noteFreq     = 440.0f;
    float noteVelocity = 1.0f;

    // ── DSP helpers ───────────────────────────────────────────────────────────
    double synthSample  (double dt, float xMod, float yMod);
    double organSample  (double dt, float xMod, float yMod);
    double advanceEnv   (double dt);
    double biquadLP     (double input, double cutoff, double resonance);
    double waveform     (double phase, Waveform w);
};
