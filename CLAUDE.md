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

## Key decisions
- Single master AVAudioSourceNode (not per-voice) to share the effects chain across all voices
- SamplerEngine uses AVAudioPlayerNode + AVAudioUnitVarispeed pool (not AVAudioUnitSampler)
- Bundle WAV lookup via FileManager.enumerator, not Bundle.url(forResource:subdirectory:)
- Mono WAV buffers are promoted to stereo in makeStereo() before scheduling
