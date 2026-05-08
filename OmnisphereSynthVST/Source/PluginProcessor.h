#pragma once
#include <JuceHeader.h>
#include "Presets.h"
#include "OmniVoice.h"
#include <array>
#include <atomic>

class OmnisphereSynthProcessor : public juce::AudioProcessor
{
public:
    OmnisphereSynthProcessor();
    ~OmnisphereSynthProcessor() override;

    // ── AudioProcessor ────────────────────────────────────────────────────────
    void prepareToPlay   (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override;
    void processBlock    (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor()    const override { return true; }

    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi()  const override { return true; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return 6.0; }

    int  getNumPrograms() override { return 1; }
    int  getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock&) override;
    void setStateInformation (const void*, int) override;

    // ── Public API ─────────────────────────────────────────────────────────────
    void loadPreset (int index);

    juce::AudioProcessorValueTreeState apvts;

    // XY pad — written from UI thread, read from audio thread
    std::atomic<float> xyX { 0.5f };
    std::atomic<float> xyY { 0.5f };

    // Waveform display ring buffer (written audio → read UI)
    static constexpr int kWaveSize = 256;
    std::array<std::atomic<float>, kWaveSize> waveRing;
    std::atomic<int> waveWritePos { 0 };

    int currentPresetIndex = 0;

private:
    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    void applyEffectParams();

    // ── Synth ─────────────────────────────────────────────────────────────────
    juce::Synthesiser synth;
    static constexpr int kMaxVoices = 12;
    std::vector<SynthPreset> presets;

    // ── Effects ───────────────────────────────────────────────────────────────
    // Main chain: distortion (inline) → reverb → delay
    juce::dsp::Reverb mainReverb;

    // Delay — up to 2 s at 96 kHz
    static constexpr int kMaxDelaySamples = 192000;
    juce::dsp::DelayLine<float, juce::dsp::DelayLineInterpolationTypes::Linear> delayLine;
    float delayFeedback = 0.3f;

    // Shimmer — parallel path: copy → long reverb → pitch-shift +1 oct → blend
    juce::dsp::Reverb shimmerReverb;
    juce::AudioBuffer<float> shimmerBuf;

    // Granular pitch-shifter (+1 octave) for shimmer
    static constexpr int kGrainSize  = 2048;
    static constexpr int kShiftBuf   = kGrainSize * 4;
    float shiftBuffer[2][kShiftBuf]  = {};
    int   shiftWritePos = 0;
    float shiftReadA[2] { 0.f, 0.f };
    float shiftReadB[2] {};   // offset by half grain

    float pitchShiftSample (int ch, float input);

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (OmnisphereSynthProcessor)
};
