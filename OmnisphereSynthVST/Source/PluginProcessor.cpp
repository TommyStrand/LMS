#include "PluginProcessor.h"
#include "PluginEditor.h"
#include <cmath>

// ─────────────────────────────────────────────────────────────────────────────
// Parameter layout
// ─────────────────────────────────────────────────────────────────────────────
juce::AudioProcessorValueTreeState::ParameterLayout
SuperNovaPadProcessor::createLayout()
{
    using namespace juce;
    std::vector<std::unique_ptr<RangedAudioParameter>> p;
    auto add = [&](auto* param){ p.push_back(std::unique_ptr<RangedAudioParameter>(param)); };

    add(new AudioParameterInt   ("preset",      "Preset",           0, 8,      0));
    add(new AudioParameterFloat ("reverb",      "Reverb",           0.f, 1.f,  0.65f));
    add(new AudioParameterFloat ("delay_mix",   "Delay Mix",        0.f, 1.f,  0.3f));
    add(new AudioParameterFloat ("delay_time",  "Delay Time",       0.05f,2.f, 0.375f));
    add(new AudioParameterFloat ("cutoff",      "Filter Cutoff",
        NormalisableRange<float>(20.f,20000.f,0.f,0.3f), 800.f));
    add(new AudioParameterFloat ("resonance",   "Resonance",        0.f, 0.95f,0.3f));
    add(new AudioParameterFloat ("attack",      "Attack",           0.001f,4.f,1.2f));
    add(new AudioParameterFloat ("decay",       "Decay",            0.001f,4.f,0.5f));
    add(new AudioParameterFloat ("sustain",     "Sustain",          0.f,  1.f, 0.8f));
    add(new AudioParameterFloat ("release",     "Release",          0.01f,8.f, 2.0f));
    add(new AudioParameterFloat ("lfo_rate",    "LFO Rate",         0.05f,10.f,0.3f));
    add(new AudioParameterFloat ("lfo_depth",   "LFO Depth",        0.f,  1.f, 0.15f));
    add(new AudioParameterFloat ("osc_mix",     "Osc Mix",          0.f,  1.f, 0.5f));
    add(new AudioParameterFloat ("osc2_detune", "Osc2 Detune",     -24.f,24.f, 7.0f));
    add(new AudioParameterFloat ("distortion",  "Distortion",       0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("shimmer",     "Shimmer",          0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("tremulant",   "Tremulant",        0.f,  1.f, 0.25f));
    // New texture effects
    add(new AudioParameterFloat ("lofi",        "Lo-Fi",            0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("vinyl",       "Vinyl",            0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("broken_tape", "Broken Tape",      0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("grit",        "Grit",             0.f,  1.f, 0.0f));
    add(new AudioParameterFloat ("doubler",     "Doubler",          0.f,  1.f, 0.0f));

    return { p.begin(), p.end() };
}

// ─────────────────────────────────────────────────────────────────────────────
SuperNovaPadProcessor::SuperNovaPadProcessor()
    : AudioProcessor (BusesProperties()
                      .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      apvts (*this, nullptr, "State", createLayout())
{
    presets = Presets::all();
    for (auto& a : waveRing) a.store (0.0f);
    shiftReadB[0] = shiftReadB[1] = float (kGrainSize);

    for (int i = 0; i < kMaxVoices; ++i) {
        auto* v = new OmniVoice();
        v->xyX           = &xyX;
        v->xyY           = &xyY;
        v->modWheelPtr   = &midiModWheel;
        v->expressionPtr = &midiExpression;
        v->leslieSpeedPtr= &midiLeslieSpd;
        v->setPreset (presets[0]);
        synth.addVoice (v);
    }
    synth.addSound (new OmniSound());
}

SuperNovaPadProcessor::~SuperNovaPadProcessor() {}

// ─────────────────────────────────────────────────────────────────────────────
void SuperNovaPadProcessor::loadPreset (int index)
{
    index = juce::jlimit (0, int (presets.size()) - 1, index);
    currentPresetIndex = index;
    const auto& pr = presets[index];

    for (int i = 0; i < synth.getNumVoices(); ++i)
        if (auto* v = dynamic_cast<OmniVoice*> (synth.getVoice (i)))
            v->setPreset (pr);

    auto set = [&](const char* id, float val) {
        if (auto* param = apvts.getParameter (id))
            param->setValueNotifyingHost (param->convertTo0to1 (val));
    };
    set ("reverb",     pr.reverbMix);
    set ("delay_mix",  pr.delayMix);
    set ("delay_time", pr.delayTime);
    set ("cutoff",     pr.filterCutoff);
    set ("resonance",  pr.filterResonance);
    set ("attack",     pr.attack);
    set ("decay",      pr.decay);
    set ("sustain",    pr.sustain);
    set ("release",    pr.release);
    set ("lfo_rate",   pr.lfoRate);
    set ("lfo_depth",  pr.lfoDepth);
    set ("osc_mix",    pr.oscMix);
    set ("osc2_detune",pr.osc2Detune);
    set ("distortion", pr.distortion);
    set ("shimmer",    pr.shimmerAmount);
    set ("tremulant",  pr.tremulantDepth);
    set ("lofi",       pr.lofiAmount);
    set ("vinyl",      pr.vinylAmount);
    set ("broken_tape",pr.brokenTape);
    set ("grit",       pr.gritAmount);
    set ("doubler",    pr.doublerAmount);
}

// ─────────────────────────────────────────────────────────────────────────────
void SuperNovaPadProcessor::prepareToPlay (double sr, int blockSize)
{
    synth.setCurrentPlaybackSampleRate (sr);

    juce::dsp::ProcessSpec spec { sr, uint32_t (blockSize), 2 };
    mainReverb.prepare (spec);
    shimmerReverb.prepare (spec);

    juce::dsp::Reverb::Parameters shimP;
    shimP.roomSize = 0.95f; shimP.damping = 0.1f;
    shimP.wetLevel = 0.8f;  shimP.dryLevel = 0.0f; shimP.width = 1.0f;
    shimmerReverb.setParameters (shimP);

    shimBuf.setSize (2, blockSize);

    std::memset (shiftBuffer, 0, sizeof (shiftBuffer));
    shiftReadA[0] = shiftReadA[1] = 0.0f;
    shiftReadB[0] = shiftReadB[1] = float (kGrainSize);
    shiftWrite = 0;

    for (int ch = 0; ch < 2; ++ch) {
        lofi[ch].reset();
        vinyl[ch].prepare (sr);  vinyl[ch].reset();
        tapeDelay[ch].prepare (sr, blockSize); // prepare sets internal buffer
    }
    doubler.prepare (sr);  doubler.reset();

    applyReverbParams();
}

void SuperNovaPadProcessor::releaseResources() {}

void SuperNovaPadProcessor::applyReverbParams()
{
    const float rev = *apvts.getRawParameterValue ("reverb");
    juce::dsp::Reverb::Parameters rp;
    rp.roomSize = 0.8f; rp.damping = 0.4f;
    rp.wetLevel = rev * 0.85f; rp.dryLevel = 1.0f - rev * 0.4f; rp.width = 1.0f;
    mainReverb.setParameters (rp);
}

// ─────────────────────────────────────────────────────────────────────────────
// Granular pitch-shift (+1 oct) for shimmer
// ─────────────────────────────────────────────────────────────────────────────
float SuperNovaPadProcessor::pitchShiftSample (int ch, float in)
{
    shiftBuffer[ch][shiftWrite & (kShiftBuf - 1)] = in;

    auto lerp = [&](float pos) {
        int i0 = int(pos) & (kShiftBuf - 1);
        int i1 = (i0 + 1) & (kShiftBuf - 1);
        float f = pos - std::floor (pos);
        return shiftBuffer[ch][i0] * (1.0f - f) + shiftBuffer[ch][i1] * f;
    };

    const float pA = std::fmod (shiftReadA[ch], float (kGrainSize));
    const float pB = std::fmod (shiftReadB[ch], float (kGrainSize));
    const float wA = 0.5f * (1.0f - std::cos (6.2832f * pA / float (kGrainSize)));
    const float wB = 0.5f * (1.0f - std::cos (6.2832f * pB / float (kGrainSize)));

    const float out = lerp (shiftReadA[ch]) * wA + lerp (shiftReadB[ch]) * wB;

    shiftReadA[ch] = std::fmod (shiftReadA[ch] + 2.0f, float (kShiftBuf));
    shiftReadB[ch] = std::fmod (shiftReadB[ch] + 2.0f, float (kShiftBuf));
    if (ch == 1) shiftWrite = (shiftWrite + 1) & (kShiftBuf - 1);

    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// processBlock
// ─────────────────────────────────────────────────────────────────────────────
void SuperNovaPadProcessor::processBlock (juce::AudioBuffer<float>& buffer,
                                              juce::MidiBuffer& midi)
{
    juce::ScopedNoDenormals noDenormals;
    const int numSamples = buffer.getNumSamples();
    buffer.clear();

    // ── MIDI CC extraction (before synth renders) ─────────────────────────────
    for (const auto& meta : midi) {
        const auto m = meta.getMessage();
        if (m.isController()) {
            const float v = float (m.getControllerValue()) / 127.0f;
            switch (m.getControllerNumber()) {
                case 1:  midiModWheel.store (v); break;    // mod wheel
                case 3:  midiLeslieSpd.store (v > 0.5f ? 1.0f : 0.0f); break; // Leslie
                case 11: midiExpression.store (v); break;  // expression
                case 74: {  // brightness → filter cutoff
                    // map 0-1 → 100-16000 Hz (log)
                    const float hz = 100.0f * std::pow (160.0f, v);
                    if (auto* param = apvts.getParameter ("cutoff"))
                        param->setValueNotifyingHost (param->convertTo0to1 (hz));
                    break;
                }
                default: break;
            }
        }
    }

    // ── Sync voice params from APVTS ──────────────────────────────────────────
    {
        const auto& base = presets[currentPresetIndex];
        SynthPreset vp   = base;
        vp.filterCutoff    = *apvts.getRawParameterValue ("cutoff");
        vp.filterResonance = *apvts.getRawParameterValue ("resonance");
        vp.attack          = *apvts.getRawParameterValue ("attack");
        vp.decay           = *apvts.getRawParameterValue ("decay");
        vp.sustain         = *apvts.getRawParameterValue ("sustain");
        vp.release         = *apvts.getRawParameterValue ("release");
        vp.lfoRate         = *apvts.getRawParameterValue ("lfo_rate");
        vp.lfoDepth        = *apvts.getRawParameterValue ("lfo_depth");
        vp.oscMix          = *apvts.getRawParameterValue ("osc_mix");
        vp.osc2Detune      = *apvts.getRawParameterValue ("osc2_detune");
        vp.tremulantDepth  = *apvts.getRawParameterValue ("tremulant");

        for (int i = 0; i < synth.getNumVoices(); ++i)
            if (auto* v = dynamic_cast<OmniVoice*> (synth.getVoice (i)))
                v->setPreset (vp);
    }

    // ── Render voices ────────────────────────────────────────────────────────
    synth.renderNextBlock (buffer, midi, 0, numSamples);

    applyReverbParams();

    // Read effect amounts once per block
    const float distAmt  = *apvts.getRawParameterValue ("distortion");
    const float shimAmt  = *apvts.getRawParameterValue ("shimmer");
    const float lofiAmt  = *apvts.getRawParameterValue ("lofi");
    const float vinylAmt = *apvts.getRawParameterValue ("vinyl");
    const float tapeAmt  = *apvts.getRawParameterValue ("broken_tape");
    const float gritAmt  = *apvts.getRawParameterValue ("grit");
    const float dblAmt   = *apvts.getRawParameterValue ("doubler");
    const float delMix   = *apvts.getRawParameterValue ("delay_mix");
    const float delTime  = *apvts.getRawParameterValue ("delay_time");
    const float dt       = 1.0f / float (getSampleRate());

    // ── Grit (asymmetric saturation) ─────────────────────────────────────────
    if (gritAmt > 0.01f) {
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                d[i] = grit.process (d[i], gritAmt);
        }
    }

    // ── Organic distortion (tanh soft-clip) ───────────────────────────────────
    if (distAmt > 0.01f) {
        const float drive   = 1.0f + distAmt * 17.0f;
        const float invTanh = 1.0f / std::tanh (drive);
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                d[i] = std::tanh (d[i] * drive) * invTanh;
        }
    }

    // ── Lo-fi (bit/rate crush) ───────────────────────────────────────────────
    if (lofiAmt > 0.01f) {
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                d[i] = lofi[ch].process (d[i], lofiAmt);
        }
    }

    // ── Vinyl (wow/flutter/crackle) ──────────────────────────────────────────
    if (vinylAmt > 0.01f) {
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                d[i] = vinyl[ch].process (d[i], vinylAmt);
        }
    }

    // ── Shimmer ───────────────────────────────────────────────────────────────
    if (shimAmt > 0.01f) {
        shimBuf.setSize (buffer.getNumChannels(), numSamples, false, false, true);
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
            shimBuf.copyFrom (ch, 0, buffer, ch, 0, numSamples);

        juce::dsp::AudioBlock<float> sb (shimBuf);
        shimmerReverb.process (juce::dsp::ProcessContextReplacing<float> (sb));

        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* dst = buffer.getWritePointer (ch);
            auto* src = shimBuf.getReadPointer (ch);
            for (int i = 0; i < numSamples; ++i)
                dst[i] += pitchShiftSample (ch, src[i]) * shimAmt * 0.45f;
        }
    }

    // ── Main reverb ───────────────────────────────────────────────────────────
    {
        juce::dsp::AudioBlock<float> blk (buffer);
        mainReverb.process (juce::dsp::ProcessContextReplacing<float> (blk));
    }

    // ── Broken tape delay ─────────────────────────────────────────────────────
    for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
        auto* d = buffer.getWritePointer (ch);
        for (int i = 0; i < numSamples; ++i)
            d[i] = tapeDelay[ch].process (d[i], delTime, 0.28f, delMix, tapeAmt);
    }

    // ── Doubler (stereo widener) ──────────────────────────────────────────────
    if (dblAmt > 0.01f && buffer.getNumChannels() >= 2) {
        auto* L = buffer.getWritePointer (0);
        auto* R = buffer.getWritePointer (1);
        for (int i = 0; i < numSamples; ++i) {
            const float mono = (L[i] + R[i]) * 0.5f;
            auto out = doubler.process (mono, dblAmt, dt);
            L[i] = out.L;
            R[i] = out.R;
        }
    }

    // ── Waveform display ring ─────────────────────────────────────────────────
    const auto* mono = buffer.getReadPointer (0);
    int wp = waveWritePos.load();
    for (int i = 0; i < numSamples; ++i) {
        waveRing[wp % kWaveSize].store (mono[i]);
        ++wp;
    }
    waveWritePos.store (wp % kWaveSize);
}

// ─────────────────────────────────────────────────────────────────────────────
void SuperNovaPadProcessor::getStateInformation (juce::MemoryBlock& data)
{
    auto state = apvts.copyState();
    state.setProperty ("presetIndex", currentPresetIndex, nullptr);
    std::unique_ptr<juce::XmlElement> xml (state.createXml());
    copyXmlToBinary (*xml, data);
}

void SuperNovaPadProcessor::setStateInformation (const void* data, int size)
{
    std::unique_ptr<juce::XmlElement> xml (getXmlFromBinary (data, size));
    if (xml && xml->hasTagName (apvts.state.getType())) {
        auto tree = juce::ValueTree::fromXml (*xml);
        apvts.replaceState (tree);
        loadPreset ((int) tree.getProperty ("presetIndex", 0));
    }
}

juce::AudioProcessorEditor* SuperNovaPadProcessor::createEditor()
{
    return new SuperNovaPadEditor (*this);
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new SuperNovaPadProcessor();
}
