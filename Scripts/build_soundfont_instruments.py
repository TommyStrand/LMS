#!/usr/bin/env python3
"""
build_soundfont_instruments.py — build the app's reed, choir, voice and fiddle
instruments from recordings in the GeneralUser GS SoundFont.

Why: Harmonium, Musette Accordion, Choir Ahs, Vox Humana and Hurdy-Gurdy were
two-oscillator synth patches and sounded like it. A SoundFont holds short REAL
recordings (the attack of a note plus a loop cut from its sustain); this script
turns those into the app's sample format.

Source: GeneralUser GS 2.0.3 by S. Christian Collins
        https://github.com/mrbumpy409/GeneralUser-GS
Licence: free to use, also in software projects and commercially (see
        documentation/LICENSE.txt in that repository). Its author notes that he
        cannot be completely sure of the origin of every sample collected from
        free SoundFonts over the years — see CREDITS.md.

What is built (one velocity layer each, mono 16-bit 44.1 kHz, {midi}_64.wav):

  reed_organ         accordion reeds: a reed + the octave below + a faintly
                     detuned second reed            → Harmonium
  musette_accordion  accordion reeds: three reeds, one in tune, one sharp, one
                     flat — the musette "wet" beat  → Musette Accordion
  concert_choir      mixed choir "aah"              → Choir Ahs
  voice_oohs         voices "ooh"                   → Vox Humana
  fiddle             solo violin                    → Hurdy-Gurdy (nearest real
                                                      bowed-string recording)

Each note is rendered as attack + the SoundFont's own loop repeated to a few
seconds, so the app's sustain loop has steady material to hold. The pitch of
every recording is MEASURED and compared with the tuning the SoundFont declares
(root key and cent correction); the recording is then re-pitched by the few
cents needed to sit exactly on a semitone, and the file is written under that
note. Run Scripts/validate_samples.py afterwards.

Needs: python3, curl, ffmpeg. Downloads the 32 MB SoundFont into a cache folder.
"""
from __future__ import annotations

import argparse
import array
import math
import struct
import subprocess
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_free_samples import flatten_sustain  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
SAMPLES   = REPO_ROOT / "OmnisphereSynth" / "Resources" / "Samples"
SF2_URL   = "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"
RATE      = 44100


# ── Minimal SoundFont 2 reader ───────────────────────────────────────────────

class SoundFont:
    def __init__(self, path: Path):
        d = path.read_bytes()
        if d[:4] != b"RIFF" or d[8:12] != b"sfbk":
            raise ValueError(f"{path} is not a SoundFont")
        self.d = d
        self.chunks: dict[bytes, tuple[int, int]] = {}

        def walk(i: int, end: int) -> None:
            while i + 8 <= end:
                tag, n = d[i:i + 4], struct.unpack("<I", d[i + 4:i + 8])[0]
                if tag == b"LIST":
                    walk(i + 12, i + 8 + n)
                else:
                    self.chunks[tag] = (i + 8, n)
                i += 8 + n + (n & 1)

        walk(12, len(d))
        self.phdr = self._records(b"phdr", "<20sHHHIII")
        self.pbag = self._records(b"pbag", "<HH")
        self.pgen = self._records(b"pgen", "<HH")
        self.inst = self._records(b"inst", "<20sH")
        self.ibag = self._records(b"ibag", "<HH")
        self.igen = self._records(b"igen", "<HH")
        self.shdr = self._records(b"shdr", "<20sIIIIIBbHH")

    def _records(self, tag: bytes, fmt: str) -> list[tuple]:
        offset, size = self.chunks[tag]
        step = struct.calcsize(fmt)
        return [struct.unpack(fmt, self.d[offset + k * step:offset + (k + 1) * step])
                for k in range(size // step)]

    def first_instrument_samples(self, bank: int, program: int) -> list[dict]:
        """The distinct samples of the preset's first instrument layer, low to high."""
        preset = next(i for i, p in enumerate(self.phdr[:-1]) if p[1] == program and p[2] == bank)
        instrument = None
        for bag in range(self.phdr[preset][3], self.phdr[preset + 1][3]):
            gens = dict(self.pgen[g] for g in range(self.pbag[bag][0], self.pbag[bag + 1][0]))
            if 41 in gens:                       # generator 41 = instrument
                instrument = gens[41]
                break
        if instrument is None:
            raise ValueError(f"preset {bank}:{program} has no instrument")
        seen, out = set(), []
        for bag in range(self.inst[instrument][1], self.inst[instrument + 1][1]):
            gens = dict(self.igen[g] for g in range(self.ibag[bag][0], self.ibag[bag + 1][0]))
            if 53 not in gens or gens[53] in seen:   # generator 53 = sampleID
                continue
            seen.add(gens[53])
            _name, start, end, loop_start, loop_end, rate, original, correction, *_ = self.shdr[gens[53]]
            root = gens.get(58, original)            # generator 58 = overridingRootKey
            base = self.chunks[b"smpl"][0]
            pcm = array.array("h", self.d[base + start * 2:base + end * 2])
            if sys.byteorder != "little":
                pcm.byteswap()
            out.append({"pcm": pcm, "loop": (loop_start - start, loop_end - start), "rate": rate,
                        # The pitch the SoundFont's author tuned this recording to.
                        "declared": root - correction / 100.0})
        return out


# ── Rendering ────────────────────────────────────────────────────────────────

def render(sample: dict, seconds: float) -> list[float]:
    """Attack, then the SoundFont's loop repeated, at the sample's own rate."""
    pcm, (a, b) = sample["pcm"], sample["loop"]
    total = int(seconds * sample["rate"])
    out = [float(v) for v in pcm[:b]]
    loop = [float(v) for v in pcm[a:b]]
    if not loop:
        return out[:total]
    while len(out) < total:
        out.extend(loop)
    return out[:total]


def measure_pitch(x: list[float], rate: float) -> float:
    """Fundamental (Hz) of the steady part: the lag that minimises the mean
    squared difference (as in YIN), refined between lags by a parabola."""
    n = min(len(x) // 2, int(rate * 0.12))
    seg = x[len(x) // 2:len(x) // 2 + 2 * n]
    lo, hi = int(rate / 1500), min(n - 1, int(rate / 55))
    diffs, running = [], 0.0
    best, best_val = lo, float("inf")
    for lag in range(1, hi + 1):
        d = sum((seg[i] - seg[i + lag]) ** 2 for i in range(0, n, 2))
        running += d
        norm = d * lag / running if running > 0 else 1.0      # cumulative-mean normalised
        diffs.append(norm)
    # first clear dip below a threshold (avoids octave-too-low picks), else the minimum
    for lag in range(lo, hi):
        v = diffs[lag - 1]
        if v < 0.15 and v <= diffs[lag]:
            while lag + 1 <= hi and diffs[lag] < diffs[lag - 1]:
                lag += 1
            best = lag
            break
    else:
        best = min(range(lo, hi + 1), key=lambda l: diffs[l - 1])
    if 1 < best < hi:
        y0, y1, y2 = diffs[best - 2], diffs[best - 1], diffs[best]
        denom = y0 - 2 * y1 + y2
        shift = 0.5 * (y0 - y2) / denom if denom else 0.0
    else:
        shift = 0.0
    return rate / (best + shift)


def resample(x: list[float], ratio: float) -> list[float]:
    """Linear-interpolation resample: ratio > 1 plays faster (higher)."""
    n = int((len(x) - 1) / ratio)
    out = []
    for k in range(n):
        pos = k * ratio
        i = int(pos)
        frac = pos - i
        out.append(x[i] * (1 - frac) + x[i + 1] * frac)
    return out


def to_44k(x: list[float], rate: float, tmp: Path) -> list[float]:
    """Proper (band-limited) conversion to 44.1 kHz via ffmpeg."""
    peak = max(1.0, max(abs(v) for v in x))
    ints = array.array("h", (int(v / peak * 30000) for v in x))
    if sys.byteorder != "little":
        ints.byteswap()
    src, dst = tmp / "in.raw", tmp / "out.raw"
    src.write_bytes(ints.tobytes())
    # ffmpeg only takes whole-number rates, and the pitch correction makes `rate`
    # fractional — so state both rates ×100. Only their ratio matters.
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(round(rate * 100)), "-ac", "1",
                    "-i", str(src), "-ar", str(RATE * 100), "-ac", "1", "-f", "s16le", str(dst)], check=True)
    out = array.array("h", dst.read_bytes())
    if sys.byteorder != "little":
        out.byteswap()
    return [float(v) for v in out]


def mix(layers: list[tuple[list[float], float]]) -> list[float]:
    n = min(len(x) for x, _ in layers)
    return [sum(x[i] * g for x, g in layers) for i in range(n)]


def write_wav(path: Path, x: list[float], peak: float = 0.7, fade: float = 0.03) -> None:
    n = len(x)
    f = int(fade * RATE)
    for k in range(min(f, n)):
        x[n - 1 - k] *= k / f                          # end at zero
    loudest = max(1.0, max(abs(v) for v in x))
    gain = peak * 32767 / loudest
    ints = array.array("h", (max(-32766, min(32766, int(round(v * gain)))) for v in x))
    if sys.byteorder != "little":
        ints.byteswap()
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(RATE)
        wf.writeframes(ints.tobytes())


# ── Instruments ──────────────────────────────────────────────────────────────
# name → (GM program, seconds, layers, flatten). A layer is (cents offset, gain):
# the recording is mixed with re-pitched copies of itself, e.g. the octave below
# for a second reed bank, or a few cents away for the beating of two reeds.
# flatten: even out the level of the held part. The choir's loop swells and
# sinks by several dB twice a second, which reads as a pulse when held; the
# reeds are NOT flattened — their slow beating is the point.

INSTRUMENTS = {
    "reed_organ":        (21, 3.5, [(0, 1.0), (-1200, 0.55), (4, 0.6)], False),
    "musette_accordion": (21, 3.5, [(0, 1.0), (13, 0.8), (-11, 0.7)], False),
    "concert_choir":     (52, 3.5, [(0, 1.0)], True),
    "voice_oohs":        (53, 3.5, [(0, 1.0)], False),
    "fiddle":            (110, 3.5, [(0, 1.0)], True),
}


def build(name: str, sf: SoundFont, tmp: Path) -> list[int]:
    program, seconds, layers, flatten = INSTRUMENTS[name]
    out_dir = SAMPLES / name
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.wav"):
        old.unlink()
    roots = []
    for sample in sf.first_instrument_samples(0, program):
        raw = render(sample, seconds + 1.5)            # extra: re-pitched layers get shorter
        hz = measure_pitch(raw, sample["rate"])
        measured = 69 + 12 * math.log2(hz / 440.0)
        # Use the author's tuning, but only when the measurement confirms it (a
        # choir or a vibrato makes the measurement itself wobble by 20–30 cents,
        # so it is a check, not the source). A recording where the two disagree
        # by more than half a semitone is left out.
        if abs(sample["declared"] - measured) >= 0.6:
            print(f"  {name}: skipped a recording — declared {sample['declared']:.2f} but measures "
                  f"{measured:.2f}; its pitch can't be trusted")
            continue
        exact = sample["declared"]
        note = round(exact)
        if not 24 <= note <= 108 or note in roots:
            continue
        # Play the recording a touch faster/slower so it lands exactly on the note.
        correction = 2 ** ((note - exact) / 12)
        base = to_44k(raw, sample["rate"] * correction, tmp)
        voices = [(base if cents == 0 else resample(base, 2 ** (cents / 1200)), gain)
                  for cents, gain in layers]
        mixed = mix(voices)[:int(seconds * RATE)]
        if flatten:
            mixed = flatten_sustain(mixed, RATE)
        write_wav(out_dir / f"{note}_64.wav", mixed)
        roots.append(note)
        print(f"  {name}: MIDI {note}  (measured {measured:6.2f}, declared {sample['declared']:6.2f} "
              f"→ corrected {100 * (note - exact):+5.1f} cents)")
    return sorted(roots)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", choices=sorted(INSTRUMENTS))
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache" / "supernova-samples")
    args = parser.parse_args()

    args.cache.mkdir(parents=True, exist_ok=True)
    sf2 = args.cache / "GeneralUser-GS.sf2"
    if not sf2.exists() or sf2.stat().st_size < 1_000_000:
        subprocess.run(["curl", "-sSL", "--fail", "-m", "600", "-o", str(sf2), SF2_URL], check=True)
    sf = SoundFont(sf2)
    tmp = args.cache / "tmp"
    tmp.mkdir(exist_ok=True)

    print("rootNotes for SynthPreset.swift:")
    summary = {}
    for name in ([args.only] if args.only else list(INSTRUMENTS)):
        summary[name] = build(name, sf, tmp)
    for name, roots in summary.items():
        print(f"  {name}: {roots}")
    print("\nDone. Now run: python3 Scripts/validate_samples.py")


if __name__ == "__main__":
    main()
