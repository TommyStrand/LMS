#!/usr/bin/env python3
"""
fetch_free_samples.py — download free, real recordings and install them as the
app's String Ensemble and Concert Flute.

Both used to be SYNTHESISED WAVs (Scripts/generate_samples.py). This script
replaces them with real recordings from VSCO 2 Community Edition by Versilian
Studios (https://github.com/sgossner/VSCO-2-CE, CC0 1.0 — public domain),
fetched file by file from GitHub:

  String Ensemble  cello section (low notes) + violin section (high notes)
  Concert Flute    solo flute with vibrato

Output: mono 16-bit 44.1 kHz WAVs named {midi_note}_{velocity}.wav in
OmnisphereSynth/Resources/Samples/<instrument>/, each written under its OWN
recorded pitch, with the descriptor's `rootNotes` in SynthPreset.swift patched to
match (same rules as import_samples.py). Run Scripts/validate_samples.py after.

The players shape every note (the level drifts by up to 10 dB over a held
note), which is musical in a performance but ruins a sample that has to LOOP:
each pass would swell and jump. So after the attack the level is flattened
(`flatten_sustain`) — the app's sustain loop then repeats without pumping.

Needs: python3, curl, ffmpeg. Downloads ~60 MB into a cache folder (default
~/.cache/supernova-samples, override with --cache); re-runs reuse the cache.

  python3 Scripts/fetch_free_samples.py            # both
  python3 Scripts/fetch_free_samples.py --only concert_flute

To go back to the synthesised set, run generate_samples.py and restore the
descriptors (`loops: true`, the stride root lists) in SynthPreset.swift.
"""
from __future__ import annotations

import argparse
import array
import subprocess
import sys
import urllib.parse
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_samples  # noqa: E402  (patch_descriptor, shared conventions)

REPO_ROOT = Path(__file__).resolve().parent.parent
SAMPLES   = REPO_ROOT / "OmnisphereSynth" / "Resources" / "Samples"
SWIFT     = REPO_ROOT / "OmnisphereSynth" / "Models" / "SynthPreset.swift"

VSCO       = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master/"

PITCH = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
SOFT, HARD = 64, 110          # the app's two velocity-layer file suffixes


def midi(name: str, octave: int) -> int:
    """Standard naming: C4 = 60."""
    return PITCH[name] + (octave + 1) * 12


# ── What to fetch ─────────────────────────────────────────────────────────────
# Each entry: (midi note, velocity suffix, url, seconds to keep, target peak)

def strings_plan() -> list[tuple]:
    """Cello section below G3, violin section from G3 up — one continuous
    ensemble. NOTE: VSCO 2 names octaves one lower than standard (its "C3" is
    middle C, MIDI 60; checked by measuring the recordings' pitch)."""
    cello  = ["C1", "E1", "G1", "B1", "D2", "F2"]                       # MIDI 36…53
    violin = ["G2", "B2", "D3", "F#3", "A3", "C4", "E4", "G4", "B4"]    # MIDI 55…83
    plan = []
    for token in cello:
        note = midi(token[:-1], int(token[-1]) + 1)
        for suffix, layer, peak in ((SOFT, "v1_1", 0.45), (HARD, "v3_1", 0.75)):
            path = f"Strings/Cello Section/susvib/susvib_{token}_{layer}.wav"
            plan.append((note, suffix, VSCO + urllib.parse.quote(path), 5.5, peak))
    for token in violin:
        note = midi(token[:-1], int(token[-1]) + 1)
        for suffix, layer, peak in ((SOFT, "v1", 0.45), (HARD, "v2", 0.75)):
            path = f"Strings/Violin Section/susVib/VlnEns_susVib_{token}_{layer}.wav"
            plan.append((note, suffix, VSCO + urllib.parse.quote(path), 5.5, peak))
    return plan


def flute_plan() -> list[tuple]:
    """Solo flute with vibrato. The library has one dynamic for this
    articulation, so both velocity layers use the same take (the loud layer is
    simply louder) — the app requires every root to have every layer."""
    plan = []
    for token in ["C3", "E3", "A3", "C4", "E4", "A4", "C5", "E5", "A5", "C6"]:   # MIDI 60…96
        note = midi(token[:-1], int(token[-1]) + 1)
        path = f"Woodwinds/Flute/susvib/LDFlute_susvib_{token}_v1_1.wav"
        for suffix, peak in ((SOFT, 0.45), (HARD, 0.75)):
            plan.append((note, suffix, VSCO + urllib.parse.quote(path), 4.5, peak))
    return plan


PLANS = {
    "string_ensemble": (strings_plan, 0.05),   # (plan, fade-out seconds at the end)
    "concert_flute":   (flute_plan,   0.05),
}


# ── Download / convert ────────────────────────────────────────────────────────

def download(url: str, cache: Path) -> Path:
    dest = cache / urllib.parse.unquote(url.split("/master/", 1)[1]).replace("/", "__")
    if dest.exists() and dest.stat().st_size > 10_000:
        return dest
    cache.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    for attempt in range(4):
        result = subprocess.run(["curl", "-sSL", "--fail", "-m", "180", "-o", str(tmp), url])
        if result.returncode == 0 and tmp.stat().st_size > 10_000:
            tmp.rename(dest)
            return dest
    raise RuntimeError(f"download failed: {url}")


def flatten_sustain(samples: array.array, rate: int = 44100) -> list[float]:
    """Even out the level of a held note after its attack.

    RMS is measured in 100 ms windows; the reference is the 75th-percentile
    window. From the first window that reaches 70 % of it (the attack has
    settled) every window is scaled toward the reference, the gain limited to
    0.4…5× and interpolated between window centres so it never steps. The attack
    itself keeps its shape (it gets the first settled window's gain).
    """
    win = rate // 10
    count = len(samples) // win
    if count < 6:
        return [float(v) for v in samples]
    rms = []
    for w in range(count):
        chunk = samples[w * win:(w + 1) * win]
        rms.append((sum(v * v for v in chunk) / win) ** 0.5)
    ref = sorted(rms)[count * 3 // 4]
    if ref <= 1:
        return [float(v) for v in samples]
    settled = next((i for i, r in enumerate(rms) if r >= 0.7 * ref), 0)
    gains = [min(5.0, max(0.4, ref / max(r, 1e-9))) for r in rms]
    for i in range(settled):
        gains[i] = gains[settled]
    out = []
    for n, v in enumerate(samples):
        pos = (n - win / 2) / win              # window-centre coordinates
        lo = min(count - 1, max(0, int(pos)))
        hi = min(count - 1, lo + 1)
        frac = min(1.0, max(0.0, pos - lo))
        out.append(v * (gains[lo] * (1 - frac) + gains[hi] * frac))
    return out


def convert(src: Path, dest: Path, keep: float, fade: float, peak: float) -> None:
    """→ mono 16-bit 44.1 kHz, trimmed to `keep` seconds with a fade-out, leading
    silence removed (so notes speak immediately), the sustain level flattened,
    peak-normalised to `peak`."""
    raw = dest.with_suffix(".tmp.wav")
    filters = (
        "silenceremove=start_periods=1:start_threshold=-55dB:start_silence=0.004,"
        f"atrim=0:{keep:.3f}"
    )
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
         "-ac", "1", "-ar", "44100", "-af", filters, "-sample_fmt", "s16", str(raw)],
        check=True)
    with wave.open(str(raw), "rb") as wf:
        samples = array.array("h", wf.readframes(wf.getnframes()))
    raw.unlink()
    if sys.byteorder != "little":
        samples.byteswap()
    flat = flatten_sustain(samples)
    fade_len = int(fade * 44100)                 # short fade so the file ends at zero
    for k in range(min(fade_len, len(flat))):
        flat[len(flat) - 1 - k] *= k / fade_len
    loudest = max(1.0, max(abs(v) for v in flat))
    gain = peak * 32767 / loudest
    scaled = array.array("h", (max(-32766, min(32766, int(round(v * gain)))) for v in flat))
    if sys.byteorder != "little":
        scaled.byteswap()
    with wave.open(str(dest), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(44100)
        wf.writeframes(scaled.tobytes())


def install(instrument: str, cache: Path) -> None:
    plan_fn, fade = PLANS[instrument]
    plan = plan_fn()
    out_dir = SAMPLES / instrument
    out_dir.mkdir(parents=True, exist_ok=True)
    # Replace, don't merge (same rule as import_samples.py).
    for old in out_dir.glob("*.wav"):
        if import_samples.NAME_RE.fullmatch(old.name):
            old.unlink()
    print(f"{instrument}: {len(plan)} files")
    for index, (note, suffix, url, keep, peak) in enumerate(plan, 1):
        src = download(url, cache)
        convert(src, out_dir / f"{note}_{suffix}.wav", keep, fade, peak)
        if index % 10 == 0 or index == len(plan):
            print(f"  {index}/{len(plan)}")
    roots = sorted({note for note, *_ in plan})
    import_samples.patch_descriptor(SWIFT, instrument, roots)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", choices=sorted(PLANS), help="install just this instrument")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache" / "supernova-samples")
    args = parser.parse_args()
    for instrument in ([args.only] if args.only else list(PLANS)):
        install(instrument, args.cache)
    print("\nDone. Now run: python3 Scripts/validate_samples.py")


if __name__ == "__main__":
    main()
