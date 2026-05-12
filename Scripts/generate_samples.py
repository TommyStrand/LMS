"""
Synthesises royalty-free placeholder instrument samples and writes them as
16-bit mono WAV files. Run once; commit the resulting WAV files to the repo.

Instruments
-----------
grand_piano      – multi-partial decaying string model with inharmonicity
string_ensemble  – six detuned bowed-string voices with vibrato
concert_flute    – breath noise + pure tone with tremolo

Output layout
-------------
  OmnisphereSynth/Resources/Samples/
    grand_piano/     {midi_note}_{velocity}.wav   (MIDI 24-96, step 3)
    string_ensemble/ {midi_note}_{velocity}.wav   (MIDI 36-84, step 3)
    concert_flute/   {midi_note}_{velocity}.wav   (MIDI 60-96, step 3)

velocity is the literal MIDI velocity used:  64 (soft) or 110 (loud)

Attribution / license
---------------------
These samples are synthesised entirely by this script; they contain no
recorded content and are freely usable in commercial works.
"""

import math, wave, struct, os, time

SAMPLE_RATE = 44100
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_ROOT    = os.path.join(SCRIPT_DIR, "..", "OmnisphereSynth", "Resources", "Samples")

NOTE_NAMES = ["C","Cs","D","Ds","E","F","Fs","G","Gs","A","As","B"]
def midi_to_hz(n):   return 440.0 * (2.0 ** ((n - 69) / 12.0))
def midi_name(n):    return NOTE_NAMES[n % 12] + str(n // 12 - 1)

# ---------------------------------------------------------------------------
# Fast random noise (LCG – avoids random.random() overhead)
# ---------------------------------------------------------------------------
_lcg_state = [0xDEADBEEF]
def _lcg():
    _lcg_state[0] = (_lcg_state[0] * 1664525 + 1013904223) & 0xFFFFFFFF
    return (_lcg_state[0] / 0x80000000) - 1.0

def _seed(v): _lcg_state[0] = v & 0xFFFFFFFF

# ---------------------------------------------------------------------------
# WAV writer
# ---------------------------------------------------------------------------
def write_wav(path, samples_f):
    """samples_f: list of float in [-1.0, 1.0]"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    peak = max(abs(x) for x in samples_f) if samples_f else 1.0
    if peak < 1e-6: peak = 1.0
    scale = 0.90 / peak
    pcm = struct.pack(f"<{len(samples_f)}h",
                      *(max(-32767, min(32767, int(s * scale * 32767)))
                        for s in samples_f))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)

# ---------------------------------------------------------------------------
# Grand Piano  –  multi-partial exponential decay with slight inharmonicity
# ---------------------------------------------------------------------------
PIANO_DURATION = 3.0    # seconds; most of the sustain captured

def piano_sample(midi_note, velocity):
    freq    = midi_to_hz(midi_note)
    vel     = velocity / 127.0
    sr      = SAMPLE_RATE
    n       = int(PIANO_DURATION * sr)
    B       = 3e-4          # inharmonicity coefficient (typical piano string)
    # (partial, relative_amplitude, decay_tau_seconds)
    partials = [
        (1, 1.000, 3.5 - vel * 1.0),
        (2, 0.550, 2.2 - vel * 0.5),
        (3, 0.350, 1.4),
        (4, 0.200, 1.0),
        (5, 0.140, 0.7),
        (6, 0.075, 0.55),
        (7, 0.045, 0.42),
        (8, 0.025 * vel, 0.32),
    ]
    # noise burst length proportional to velocity (louder hit → longer noise)
    noise_n = int((0.003 + vel * 0.006) * sr)
    _seed(midi_note * 137)
    samples = []
    for i in range(n):
        t   = i / sr
        s   = 0.0
        for k, amp, tau in partials:
            fk = freq * k * math.sqrt(1.0 + B * k * k)
            s += amp * math.exp(-t / tau) * math.sin(2.0 * math.pi * fk * t)
        if i < noise_n:
            env = math.exp(-i / (noise_n / 4.0))
            s  += _lcg() * env * vel * 0.5
        samples.append(s * vel)
    return samples

# ---------------------------------------------------------------------------
# String Ensemble  –  6 detuned bowed voices, vibrato after 0.5s
# ---------------------------------------------------------------------------
STRING_DURATION = 4.0   # long enough for vibrato to develop fully

_STRING_DETUNES = [0.0000, 0.0010, -0.0010, 0.0025, -0.0025, 0.0040]
_STRING_AMPS    = [1.00,   0.70,    0.70,    0.40,    0.40,    0.20]
_STRING_HARM    = [(1, 1.00), (2, 0.65), (3, 0.45), (4, 0.28), (5, 0.14)]
_VIB_FREQ = 5.0
_VIB_DEPTH = 0.0028      # ≈ ±5 cents

def strings_sample(midi_note, velocity):
    freq = midi_to_hz(midi_note)
    vel  = velocity / 127.0
    n    = int(STRING_DURATION * SAMPLE_RATE)
    attack_tau = 0.12
    vib_onset  = 0.50
    vib_ramp   = 0.30
    samples = []
    for i in range(n):
        t   = i / SAMPLE_RATE
        atk = min(t / attack_tau, 1.0)                          # attack
        rel = max(0.0, min(1.0, (STRING_DURATION - t) / 0.5))  # gentle release
        vib_env = max(0.0, min(1.0, (t - vib_onset) / vib_ramp))
        vib     = 1.0 + _VIB_DEPTH * math.sin(2.0 * math.pi * _VIB_FREQ * t) * vib_env
        s = 0.0
        for det, str_amp in zip(_STRING_DETUNES, _STRING_AMPS):
            f = freq * (1.0 + det) * vib
            for h, ha in _STRING_HARM:
                s += str_amp * ha * math.sin(2.0 * math.pi * f * h * t)
        samples.append(s * atk * rel * vel * 0.12)
    return samples

# ---------------------------------------------------------------------------
# Concert Flute  –  breath noise attack + pure tone + tremolo
# ---------------------------------------------------------------------------
FLUTE_DURATION = 3.0

def flute_sample(midi_note, velocity):
    freq = midi_to_hz(midi_note)
    vel  = velocity / 127.0
    n    = int(FLUTE_DURATION * SAMPLE_RATE)
    atk  = 0.035
    trem_freq  = 5.2
    trem_depth = 0.018
    _seed(midi_note * 97)
    samples = []
    for i in range(n):
        t   = i / SAMPLE_RATE
        env = min(t / atk, 1.0) * max(0.0, min(1.0, (FLUTE_DURATION - t) / 0.25))
        # tremolo ramps in after 0.3s
        trem = 1.0 + trem_depth * math.sin(2.0 * math.pi * trem_freq * t) \
               * max(0.0, min(1.0, (t - 0.3) / 0.5))
        # harmonic content: louder = slightly brighter
        h1 = 1.0
        h2 = 0.08 + vel * 0.14
        h3 = 0.03 + vel * 0.05
        tone = (h1 * math.sin(2.0 * math.pi * freq * t)
              + h2 * math.sin(2.0 * math.pi * freq * 2 * t)
              + h3 * math.sin(2.0 * math.pi * freq * 3 * t))
        # sustained breath noise (much quieter than tone)
        breath = _lcg() * (0.06 + vel * 0.05) * math.exp(-t * 5.0) \
               + _lcg() * 0.02 * vel
        samples.append((tone + breath) * env * trem * vel)
    return samples

# ---------------------------------------------------------------------------
# Generation driver
# ---------------------------------------------------------------------------
INSTRUMENTS = [
    # (folder, synth_fn, midi_root_start, midi_root_end, step)
    ("grand_piano",      piano_sample,   24, 96, 3),
    ("string_ensemble",  strings_sample, 36, 84, 3),
    ("concert_flute",    flute_sample,   60, 96, 3),
]
VELOCITIES = [64, 110]  # soft, loud

def main():
    t0 = time.time()
    total = sum(
        len(range(s, e+1, step)) * len(VELOCITIES)
        for _, _, s, e, step in INSTRUMENTS
    )
    done = 0
    for folder, fn, start, end, step in INSTRUMENTS:
        out_dir = os.path.join(OUT_ROOT, folder)
        notes   = list(range(start, end + 1, step))
        for n in notes:
            for v in VELOCITIES:
                samples  = fn(n, v)
                filename = f"{n}_{v}.wav"
                path     = os.path.join(out_dir, filename)
                write_wav(path, samples)
                done += 1
                elapsed = time.time() - t0
                eta     = (elapsed / done) * (total - done) if done else 0
                print(f"[{done:3}/{total}] {folder}/{filename}  "
                      f"({elapsed:.0f}s elapsed, ~{eta:.0f}s remaining)",
                      flush=True)
    print(f"\nDone — {total} files in {time.time()-t0:.1f}s")

if __name__ == "__main__":
    main()
