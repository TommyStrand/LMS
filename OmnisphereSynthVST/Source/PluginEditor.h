#pragma once
#include <JuceHeader.h>
#include "PluginProcessor.h"
#include "Presets.h"

// ─────────────────────────────────────────────────────────────────────────────
// Dark glow look-and-feel
// ─────────────────────────────────────────────────────────────────────────────
class OmniLookAndFeel : public juce::LookAndFeel_V4
{
public:
    juce::Colour accentColour { 0xFF8B5CF6 };

    OmniLookAndFeel();

    void drawRotarySlider (juce::Graphics&, int x, int y, int w, int h,
                           float pos, float startAngle, float endAngle,
                           juce::Slider&) override;

    void drawLinearSlider (juce::Graphics&, int x, int y, int w, int h,
                           float pos, float minPos, float maxPos,
                           juce::Slider::SliderStyle, juce::Slider&) override;

    juce::Font getLabelFont (juce::Label&) override;
    juce::Font getComboBoxFont (juce::ComboBox&) override;
};

// ─────────────────────────────────────────────────────────────────────────────
// XY pad — mouse controls filter brightness (X) and mod depth (Y)
// ─────────────────────────────────────────────────────────────────────────────
class XYPad : public juce::Component
{
public:
    XYPad (std::atomic<float>& xRef, std::atomic<float>& yRef, juce::Colour col);
    void setAccentColour (juce::Colour c) { accent = c; repaint(); }
    void paint (juce::Graphics&) override;
    void mouseDown (const juce::MouseEvent&) override;
    void mouseDrag (const juce::MouseEvent&) override;
private:
    std::atomic<float>& xVal;
    std::atomic<float>& yVal;
    juce::Colour accent;
    void update (juce::Point<float>);
};

// ─────────────────────────────────────────────────────────────────────────────
// Oscilloscope display
// ─────────────────────────────────────────────────────────────────────────────
class WaveformDisplay : public juce::Component, private juce::Timer
{
public:
    WaveformDisplay (OmnisphereSynthProcessor&);
    ~WaveformDisplay() override;
    void setAccentColour (juce::Colour c) { accent = c; }
    void paint (juce::Graphics&) override;
private:
    OmnisphereSynthProcessor& proc;
    juce::Colour accent { 0xFF8B5CF6 };
    void timerCallback() override { repaint(); }
};

// ─────────────────────────────────────────────────────────────────────────────
// Labelled rotary knob backed by APVTS
// ─────────────────────────────────────────────────────────────────────────────
class LabelledKnob : public juce::Component
{
public:
    LabelledKnob (const juce::String& paramID, const juce::String& labelText,
                  OmnisphereSynthProcessor&, OmniLookAndFeel&);
    void resized() override;
    juce::Slider slider;
private:
    juce::Label label;
    std::unique_ptr<juce::AudioProcessorValueTreeState::SliderAttachment> attachment;
};

// ─────────────────────────────────────────────────────────────────────────────
// Main editor  —  820 × 580 px
// ─────────────────────────────────────────────────────────────────────────────
class OmnisphereSynthEditor : public juce::AudioProcessorEditor,
                               private juce::ComboBox::Listener
{
public:
    OmnisphereSynthEditor (OmnisphereSynthProcessor&);
    ~OmnisphereSynthEditor() override;

    void paint   (juce::Graphics&) override;
    void resized () override;

private:
    OmnisphereSynthProcessor& proc;
    OmniLookAndFeel laf;
    std::vector<SynthPreset> presets;

    // Header
    juce::ComboBox presetBox;
    juce::Label    titleLabel;
    juce::Label    midiHintLabel;

    // Main panels
    XYPad           xyPad;
    WaveformDisplay waveDisplay;

    // ── Knob groups ───────────────────────────────────────────────────────────
    // Row 1 – core effects (always shown)
    std::unique_ptr<LabelledKnob> knobReverb, knobDelayMix, knobDelayTime;
    std::unique_ptr<LabelledKnob> knobCutoff, knobResonance;

    // Row 2 – envelope or organ controls
    std::unique_ptr<LabelledKnob> knobAttack, knobDecay, knobSustain, knobRelease;
    std::unique_ptr<LabelledKnob> knobDistortion, knobShimmer, knobTremulant;

    // Row 3 – LFO / osc
    std::unique_ptr<LabelledKnob> knobLfoRate, knobLfoDepth;
    std::unique_ptr<LabelledKnob> knobOscMix, knobDetune;

    // Row 4 – texture effects (always shown)
    std::unique_ptr<LabelledKnob> knobLofi, knobVinyl, knobBrokenTape;
    std::unique_ptr<LabelledKnob> knobGrit, knobDoubler;

    // Section labels
    juce::Label secFX, secEnv, secOrgan, secLFO, secOsc, secTexture;

    void comboBoxChanged (juce::ComboBox*) override;
    void updateForPreset (const SynthPreset&);

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (OmnisphereSynthEditor)
};
