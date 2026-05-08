#include "PluginProcessor.h"
#include "PluginEditor.h"
#include <cmath>

// ─────────────────────────────────────────────────────────────────────────────
// Parameter layout
// ─────────────────────────────────────────────────────────────────────────────
juce::AudioProcessorValueTreeState::ParameterLayout OmnisphereSynthProcessor::createLayout()
{
    using namespace juce;
    std::vector<std::unique_ptr<RangedAudioParameter>> params;

    auto add = [&](auto* p){ params.push_back(std::unique_ptr<RangedAudioParameter>(p)); };

    add (new AudioParameterInt   ("preset",     "Preset",       0, 6,    0));
    add (new AudioParameterFloat ("reverb",     "Reverb",       0.0f, 1.0f, 0.65f));
    add (new AudioParameterFloat ("delay_mix",  "Delay Mix",    0.0f, 1.0f, 0.3f));
    add (new AudioParameterFloat ("delay_time", "Delay Time",   0.05f, 2.0f, 0.375f));
    add (new AudioParameterFloat ("cutoff",     "Filter Cutoff",
                                  NormalisableRange<float>(20.f, 20000.f, 0.f, 0.3f), 800.f));
    add (new AudioParameterFloat ("resonance",  "Resonance",    0.0f, 0.95f, 0.3f));
    add (new AudioParameterFloat ("attack",     "Attack",       0.001f, 4.0f, 1.2f));
    add (new AudioParameterFloat ("decay",      "Decay",        0.001f, 4.0f, 0.5f));
    add (new AudioParameterFloat ("sustain",    "Sustain",      0.0f,   1.0f, 0.8f));
    add (new AudioParameterFloat ("release",    "Release",      0.01f,  8.0f, 2.0f));
    add (new AudioParameterFloat ("lfo_rate",   "LFO Rate",     0.05f, 10.0f, 0.3f));
    add (new AudioParameterFloat ("lfo_depth",  "LFO Depth",    0.0f,   1.0f, 0.15f));
    add (new AudioParameterFloat ("osc_mix",    "Osc Mix",      0.0f,   1.0f, 0.5f));
    add (new AudioParameterFloat ("osc2_detune","Osc2 Detune", -24.0f, 24.0f, 7.0f));
    add (new AudioParameterFloat ("distortion", "Distortion",   0.0f,   1.0f, 0.0f));
    add (new AudioParameterFloat ("shimmer",    "Shimmer",      0.0f,   1.0f, 0.0f));
    add (new AudioParameterFloat ("tremulant",  "Tremulant",    0.0f,   1.0f, 0.25f));

    return { params.begin(), params.end() };
}

// ─────────────────────────────────────────────────────────────────────────────
// Constructor / destructor
// ─────────────────────────────────────────────────────────────────────────────
OmnisphereSynthProcessor::OmnisphereSynthProcessor()
    : AudioProcessor (BusesProperties()
                      .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      apvts (*this, nullptr, "State", createLayout()),
      delayLine (kMaxDelaySamples)
{
    presets = Presets::all();
    for (auto& a : waveRing) a.store (0.0f);
    shiftReadB[0] = float (kGrainSize);
    shiftReadB[1] = float (kGrainSize);

    for (int i = 0; i < kMaxVoices; ++i) {
        auto* v = new OmniVoice();
        v->xyX = &xyX;
        v->xyY = &xyY;
        v->setPreset (presets[0]);
        synth.addVoice (v);
    }
    synth.addSound (new OmniSound());
}

OmnisphereSynthProcessor::~OmnisphereSynthProcessor() {}

// ─────────────────────────────────────────────────────────────────────────────
// Preset loading — updates voice parameters and effect defaults
// ─────────────────────────────────────────────────────────────────────────────
void OmnisphereSynthProcessor::loadPreset (int index)
{
    index = juce::jlimit (0, int (presets.size()) - 1, index);
    currentPresetIndex = index;
    const auto& p = presets[index];

    for (int i = 0; i < synth.getNumVoices(); ++i)
        if (auto* v = dynamic_cast<OmniVoice*> (synth.getVoice (i)))
            v->setPreset (p);

    // Push preset defaults into APVTS (will update knobs in editor)
    auto setValue = [&](const char* id, float v)
    {
        if (auto* param = apvts.getParameter (id))
            param->setValueNotifyingHost (param->convertTo0to1 (v));
    };

    setValue ("reverb",     p.reverbMix);
    setValue ("delay_mix",  p.delayMix);
    setValue ("delay_time", p.delayTime);
    setValue ("cutoff",     p.filterCutoff);
    setValue ("resonance",  p.filterResonance);
    setValue ("attack",     p.attack);
    setValue ("decay",      p.decay);
    setValue ("sustain",    p.sustain);
    setValue ("release",    p.release);
    setValue ("lfo_rate",   p.lfoRate);
    setValue ("lfo_depth",  p.lfoDepth);
    setValue ("osc_mix",    p.oscMix);
    setValue ("osc2_detune",p.osc2Detune);
    setValue ("distortion", p.distortionAmount);
    setValue ("shimmer",    p.shimmerAmount);
    setValue ("tremulant",  p.tremulantDepth);
}

// ─────────────────────────────────────────────────────────────────────────────
// Prepare
// ─────────────────────────────────────────────────────────────────────────────
void OmnisphereSynthProcessor::prepareToPlay (double sr, int blockSize)
{
    synth.setCurrentPlaybackSampleRate (sr);

    juce::dsp::ProcessSpec spec { sr, uint32_t (blockSize), 2 };
    mainReverb.prepare (spec);
    shimmerReverb.prepare (spec);
    delayLine.prepare (spec);

    juce::dsp::Reverb::Parameters shimP;
    shimP.roomSize  = 0.95f;
    shimP.damping   = 0.1f;
    shimP.wetLevel  = 0.8f;
    shimP.dryLevel  = 0.0f;
    shimP.width     = 1.0f;
    shimmerReverb.setParameters (shimP);

    shimmerBuf.setSize (2, blockSize);

    std::memset (shiftBuffer, 0, sizeof (shiftBuffer));
    shiftReadA[0] = shiftReadA[1] = 0.0f;
    shiftReadB[0] = shiftReadB[1] = float (kGrainSize);
    shiftWritePos = 0;

    applyEffectParams();
}

void OmnisphereSynthProcessor::releaseResources() {}

// ─────────────────────────────────────────────────────────────────────────────
// Update reverb / delay from APVTS each block
// ─────────────────────────────────────────────────────────────────────────────
void OmnisphereSynthProcessor::applyEffectParams()
{
    const float rev  = *apvts.getRawParameterValue ("reverb");
    juce::dsp::Reverb::Parameters rp;
    rp.roomSize  = 0.8f;
    rp.damping   = 0.4f;
    rp.wetLevel  = rev * 0.85f;
    rp.dryLevel  = 1.0f - rev * 0.4f;
    rp.width     = 1.0f;
    mainReverb.setParameters (rp);
}

// ─────────────────────────────────────────────────────────────────────────────
// Granular pitch-shifter (+1 octave) — per-channel, per-sample
// ─────────────────────────────────────────────────────────────────────────────
float OmnisphereSynthProcessor::pitchShiftSample (int ch, float input)
{
    // Write into ring buffer
    shiftBuffer[ch][shiftWritePos] = input;

    // Interpolated read from ring buffer
    auto lerp = [&](float pos) -> float {
        int i0 = int (pos) & (kShiftBuf - 1);
        int i1 = (i0 + 1) & (kShiftBuf - 1);
        float f = pos - std::floor (pos);
        return shiftBuffer[ch][i0] * (1.0f - f) + shiftBuffer[ch][i1] * f;
    };

    // Hann window for each grain
    const float pA = std::fmod (shiftReadA[ch], float (kGrainSize));
    const float pB = std::fmod (shiftReadB[ch], float (kGrainSize));
    const float wA = 0.5f * (1.0f - std::cos (2.0f * float (M_PI) * pA / float (kGrainSize)));
    const float wB = 0.5f * (1.0f - std::cos (2.0f * float (M_PI) * pB / float (kGrainSize)));

    const float out = lerp (shiftReadA[ch]) * wA + lerp (shiftReadB[ch]) * wB;

    // Advance read at 2× (= +1 octave), wrap within buffer
    shiftReadA[ch] = std::fmod (shiftReadA[ch] + 2.0f, float (kShiftBuf));
    shiftReadB[ch] = std::fmod (shiftReadB[ch] + 2.0f, float (kShiftBuf));

    // Advance write only once per channel 0 call (both channels share write pos)
    if (ch == 1)
        shiftWritePos = (shiftWritePos + 1) & (kShiftBuf - 1);

    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Process block
// ─────────────────────────────────────────────────────────────────────────────
void OmnisphereSynthProcessor::processBlock (juce::AudioBuffer<float>& buffer,
                                              juce::MidiBuffer& midi)
{
    juce::ScopedNoDenormals noDenormals;
    const int numSamples = buffer.getNumSamples();
    buffer.clear();

    // Sync voice params from APVTS every block
    {
        SynthPreset vp;
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

        const auto& basePreset = presets[currentPresetIndex];
        vp.isOrgan    = basePreset.isOrgan;
        vp.osc1Wave   = basePreset.osc1Wave;
        vp.osc2Wave   = basePreset.osc2Wave;
        vp.lfoTarget  = basePreset.lfoTarget;

        for (int i = 0; i < synth.getNumVoices(); ++i)
            if (auto* v = dynamic_cast<OmniVoice*> (synth.getVoice (i)))
                v->setPreset (vp);
    }

    // Render voices
    synth.renderNextBlock (buffer, midi, 0, numSamples);

    applyEffectParams();

    // ── Distortion (tanh soft-clip, organic) ──────────────────────────────────
    const float distAmt = *apvts.getRawParameterValue ("distortion");
    if (distAmt > 0.01f) {
        const float drive    = 1.0f + distAmt * 17.0f;
        const float invTanh  = 1.0f / std::tanh (drive);
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                d[i] = std::tanh (d[i] * drive) * invTanh;
        }
    }

    // ── Shimmer (parallel: long reverb → pitch shift +1 oct) ─────────────────
    const float shimAmt = *apvts.getRawParameterValue ("shimmer");
    if (shimAmt > 0.01f) {
        shimmerBuf.setSize (buffer.getNumChannels(), numSamples, false, false, true);
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
            shimmerBuf.copyFrom (ch, 0, buffer, ch, 0, numSamples);

        // Apply long plate reverb
        juce::dsp::AudioBlock<float> shimBlock (shimmerBuf);
        juce::dsp::ProcessContextReplacing<float> shimCtx (shimBlock);
        shimmerReverb.process (shimCtx);

        // Pitch-shift +1 octave and mix back
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* src = shimmerBuf.getReadPointer (ch);
            auto* dst = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i)
                dst[i] += pitchShiftSample (ch, src[i]) * shimAmt * 0.45f;
        }
    }

    // ── Main reverb ────────────────────────────────────────────────────────────
    {
        juce::dsp::AudioBlock<float> block (buffer);
        juce::dsp::ProcessContextReplacing<float> ctx (block);
        mainReverb.process (ctx);
    }

    // ── Delay ─────────────────────────────────────────────────────────────────
    {
        const float delMix  = *apvts.getRawParameterValue ("delay_mix");
        const float delTime = *apvts.getRawParameterValue ("delay_time");
        const int   delaySamples = int (delTime * getSampleRate());
        delayLine.setDelay (float (delaySamples));

        for (int ch = 0; ch < buffer.getNumChannels(); ++ch) {
            auto* d = buffer.getWritePointer (ch);
            for (int i = 0; i < numSamples; ++i) {
                const float delayed = delayLine.popSample (ch);
                delayLine.pushSample (ch, d[i] + delayed * 0.28f);
                d[i] += delayed * delMix;
            }
        }
    }

    // ── Feed waveform display ring ────────────────────────────────────────────
    const auto* mono = buffer.getReadPointer (0);
    int wPos = waveWritePos.load();
    for (int i = 0; i < numSamples; ++i) {
        waveRing[wPos % kWaveSize].store (mono[i]);
        ++wPos;
    }
    waveWritePos.store (wPos % kWaveSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// State persistence
// ─────────────────────────────────────────────────────────────────────────────
void OmnisphereSynthProcessor::getStateInformation (juce::MemoryBlock& data)
{
    auto state = apvts.copyState();
    state.setProperty ("presetIndex", currentPresetIndex, nullptr);
    std::unique_ptr<juce::XmlElement> xml (state.createXml());
    copyXmlToBinary (*xml, data);
}

void OmnisphereSynthProcessor::setStateInformation (const void* data, int size)
{
    std::unique_ptr<juce::XmlElement> xml (getXmlFromBinary (data, size));
    if (xml && xml->hasTagName (apvts.state.getType())) {
        auto tree = juce::ValueTree::fromXml (*xml);
        apvts.replaceState (tree);
        loadPreset (tree.getProperty ("presetIndex", 0));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
juce::AudioProcessorEditor* OmnisphereSynthProcessor::createEditor()
{
    return new OmnisphereSynthEditor (*this);
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new OmnisphereSynthProcessor();
}
