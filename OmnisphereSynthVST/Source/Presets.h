#pragma once
#include <JuceHeader.h>
#include <vector>

enum class Waveform  { Sine, Triangle, Sawtooth, Square, Noise };
enum class LFOTarget { Pitch, Filter, Amplitude };
enum class VoiceMode { Synth, OrganChurch, HammondB3, Rhodes };

struct SynthPreset
{
    juce::String name;
    juce::Colour color { 0xFF8B5CF6 };
    VoiceMode    voiceMode = VoiceMode::Synth;

    // Oscillator (synth mode)
    Waveform osc1Wave   = Waveform::Sawtooth;
    Waveform osc2Wave   = Waveform::Sawtooth;
    float    osc2Detune = 7.0f;
    float    oscMix     = 0.5f;

    // Filter
    float filterCutoff    = 800.0f;
    float filterResonance = 0.3f;

    // Envelope
    float attack  = 1.2f;
    float decay   = 0.5f;
    float sustain = 0.8f;
    float release = 2.0f;

    // LFO
    float     lfoRate   = 0.3f;
    float     lfoDepth  = 0.15f;
    LFOTarget lfoTarget = LFOTarget::Filter;

    // Core effects
    float reverbMix   = 0.7f;
    float delayMix    = 0.3f;
    float delayTime   = 0.375f;

    // Organ / Hammond
    float tremulantDepth = 0.0f;   // 0–1

    // New texture effects
    float lofiAmount    = 0.0f;   // 0–1
    float vinylAmount   = 0.0f;   // 0–1
    float brokenTape    = 0.0f;   // 0–1 (broken-tape delay amount)
    float gritAmount    = 0.0f;   // 0–1
    float doublerAmount = 0.0f;   // 0–1
    float shimmerAmount = 0.0f;   // 0–1
    float distortion    = 0.0f;   // 0–1 (organic soft-clip)
};

// ─────────────────────────────────────────────────────────────────────────────
namespace Presets
{
    inline std::vector<SynthPreset> all()
    {
        std::vector<SynthPreset> p;

        // 0 — Hammond B3 (classic rock 888000000 + fast Leslie)
        { SynthPreset s;
          s.name = "Hammond B3"; s.color = juce::Colour (0xFFD97706);
          s.voiceMode = VoiceMode::HammondB3;
          s.attack = 0.005f; s.decay = 0.0f; s.sustain = 1.0f; s.release = 0.05f;
          s.filterCutoff = 9000.0f;
          s.reverbMix = 0.35f; s.delayMix = 0.08f; s.delayTime = 0.4f;
          s.tremulantDepth = 0.0f;   // Leslie is always on; mod wheel toggles fast/slow
          s.gritAmount = 0.25f;
          p.push_back (s); }

        // 1 — Church Organ (pipe, slow tremulant)
        { SynthPreset s;
          s.name = "Church Organ"; s.color = juce::Colour (0xFFC4A35A);
          s.voiceMode = VoiceMode::OrganChurch;
          s.attack = 0.005f; s.decay = 0.0f; s.sustain = 1.0f; s.release = 0.04f;
          s.filterCutoff = 8000.0f;
          s.reverbMix = 0.65f; s.delayMix = 0.1f; s.delayTime = 0.5f;
          s.tremulantDepth = 0.25f;
          p.push_back (s); }

        // 2 — Rhodes Mk1 (70s electric piano)
        { SynthPreset s;
          s.name = "Rhodes Mk1"; s.color = juce::Colour (0xFF0EA5E9);
          s.voiceMode = VoiceMode::Rhodes;
          s.attack = 0.002f; s.decay = 2.0f; s.sustain = 0.0f; s.release = 0.5f;
          s.filterCutoff = 5000.0f; s.filterResonance = 0.1f;
          s.lfoRate = 5.0f; s.lfoDepth = 0.12f; s.lfoTarget = LFOTarget::Amplitude;
          s.reverbMix = 0.45f; s.delayMix = 0.2f; s.delayTime = 0.333f;
          s.doublerAmount = 0.3f;
          p.push_back (s); }

        // 3 — Mystic Pad
        { SynthPreset s;
          s.name = "Mystic Pad"; s.color = juce::Colour (0xFF8B5CF6);
          s.osc1Wave = Waveform::Sawtooth; s.osc2Wave = Waveform::Sawtooth;
          s.osc2Detune = 7.0f; s.oscMix = 0.5f;
          s.filterCutoff = 800.0f; s.filterResonance = 0.3f;
          s.attack = 1.2f; s.decay = 0.5f; s.sustain = 0.8f; s.release = 2.0f;
          s.lfoRate = 0.3f; s.lfoDepth = 0.15f; s.lfoTarget = LFOTarget::Filter;
          s.reverbMix = 0.7f; s.delayMix = 0.3f; s.delayTime = 0.375f;
          s.shimmerAmount = 0.2f;
          p.push_back (s); }

        // 4 — Dark Matter
        { SynthPreset s;
          s.name = "Dark Matter"; s.color = juce::Colour (0xFF3B82F6);
          s.osc1Wave = Waveform::Square; s.osc2Wave = Waveform::Sawtooth;
          s.osc2Detune = -5.0f; s.oscMix = 0.4f;
          s.filterCutoff = 400.0f; s.filterResonance = 0.6f;
          s.attack = 0.05f; s.decay = 0.8f; s.sustain = 0.5f; s.release = 1.5f;
          s.lfoRate = 0.8f; s.lfoDepth = 0.2f; s.lfoTarget = LFOTarget::Pitch;
          s.reverbMix = 0.5f; s.delayMix = 0.4f; s.delayTime = 0.5f;
          s.gritAmount = 0.15f;
          p.push_back (s); }

        // 5 — Celestial
        { SynthPreset s;
          s.name = "Celestial"; s.color = juce::Colour (0xFF06B6D4);
          s.osc1Wave = Waveform::Sine; s.osc2Wave = Waveform::Triangle;
          s.osc2Detune = 12.0f; s.oscMix = 0.6f;
          s.filterCutoff = 2000.0f; s.filterResonance = 0.1f;
          s.attack = 2.0f; s.decay = 1.0f; s.sustain = 0.9f; s.release = 3.0f;
          s.lfoRate = 0.15f; s.lfoDepth = 0.1f; s.lfoTarget = LFOTarget::Amplitude;
          s.reverbMix = 0.85f; s.delayMix = 0.2f; s.delayTime = 0.666f;
          s.shimmerAmount = 0.45f; s.doublerAmount = 0.4f;
          p.push_back (s); }

        // 6 — Pulse Drive
        { SynthPreset s;
          s.name = "Pulse Drive"; s.color = juce::Colour (0xFFF59E0B);
          s.osc1Wave = Waveform::Square; s.osc2Wave = Waveform::Square;
          s.filterCutoff = 1200.0f; s.filterResonance = 0.8f;
          s.attack = 0.01f; s.decay = 0.3f; s.sustain = 0.6f; s.release = 0.4f;
          s.lfoRate = 4.0f; s.lfoDepth = 0.4f; s.lfoTarget = LFOTarget::Filter;
          s.reverbMix = 0.3f; s.delayMix = 0.5f; s.delayTime = 0.25f;
          s.distortion = 0.4f; s.gritAmount = 0.3f;
          p.push_back (s); }

        // 7 — Void Walker
        { SynthPreset s;
          s.name = "Void Walker"; s.color = juce::Colour (0xFF059669);
          s.osc1Wave = Waveform::Noise; s.osc2Wave = Waveform::Sawtooth;
          s.osc2Detune = 2.0f; s.oscMix = 0.3f;
          s.filterCutoff = 600.0f; s.filterResonance = 0.4f;
          s.attack = 0.8f; s.decay = 1.2f; s.sustain = 0.4f; s.release = 2.5f;
          s.lfoRate = 0.5f; s.lfoDepth = 0.25f; s.lfoTarget = LFOTarget::Pitch;
          s.reverbMix = 0.6f; s.delayMix = 0.35f; s.delayTime = 0.333f;
          s.lofiAmount = 0.2f; s.vinylAmount = 0.15f; s.brokenTape = 0.3f;
          p.push_back (s); }

        // 8 — Solar Wind
        { SynthPreset s;
          s.name = "Solar Wind"; s.color = juce::Colour (0xFFEF4444);
          s.osc1Wave = Waveform::Sawtooth; s.osc2Wave = Waveform::Triangle;
          s.osc2Detune = 3.0f; s.oscMix = 0.45f;
          s.filterCutoff = 1500.0f; s.filterResonance = 0.5f;
          s.attack = 0.4f; s.decay = 0.6f; s.sustain = 0.7f; s.release = 1.8f;
          s.lfoRate = 1.2f; s.lfoDepth = 0.3f; s.lfoTarget = LFOTarget::Filter;
          s.reverbMix = 0.55f; s.delayMix = 0.25f; s.delayTime = 0.4f;
          p.push_back (s); }

        return p;
    }
}
