# LMS / OmnisphereSynth — Claude Code Notes

## Branch
All development happens on `claude/ios-music-creation-app-1Bpf8`.

## After every push
Always end the response by telling the user to pull the latest changes:

```
git pull origin claude/ios-music-creation-app-1Bpf8
```

## Project structure
- `OmnisphereSynth/` — Xcode project (Swift/SwiftUI, iOS)
- `OmnisphereSynth/Audio/` — AudioEngine, SamplerEngine, voice files, effects
- `OmnisphereSynth/Views/` — SwiftUI views
- `OmnisphereSynth/Models/` — SynthPreset, SamplerInstrument
- `OmnisphereSynth/Resources/Samples/` — WAV samples (folder reference in Xcode; subfolders are bundled automatically). Grand piano, strings and flute are REAL recordings in git, installed by `Scripts/fetch_free_samples.py` (Salamander Grand Piano V3, CC BY 3.0 — the credit in Settings → About and CREDITS.md is a licence requirement; VSCO 2 CE, CC0). `generate_samples.py` still produces the old synthesised set if ever needed.
- `Scripts/fetch_free_samples.py` — downloads those recordings file by file from GitHub (raw.githubusercontent.com), converts with ffmpeg (mono 16-bit 44.1 kHz, leading silence removed, trimmed, peak-normalised) and patches the descriptors. VSCO 2 names octaves one lower than standard (its "C3" = MIDI 60)
- `OmnisphereSynth/Resources/Backgrounds/` — per-preset backdrop scenes (folder reference, bundled as
  `Backgrounds/`). File name = `Backdrop.slug(presetName)` + `.webp` (e.g. "Suitcase '73" → `suitcase_73.webp`);
  a preset without its own file borrows a related scene (`Backdrop.borrowed`, e.g. Church Organ → pipe_organ,
  the tape/string machines → `vintage_studio.webp`), and anything else (synth pads, flute) gets a generated
  `AbstractScene` in the preset colour — so every preset has a backdrop. Art is generated in ChatGPT in one shared
  painterly night style, instrument in the upper half, no text/logos. Adding `<slug>.webp` later overrides the
  borrowed/generated scene automatically. Spare variants live in `design/backgrounds/`
- `Scripts/generate_samples.py` — regenerates the synthesised WAV samples (piano/strings/flute)
- `Scripts/import_samples.py` — converts free sample libraries (Salamander piano, VSCO2 strings/flute, SFZ organ, or generic) to the app's mono 16-bit 44.1 kHz `{note}_{velocity}.wav` layout. Each recording is written under its OWN source note (never a target grid note — that played it out of tune), the target folder is cleared first, and for git-tracked instruments the descriptor's `rootNotes` is patched to the notes written and `loops` set to false (real recordings are one-shot). `validate_samples.py` checks folders against those declared `rootNotes`
- `Scripts/validate_samples.py` — validates the sample library (run in QA / CI)

## Testing & QA
Run BEFORE committing sample or sampler changes, and as part of any QA pass:

```
python3 Scripts/validate_samples.py   # exit 0 = pass; runs without Xcode/device
```

It checks every instrument folder for missing/extra files, wrong format
(must be mono 16-bit @ 44.1 kHz), silent or clipped audio, and reports
cross-folder filename collisions. The collisions are expected (all instruments
use `{note}_{velocity}.wav`), which is exactly why **sample lookup must always
be keyed by folder, never bare filename** — a bare-filename lookup silently
loads the wrong instrument. `SamplerEngine.load()` asserts this invariant in
debug builds (folder identity + loaded == expected).

Folders produced by `generate_samples.py` (piano/strings/flute) are validated
against a fixed `{note}_{velocity}.wav` grid. Folders imported by
`import_samples.py` (e.g. `pipe_organ`) have no fixed grid — real libraries
cover an irregular set of keys — so they are validated for format/content/naming
only. Imported-only instruments (`pipe_organ`) are NOT in git — their WAVs exist
only on the machine that ran the importer — so their descriptor sets
`discoversRoots: true` and `SamplerEngine.load()` derives the roots from the
folder (`SamplerSelection.discoverRoots`, complete roots only). A hard-coded
`rootNotes` list there would drift from the local files on every pull/reset and
trip the loaded == expected assert (it did: "pipe_organ loaded 46/50"). The
importer therefore skips patching their descriptor. Instruments whose samples ARE
in git (piano/strings/flute) keep the strict declared-roots check.

When you can't run on-device, prefer encoding an invariant (validator check or
`assert`) over relying on someone hearing the problem.

Unit tests live in `SuperNovaPadTests/` (Xcode: ⌘U). They cover pure logic only —
no audio hardware — so the pattern for anything testable is to factor it into a
plain `enum`/`struct` with no `Date`/timers/AVFoundation and test that:
`SamplerSelection` (note/velocity → sample), `PitchSnap` (keyboard glide + snap-
to-scale), `LoopSchedule` (looper event firing/wrap, resuming mid-loop), `LoopSync` (snapping a take to the drums' bar grid), `FingerVibrato`
(wiggle → vibrato on a locked note), `PitchColor` (pitch → blob hue), `WaveMorph` (sine→tri→saw→square), `DrumSchedule` (which
drum hits land on which frame of a buffer), `MoodGrooves` (mood drum
patterns stay on the 32-step grid at a playable tempo), `SustainLoop` (attack + seamless
sustain loop found in real recordings), `BackdropPalette` / `Backdrop.slug` / `Backdrop.imageSlug` / `AbstractScene` (scene colours, image names, borrowed and generated scenes), `SynthVoice` / `RhodesVoice` (every preset renders finite, bounded, and ends), `RenderParams` (preset →
audio-thread scalars), plus descriptor and scale invariants.

## Key decisions
- Sampler instruments: piano is a one-shot with `damps: true` (a lifted key fades over `release` — without it
  real 6–8 s piano tails behave like a permanently held sustain pedal); strings/flute are `loops: false` +
  `sustainLoop: true`. Hammond registration is a fuller drawbar set (the old 16'+8'+5⅓' at equal level was
  hollow and put a parallel fifth on every note); constant per-partial detune ratios are precomputed
- Sound engine (the user can't describe DSP; "sounds bad" was traced to these): `SynthVoice` uses PolyBLEP
  saw/square (naive ones alias — measured ~18 dB more inharmonic hash), stereo unison (`unisonCents`), a
  filter envelope + key tracking + velocity brightness, optional 2-op FM on a sine osc 1 (`fmIndex`, bells/
  mallets/glass) and exponential decay/release; slow values update every 16 samples. Presets must keep osc 2
  at a unison or whole octaves (parallel thirds/fourths muddied every chord — enforced by a test) and use
  `level` to sit at a similar loudness. `RhodesVoice` = FM body + tine partial, exponential decay, per-preset
  character. Chorus delays are 9/13 ms (they were 0.3 ms = a flanger). A master limiter in the render loop
  replaces hard clipping on big chords. Check DSP changes numerically (a Python port) when you can't listen
- No parameter steps on the audio path: the render thread glides `RenderParams` toward the published values
  (per-sample ramp), AU-node levels are ramped in `applyPresetToNodes`, reverb preset / delay time change only
  at zero wet, and a boutique effect is `reset()` once it has faded out (stale delay lines pop when re-enabled).
  New effects need a `reset()` and must be continuous at their bypass threshold
- Looper ↔ drums: with SYNC on (`LooperEngine.syncToDrums`, the button in the looper strip) and the drums
  running, a recorded take is snapped to bars (`LoopSync.align`) and played from the drum clock
  (`DrumEngine.beatsNow()`: the render thread publishes an anchor — buffer host time + beat count, two plain
  Doubles like `renderBeatFraction` — and main extrapolates the few ms since it), so it stays locked and follows tempo. Drums stopped / SYNC off →
  free wall-clock loop. The looper records synth notes only; the header record button captures synth + drums audio
- iPad main screen (ContentView.ipadLayout), top to bottom: header (wordmark + preset name + key/mode),
  preset strip (scene-thumbnail chips from `BackdropThumbnails`, ≤320 px via ImageIO — never the full images),
  full-width play surface, sound drawer (`ControlsView(wide: true)`, toggled by the footer SOUND button, closed
  at launch), footer (looper + SOUND). The backdrop is the background of everything below the preset strip.
  iPhone keeps the stacked layout with a full-screen backdrop
- Panels and chips are styled with `.panelSurface(theme, radius:border:)` (AppTheme.swift), not hand-rolled
  background + clipShape + border. On a glass theme (`theme.isGlass`) it adds a blur material, a lit top edge
  and a soft shadow; header chips use `theme.chipRadius`. iPad header keeps only play-time controls; the
  visualizer, performance meter (`showHeaderMeter`, auto-shown at ≥85 % CPU) and Settings live in the More menu
- Backdrops: `ThemeManager.current` returns `base.glass()` (translucent surfaces) while a backdrop shows;
  screens with their own background (Settings) use `ThemeManager.base`. Dark themes only. `BackdropView`
  decodes off the main thread and cross-fades on preset change. It also samples a `BackdropPalette` from a
  32×21 thumbnail (dominant light hue family → accent for every preset; ambient cast → dark panel tint and
  `screenBackground`) so the UI matches the scene instead of mixing warm art with neon chrome
- Drum patterns: the Mood collection (`MoodGrooves`, original, written as 32-step text grids
  in Models/DrumPatterns.swift) comes first in `DrumPattern.all`; the 30 post-rock grooves and
  any bundled .mid files follow. New patterns must be 2 bars of 4/4 to match the step grid
- Single master AVAudioSourceNode (not per-voice) to share the effects chain across all voices
- SamplerEngine uses AVAudioPlayerNode + AVAudioUnitVarispeed pool (not AVAudioUnitSampler)
- Bundle WAV lookup via FileManager.enumerator, not Bundle.url(forResource:subdirectory:)
- Mono WAV buffers are promoted to stereo in makeStereo() before scheduling
- Sampler playback modes: `loops` (synthesised seamless loops, whole buffer loops),
  `sustainLoop` with `loops: false` (real recordings of sustaining instruments — organ,
  imported strings/flute: attack plays once, then `SustainLoop` finds the steady part,
  phase-aligns its end and crossfades it so it holds while the key is down), or one-shot
  (piano). Sustaining notes are tracked in `slotNote` and released with a ramp
- Deployment target is iOS 17. Model classes use `@Observable` (not ObservableObject);
  app-lifetime objects are created once in `SuperNovaPadApp` and injected via `.environment()`
- **Real-time rule:** `@Observable` tracking accessors take a lock, so any property the audio
  render thread touches (AudioEngine, DrumEngine) MUST be `@ObservationIgnored`. Only
  main-thread, UI-facing properties may be tracked
- Both engines hand state to the render thread the same way: main thread publishes an
  immutable snapshot (AudioEngine `RenderSnapshot`, DrumEngine `DrumRenderState`) under an
  `os_unfair_lock`; the render thread reads it with `os_unfair_lock_trylock` and keeps its
  last copy if contended. Never take a blocking lock, allocate, or `DispatchQueue.async`
  on the render thread
