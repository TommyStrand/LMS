#pragma once
#include <JuceHeader.h>
#include "Presets.h"
#include "OmniVoice.h"
#include "Effects/LofiEffect.h"
#include "Effects/VinylEffect.h"
#include "Effects/TapeDelay.h"
#include "Effects/GritEffect.h"
#include "Effects/DoublerEffect.h"
#include <array>
#include <atomic>
#include <vector>

class SuperNovaPadProcessor : public juce::AudioProcessor
{
public:
    SuperNovaPadProcessor();
    ~SuperNovaPadProcessor() override;

    void prepareToPlay   (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override;
    void processBlock    (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor()    const override { return true; }

    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi()  const override { return true; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return 8.0; }

    int  getNumPrograms() override { return 1; }
    int  getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock&) override;
    void setStateInformation (const void*, int) override;

    void loadPreset (int index);

    juce::AudioProcessorValueTreeState apvts;

    // Performance controls — written by UI/MIDI, read by audio thread
    std::atomic<float> xyX          { 0.5f };
    std::atomic<float> xyY          { 0.5f };
    std::atomic<float> midiModWheel { 0.0f };  // CC1
    std::atomic<float> midiExpression{ 1.0f }; // CC11
    std::atomic<float> midiLeslieSpd { 0.0f }; // CC3 / mod-wheel for Hammond

    // Waveform display ring (written audio → read UI, 30 Hz)
    static constexpr int kWaveSize = 256;
    std::array<std::atomic<float>, kWaveSize> waveRing;
    std::atomic<int> waveWritePos { 0 };

    int currentPresetIndex = 0;

private:
    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    void applyReverbParams();

    // ── Synth ─────────────────────────────────────────────────────────────────
    juce::Synthesiser synth;
    static constexpr int kMaxVoices = 12;
    std::vector<SynthPreset> presets;

    // ── Main reverb ────────────────────────────────────────────────────────────
    juce::dsp::Reverb mainReverb;

    // ── Shimmer: long plate → +1 oct pitch-shift ──────────────────────────────
    juce::dsp::Reverb shimmerReverb;
    juce::AudioBuffer<float> shimBuf;
    static constexpr int kGrainSize = 2048;
    static constexpr int kShiftBuf  = kGrainSize * 4;
    float shiftBuffer[2][kShiftBuf] = {};
    int   shiftWrite = 0;
    float shiftReadA[2] { 0.f, 0.f };
    float shiftReadB[2] { float(kGrainSize), float(kGrainSize) };
    float pitchShiftSample (int ch, float in);

    // ── New texture effects (stereo instances) ────────────────────────────────
    LofiEffect   lofi[2];
    VinylEffect  vinyl[2];
    TapeDelay    tapeDelay[2];
    GritEffect   grit;           // same algorithm per channel, stateless
    DoublerEffect doubler;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (SuperNovaPadProcessor)
};
