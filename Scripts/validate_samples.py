"""
Validates the synthesised sample library against the contract that
SamplerEngine relies on. Runs anywhere Python does (dev host, CI) — no Xcode,
no device, no audio hardware required.

This exists because the kind of bug it catches (samples present but resolving to
the WRONG instrument because filenames collide across folders) is invisible to a
"did we load N files?" check and is only otherwise audible on-device in certain
note ranges. Encode the invariant instead of hoping someone hears it.

Exit code 0 = all checks pass; non-zero = at least one failure (CI-friendly).

Usage:
    python3 Scripts/validate_samples.py
"""

import os, re, sys, wave, struct

# Single source of truth: pull the expected layout straight from the generator
# so the validator can never drift from what we actually produce.
from generate_samples import INSTRUMENTS, VELOCITIES, SAMPLE_RATE, OUT_ROOT

# Filename scheme every sampler folder must follow: {midi_note}_{velocity}.wav
NAME_RE = re.compile(r"^(\d{1,3})_(\d{1,3})\.wav$")

EXPECT_CHANNELS = 1
EXPECT_WIDTH    = 2          # 16-bit
EXPECT_RATE     = SAMPLE_RATE

failures = []
warnings = []

def fail(msg): failures.append(msg)
def warn(msg): warnings.append(msg)

def expected_files(start, end, step):
    return {f"{n}_{v}.wav"
            for n in range(start, end + 1, step)
            for v in VELOCITIES}

SYNTH_PRESET = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "OmnisphereSynth", "Models", "SynthPreset.swift")

def descriptor_roots(folder):
    """The rootNotes the APP declares for `folder` in SynthPreset.swift — the set
    SamplerEngine.load() asserts against. Handles the literal list the importer
    writes and the Array(stride(...)) form. None if not found / unparsable."""
    try:
        text = open(SYNTH_PRESET).read()
    except OSError:
        return None
    i = text.find(f'id: "{folder}"')
    if i < 0:
        return None
    m = re.search(r"rootNotes:\s*(.+?),[ \t]*\n", text[i:])
    if not m:
        return None
    expr = m.group(1).strip()
    if expr.startswith("["):
        return [int(x) for x in re.findall(r"-?\d+", expr)]
    st = re.match(r"Array\(stride\(from:\s*(\d+),\s*through:\s*(\d+),\s*by:\s*(\d+)\)\)", expr)
    if st:
        a, b, c = map(int, st.groups())
        return list(range(a, b + 1, c))
    return None

def discovers_roots(folder):
    """True if the descriptor sets discoversRoots (roots read from disk at load)."""
    try:
        text = open(SYNTH_PRESET).read()
    except OSError:
        return False
    i = text.find(f'id: "{folder}"')
    j = text.find("\n    )", i)
    return i >= 0 and "discoversRoots: true" in text[i:j]

def check_wav(path):
    """Returns a list of problem strings for one WAV file (empty == OK)."""
    problems = []
    try:
        with wave.open(path, "rb") as w:
            ch, width, rate, nframes = (w.getnchannels(), w.getsampwidth(),
                                        w.getframerate(), w.getnframes())
            if ch    != EXPECT_CHANNELS: problems.append(f"channels={ch} (want {EXPECT_CHANNELS})")
            if width != EXPECT_WIDTH:    problems.append(f"sampwidth={width} (want {EXPECT_WIDTH})")
            if rate  != EXPECT_RATE:     problems.append(f"rate={rate} (want {EXPECT_RATE})")
            if nframes == 0:
                problems.append("empty")
                return problems
            raw = w.readframes(nframes)
        samples = struct.unpack(f"<{len(raw)//2}h", raw)
        peak = max(abs(s) for s in samples)
        if peak < 32:                       # < ~ -60 dBFS everywhere → effectively silent
            problems.append("silent")
        clipped = sum(1 for s in samples if abs(s) >= 32767)
        if clipped > len(samples) * 0.02:   # >2% hard-clipped → almost certainly broken
            problems.append(f"clipped ({100*clipped/len(samples):.1f}%)")
    except Exception as e:
        problems.append(f"unreadable ({e})")
    return problems

def main():
    print(f"Validating samples under {os.path.relpath(OUT_ROOT)}\n")

    # Per-instrument structural + format + content checks.
    bare_name_owners = {}   # filename -> [folders] (cross-folder collision tracking)
    for folder, _fn, start, end, step in INSTRUMENTS:
        out_dir = os.path.join(OUT_ROOT, folder)
        if not os.path.isdir(out_dir):
            fail(f"{folder}: directory missing")
            continue

        actual   = {f for f in os.listdir(out_dir) if f.endswith(".wav")}
        # Validate against what the APP declares (SynthPreset.swift), which is what
        # SamplerEngine asserts at load. After import_samples.py replaces a folder
        # with real recordings, the generator's fixed grid no longer applies — the
        # importer patched rootNotes to the notes it actually wrote.
        roots = descriptor_roots(folder)
        expected = ({f"{n}_{v}.wav" for n in roots for v in VELOCITIES}
                    if roots is not None else expected_files(start, end, step))

        for name in sorted(expected - actual):
            fail(f"{folder}/{name}: missing")
        for name in sorted(actual - expected):
            warn(f"{folder}/{name}: unexpected extra file")

        bad = 0
        for name in sorted(actual & expected):
            bare_name_owners.setdefault(name, []).append(folder)
            problems = check_wav(os.path.join(out_dir, name))
            if problems:
                fail(f"{folder}/{name}: " + ", ".join(problems))
                bad += 1
        ok = len(actual & expected) - bad
        print(f"  {folder:16} {ok}/{len(expected)} files OK")

    # Imported instruments (e.g. pipe_organ) live under the same Samples root but
    # are NOT produced by generate_samples.py, so they have no fixed grid contract —
    # real libraries cover an irregular set of keys. Validate whatever is there for
    # format/content/naming and feed them into the collision tracker, but don't
    # demand a complete note range.
    known = {folder for folder, *_ in INSTRUMENTS}
    if os.path.isdir(OUT_ROOT):
        for folder in sorted(os.listdir(OUT_ROOT)):
            out_dir = os.path.join(OUT_ROOT, folder)
            if folder in known or not os.path.isdir(out_dir):
                continue
            wavs = sorted(f for f in os.listdir(out_dir) if f.endswith(".wav"))
            if not wavs:
                warn(f"{folder}: no .wav files (imported instrument folder is empty)")
                continue
            bad = 0
            for name in wavs:
                if not NAME_RE.match(name):
                    fail(f"{folder}/{name}: name must be {{note}}_{{velocity}}.wav")
                    bad += 1
                    continue
                bare_name_owners.setdefault(name, []).append(folder)
                problems = check_wav(os.path.join(out_dir, name))
                if problems:
                    fail(f"{folder}/{name}: " + ", ".join(problems))
                    bad += 1
            print(f"  {folder:16} {len(wavs)-bad}/{len(wavs)} files OK (imported)")

    # Imported-only instruments declared in the app but absent here (not in git, not
    # imported on this machine). The app hides such presets, so this is a warning.
    for folder in ("pipe_organ",):
        out_dir = os.path.join(OUT_ROOT, folder)
        has_wavs = os.path.isdir(out_dir) and any(f.endswith(".wav") for f in os.listdir(out_dir))
        if discovers_roots(folder) and not has_wavs:
            warn(f"{folder}: not imported on this machine — its preset is hidden in the app "
                 f"(run Scripts/import_samples.py --source sfz ...)")

    # Cross-folder filename collisions. This is EXPECTED here (all instruments use
    # the same {note}_{velocity}.wav scheme) — the point is to make the hazard
    # explicit: any bundle-wide, filename-only lookup will silently load the wrong
    # instrument. SamplerEngine MUST disambiguate by folder (and asserts it does).
    collisions = {n: f for n, f in bare_name_owners.items() if len(f) > 1}
    if collisions:
        print(f"\nNote: {len(collisions)} filenames exist in multiple folders "
              f"(e.g. {sorted(collisions)[0]} in {sorted(collisions[sorted(collisions)[0]])}).")
        print("      Sample lookup MUST be keyed by folder, never bare filename.")

    print()
    for w in warnings: print(f"WARN  {w}")
    for f in failures: print(f"FAIL  {f}")

    if failures:
        print(f"\n{len(failures)} failure(s).")
        sys.exit(1)
    print(f"All checks passed ({len(warnings)} warning(s)).")

if __name__ == "__main__":
    main()
