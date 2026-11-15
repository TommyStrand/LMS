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

Also installed here, from the Versilian Community Sample Library (VCSL, same
studio, also CC0): Vibraphone, Wine Glasses (→ Glass Harmonica), Bowed Psaltery
and a real church organ (→ Church Organ). See VCSL_INSTRUMENTS below.

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
import math
import re
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


# ── VCSL instruments (measured pitch) ────────────────────────────────────────
# Versilian Community Sample Library, https://github.com/sgossner/VCSL (CC0 1.0).
# name → (folder in the library, file names, seconds kept, fade-out seconds,
#         flatten the held part?, key from the file name?, options). One
#         velocity layer each: {midi}_64.wav. Options: "source": "vsco" (else
#         VCSL), "octave": octave-name offset (default +1), "tune": "strict"
#         (default) | "loose" | "none" — see install_vcsl.
# Pitch: VCSL names octaves one lower than standard (its "C3" = MIDI 60, checked
# by measurement). The KEY comes from the file name; the measured pitch is used
# only for fine tuning — the few cents needed to sit exactly on that key. (The
# measurement can't supply the octave: the organ's 16' stop makes many of its
# notes measure an octave low, and a low vibraphone bar can read a semitone off.)
# The exception is `tuned: False` — rubbed wine glasses are not tuned to concert
# pitch at all, so there the measured pitch decides the key too.

VCSL = "https://raw.githubusercontent.com/sgossner/VCSL/master/"

VCSL_INSTRUMENTS = {
    # Struck bars ring and die away: one-shots, long fade, never flattened.
    "vibraphone": (
        "Idiophones/Struck Idiophones/Vibraphone/Hard Mallets",
        [f"Vibes_hard_{n}_v2_rr1_Main.wav" for n in
         ["F2", "A2", "C3", "E3", "G3", "B3", "D4", "F4", "A4", "C5", "E5"]],
        5.0, 1.5, False, True),
    # A finger circling the rim of a wine glass — what a glass harmonica is.
    "wine_glasses": (
        "Idiophones/Friction Idiophones/Wine Glasses/Sustains/Slow",
        ["glass1_D#4_Slow_1_Main.wav", "glass2_F#4_Slow_1_Main.wav",
         "glass3_A#4_Slow_1_Main.wav", "glass4_D5_Slow_2_Main.wav"],
        6.0, 0.05, True, False),
    "bowed_psaltery": (
        "Chordophones/Zithers/Psaltery, Bowed and Plucked/LongBow",
        [f"BowedPsaltery_{n}_Main_LongBow_rr{r}.wav" for n, r in
         [("A#3", 2), ("C4", 1), ("D4", 1), ("E4", 2), ("F#4", 1), ("G#4", 1),
          ("A#4", 2), ("C5", 1), ("D5", 2), ("E5", 2), ("F#5", 2)]],
        5.0, 0.05, True, True),
    # A real church organ, open (loud) registration on the third manual.
    "church_organ": (
        "Aerophones/Edge-blown Aerophones/Pipe Organ/Loud",
        [f"Rode_Man3Open_{n}{o}.wav" for o in range(1, 6) for n in ["C", "D#", "F#", "A"]]
        + ["Rode_Man3Open_C6.wav"],
        4.5, 0.05, False, True),

    # ── More sources for blends (the unusual and the orchestral) ─────────────
    # A vibraphone bar drawn with a bow: a slow swell that rings on.
    "bowed_vibraphone": (
        "Idiophones/Struck Idiophones/Vibraphone/Bowed",
        # (The library's "A2" take is left out: it measures a fourth away from its name.)
        [f"Vibes_bowed_{n}_rr1_Main.wav" for n in ["E3", "G3", "D4", "A4", "E5"]],
        6.0, 1.5, False, True),
    "concert_harp": (
        "Chordophones/Composite Chordophones/Concert Harp",
        [f"KSHarp_{n}_f{r}.wav" for n, r in
         [("G1", 1), ("B1", 1), ("D2", 1), ("F2", 1), ("A2", 1), ("C3", 2), ("E3", 1), ("G3", 1),
          ("B3", 1), ("D4", 1), ("F4", 1), ("A4", 1), ("C5", 1), ("E5", 1), ("G5", 1), ("B5", 1),
          ("D6", 1), ("F6", 1), ("A6", 1)]],
        4.5, 1.5, False, True, {"octave": 0}),      # the harp files use standard octave names
    # A Tanzanian kalimba in its own tuning — the measurement decides each key.
    "kalimba": (
        "Idiophones/Plucked Idiophones/Kalimba, Tanzania",
        [f"MBira3_pluck_Main_{n}_k{k}_50_100_rr2.wav" for n, k in
         [("G1", 12), ("G#1", 11), ("B1", 13), ("C#2", 10), ("D#2", 14), ("F2", "9alt"), ("G2", 15),
          ("A#2", 8), ("C#3", 16), ("D#3", 7), ("F3", 17), ("G3", 6), ("A#3", 18), ("C#4", 5),
          ("D4", 19), ("D#4", 20), ("F4", 21), ("G4", 22), ("A#4", 2), ("B4", 23), ("C#5", 24),
          ("E5", 25), ("F#5", 1), ("G#5", 26), ("C#6", 27)]],
        3.0, 1.0, False, True, {"tune": "loose"}),
    "tubular_bells": (
        "Idiophones/Struck Idiophones/Tubular Bells 2",
        [f"TB_hit_{n}_v4_{r}.wav" for n, r in
         [("C4", 1), ("D4", 2), ("E4", 1), ("F4", 1), ("G4", 1), ("A4", 1), ("B4", 1),
          ("C5", 1), ("D5", 1), ("E5", 2), ("F5", 1)]],
        # Standard octave names. A bell's pitch is a "strike tone" the ear builds
        # from its partials, not a partial that can be measured — so no fine tuning.
        6.0, 2.0, False, True, {"octave": 0, "tune": "none"}),
    "hand_chimes": (
        "Idiophones/Struck Idiophones/Hand Chimes",
        [f"sus_{n}_r01_main.wav" for n in
         ["C3", "D3", "E3", "F#3", "G#3", "A#3", "C4", "D4", "E4", "F#4", "G#4", "A4",
          "C5", "D5", "E5", "F#5", "G#5", "A#5", "C6"]],
        5.0, 1.5, False, True),
    "ocarina": (
        "Aerophones/Edge-blown Aerophones/Ocarina, Typical/Sustains/Sus",
        [f"StdOcarina_Sus_{n}.wav" for n in
         ["A3", "B3", "C#4", "D4", "E4", "F#4", "G#4", "A4", "A#4", "C5", "C#5"]],
        4.0, 0.05, True, True),

    # From VSCO 2 Community Edition (same studio, CC0).
    "french_horn": (
        "Brass/F Horn/sus",
        [f"MOHorn_sus_{n}_v{v}_1.wav" for n, v in
         [("A0", 1), ("C1", 2), ("D#1", 2), ("G1", 2), ("A#1", 2), ("D2", 2), ("F2", 2),
          ("A2", 2), ("C3", 2), ("D4", 1), ("F4", 1)]],
        5.0, 0.05, True, True, {"source": "vsco"}),
    "tremolo_strings": (
        "Strings",
        [f"Cello Section/trem/trem_{n}_v{v}_1.wav" for n, v in
         [("C1", 2), ("E1", 2), ("G1", 2), ("B1", 1), ("D2", 2), ("F2", 2)]]
        + [f"Violin Section/Trem/VlnEns_Trem_{n}_v{v}.wav" for n, v in
           [("G2", 2), ("B2", 2), ("D3", 2), ("F#3", 1), ("A3", 2), ("C4", 2), ("E4", 2),
            ("G4", 2), ("B4", 2), ("D5", 2)]],
        5.0, 0.05, True, True, {"source": "vsco"}),
    "clarinet": (
        "Woodwinds/Clarinet/susLong",
        [f"DCClar_susLong_{n}_v2_rr1_sum.wav" for n in
         ["D2", "F2", "A#2", "D3", "F3", "A#3", "D4", "F4", "A#4", "D5", "F#5"]],
        5.0, 0.05, True, True, {"source": "vsco"}),

    # A 1958 Otto Rubner double bass, bowed — played and recorded by D. Smolken
    # (https://github.com/sfzinstruments/dsmolken.double-bass, CC0 1.0).
    "bowed_bass": (
        "arco",
        [f"arco_{n}_mf_down.wav" for n in
         ["c1", "eb1", "f1", "g1", "bb1", "c2", "d2", "f2", "a2", "c3", "e3", "g3", "a3",
          "c4", "e4", "a4"]],
        5.0, 0.05, True, True, {"source": "bass", "octave": 0, "lowest": 28.0}),
}

SOURCES = {
    "vsco": VSCO,
    "bass": "https://raw.githubusercontent.com/sfzinstruments/dsmolken.double-bass/master/",
}

_NOTE_IN_NAME = re.compile(r"_([A-Ga-g][#b]?)(\d)(?=[_.])")
_FLATS = {"Bb": "A#", "Eb": "D#", "Ab": "G#", "Db": "C#", "Gb": "F#"}


def install_vcsl(instrument: str, cache: Path) -> list[int]:
    # (Imported here: that module imports flatten_sustain from this one.)
    from build_soundfont_instruments import measure_pitch, to_44k

    folder, names, keep, fade, flatten, tuned_to_pitch, *extra = VCSL_INSTRUMENTS[instrument]
    options = extra[0] if extra else {}
    base = SOURCES.get(options.get("source"), VCSL)
    octave_shift = options.get("octave", 1)      # most files name octaves one low
    tune = options.get("tune", "strict")
    out_dir = SAMPLES / instrument
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.wav"):
        old.unlink()
    tmp = cache / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    roots: list[int] = []
    for name in names:
        src = download(base + urllib.parse.quote(f"{folder}/{name}"), cache)
        decoded = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(src), "-ac", "1", "-ar", "44100",
             "-af", f"silenceremove=start_periods=1:start_threshold=-55dB:start_silence=0.004,atrim=0:{keep + 1:.2f}",
             "-f", "s16le", "-"], check=True, capture_output=True).stdout
        samples = array.array("h", decoded)
        if sys.byteorder != "little":
            samples.byteswap()
        x = [float(v) for v in samples]
        steady = x[int(0.4 * 44100):int(1.4 * 44100)]
        hz = measure_pitch(steady, 44100, options.get("lowest", 55.0))
        exact = 69 + 12 * math.log2(hz / 440.0)
        if tuned_to_pitch:
            token = _NOTE_IN_NAME.search(name)
            letter = token.group(1).capitalize()            # "bb" → "Bb", "a" → "A"
            note = midi(_FLATS.get(letter, letter), int(token.group(2)) + octave_shift)
            # distance from that key to what was measured, ignoring whole octaves
            off = ((exact - note + 6) % 12) - 6
            if tune == "none":
                exact = float(note)
            elif tune == "loose":
                # An instrument in its own tuning (kalimba): the name is only the
                # nearest Western note. Follow the measurement when it lands within
                # two semitones of the name; otherwise it has locked onto an
                # overtone — keep the named key, untuned.
                if abs(exact - note) <= 2:
                    note = round(exact)
                else:
                    exact = float(note)
            elif abs(off) <= 1.5:
                # In tune, or mislabelled by a semitone (one clarinet take is):
                # the measurement names the key and supplies the cents.
                note += round(off)
                exact = note + (off - round(off))
            else:
                exact = float(note)                # measurement unusable: trust the name
        else:
            note = round(exact)
        if note in roots or not 24 <= note <= 108:
            print(f"  {instrument}: skipped {name} (MIDI {note} already covered or out of range)")
            continue
        tuned = to_44k(x, 44100 * 2 ** ((note - exact) / 12), tmp)[:int(keep * 44100)]
        if flatten:
            tuned = flatten_sustain(tuned)
        fade_len = int(fade * 44100)
        for k in range(min(fade_len, len(tuned))):
            tuned[len(tuned) - 1 - k] *= k / fade_len
        gain = 0.7 * 32767 / max(1.0, max(abs(v) for v in tuned))
        out = array.array("h", (max(-32766, min(32766, int(round(v * gain)))) for v in tuned))
        if sys.byteorder != "little":
            out.byteswap()
        with wave.open(str(out_dir / f"{note}_64.wav"), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(44100)
            wf.writeframes(out.tobytes())
        roots.append(note)
        heard = 69 + 12 * math.log2(hz / 440.0)
        print(f"  {instrument}: MIDI {note:3d} ← {name.split('/')[-1]}  (measures as MIDI {heard:6.2f}, "
              f"corrected {100 * (note - exact):+5.1f} cents)")
    return sorted(roots)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", choices=sorted(list(PLANS) + list(VCSL_INSTRUMENTS)),
                        help="install just this instrument")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache" / "supernova-samples")
    args = parser.parse_args()
    wanted = [args.only] if args.only else list(PLANS) + list(VCSL_INSTRUMENTS)
    measured: dict[str, list[int]] = {}
    for instrument in wanted:
        if instrument in PLANS:
            install(instrument, args.cache)
        else:
            measured[instrument] = install_vcsl(instrument, args.cache)
    if measured:
        print("\nrootNotes for the VCSL instruments (SynthPreset.swift):")
        for instrument, roots in measured.items():
            print(f"  {instrument}: {roots}")
    print("\nDone. Now run: python3 Scripts/validate_samples.py")


if __name__ == "__main__":
    main()
