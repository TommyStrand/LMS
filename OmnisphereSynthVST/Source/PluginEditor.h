#pragma once
#include <JuceHeader.h>
#include "PluginProcessor.h"
#include "Presets.h"

// ─────────────────────────────────────────────────────────────────────────────
// Custom dark look-and-feel — knobs, combo box, labels
// ─────────────────────────────────────────────────────────────────────────────
class OmniLookAndFeel : public juce::LookAndFeel_V4
{
public:
    OmniLookAndFeel();

    void drawRotarySlider (juce::Graphics&, int x, int y, int w, int h,
                           float sliderPos, float startAngle, float endAngle,
                           juce::Slider&) override;

    void drawLinearSlider (juce::Graphics&, int x, int y, int w, int h,
                           float sliderPos, float minSliderPos, float maxSliderPos,
                           juce::Slider::SliderStyle, juce::Slider&) override;

    juce::Font getLabelFont (juce::Label&) override;
    juce::Font getComboBoxFont (juce::ComboBox&) override;

    juce::Colour accentColour { 0xFF8B5CF6 };
};

// ─────────────────────────────────────────────────────────────────────────────
// Interactive XY pad — mouse controls filter cutoff (X) and mod depth (Y)
// ─────────────────────────────────────────────────────────────────────────────
class XYPad : public juce::Component
{
public:
    XYPad (std::atomic<float>& xRef, std::atomic<float>& yRef, juce::Colour col);

    void setAccentColour (juce::Colour c) { accent = c; repaint(); }
    void paint (juce::Graphics&) override;
    void mouseDown  (const juce::MouseEvent&) override;
    void mouseDrag  (const juce::MouseEvent&) override;

private:
    std::atomic<float>& xVal;
    std::atomic<float>& yVal;
    juce::Colour accent;

    void updateFromMouse (juce::Point<float> pos);
};

// ─────────────────────────────────────────────────────────────────────────────
// Oscilloscope display — reads from processor's ring buffer
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
    void timerCallback() override;
};

// ─────────────────────────────────────────────────────────────────────────────
// Labelled knob (rotary slider + label)
// ─────────────────────────────────────────────────────────────────────────────
class LabelledKnob : public juce::Component
{
public:
    LabelledKnob (const juce::String& paramID,
                  const juce::String& labelText,
                  OmnisphereSynthProcessor&,
                  OmniLookAndFeel&);

    void resized() override;

    juce::Slider slider;

private:
    juce::Label  label;
    std::unique_ptr<juce::AudioProcessorValueTreeState::SliderAttachment> attachment;
};

// ─────────────────────────────────────────────────────────────────────────────
// Main plugin editor
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
    juce::ComboBox   presetBox;
    juce::Label      titleLabel;

    // Main panels
    XYPad            xyPad;
    WaveformDisplay  waveDisplay;

    // Knob groups
    std::unique_ptr<LabelledKnob> knobReverb, knobDelay, knobDelayTime;
    std::unique_ptr<LabelledKnob> knobCutoff, knobResonance;
    std::unique_ptr<LabelledKnob> knobAttack, knobDecay, knobSustain, knobRelease;
    std::unique_ptr<LabelledKnob> knobLfoRate, knobLfoDepth;
    std::unique_ptr<LabelledKnob> knobOscMix, knobDetune;
    std::unique_ptr<LabelledKnob> knobDrive, knobShimmer, knobTremulant;

    // Section labels
    juce::Label secEffects, secEnv, secLFO, secOsc, secOrgan;

    void comboBoxChanged (juce::ComboBox*) override;
    void updateForPreset (const SynthPreset&);

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (OmnisphereSynthEditor)
};
