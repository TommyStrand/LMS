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
# String Ensemble  –  6 detuned bowed voices, independent vibrato per voice
# ---------------------------------------------------------------------------
# Fix for v1: all voices shared the same vibrato phase, causing a 5 Hz tremolo
# throb instead of an ensemble sound.  Each voice now has its own LFO phase
# offset and slightly different rate.  Phase is accumulated per-sample
# (phase += 2π·f/sr) rather than computed as sin(2π·f·t), which eliminated
# drift artifacts that grew louder over the 4-second sample duration.
# ---------------------------------------------------------------------------
STRING_DURATION = 4.0

_STRING_DETUNES    = [0.0000,  0.0010, -0.0010,  0.0025, -0.0025,  0.0040]
_STRING_AMPS       = [1.00,    0.70,    0.70,     0.40,    0.40,    0.20  ]
_STRING_HARM       = [(1, 1.00), (2, 0.60), (3, 0.38), (4, 0.22), (5, 0.10)]
# Each voice has its own LFO rate (4.8–5.4 Hz) and start phase so their
# individual tremolos cancel each other out rather than adding together.
_STRING_VIB_RATES  = [5.0,  4.8,  5.2,  5.0,  4.9,  5.4]
_STRING_VIB_PHASES = [0.00, 0.37, 0.71, 1.23, 1.85, 2.54]
_VIB_DEPTH = 0.0028      # ≈ ±5 cents

def strings_sample(midi_note, velocity):
    freq       = midi_to_hz(midi_note)
    vel        = velocity / 127.0
    n          = int(STRING_DURATION * SAMPLE_RATE)
    sr         = float(SAMPLE_RATE)
    attack_tau = 0.12
    vib_onset  = 0.50
    vib_ramp   = 0.30
    n_voices   = len(_STRING_DETUNES)
    n_harm     = len(_STRING_HARM)

    # Per-voice, per-harmonic phase accumulators — avoids the sin(f·t) drift.
    phases = [[0.0] * n_harm for _ in range(n_voices)]
    _seed(midi_note * 31)

    samples = []
    for i in range(n):
        t       = i / sr
        atk     = min(t / attack_tau, 1.0)
        rel     = max(0.0, min(1.0, (STRING_DURATION - t) / 0.5))
        vib_env = max(0.0, min(1.0, (t - vib_onset) / vib_ramp))

        s = 0.0
        for vi in range(n_voices):
            vib_rate  = _STRING_VIB_RATES[vi]
            vib_phase = _STRING_VIB_PHASES[vi]
            det       = _STRING_DETUNES[vi]
            str_amp   = _STRING_AMPS[vi]
            vib = 1.0 + _VIB_DEPTH * math.sin(
                2.0 * math.pi * vib_rate * t + vib_phase) * vib_env
            f_base = freq * (1.0 + det) * vib
            for hi, (h, ha) in enumerate(_STRING_HARM):
                # Accumulate phase: integrates the instantaneous frequency exactly.
                phases[vi][hi] += 2.0 * math.pi * f_base * h / sr
                s += str_amp * ha * math.sin(phases[vi][hi])

        # Brief bow-noise burst on the attack, mimics the initial bow scrape.
        bow = _lcg() * 0.18 * math.exp(-t * 10.0)
        samples.append((s + bow) * atk * rel * vel * 0.12)
    return samples

# ---------------------------------------------------------------------------
# Concert Flute  –  breath attack + vibrato tone
# ---------------------------------------------------------------------------
# Fix for v1: a constant `_lcg() * 0.02 * vel` term added white noise through
# the entire sample (~36 dB below signal), clearly audible as digital hiss.
# Removed; only attack breath remains (fast decay, gone by ~200 ms).
# Proper pitch vibrato added via phase accumulation, replacing amplitude-only
# tremolo which made the tone sound like a buzzing sine wave.
# ---------------------------------------------------------------------------
FLUTE_DURATION = 3.0

def flute_sample(midi_note, velocity):
    freq       = midi_to_hz(midi_note)
    vel        = velocity / 127.0
    n          = int(FLUTE_DURATION * SAMPLE_RATE)
    sr         = float(SAMPLE_RATE)
    atk        = 0.035
    trem_depth = 0.016   # amplitude tremolo (slight, ramps in after 0.3 s)
    vib_depth  = 0.0030  # pitch vibrato depth (≈ ±5 cents, ramps in after 0.4 s)
    vib_rate   = 5.2

    _seed(midi_note * 97)

    # Phase accumulators for harmonics 1, 2, 3
    ph = [0.0, 0.0, 0.0]

    samples = []
    for i in range(n):
        t   = i / sr
        env = min(t / atk, 1.0) * max(0.0, min(1.0, (FLUTE_DURATION - t) / 0.25))

        # Pitch vibrato: ramps in at 0.4 s — gives pure-tone character before it kicks in.
        vib_env = max(0.0, min(1.0, (t - 0.40) / 0.40))
        vib     = 1.0 + vib_depth * math.sin(2.0 * math.pi * vib_rate * t) * vib_env

        # Amplitude tremolo lags slightly behind vibrato (natural flute performance).
        trem = 1.0 + trem_depth * math.sin(2.0 * math.pi * vib_rate * t + 0.8) \
               * max(0.0, min(1.0, (t - 0.30) / 0.50))

        # Harmonic brightness scales with velocity.
        h2 = 0.06 + vel * 0.12
        h3 = 0.02 + vel * 0.04

        # Phase accumulation — correct FM without drift artefacts.
        ph[0] += 2.0 * math.pi * freq * 1 * vib / sr
        ph[1] += 2.0 * math.pi * freq * 2 * vib / sr
        ph[2] += 2.0 * math.pi * freq * 3 * vib / sr

        tone = math.sin(ph[0]) + h2 * math.sin(ph[1]) + h3 * math.sin(ph[2])

        # Attack breath only — no sustained noise.
        breath = _lcg() * (0.05 + vel * 0.04) * math.exp(-t * 8.0)

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
