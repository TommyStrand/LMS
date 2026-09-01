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
- `OmnisphereSynth/Resources/Samples/` — WAV samples (folder reference in Xcode; subfolders are bundled automatically). Some folders hold synthesised WAVs (generate_samples.py); others hold real recordings (import_samples.py).
- `Scripts/generate_samples.py` — regenerates the synthesised WAV samples (piano/strings/flute)
- `Scripts/import_samples.py` — converts free sample libraries (Salamander piano, VSCO2 strings/flute, SFZ organ, or generic) to the app's mono 16-bit 44.1 kHz `{note}_{velocity}.wav` layout, and patches the matching `SamplerInstrument.rootNotes` in SynthPreset.swift so it exactly matches the files written
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
only. Their `SamplerInstrument.rootNotes` is whatever the importer wrote, which
is why the importer rewrites that line: `SamplerEngine.load()` asserts
loaded == expected, so the descriptor and the files on disk must agree exactly.

When you can't run on-device, prefer encoding an invariant (validator check or
`assert`) over relying on someone hearing the problem.

## Key decisions
- Single master AVAudioSourceNode (not per-voice) to share the effects chain across all voices
- SamplerEngine uses AVAudioPlayerNode + AVAudioUnitVarispeed pool (not AVAudioUnitSampler)
- Bundle WAV lookup via FileManager.enumerator, not Bundle.url(forResource:subdirectory:)
- Mono WAV buffers are promoted to stereo in makeStereo() before scheduling
- Deployment target is iOS 17. Model classes use `@Observable` (not ObservableObject);
  app-lifetime objects are created once in `SuperNovaPadApp` and injected via `.environment()`
- **Real-time rule:** `@Observable` tracking accessors take a lock, so any property the audio
  render thread touches (AudioEngine, DrumEngine) MUST be `@ObservationIgnored`. Only
  main-thread, UI-facing properties may be tracked
