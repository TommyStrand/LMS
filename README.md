# SuperNovaPad

A polyphonic synthesizer in two forms: an **iOS touch app** and a **JUCE-based VST3 / AU / Standalone plugin** for macOS.

---

## iOS App

Touch the pad to play. Each finger is an independent voice. Slide horizontally to change filter brightness, vertically to change modulation depth.

### Voice Engines

| Preset | Engine | Character |
|--------|--------|-----------|
| Hammond B3 | 9-partial additive + Leslie rotary | Classic rock organ, slow/fast rotary |
| Rhodes Mk1 | 2-operator FM | Warm electric piano, velocity-sensitive |
| Church Organ | 9-partial additive + tremulant | Cathedral pipe organ |
| Mystic Pad | Dual sawtooth subtractive | Lush detuned pad |
| Dark Matter | Square + sawtooth subtractive | Heavy filtered bass |
| Celestial | Sine + triangle subtractive | Airy evolving pad |
| Pulse Drive | Dual square subtractive | Aggressive resonant lead |
| Void Walker | Noise + sawtooth subtractive | Evolving texture |
| Solar Wind | Sawtooth + triangle subtractive | Moving filter sweep |

### Texture Effects

Applied per-sample in this order:

```
Grit → Lo-Fi → Vinyl → Broken Tape Delay → Doubler
```

| Effect | Description |
|--------|-------------|
| **Grit** | Asymmetric tube waveshaper — adds even harmonics |
| **Lo-Fi** | Bit-depth crush (16→4 bit) + sample-rate decimation |
| **Vinyl** | Wow/flutter pitch drift + random crackle |
| **Broken Tape** | Wow/flutter on delay time + dropouts + tape saturation |
| **Doubler** | Detuned stereo widener — two delayed copies panned L/R |

### Classic Effects

Reverb · Delay · Distortion · Shimmer (plate reverb into +1 octave pitch shift)

---

## VST3 / AU Plugin

Built with [JUCE 7](https://juce.com) — auto-downloaded via CMake FetchContent. No manual JUCE install needed.

### Building

```bash
cd OmnisphereSynthVST
cmake -S . -B build -G Xcode
cmake --build build --config Release
```

Or use the build script:

```bash
./build.sh          # Release
./build.sh Debug    # Debug
```

Plugin formats built simultaneously: **VST3**, **AU**, **Standalone**.

### MIDI CC Map

| CC | Parameter |
|----|-----------|
| CC1 | Mod Wheel — LFO depth / Leslie speed blend |
| CC3 | Leslie Speed — 0 = slow chorale, 127 = fast tremolo |
| CC11 | Expression — volume scaling |
| CC74 | Filter Cutoff — 100 Hz to 16 kHz (logarithmic) |

### All Parameters (DAW Automation)

`voice_mode` · `osc1` · `osc2` · `detune` · `osc_mix` · `filter_cutoff` · `filter_res` · `attack` · `decay` · `sustain` · `release` · `lfo_rate` · `lfo_depth` · `reverb` · `delay` · `delay_time` · `shimmer` · `distortion` · `tremulant` · `lofi` · `vinyl` · `broken_tape` · `grit` · `doubler`

---

## macOS Installer

Creates a signed `.pkg` + compressed `.dmg` ready to distribute.

```bash
cd OmnisphereSynthVST
./create_installer.sh              # build from source then package
./create_installer.sh --skip-build # package an existing build/
```

Output in `dist/`:
- `SuperNovaPad-1.0.0.pkg` — installer with VST3 / AU / Standalone options
- `SuperNovaPad-1.0.0.dmg` — disk image ready to share

Install locations:

| Format | Path |
|--------|------|
| VST3 | `/Library/Audio/Plug-Ins/VST3/` |
| AU | `/Library/Audio/Plug-Ins/Components/` |
| Standalone | `/Applications/` |

---

## Project Structure

```
OmnisphereSynth/          iOS app (Swift / SwiftUI / AVFoundation)
  Audio/
    AnyVoice.swift          Voice protocol
    AudioEngine.swift       AVAudioEngine graph + effects routing
    SynthVoice.swift        Dual-oscillator subtractive synth
    OrganVoice.swift        Church pipe organ (additive)
    HammondVoice.swift      Hammond B3 + Leslie rotary speaker
    RhodesVoice.swift       Rhodes Mk1 (2-op FM)
    EffectsProcessor.swift  Lo-Fi, Vinyl, Grit, Doubler, Broken Tape
  Models/
    SynthPreset.swift       Preset definitions + VoiceMode enum
  Views/
    XYPadView.swift         Multi-touch XY performance pad
    ControlsView.swift      Knobs, ADSR sliders, Texture row
    VisualizerView.swift    Real-time waveform display
    PresetSelectorView.swift Preset carousel

OmnisphereSynthVST/       VST3/AU plugin (C++ / JUCE)
  Source/
    PluginProcessor.cpp     Audio processing + MIDI CC routing
    PluginEditor.cpp        Plugin UI (860×590 px)
    OmniVoice.cpp           All four voice engines + Leslie
    Effects/
      GritEffect.h          Asymmetric waveshaper
      LofiEffect.h          Bit crush + decimation
      VinylEffect.h         Wow/flutter + crackle
      TapeDelay.h           Broken tape delay
      DoublerEffect.h       Stereo widener
      LeslieEffect.h        Rotary speaker simulation
  create_installer.sh       macOS .pkg + .dmg installer
```

---

## Requirements

### iOS App
- iOS 16 or later
- iPhone or iPad (requires full screen — no Split View)

### VST3 / AU Plugin
- macOS 12 or later
- Xcode 14+ and CMake 3.22+ for building
- Any VST3 or AU host (Logic Pro, Ableton Live, Reaper, etc.)
