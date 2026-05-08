#include "PluginEditor.h"
#include <cmath>

static constexpr int kW = 820;
static constexpr int kH = 540;

// ─────────────────────────────────────────────────────────────────────────────
// OmniLookAndFeel
// ─────────────────────────────────────────────────────────────────────────────
OmniLookAndFeel::OmniLookAndFeel()
{
    setColour (juce::ResizableWindow::backgroundColourId,  juce::Colour (0xFF0a0a14));
    setColour (juce::Slider::rotarySliderFillColourId,     accentColour);
    setColour (juce::Slider::thumbColourId,                accentColour);
    setColour (juce::Label::textColourId,                  juce::Colours::white.withAlpha (0.55f));
    setColour (juce::ComboBox::backgroundColourId,         juce::Colour (0xFF16162a));
    setColour (juce::ComboBox::textColourId,               juce::Colours::white);
    setColour (juce::ComboBox::outlineColourId,            accentColour.withAlpha (0.4f));
    setColour (juce::PopupMenu::backgroundColourId,        juce::Colour (0xFF16162a));
    setColour (juce::PopupMenu::textColourId,              juce::Colours::white);
    setColour (juce::PopupMenu::highlightedBackgroundColourId, accentColour.withAlpha (0.3f));
}

void OmniLookAndFeel::drawRotarySlider (juce::Graphics& g, int x, int y, int w, int h,
                                         float sliderPos, float startAngle, float endAngle,
                                         juce::Slider& slider)
{
    const float cx = float (x) + float (w) * 0.5f;
    const float cy = float (y) + float (h) * 0.5f;
    const float r  = std::min (float (w), float (h)) * 0.5f - 4.0f;

    // Track ring
    juce::Path track;
    track.addCentredArc (cx, cy, r, r, 0.0f, startAngle, endAngle, true);
    g.setColour (juce::Colours::white.withAlpha (0.08f));
    g.strokePath (track, juce::PathStrokeType (2.5f, juce::PathStrokeType::curved,
                                               juce::PathStrokeType::rounded));

    // Value arc
    const float angle = startAngle + sliderPos * (endAngle - startAngle);
    juce::Path arc;
    arc.addCentredArc (cx, cy, r, r, 0.0f, startAngle, angle, true);
    g.setColour (accentColour);
    g.strokePath (arc, juce::PathStrokeType (2.5f, juce::PathStrokeType::curved,
                                             juce::PathStrokeType::rounded));

    // Knob body
    const float kr = r * 0.6f;
    g.setColour (juce::Colour (0xFF1a1a2e));
    g.fillEllipse (cx - kr, cy - kr, kr * 2.0f, kr * 2.0f);

    // Pointer line
    const float px = cx + (kr - 4.0f) * std::sin (angle);
    const float py = cy - (kr - 4.0f) * std::cos (angle);
    g.setColour (accentColour);
    g.drawLine (cx, cy, px, py, 2.0f);

    // Glow
    g.setColour (accentColour.withAlpha (0.15f));
    g.fillEllipse (cx - kr - 3.0f, cy - kr - 3.0f, (kr + 3.0f) * 2.0f, (kr + 3.0f) * 2.0f);
}

void OmniLookAndFeel::drawLinearSlider (juce::Graphics& g, int x, int y, int w, int h,
                                         float sliderPos, float minPos, float maxPos,
                                         juce::Slider::SliderStyle style, juce::Slider& slider)
{
    // Vertical bar style for ADSR faders
    const float trackX = float (x) + float (w) * 0.5f - 2.0f;
    g.setColour (juce::Colours::white.withAlpha (0.07f));
    g.fillRoundedRectangle (trackX, float (y), 4.0f, float (h), 2.0f);

    const float fillH = float (y) + float (h) - sliderPos;
    g.setColour (accentColour.withAlpha (0.85f));
    g.fillRoundedRectangle (trackX, sliderPos, 4.0f, float (y) + float (h) - sliderPos, 2.0f);

    g.setColour (juce::Colours::white);
    g.fillEllipse (trackX - 4.0f, sliderPos - 5.0f, 12.0f, 10.0f);
}

juce::Font OmniLookAndFeel::getLabelFont (juce::Label&)
{
    return juce::Font ("Helvetica Neue", 9.5f, juce::Font::plain);
}

juce::Font OmniLookAndFeel::getComboBoxFont (juce::ComboBox&)
{
    return juce::Font ("Helvetica Neue", 13.0f, juce::Font::plain);
}

// ─────────────────────────────────────────────────────────────────────────────
// XYPad
// ─────────────────────────────────────────────────────────────────────────────
XYPad::XYPad (std::atomic<float>& xRef, std::atomic<float>& yRef, juce::Colour col)
    : xVal (xRef), yVal (yRef), accent (col)
{
    setMouseCursor (juce::MouseCursor::CrosshairCursor);
}

void XYPad::paint (juce::Graphics& g)
{
    auto bounds = getLocalBounds().toFloat();

    // Background
    g.setGradientFill (juce::ColourGradient (
        accent.withAlpha (0.18f), bounds.getTopLeft(),
        juce::Colour (0xFF060610),  bounds.getBottomRight(), false));
    g.fillRoundedRectangle (bounds, 12.0f);

    // Grid
    g.setColour (juce::Colours::white.withAlpha (0.06f));
    for (int i = 1; i < 8; ++i) {
        float xg = bounds.getX() + bounds.getWidth()  * float (i) / 8.0f;
        float yg = bounds.getY() + bounds.getHeight() * float (i) / 8.0f;
        g.drawLine (xg, bounds.getY(), xg, bounds.getBottom(), 0.5f);
        g.drawLine (bounds.getX(), yg, bounds.getRight(), yg, 0.5f);
    }

    // Labels
    g.setFont (juce::Font (9.0f));
    g.setColour (juce::Colours::white.withAlpha (0.3f));
    g.drawText ("BRIGHTNESS →",
                bounds.reduced (8).removeFromBottom (14), juce::Justification::centredRight);
    g.drawText ("↑ MODULATION",
                bounds.reduced (8).removeFromTop (14), juce::Justification::centredLeft);

    // Cursor
    const float cx = xVal.load() * bounds.getWidth()  + bounds.getX();
    const float cy = (1.0f - yVal.load()) * bounds.getHeight() + bounds.getY();

    g.setColour (accent.withAlpha (0.25f));
    g.fillEllipse (cx - 24.0f, cy - 24.0f, 48.0f, 48.0f);
    g.setColour (accent);
    g.drawEllipse (cx - 12.0f, cy - 12.0f, 24.0f, 24.0f, 1.5f);
    g.fillEllipse (cx - 4.0f,  cy - 4.0f,  8.0f,  8.0f);

    // Border
    g.setColour (accent.withAlpha (0.4f));
    g.drawRoundedRectangle (bounds.reduced (0.5f), 12.0f, 1.5f);
}

void XYPad::mouseDown  (const juce::MouseEvent& e) { updateFromMouse (e.position); }
void XYPad::mouseDrag  (const juce::MouseEvent& e) { updateFromMouse (e.position); }

void XYPad::updateFromMouse (juce::Point<float> pos)
{
    xVal.store (juce::jlimit (0.0f, 1.0f, pos.x / float (getWidth())));
    yVal.store (juce::jlimit (0.0f, 1.0f, 1.0f - pos.y / float (getHeight())));
    repaint();
}

// ─────────────────────────────────────────────────────────────────────────────
// WaveformDisplay
// ─────────────────────────────────────────────────────────────────────────────
WaveformDisplay::WaveformDisplay (OmnisphereSynthProcessor& p) : proc (p)
{
    startTimerHz (30);
}

WaveformDisplay::~WaveformDisplay() { stopTimer(); }

void WaveformDisplay::timerCallback() { repaint(); }

void WaveformDisplay::paint (juce::Graphics& g)
{
    auto b = getLocalBounds().toFloat();
    g.setColour (juce::Colour (0xFF0d0d1e));
    g.fillRoundedRectangle (b, 8.0f);

    const int N = OmnisphereSynthProcessor::kWaveSize;
    const float midY = b.getCentreY();

    juce::Path path;
    for (int i = 0; i < N; ++i) {
        const float x = b.getX() + float (i) / float (N - 1) * b.getWidth();
        const float y = midY - proc.waveRing[i].load() * midY * 0.85f;
        if (i == 0) path.startNewSubPath (x, y);
        else         path.lineTo (x, y);
    }

    g.setColour (accent.withAlpha (0.25f));
    g.strokePath (path, juce::PathStrokeType (5.0f, juce::PathStrokeType::curved));
    g.setColour (accent.withAlpha (0.7f));
    g.strokePath (path, juce::PathStrokeType (1.5f, juce::PathStrokeType::curved));

    g.setColour (accent.withAlpha (0.35f));
    g.drawRoundedRectangle (b.reduced (0.5f), 8.0f, 1.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// LabelledKnob
// ─────────────────────────────────────────────────────────────────────────────
LabelledKnob::LabelledKnob (const juce::String& paramID,
                              const juce::String& labelText,
                              OmnisphereSynthProcessor& proc,
                              OmniLookAndFeel& laf)
{
    slider.setSliderStyle (juce::Slider::RotaryVerticalDrag);
    slider.setTextBoxStyle (juce::Slider::NoTextBox, false, 0, 0);
    slider.setLookAndFeel (&laf);
    addAndMakeVisible (slider);

    label.setText (labelText, juce::dontSendNotification);
    label.setJustificationType (juce::Justification::centred);
    label.setFont (juce::Font (9.0f, juce::Font::bold));
    label.setColour (juce::Label::textColourId, juce::Colours::white.withAlpha (0.45f));
    addAndMakeVisible (label);

    attachment = std::make_unique<juce::AudioProcessorValueTreeState::SliderAttachment>
                    (proc.apvts, paramID, slider);
}

void LabelledKnob::resized()
{
    auto b = getLocalBounds();
    label.setBounds (b.removeFromBottom (16));
    slider.setBounds (b);
}

// ─────────────────────────────────────────────────────────────────────────────
// OmnisphereSynthEditor
// ─────────────────────────────────────────────────────────────────────────────
OmnisphereSynthEditor::OmnisphereSynthEditor (OmnisphereSynthProcessor& p)
    : AudioProcessorEditor (&p),
      proc (p),
      presets (Presets::all()),
      xyPad (p.xyX, p.xyY, juce::Colour (0xFF8B5CF6)),
      waveDisplay (p)
{
    setLookAndFeel (&laf);
    setSize (kW, kH);

    // Preset combo
    for (int i = 0; i < int (presets.size()); ++i)
        presetBox.addItem (presets[i].name, i + 1);
    presetBox.setSelectedId (p.currentPresetIndex + 1, juce::dontSendNotification);
    presetBox.addListener (this);
    addAndMakeVisible (presetBox);

    // Title
    titleLabel.setText ("OMNISPHERE SYNTH", juce::dontSendNotification);
    titleLabel.setFont (juce::Font (14.0f, juce::Font::bold));
    titleLabel.setColour (juce::Label::textColourId, juce::Colours::white.withAlpha (0.7f));
    titleLabel.setJustificationType (juce::Justification::centredLeft);
    addAndMakeVisible (titleLabel);

    addAndMakeVisible (xyPad);
    addAndMakeVisible (waveDisplay);

    // Section labels
    auto makeSec = [&](juce::Label& l, const char* t) {
        l.setText (t, juce::dontSendNotification);
        l.setFont (juce::Font (8.5f, juce::Font::bold));
        l.setColour (juce::Label::textColourId, juce::Colours::white.withAlpha (0.3f));
        l.setJustificationType (juce::Justification::centredLeft);
        addAndMakeVisible (l);
    };
    makeSec (secEffects, "EFFECTS");
    makeSec (secEnv,     "ENVELOPE");
    makeSec (secLFO,     "LFO");
    makeSec (secOsc,     "OSCILLATOR");
    makeSec (secOrgan,   "ORGAN");

    // Knobs
    auto mk = [&](std::unique_ptr<LabelledKnob>& knob,
                  const char* id, const char* label) {
        knob = std::make_unique<LabelledKnob> (id, label, proc, laf);
        addAndMakeVisible (*knob);
    };

    mk (knobReverb,    "reverb",     "REVERB");
    mk (knobDelay,     "delay_mix",  "DELAY");
    mk (knobDelayTime, "delay_time", "D.TIME");
    mk (knobCutoff,    "cutoff",     "CUTOFF");
    mk (knobResonance, "resonance",  "RESON");
    mk (knobAttack,    "attack",     "ATK");
    mk (knobDecay,     "decay",      "DEC");
    mk (knobSustain,   "sustain",    "SUS");
    mk (knobRelease,   "release",    "REL");
    mk (knobLfoRate,   "lfo_rate",   "RATE");
    mk (knobLfoDepth,  "lfo_depth",  "DEPTH");
    mk (knobOscMix,    "osc_mix",    "MIX");
    mk (knobDetune,    "osc2_detune","DETUNE");
    mk (knobDrive,     "distortion", "DRIVE");
    mk (knobShimmer,   "shimmer",    "SHIMMER");
    mk (knobTremulant, "tremulant",  "TREMUL");

    updateForPreset (presets[p.currentPresetIndex]);
}

OmnisphereSynthEditor::~OmnisphereSynthEditor()
{
    setLookAndFeel (nullptr);
}

void OmnisphereSynthEditor::comboBoxChanged (juce::ComboBox* box)
{
    if (box == &presetBox) {
        const int idx = presetBox.getSelectedId() - 1;
        proc.loadPreset (idx);
        updateForPreset (presets[idx]);
    }
}

void OmnisphereSynthEditor::updateForPreset (const SynthPreset& p)
{
    laf.accentColour = p.color;
    xyPad.setAccentColour (p.color);
    waveDisplay.setAccentColour (p.color);

    const bool isOrg = p.isOrgan;
    knobAttack->setVisible  (!isOrg);
    knobDecay->setVisible   (!isOrg);
    knobSustain->setVisible (!isOrg);
    knobRelease->setVisible (!isOrg);
    knobOscMix->setVisible  (!isOrg);
    knobDetune->setVisible  (!isOrg);
    secEnv.setVisible       (!isOrg);
    secOsc.setVisible       (!isOrg);

    knobDrive->setVisible     (isOrg);
    knobShimmer->setVisible   (isOrg);
    knobTremulant->setVisible (isOrg);
    secOrgan.setVisible       (isOrg);

    repaint();
}

void OmnisphereSynthEditor::paint (juce::Graphics& g)
{
    // Deep dark background
    g.setGradientFill (juce::ColourGradient (
        juce::Colour (0xFF0f0f20), 0, 0,
        juce::Colour (0xFF070710), float (kW), float (kH), false));
    g.fillAll();

    // Subtle horizontal rule between pad and controls
    g.setColour (juce::Colours::white.withAlpha (0.05f));
    g.drawLine (440.0f, 50.0f, 440.0f, float (kH - 70), 1.0f);
}

void OmnisphereSynthEditor::resized()
{
    const int padL = 12, padT = 50, xyW = 420, xyH = 390;
    const int ctrlX = 450, ctrlW = kW - ctrlX - 12;
    const int knobS = 58;  // knob component size (square)

    titleLabel.setBounds (12, 8, 280, 36);
    presetBox.setBounds  (kW - 220, 12, 208, 28);

    xyPad.setBounds (padL, padT, xyW, xyH);
    waveDisplay.setBounds (padL, padT + xyH + 8, xyW, kH - padT - xyH - 20);

    // Right panel layout
    int ry = padT + 4;

    // Effects row
    secEffects.setBounds (ctrlX, ry, ctrlW, 14);  ry += 16;
    auto placeRow = [&](std::initializer_list<LabelledKnob*> knobs) {
        int kx = ctrlX;
        for (auto* k : knobs) {
            k->setBounds (kx, ry, knobS, knobS + 16);
            kx += knobS + 4;
        }
        ry += knobS + 22;
    };
    placeRow ({ knobReverb.get(), knobDelay.get(), knobDelayTime.get(),
                knobCutoff.get(), knobResonance.get() });

    // Envelope / Organ row
    secEnv.setBounds   (ctrlX, ry, ctrlW, 14);
    secOrgan.setBounds (ctrlX, ry, ctrlW, 14);  ry += 16;
    placeRow ({ knobAttack.get(), knobDecay.get(), knobSustain.get(), knobRelease.get() });
    // organ knobs overlay same slot — visibility toggled
    {
        int kx = ctrlX;
        for (auto* k : { knobDrive.get(), knobShimmer.get(), knobTremulant.get() }) {
            k->setBounds (kx, ry - knobS - 22, knobS, knobS + 16);
            kx += knobS + 4;
        }
    }

    // LFO row
    secLFO.setBounds (ctrlX, ry, ctrlW, 14);  ry += 16;
    placeRow ({ knobLfoRate.get(), knobLfoDepth.get() });

    // Osc row
    secOsc.setBounds (ctrlX, ry, ctrlW, 14);  ry += 16;
    placeRow ({ knobOscMix.get(), knobDetune.get() });
}
