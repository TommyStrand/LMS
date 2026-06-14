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
- `OmnisphereSynth/Resources/Samples/` — synthesised WAV samples (folder reference in Xcode)
- `Scripts/generate_samples.py` — regenerates the WAV samples
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

When you can't run on-device, prefer encoding an invariant (validator check or
`assert`) over relying on someone hearing the problem.

## Key decisions
- Single master AVAudioSourceNode (not per-voice) to share the effects chain across all voices
- SamplerEngine uses AVAudioPlayerNode + AVAudioUnitVarispeed pool (not AVAudioUnitSampler)
- Bundle WAV lookup via FileManager.enumerator, not Bundle.url(forResource:subdirectory:)
- Mono WAV buffers are promoted to stereo in makeStereo() before scheduling
