# Changelog

## [Unreleased] — v1.0.0

### New Effects (iOS App)

- **Phaser** — 4-stage first-order all-pass filter with LFO sweep (0.1–4 Hz) and resonant feedback. L/R channels have a 180° LFO phase offset for stereo width.
- **Auto-Wah** — Envelope-following bandpass filter. Attack envelope (250 Hz → 4 kHz) driven by input level; slow release for a natural open/close feel. Sits before Grit so the filter shapes the voice before harmonic distortion.
- **Modulating Delay (Waver)** — LFO-swept delay line (~270 ms base, ±35 ms mod). L/R use slightly different LFO rates (0.33 Hz / 0.37 Hz) for organic stereo movement.

### Effects Chain Order (per voice, iOS)

```
Auto-Wah → Grit → Lo-Fi → Space Echo → Broken Tape
  → Bloom Reverb → Tremolo/Chorus → Tube Saturation → Phaser → Modulating Delay
```

### Bug Fixes

- **Silent notes (all presets)** — iOS recycles `UITouch` memory addresses, so a new touch could reuse the hash of an in-tail voice. The early `guard voiceNodes[touchID] == nil` returned without creating a new voice. Fixed: old voice is now force-torn-down at the start of `noteOn`.
- **Data race on effect processors (C-1)** — Effect processor instances (`LofiProcessor`, `GritProcessor`, `BloomReverbProcessor`, etc.) were shared across concurrent `AVAudioSourceNode` render threads. Fixed: all effect instances are now created fresh per voice inside `noteOn`.
- **Bloom Reverb stereo collapse (L-1)** — The bloom wet signal replaced `l`/`r` instead of blending additively, collapsing all prior-stage stereo width to mono. Fixed: additive blend `l = l*(1−amt*0.3) + bl`.
- **Bloom Reverb hardcoded sample rate (L-2)** — `BloomReverbProcessor` LPF used `0.19 / 44100` literally instead of the engine's `sampleRate`. Fixed.
- **OrganVoice tremulant knob had no effect (L-3)** — `tremulantDepth` was a `let` constant captured at init time; live knob changes never reached active voices. Fixed: changed to `var`, synced from `currentPreset` before each render buffer.
- **Modulation drop-out after note release (L-5)** — `mod` (`ModulationProcessor`) was captured `weak` in the render closure, so it was deallocated when `voiceMods` was cleared on release. Tremolo and chorus vanished during the tail. Fixed: `mod` captured strongly.
- **Bloom guard returned wrong value (L-2b)** — `guard amount > 0.005 else { return (input, input) }` returned the raw input rather than `(0, 0)`, leaking dry signal when bloom was off. Fixed.
- **Chorus silence on onset (L-16)** — `ModulationProcessor` only advanced the chorus write pointer when `chorusMix > 0.001`, so raising chorus mid-note read stale/zero history producing a momentary silence. Fixed: write pointer always advances.
- **Knob/ADSR drag value jump (Q-4)** — `lastDragY` was reset to `0` in `onEnded`; the first `.onChanged` of the next gesture computed a large spurious delta (~17% jump). Fixed: `lastDragY` is seeded from the actual start position of each new gesture.
- **HammondVoice per-sample reduce (M-1)** — `levels.reduce(0,+)` was computed every sample. Moved to a `static let totalLevel` constant.
- **OrganVoice per-sample reduce (M-2)** — Same as above for `churchLevelSum`.

---

## [0.1.0] — 2026-05-09 (pre-release)

Initial release. iOS polyphonic touch pad synthesizer with four voice engines and effects.

### Voice Engines
- Hammond B3 — 9-partial additive synthesis + percussion + Leslie rotary speaker (stereo)
- Rhodes Mk1 — 2-operator FM with tine model and velocity sensitivity
- Church Organ — 9-partial additive with per-partial detuning and tremulant
- Subtractive Synth — dual oscillator with resonant filter, ADSR, LFO

### Effects
- Grit (asymmetric tube waveshaper)
- Lo-Fi (bit crush + decimation)
- Space Echo (tape echo)
- Broken Tape Delay (wow/flutter + dropouts)
- Bloom Reverb (swell reverb)
- Modulation (tremolo + stereo chorus)
- Tube Saturation (soft-knee overdrive)
- Shimmer Reverb (plate + pitch shift)
- Hall/Chamber Reverb
- Tempo-synced Delay

### Presets
Hammond B3 · Rhodes Mk1 · Church Organ · Mystic Pad · Dark Matter · Celestial · Pulse Drive · Void Walker · Solar Wind
