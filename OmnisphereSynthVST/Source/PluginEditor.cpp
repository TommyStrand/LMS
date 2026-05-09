#include "PluginEditor.h"
#include <cmath>

static constexpr int kW = 860;
static constexpr int kH = 590;

// ─────────────────────────────────────────────────────────────────────────────
// OmniLookAndFeel
// ─────────────────────────────────────────────────────────────────────────────
OmniLookAndFeel::OmniLookAndFeel()
{
    setColour (juce::ResizableWindow::backgroundColourId, juce::Colour (0xFF0a0a14));
    setColour (juce::Label::textColourId,                 juce::Colours::white.withAlpha (0.5f));
    setColour (juce::ComboBox::backgroundColourId,        juce::Colour (0xFF16162a));
    setColour (juce::ComboBox::textColourId,              juce::Colours::white);
    setColour (juce::ComboBox::outlineColourId,           accentColour.withAlpha (0.4f));
    setColour (juce::PopupMenu::backgroundColourId,       juce::Colour (0xFF16162a));
    setColour (juce::PopupMenu::textColourId,             juce::Colours::white);
    setColour (juce::PopupMenu::highlightedBackgroundColourId, accentColour.withAlpha (0.3f));
}

void OmniLookAndFeel::drawRotarySlider (juce::Graphics& g, int x, int y, int w, int h,
                                         float pos, float startA, float endA, juce::Slider&)
{
    const float cx = float(x) + float(w)*0.5f, cy = float(y)+float(h)*0.5f;
    const float r  = std::min(float(w),float(h))*0.5f - 4.0f;

    juce::Path track;
    track.addCentredArc(cx,cy,r,r,0,startA,endA,true);
    g.setColour(juce::Colours::white.withAlpha(0.08f));
    g.strokePath(track, juce::PathStrokeType(2.5f,juce::PathStrokeType::curved,juce::PathStrokeType::rounded));

    const float angle = startA + pos*(endA-startA);
    juce::Path arc; arc.addCentredArc(cx,cy,r,r,0,startA,angle,true);
    g.setColour(accentColour);
    g.strokePath(arc, juce::PathStrokeType(2.5f,juce::PathStrokeType::curved,juce::PathStrokeType::rounded));

    const float kr = r*0.6f;
    g.setColour(juce::Colour(0xFF1a1a2e));
    g.fillEllipse(cx-kr,cy-kr,kr*2,kr*2);
    const float px = cx+(kr-4)*std::sin(angle), py = cy-(kr-4)*std::cos(angle);
    g.setColour(accentColour); g.drawLine(cx,cy,px,py,2.0f);
    g.setColour(accentColour.withAlpha(0.12f));
    g.fillEllipse(cx-kr-3,cy-kr-3,(kr+3)*2,(kr+3)*2);
}

void OmniLookAndFeel::drawLinearSlider (juce::Graphics& g, int x, int y, int w, int h,
                                         float pos, float, float, juce::Slider::SliderStyle, juce::Slider&)
{
    const float tx = float(x)+float(w)*0.5f-2;
    g.setColour(juce::Colours::white.withAlpha(0.07f));
    g.fillRoundedRectangle(tx,float(y),4,float(h),2);
    g.setColour(accentColour.withAlpha(0.85f));
    g.fillRoundedRectangle(tx,pos,4,float(y)+float(h)-pos,2);
    g.setColour(juce::Colours::white);
    g.fillEllipse(tx-4,pos-5,12,10);
}

juce::Font OmniLookAndFeel::getLabelFont(juce::Label&)
    { return juce::Font("Helvetica Neue",9.5f,juce::Font::plain); }
juce::Font OmniLookAndFeel::getComboBoxFont(juce::ComboBox&)
    { return juce::Font("Helvetica Neue",13.0f,juce::Font::plain); }

// ─────────────────────────────────────────────────────────────────────────────
// XYPad
// ─────────────────────────────────────────────────────────────────────────────
XYPad::XYPad(std::atomic<float>& xr, std::atomic<float>& yr, juce::Colour c)
    : xVal(xr), yVal(yr), accent(c)
{ setMouseCursor(juce::MouseCursor::CrosshairCursor); }

void XYPad::update(juce::Point<float> p)
{
    xVal.store(juce::jlimit(0.0f,1.0f,p.x/float(getWidth())));
    yVal.store(juce::jlimit(0.0f,1.0f,1.0f-p.y/float(getHeight())));
    repaint();
}
void XYPad::mouseDown(const juce::MouseEvent& e){ update(e.position); }
void XYPad::mouseDrag(const juce::MouseEvent& e){ update(e.position); }

void XYPad::paint(juce::Graphics& g)
{
    auto b = getLocalBounds().toFloat();
    g.setGradientFill(juce::ColourGradient(
        accent.withAlpha(0.18f), b.getTopLeft(),
        juce::Colour(0xFF060610), b.getBottomRight(), false));
    g.fillRoundedRectangle(b,12);

    g.setColour(juce::Colours::white.withAlpha(0.055f));
    for(int i=1;i<8;++i){
        g.drawLine(b.getX()+b.getWidth()*float(i)/8,b.getY(),
                   b.getX()+b.getWidth()*float(i)/8,b.getBottom(),0.5f);
        g.drawLine(b.getX(),b.getY()+b.getHeight()*float(i)/8,
                   b.getRight(),b.getY()+b.getHeight()*float(i)/8,0.5f);
    }
    g.setFont(9.0f); g.setColour(juce::Colours::white.withAlpha(0.28f));
    g.drawText("BRIGHTNESS →",b.reduced(8).removeFromBottom(14),juce::Justification::centredRight);
    g.drawText("↑ MODULATION",b.reduced(8).removeFromTop(14),   juce::Justification::centredLeft);

    const float cx = xVal.load()*b.getWidth()+b.getX();
    const float cy = (1.0f-yVal.load())*b.getHeight()+b.getY();
    g.setColour(accent.withAlpha(0.22f)); g.fillEllipse(cx-24,cy-24,48,48);
    g.setColour(accent);                  g.drawEllipse(cx-12,cy-12,24,24,1.5f);
    g.fillEllipse(cx-4,cy-4,8,8);
    g.setColour(accent.withAlpha(0.4f));
    g.drawRoundedRectangle(b.reduced(0.5f),12,1.5f);
}

// ─────────────────────────────────────────────────────────────────────────────
// WaveformDisplay
// ─────────────────────────────────────────────────────────────────────────────
WaveformDisplay::WaveformDisplay(SuperNovaPadProcessor& p): proc(p) { startTimerHz(30); }
WaveformDisplay::~WaveformDisplay() { stopTimer(); }

void WaveformDisplay::paint(juce::Graphics& g)
{
    auto b = getLocalBounds().toFloat();
    g.setColour(juce::Colour(0xFF0d0d1e)); g.fillRoundedRectangle(b,8);

    const int N = SuperNovaPadProcessor::kWaveSize;
    const float mid = b.getCentreY();
    juce::Path path;
    for(int i=0;i<N;++i){
        const float x = b.getX()+float(i)/float(N-1)*b.getWidth();
        const float y = mid - proc.waveRing[i].load()*mid*0.85f;
        if(i==0) path.startNewSubPath(x,y); else path.lineTo(x,y);
    }
    g.setColour(accent.withAlpha(0.22f)); g.strokePath(path,juce::PathStrokeType(5));
    g.setColour(accent.withAlpha(0.7f));  g.strokePath(path,juce::PathStrokeType(1.5f));
    g.setColour(accent.withAlpha(0.35f)); g.drawRoundedRectangle(b.reduced(0.5f),8,1);
}

// ─────────────────────────────────────────────────────────────────────────────
// LabelledKnob
// ─────────────────────────────────────────────────────────────────────────────
LabelledKnob::LabelledKnob(const juce::String& pid, const juce::String& lbl,
                             SuperNovaPadProcessor& proc, OmniLookAndFeel& laf)
{
    slider.setSliderStyle(juce::Slider::RotaryVerticalDrag);
    slider.setTextBoxStyle(juce::Slider::NoTextBox,false,0,0);
    slider.setLookAndFeel(&laf);
    addAndMakeVisible(slider);

    label.setText(lbl,juce::dontSendNotification);
    label.setJustificationType(juce::Justification::centred);
    label.setFont(juce::Font(9.0f,juce::Font::bold));
    label.setColour(juce::Label::textColourId,juce::Colours::white.withAlpha(0.45f));
    addAndMakeVisible(label);

    attachment = std::make_unique<juce::AudioProcessorValueTreeState::SliderAttachment>
                    (proc.apvts, pid, slider);
}

void LabelledKnob::resized()
{
    auto b = getLocalBounds();
    label.setBounds(b.removeFromBottom(16));
    slider.setBounds(b);
}

// ─────────────────────────────────────────────────────────────────────────────
// SuperNovaPadEditor
// ─────────────────────────────────────────────────────────────────────────────
SuperNovaPadEditor::SuperNovaPadEditor(SuperNovaPadProcessor& p)
    : AudioProcessorEditor(&p), proc(p),
      presets(Presets::all()),
      xyPad(p.xyX, p.xyY, juce::Colour(0xFF8B5CF6)),
      waveDisplay(p)
{
    setLookAndFeel(&laf);
    setSize(kW, kH);

    // Preset combo
    for(int i=0;i<int(presets.size());++i)
        presetBox.addItem(presets[i].name, i+1);
    presetBox.setSelectedId(p.currentPresetIndex+1, juce::dontSendNotification);
    presetBox.addListener(this);
    addAndMakeVisible(presetBox);

    // Title
    titleLabel.setText("SUPERNOVA PAD",juce::dontSendNotification);
    titleLabel.setFont(juce::Font(14,juce::Font::bold));
    titleLabel.setColour(juce::Label::textColourId,juce::Colours::white.withAlpha(0.7f));
    titleLabel.setJustificationType(juce::Justification::centredLeft);
    addAndMakeVisible(titleLabel);

    // MIDI hint
    midiHintLabel.setText("MOD=Leslie/LFO  |  CC74=Filter  |  CC11=Expression",
                           juce::dontSendNotification);
    midiHintLabel.setFont(juce::Font(8.5f));
    midiHintLabel.setColour(juce::Label::textColourId,juce::Colours::white.withAlpha(0.25f));
    midiHintLabel.setJustificationType(juce::Justification::centredRight);
    addAndMakeVisible(midiHintLabel);

    addAndMakeVisible(xyPad);
    addAndMakeVisible(waveDisplay);

    // Section labels
    auto sec=[&](juce::Label& l, const char* t){
        l.setText(t,juce::dontSendNotification);
        l.setFont(juce::Font(8.5f,juce::Font::bold));
        l.setColour(juce::Label::textColourId,juce::Colours::white.withAlpha(0.28f));
        l.setJustificationType(juce::Justification::centredLeft);
        addAndMakeVisible(l);
    };
    sec(secFX,      "EFFECTS");
    sec(secEnv,     "ENVELOPE");
    sec(secOrgan,   "ORGAN / HAMMOND");
    sec(secLFO,     "LFO");
    sec(secOsc,     "OSCILLATOR");
    sec(secTexture, "TEXTURE");

    // Knobs
    auto mk=[&](std::unique_ptr<LabelledKnob>& k, const char* id, const char* lbl){
        k = std::make_unique<LabelledKnob>(id, lbl, proc, laf);
        addAndMakeVisible(*k);
    };
    mk(knobReverb,     "reverb",      "REVERB");
    mk(knobDelayMix,   "delay_mix",   "DELAY");
    mk(knobDelayTime,  "delay_time",  "D.TIME");
    mk(knobCutoff,     "cutoff",      "CUTOFF");
    mk(knobResonance,  "resonance",   "RESON");
    mk(knobAttack,     "attack",      "ATK");
    mk(knobDecay,      "decay",       "DEC");
    mk(knobSustain,    "sustain",     "SUS");
    mk(knobRelease,    "release",     "REL");
    mk(knobDistortion, "distortion",  "DRIVE");
    mk(knobShimmer,    "shimmer",     "SHIMMER");
    mk(knobTremulant,  "tremulant",   "TREMUL");
    mk(knobLfoRate,    "lfo_rate",    "RATE");
    mk(knobLfoDepth,   "lfo_depth",   "DEPTH");
    mk(knobOscMix,     "osc_mix",     "MIX");
    mk(knobDetune,     "osc2_detune", "DETUNE");
    mk(knobLofi,       "lofi",        "LO-FI");
    mk(knobVinyl,      "vinyl",       "VINYL");
    mk(knobBrokenTape, "broken_tape", "B.TAPE");
    mk(knobGrit,       "grit",        "GRIT");
    mk(knobDoubler,    "doubler",      "DOUBLER");

    updateForPreset(presets[p.currentPresetIndex]);
}

SuperNovaPadEditor::~SuperNovaPadEditor() { setLookAndFeel(nullptr); }

void SuperNovaPadEditor::comboBoxChanged(juce::ComboBox* box)
{
    if(box == &presetBox){
        const int idx = presetBox.getSelectedId()-1;
        proc.loadPreset(idx);
        updateForPreset(presets[idx]);
    }
}

void SuperNovaPadEditor::updateForPreset(const SynthPreset& p)
{
    laf.accentColour = p.color;
    xyPad.setAccentColour(p.color);
    waveDisplay.setAccentColour(p.color);

    const bool isOrg = (p.voiceMode == VoiceMode::OrganChurch ||
                        p.voiceMode == VoiceMode::HammondB3);
    const bool isSyn = !isOrg;

    knobAttack->setVisible(isSyn);   knobDecay->setVisible(isSyn);
    knobSustain->setVisible(isSyn);  knobRelease->setVisible(isSyn);
    knobOscMix->setVisible(isSyn);   knobDetune->setVisible(isSyn);
    secEnv.setVisible(isSyn);        secOsc.setVisible(isSyn);

    knobDistortion->setVisible(isOrg);
    knobShimmer->setVisible(isOrg);
    knobTremulant->setVisible(isOrg);
    secOrgan.setVisible(isOrg);

    secLFO.setVisible(isSyn);
    knobLfoRate->setVisible(isSyn);
    knobLfoDepth->setVisible(isSyn);

    repaint();
}

void SuperNovaPadEditor::paint(juce::Graphics& g)
{
    g.setGradientFill(juce::ColourGradient(
        juce::Colour(0xFF0f0f20),0,0,
        juce::Colour(0xFF070710),float(kW),float(kH),false));
    g.fillAll();
    // Divider
    g.setColour(juce::Colours::white.withAlpha(0.05f));
    g.drawLine(448,50,448,float(kH-70),1);
}

void SuperNovaPadEditor::resized()
{
    const int padL=12,padT=50,xyW=428,xyH=390;
    const int ctrlX=458, ctrlW=kW-ctrlX-12;
    const int kS=58;  // knob size

    titleLabel.setBounds(12,8,260,34);
    midiHintLabel.setBounds(kW-400,8,388,34);
    presetBox.setBounds(kW-220,15,208,26);

    xyPad.setBounds(padL,padT,xyW,xyH);
    waveDisplay.setBounds(padL,padT+xyH+8,xyW,kH-padT-xyH-20);

    int ry = padT+4;

    auto row=[&](std::initializer_list<LabelledKnob*> knobs){
        int kx=ctrlX;
        for(auto* k:knobs){ k->setBounds(kx,ry,kS,kS+16); kx+=kS+4; }
        ry+=kS+22;
    };

    // Row 1 – effects
    secFX.setBounds(ctrlX,ry,ctrlW,14); ry+=16;
    row({knobReverb.get(),knobDelayMix.get(),knobDelayTime.get(),
         knobCutoff.get(),knobResonance.get()});

    // Row 2 – envelope or organ (visibility toggled)
    secEnv.setBounds(ctrlX,ry,ctrlW,14);
    secOrgan.setBounds(ctrlX,ry,ctrlW,14); ry+=16;
    row({knobAttack.get(),knobDecay.get(),knobSustain.get(),knobRelease.get()});
    // organ knobs occupy same area
    {
        int kx=ctrlX;
        for(auto* k:{knobDistortion.get(),knobShimmer.get(),knobTremulant.get()}){
            k->setBounds(kx,ry-kS-22,kS,kS+16); kx+=kS+4;
        }
    }

    // Row 3 – LFO + osc
    secLFO.setBounds(ctrlX,ry,ctrlW,14); ry+=16;
    row({knobLfoRate.get(),knobLfoDepth.get(),knobOscMix.get(),knobDetune.get()});

    // Row 4 – texture effects (always shown)
    secTexture.setBounds(ctrlX,ry,ctrlW,14); ry+=16;
    row({knobLofi.get(),knobVinyl.get(),knobBrokenTape.get(),
         knobGrit.get(),knobDoubler.get()});
}
