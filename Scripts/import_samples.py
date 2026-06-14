#!/usr/bin/env python3
"""
import_samples.py — Convert free CC0/CC-BY sample libraries to OmnisphereSynth format.

Output: mono 16-bit PCM WAV @ 44100 Hz, named {midi_note}_{velocity}.wav

Supported sources
─────────────────
  salamander      Salamander Grand Piano V3 (CC BY 3.0) → grand_piano
                  Files named like: A0v1.wav, C#4v16.wav, Bb2v8.wav

  vsco2-strings   VSCO2 Community Edition strings (CC0) → string_ensemble
  vsco2-flute     VSCO2 Community Edition flute (CC0)   → concert_flute
                  Files named like: Strings_arco_ff_C3_v1.wav

  sfz             Any SFZ instrument (e.g. ChurchOrganEmulation) → pipe_organ.
                  Parses the .sfz mapping (pitch_keycenter / key / lokey-hikey,
                  lovel-hivel, sample=, default_path=). Pass the .sfz file OR a
                  folder containing one as --input.

  generic         Any folder where each file is a single pitch (WAV/MP3/AIFF/FLAC).
                  Note is read from the filename as either a MIDI number or a
                  note name (A4, Cs5='C#5', Ab3). Dynamic words/abbreviations
                  (pianissimo..fortissimo, pp..ff) pick the soft/hard layer.
                  --require / --exclude filter by articulation, e.g.
                  --require arco-normal (strings) to skip pizzicato/tremolo.
                  This is the mode for the Philharmonia Orchestra library:
                    violin_A4_15_forte_arco-normal.mp3
                  MP3/AIFF are decoded via afconvert (macOS) or ffmpeg.

Usage examples
──────────────
  pip3 install scipy numpy        # one-time; enables resampling

  python3 Scripts/import_samples.py \\
      --source salamander \\
      --input ~/Downloads/SalamanderGrandPianoV3

  python3 Scripts/import_samples.py \\
      --source vsco2-strings \\
      --input ~/Downloads/VSCO2-CE/Strings

  python3 Scripts/import_samples.py \\
      --source vsco2-flute \\
      --input ~/Downloads/VSCO2-CE/Woodwinds/Flute

  python3 Scripts/import_samples.py \\
      --source sfz \\
      --input ~/Downloads/ChurchOrganEmulation

  # Philharmonia strings → String Ensemble (sustained bowed takes only):
  python3 Scripts/import_samples.py \\
      --source generic \\
      --input ~/Downloads/all-samples/violin \\
      --output OmnisphereSynth/Resources/Samples/string_ensemble \\
      --require arco-normal

  # Philharmonia flute → Concert Flute:
  python3 Scripts/import_samples.py \\
      --source generic \\
      --input ~/Downloads/all-samples/flute \\
      --output OmnisphereSynth/Resources/Samples/concert_flute \\
      --require normal --exclude flutter,staccato,trill

By default the matching SamplerInstrument descriptor's `rootNotes` in
OmnisphereSynth/Models/SynthPreset.swift is patched to match the files that
were actually written — this keeps SamplerEngine.load()'s loaded==expected
assertion satisfied even when a library's key coverage is irregular. Disable
with --no-patch.

After running, validate with:
  python3 Scripts/validate_samples.py
"""

from __future__ import annotations

import argparse
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from math import gcd
from pathlib import Path

# ── Optional scipy for resampling ─────────────────────────────────────────────

try:
    import numpy as np
    from scipy.io import wavfile
    from scipy.signal import resample_poly
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False

TARGET_SR   = 44100
TARGET_BITS = 16
TARGET_CHAN  = 1  # mono

# ── Note-name → MIDI ──────────────────────────────────────────────────────────

_PITCH_CLASS: dict[str, int] = {
    "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3,
    "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8,
    "A": 9, "A#": 10, "Bb": 10, "B": 11,
}

def note_to_midi(name: str, octave: int) -> int:
    """Return MIDI note number; C4 = 60."""
    return _PITCH_CLASS[name] + (octave + 1) * 12

# ── Audio decode (MP3/AIFF/FLAC → WAV) ────────────────────────────────────────

def _decoder() -> list[str] | None:
    """Return a command template for decoding to mono/16-bit/44100 WAV.
    Prefers macOS afconvert, falls back to ffmpeg. None if neither exists."""
    if shutil.which("afconvert"):
        return ["afconvert", "-f", "WAVE", "-d", f"LEI16@{TARGET_SR}", "-c", "1"]
    if shutil.which("ffmpeg"):
        return ["ffmpeg", "-y", "-loglevel", "error", "-ac", "1", "-ar", str(TARGET_SR)]
    return None

def ensure_wav(src: Path) -> tuple[Path, Path | None]:
    """If src is already WAV, return it unchanged. Otherwise decode to a temp
    mono/16-bit/44100 WAV and return (temp_path, temp_path_to_clean_up)."""
    if src.suffix.lower() == ".wav":
        return src, None
    dec = _decoder()
    if dec is None:
        raise RuntimeError(
            f"cannot decode {src.suffix} — install ffmpeg, or run on macOS "
            f"(afconvert). WAV inputs need no decoder.")
    tmp = Path(tempfile.mkstemp(suffix=".wav")[1])
    if dec[0] == "afconvert":
        cmd = dec + [str(src), str(tmp)]
    else:  # ffmpeg: input before output
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
               "-ac", "1", "-ar", str(TARGET_SR), str(tmp)]
    subprocess.run(cmd, check=True)
    return tmp, tmp

# ── Audio conversion ──────────────────────────────────────────────────────────

def convert_wav(src: Path) -> bytes:
    """Return mono 16-bit 44100 Hz PCM bytes for any WAV/MP3/AIFF/FLAC input."""
    wav, cleanup = ensure_wav(src)
    try:
        if HAS_SCIPY:
            return _convert_scipy(wav)
        return _convert_stdlib(wav)
    finally:
        if cleanup is not None:
            cleanup.unlink(missing_ok=True)

def _convert_scipy(src: Path) -> bytes:
    sr, data = wavfile.read(str(src))

    # Stereo → mono
    if data.ndim > 1:
        data = data.mean(axis=1)

    # Normalise to float64 [-1, 1]
    if data.dtype == np.int16:
        f = data.astype(np.float64) / 32768.0
    elif data.dtype == np.int32:
        f = data.astype(np.float64) / 2_147_483_648.0
    elif data.dtype in (np.float32, np.float64):
        f = data.astype(np.float64)
    else:
        raise ValueError(f"Unsupported dtype {data.dtype} in {src}")

    # Resample
    if sr != TARGET_SR:
        g = gcd(TARGET_SR, sr)
        f = resample_poly(f, TARGET_SR // g, sr // g)

    pcm = (np.clip(f, -1.0, 1.0) * 32767).astype(np.int16)
    return pcm.tobytes()

def _convert_stdlib(src: Path) -> bytes:
    """No scipy: stereo→mono, no resampling. Refuses to fake the sample rate."""
    with wave.open(str(src), "rb") as wf:
        nch = wf.getnchannels()
        sw  = wf.getsampwidth()
        sr  = wf.getframerate()
        raw = wf.readframes(wf.getnframes())

    if sr != TARGET_SR:
        # Writing a TARGET_SR header over differently-rated samples would silently
        # transpose the instrument. Don't — require scipy for real resampling.
        raise ValueError(
            f"source is {sr} Hz but target is {TARGET_SR} Hz and scipy is not "
            f"installed to resample. Run: pip3 install scipy numpy")

    if sw == 2:
        n    = len(raw) // 2
        vals = list(struct.unpack(f"<{n}h", raw))
    elif sw == 3:
        n = len(raw) // 3
        vals = []
        for i in range(n):
            b3 = raw[i * 3: i * 3 + 3]
            b4 = b3 + (b"\xff" if b3[2] & 0x80 else b"\x00")
            v  = struct.unpack("<i", b4)[0] >> 8
            vals.append(max(-32768, min(32767, v >> 8)))
    elif sw == 4:
        n    = len(raw) // 4
        vals = [max(-32768, min(32767, v >> 16))
                for v in struct.unpack(f"<{n}i", raw)]
    else:
        raise ValueError(f"Unsupported sample width {sw} in {src}")

    if nch == 2:
        vals = [(vals[i] + vals[i + 1]) // 2 for i in range(0, len(vals), 2)]

    return struct.pack(f"<{len(vals)}h", *vals)

def write_wav(path: Path, pcm: bytes) -> None:
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(TARGET_CHAN)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_SR)
        wf.writeframes(pcm)

# ── Instrument layouts ────────────────────────────────────────────────────────

# (output_velocity_midi, preference_label)
_LAYERS = [
    (64,  "soft"),
    (110, "hard"),
]

_ROOTS = {
    "grand_piano":      list(range(24, 97, 3)),   # 25 roots
    "string_ensemble":  list(range(36, 85, 3)),   # 17 roots
    "concert_flute":    list(range(60, 97, 3)),   # 13 roots
    "pipe_organ":       list(range(24, 97, 3)),   # 25 roots (wide; trimmed to source)
}

# Maps an instrument id → the Swift static-let descriptor name to patch.
_DESCRIPTOR_NAMES = {
    "grand_piano":     "grandPiano",
    "string_ensemble": "stringEnsemble",
    "concert_flute":   "concertFlute",
    "pipe_organ":      "pipeOrgan",
}

# ── Source scanners ───────────────────────────────────────────────────────────

# Each scanner returns: dict[midi_note, {"soft": Path | None, "hard": Path | None}]

_SAL_RE = re.compile(r"^([A-G][#b]?)(-?\d+)v(\d+)\.wav$", re.IGNORECASE)

def scan_salamander(src: Path) -> dict[int, dict]:
    """Salamander Grand Piano: A0v1.wav … C#4v16.wav"""
    out: dict[int, dict] = {}
    for f in sorted(src.iterdir()):
        m = _SAL_RE.match(f.name)
        if not m:
            continue
        raw_name = m.group(1)
        # Normalise: uppercase root, keep # or b
        name = raw_name[0].upper() + raw_name[1:]
        if name not in _PITCH_CLASS:
            continue
        midi = note_to_midi(name, int(m.group(2)))
        vel  = int(m.group(3))
        out.setdefault(midi, {})[vel] = f
    return out

def _pick_salamander(vel_map: dict, want: str) -> Path | None:
    if not vel_map:
        return None
    target = 4 if want == "soft" else 12
    best = min(vel_map, key=lambda v: abs(v - target))
    return vel_map[best]

# VSCO2 filenames contain a note token like _C3_ or _A#4_
_VSCO2_NOTE_RE = re.compile(r"_([A-G][#b]?)(\d+)_", re.IGNORECASE)
_DYNAMIC_RE    = re.compile(r"_(pp|mp|mf|ff|p|f|fff)_", re.IGNORECASE)

def scan_vsco2(src: Path) -> dict[int, dict]:
    """
    VSCO2 Community Edition: Strings_arco_ff_C3_v1.wav
    Maps pp/mp → soft, mf/ff/fff → hard.
    """
    out: dict[int, dict] = {}
    for f in sorted(src.rglob("*.wav")):
        mn = _VSCO2_NOTE_RE.search(f.name)
        if not mn:
            continue
        raw_name = mn.group(1)
        name = raw_name[0].upper() + raw_name[1:]
        if name not in _PITCH_CLASS:
            continue
        midi = note_to_midi(name, int(mn.group(2)))
        out.setdefault(midi, {})
        md = _DYNAMIC_RE.search(f.name)
        dyn = md.group(1).lower() if md else "mf"
        if dyn in ("pp", "mp", "p"):
            out[midi]["soft"] = f
        else:
            out[midi]["hard"] = f
    return out

def _pick_vsco2(vel_map: dict, want: str) -> Path | None:
    return vel_map.get(want) or vel_map.get("hard") or vel_map.get("soft")

# ── SFZ ───────────────────────────────────────────────────────────────────────

_SFZ_HEADER_RE  = re.compile(r"<(\w+)>")
_SFZ_OPCODE_RE  = re.compile(r"(\w+)=([^=]+?)(?=\s+\w+=|$)")
_SFZ_NOTE_RE    = re.compile(r"^([A-Ga-g])([#b]?)(-?\d+)$")

def parse_sfz_note(token: str, octave_offset: int) -> int | None:
    """SFZ key/pitch_keycenter: a number (MIDI) or a note name like c4 (c4=60)."""
    token = token.strip()
    if token.lstrip("-").isdigit():
        return int(token)
    m = _SFZ_NOTE_RE.match(token)
    if not m:
        return None
    name = m.group(1).upper() + m.group(2).replace("B", "b")
    if name not in _PITCH_CLASS:
        return None
    return note_to_midi(name, int(m.group(3))) + 12 * octave_offset

def _resolve_sfz_path(sfz_dir: Path, default_path: str, sample: str) -> Path | None:
    """Resolve a region's sample= against default_path and the .sfz directory.
    SFZ uses backslash separators; normalise to the host OS."""
    sample = sample.strip().replace("\\", "/")
    base = sfz_dir
    if default_path:
        base = (sfz_dir / default_path.strip().replace("\\", "/"))
    cand = (base / sample)
    if cand.exists():
        return cand
    # Fall back to a recursive search by basename (handles odd default_path).
    matches = list(sfz_dir.rglob(Path(sample).name))
    return matches[0] if matches else None

def _tokenize_sfz(text: str) -> list[tuple[str, dict]]:
    """Split SFZ into (header, opcodes) blocks. Strips comments."""
    # Remove // line comments and /* */ block comments.
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", " ", text)
    blocks: list[tuple[str, dict]] = []
    pos = 0
    for m in _SFZ_HEADER_RE.finditer(text):
        if blocks:  # body of the previous header runs up to this one
            body = text[pos:m.start()]
            blocks[-1][1].update(dict(_SFZ_OPCODE_RE.findall(body)))
        blocks.append((m.group(1).lower(), {}))
        pos = m.end()
    if blocks:
        blocks[-1][1].update(dict(_SFZ_OPCODE_RE.findall(text[pos:])))
    return blocks

def scan_sfz(sfz_path: Path, octave_offset: int) -> dict[int, list]:
    """
    Parse an SFZ instrument. Returns dict[root_midi] -> list of
    (lovel, hivel, Path). Honours <global>/<group> opcode inheritance and
    default_path. Organs are usually one full-velocity region per key.
    """
    if sfz_path.is_dir():
        sfzs = sorted(sfz_path.rglob("*.sfz"))
        if not sfzs:
            print(f"ERROR: no .sfz file found under {sfz_path}", file=sys.stderr)
            sys.exit(1)
        sfz_path = sfzs[0]
        print(f"Using SFZ mapping: {sfz_path}")

    sfz_dir = sfz_path.parent
    text = sfz_path.read_text(errors="ignore")
    blocks = _tokenize_sfz(text)

    out: dict[int, list] = {}
    inherited: dict[str, str] = {}   # from <global>/<master>/<group>
    for header, op in blocks:
        if header in ("global", "master", "group", "control"):
            if header == "control" and "default_path" in op:
                inherited["default_path"] = op["default_path"]
            else:
                inherited.update(op)
            continue
        if header != "region":
            continue

        merged = {**inherited, **op}
        sample = merged.get("sample")
        if not sample:
            continue

        # Root note: pitch_keycenter > key > centre of lokey..hikey
        root = None
        for k in ("pitch_keycenter", "key"):
            if k in merged:
                root = parse_sfz_note(merged[k], octave_offset)
                if root is not None:
                    break
        if root is None and "lokey" in merged and "hikey" in merged:
            lo = parse_sfz_note(merged["lokey"], octave_offset)
            hi = parse_sfz_note(merged["hikey"], octave_offset)
            if lo is not None and hi is not None:
                root = (lo + hi) // 2
        if root is None:
            continue

        lovel = int(merged.get("lovel", 0))
        hivel = int(merged.get("hivel", 127))

        path = _resolve_sfz_path(sfz_dir, merged.get("default_path", ""), sample)
        if path is None:
            print(f"  [WARN] sample not found on disk: {sample}", file=sys.stderr)
            continue
        out.setdefault(root, []).append((lovel, hivel, path))
    return out

def _pick_sfz(regions: list, want: str) -> Path | None:
    """Choose the region whose velocity range contains 64 (soft) or 110 (hard).
    Falls back to the region with the widest velocity coverage."""
    if not regions:
        return None
    target = 64 if want == "soft" else 110
    for lovel, hivel, path in regions:
        if lovel <= target <= hivel:
            return path
    # Widest coverage (organs typically have a single 0–127 region per key).
    return max(regions, key=lambda r: r[1] - r[0])[2]

_MIDI_IN_NAME_RE = re.compile(r"\b(\d{1,3})\b")
# A note-name token: letter + optional accidental (#, s=sharp, b=flat) + octave.
_NAME_TOKEN_RE = re.compile(r"^([A-Ga-g])([#sb]?)(-?\d{1,2})$")

# Dynamic markings → loudness rank (0 = softest, 5 = loudest). Used to pick which
# take feeds the soft (target ~1) vs hard (target ~4) velocity layer.
_DYNAMIC_RANK = {
    "pianissimo": 0, "pp": 0,
    "piano": 1, "p": 1,
    "mezzo-piano": 2, "mezzopiano": 2, "mp": 2,
    "mezzo-forte": 3, "mezzoforte": 3, "mf": 3,
    "forte": 4, "f": 4,
    "fortissimo": 5, "ff": 5, "fff": 5,
}
_DEFAULT_RANK = 3   # unknown dynamic → treat as mezzo-forte

def parse_name_note(token: str) -> int | None:
    """'A4' -> 69, 'Cs5' -> 73 (s=sharp), 'Ab3' -> 56 (b=flat). None if not a note."""
    m = _NAME_TOKEN_RE.match(token)
    if not m:
        return None
    letter = m.group(1).upper()
    acc    = m.group(2).lower()
    base   = _PITCH_CLASS.get(letter)
    if base is None:
        return None
    if acc in ("#", "s"):
        base += 1
    elif acc == "b":
        base -= 1
    return base + (int(m.group(3)) + 1) * 12

def _note_from_filename(stem: str, note_style: str) -> int | None:
    """Extract a MIDI note. note_style: 'auto' tries note-name tokens first then
    a bare integer; 'name' only note-name; 'midi' only integer."""
    tokens = re.split(r"[ _\-.]+", stem)
    if note_style in ("auto", "name"):
        for tok in tokens:
            n = parse_name_note(tok)
            if n is not None and 0 <= n <= 127:
                return n
        if note_style == "name":
            return None
    # MIDI integer (skip note-name tokens so e.g. duration '15' isn't mistaken).
    m = _MIDI_IN_NAME_RE.search(stem)
    if m:
        v = int(m.group(1))
        if 0 <= v <= 127:
            return v
    return None

def _dynamic_rank(name_lc: str) -> int:
    tokens = re.split(r"[ _\-.]+", name_lc)
    for tok in tokens:                       # exact token match first (precise)
        if tok in _DYNAMIC_RANK:
            return _DYNAMIC_RANK[tok]
    for word in ("fortissimo", "mezzo-forte", "forte",
                 "pianissimo", "mezzo-piano", "piano"):   # longest-first substring
        if word in name_lc:
            return _DYNAMIC_RANK[word]
    return _DEFAULT_RANK

_AUDIO_EXTS = {".wav", ".mp3", ".aif", ".aiff", ".flac"}

def scan_generic(src: Path, note_style: str,
                 require: list[str], exclude: list[str]) -> dict[int, list]:
    """Returns dict[midi] -> list of (rank, path). Filters by articulation:
    a file must contain every --require substring and no --exclude substring."""
    out: dict[int, list] = {}
    for f in sorted(src.rglob("*")):
        if f.suffix.lower() not in _AUDIO_EXTS:
            continue
        name_lc = f.name.lower()
        if require and not all(r in name_lc for r in require):
            continue
        if exclude and any(x in name_lc for x in exclude):
            continue
        midi = _note_from_filename(f.stem, note_style)
        if midi is None:
            continue
        out.setdefault(midi, []).append((_dynamic_rank(name_lc), f))
    return out

def _pick_generic(regions: list, want: str) -> Path | None:
    """Pick the take whose dynamic rank is closest to soft (~1) or hard (~4)."""
    if not regions:
        return None
    target = 1 if want == "soft" else 4
    return min(regions, key=lambda r: (abs(r[0] - target), r[0]))[1]

# ── Core importer ─────────────────────────────────────────────────────────────

def nearest(target: int, pool: list[int]) -> int:
    return min(pool, key=lambda x: abs(x - target))

def import_instrument(
    file_map: dict[int, dict],
    pick_fn,
    roots: list[int],
    out_dir: Path,
    instrument_id: str,
) -> list[int]:
    """Writes the WAV grid. Returns the sorted list of roots that ended up with
    a complete set of velocity layers (the set the descriptor must declare)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    available = sorted(file_map)
    if not available:
        print(f"ERROR: no samples found for {instrument_id}", file=sys.stderr)
        sys.exit(1)

    wrote        = 0
    skipped      = []
    complete     = []   # roots with ALL velocity layers written

    for root in roots:
        near = nearest(root, available)
        if abs(root - near) > 6:
            skipped.append(root)
            print(f"  [WARN] MIDI {root}: nearest source is {near} "
                  f"({abs(root-near)} semitones away — skipping)")
            continue

        layers_written = 0
        for vel_midi, vel_label in _LAYERS:
            src_path = pick_fn(file_map[near], vel_label)
            if src_path is None:
                print(f"  [WARN] MIDI {root}: no {vel_label} sample")
                continue
            out_path = out_dir / f"{root}_{vel_midi}.wav"
            try:
                pcm = convert_wav(src_path)
                write_wav(out_path, pcm)
                wrote += 1
                layers_written += 1
                if wrote <= 5 or wrote % 10 == 0:
                    print(f"  [{wrote:3d}] {out_path.name:20s} ← {src_path.name}")
            except Exception as exc:
                print(f"  [ERROR] {src_path}: {exc}", file=sys.stderr)

        # SamplerEngine requires every declared root to have every velocity layer;
        # only count a root as usable if all layers landed.
        if layers_written == len(_LAYERS):
            complete.append(root)
        elif layers_written > 0:
            # Remove the partial set so the folder stays consistent with the descriptor.
            for vel_midi, _ in _LAYERS:
                (out_dir / f"{root}_{vel_midi}.wav").unlink(missing_ok=True)
            skipped.append(root)

    print(f"\nWrote {wrote} files to {out_dir}")
    if skipped:
        print(f"Skipped MIDI notes (no nearby/complete source): {sorted(skipped)}")
    return complete

def _camel(s: str) -> str:
    words = s.split("_")
    return words[0] + "".join(w.capitalize() for w in words[1:])

def _display(s: str) -> str:
    return " ".join(w.capitalize() for w in s.split("_"))

def _swift_roots_literal(roots: list[int]) -> str:
    return "[" + ", ".join(str(r) for r in roots) + "]"

def _print_descriptor(iid: str, roots: list[int]) -> None:
    name = _DESCRIPTOR_NAMES.get(iid, _camel(iid))
    print(f"""
── SamplerInstrument descriptor ────────────────────────────────────────
    static let {name} = SamplerInstrument(
        id: "{iid}", displayName: "{_display(iid)}",
        rootNotes: {_swift_roots_literal(roots)},
        velocityLayers: [
            VelocityLayer(midiValue: 64,  loVel: 0,   hiVel: 63),
            VelocityLayer(midiValue: 110, loVel: 64,  hiVel: 127),
        ]
    )
────────────────────────────────────────────────────────────────────────""")

def patch_descriptor(swift_path: Path, iid: str, roots: list[int]) -> bool:
    """Rewrite the `rootNotes:` line of the `static let <name> = SamplerInstrument`
    block whose `id:` matches `iid`, so it exactly matches the files just written.
    Returns True if a substitution was made."""
    name = _DESCRIPTOR_NAMES.get(iid)
    if name is None:
        return False
    if not swift_path.exists():
        print(f"  [WARN] {swift_path} not found — skipping descriptor patch.",
              file=sys.stderr)
        return False

    text = swift_path.read_text()
    anchor = f'id: "{iid}"'
    start = text.find(anchor)
    if start < 0:
        print(f"  [WARN] descriptor for id \"{iid}\" not found in {swift_path.name}.")
        return False

    # Replace the first `rootNotes: <...>,` after the anchor (single line).
    rn = re.compile(r"(\n[ \t]*rootNotes:\s*).*?(,[ \t]*\n)")
    m = rn.search(text, start)
    if not m:
        print(f"  [WARN] rootNotes line not found for \"{iid}\".")
        return False

    new_line = m.group(1) + _swift_roots_literal(roots) + m.group(2)
    text = text[:m.start()] + new_line + text[m.end():]
    swift_path.write_text(text)
    print(f"  Patched {swift_path.name}: {name}.rootNotes = "
          f"{len(roots)} notes {_swift_roots_literal(roots)}")
    return True

# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--source", required=True,
                   choices=["salamander", "vsco2-strings", "vsco2-flute", "sfz", "generic"],
                   help="Sample library format")
    p.add_argument("--input", required=True, type=Path,
                   help="Folder (or .sfz file) containing the downloaded sample library")
    p.add_argument("--output", type=Path, default=None,
                   help="Output folder (default: OmnisphereSynth/Resources/Samples/<id>)")
    p.add_argument("--note-style", choices=["auto", "name", "midi"], default="auto",
                   help="How to read the note from a generic filename (default auto)")
    p.add_argument("--require", default="",
                   help="Comma-separated substrings a generic file MUST contain "
                        "(e.g. arco-normal). Use to keep sustained takes only.")
    p.add_argument("--exclude", default="",
                   help="Comma-separated substrings that disqualify a generic file "
                        "(e.g. pizz,tremolo,staccato,trill)")
    p.add_argument("--octave-offset", type=int, default=0,
                   help="Add N octaves to SFZ note names (use 1 if a library treats c3 as MIDI 60)")
    p.add_argument("--patch", type=Path,
                   default=Path("OmnisphereSynth/Models/SynthPreset.swift"),
                   help="Swift file whose SamplerInstrument rootNotes are updated to match output")
    p.add_argument("--no-patch", action="store_true",
                   help="Do not edit the Swift descriptor; just print the suggested one")
    args = p.parse_args()

    if not HAS_SCIPY:
        print("NOTE: scipy/numpy not found — no resampling. "
              "Install with: pip3 install scipy numpy\n", file=sys.stderr)

    src = args.input.expanduser().resolve()
    if not src.exists():
        print(f"ERROR: --input {src} does not exist", file=sys.stderr)
        sys.exit(1)

    source = args.source
    if source == "salamander":
        iid     = "grand_piano"
        fmap    = scan_salamander(src)
        pick_fn = _pick_salamander
    elif source == "vsco2-strings":
        iid     = "string_ensemble"
        fmap    = scan_vsco2(src)
        pick_fn = _pick_vsco2
    elif source == "vsco2-flute":
        iid     = "concert_flute"
        fmap    = scan_vsco2(src)
        pick_fn = _pick_vsco2
    elif source == "sfz":
        iid     = args.output.name if args.output else "pipe_organ"
        fmap    = scan_sfz(src, args.octave_offset)
        pick_fn = _pick_sfz
    else:  # generic
        iid     = args.output.name if args.output else "unknown"
        require = [s.strip().lower() for s in args.require.split(",") if s.strip()]
        exclude = [s.strip().lower() for s in args.exclude.split(",") if s.strip()]
        fmap    = scan_generic(src, args.note_style, require, exclude)
        pick_fn = _pick_generic

    out = args.output or (Path("OmnisphereSynth/Resources/Samples") / iid)

    print(f"Source   : {source}")
    print(f"Input    : {src}")
    print(f"Output   : {out.resolve()}")
    print(f"Scipy    : {'yes (resampling enabled)' if HAS_SCIPY else 'no  (install scipy)'}\n")

    note_count = len(fmap)
    print(f"Found {note_count} unique MIDI notes in source\n")
    if note_count == 0:
        print("ERROR: No matching files found. Check --input path and --source format.",
              file=sys.stderr)
        sys.exit(1)

    roots = import_instrument(fmap, pick_fn, _ROOTS.get(iid, list(range(36, 85, 3))), out, iid)
    if not roots:
        print("ERROR: no complete roots written — nothing to wire up.", file=sys.stderr)
        sys.exit(1)

    if args.no_patch:
        _print_descriptor(iid, roots)
    else:
        patched = patch_descriptor(args.patch, iid, roots)
        if not patched:
            _print_descriptor(iid, roots)

    print("\nNext:")
    print("  python3 Scripts/validate_samples.py")

if __name__ == "__main__":
    main()
