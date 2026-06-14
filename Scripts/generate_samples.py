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
    noise_n   = int((0.003 + vel * 0.006) * sr)
    fade_start = n - int(0.05 * sr)   # 50 ms end-of-sample fade prevents click
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
        if i >= fade_start:
            s *= (n - i) / (n - fade_start)
        samples.append(s * vel)
    return samples

# ---------------------------------------------------------------------------
# String Ensemble  –  12 detuned bowed voices, sawtooth-like spectrum
# ---------------------------------------------------------------------------
# v4 redesign — previous versions used odd-harmonic emphasis (clarinet-like)
# and only 6 voices at ±12 cents.  Real bowed strings need:
#
#   1. SAWTOOTH spectrum (all harmonics, peak at h2 via body resonance, then
#      rolling off like 1/k) — NOT odd-harmonic (that is clarinet).
#   2. 12 voices spread ±34 cents to simulate a real orchestral section where
#      players are never perfectly in unison.
#   3. Per-voice independent bow-pressure flutter (±3 %, ~1.7 Hz) that
#      thickens and animates the sound in a way vibrato alone cannot.
#   4. Register-adaptive harmonic count: low strings (C2) are warm/dark (4
#      partials); high strings (C6) are bright (12 partials).
#   5. Exponential bow-engagement attack rather than a linear ramp.
#   6. Bow-scrape onset transient that is NOT killed by the attack envelope
#      (the scrape is loudest at t≈0 before the tone has built up).
# ---------------------------------------------------------------------------
STRING_DURATION = 4.0

_N_STR_VOICES  = 12
# Detunes in fractional frequency: spread up to ±34 cents (≈ 0.020 ratio)
_STR_DETUNES   = [ 0.0000,  0.0023, -0.0023,  0.0052, -0.0052,
                   0.0087, -0.0087,  0.0122, -0.0122,  0.0156,
                  -0.0156,  0.0197]
_STR_V_AMPS    = [1.00, 0.93, 0.93, 0.83, 0.83,
                  0.70, 0.70, 0.55, 0.55, 0.40,
                  0.40, 0.26]
_STR_VIB_RATES = [5.00, 4.87, 5.13, 4.94, 5.06,
                  4.81, 5.19, 4.91, 5.10, 5.24,
                  4.76, 5.03]
# Phase offsets 30° apart so vibrato never fully aligns across voices
_STR_VIB_PH    = [0.00, 0.52, 1.05, 1.57, 2.09,
                  2.62, 3.14, 3.67, 4.19, 4.71,
                  5.24, 5.76]
_STR_VIB_DEPTH = 0.0040   # ≈ ±7 cents pitch vibrato per voice

# Sawtooth spectrum shaped by violin/viola body resonance:
# h2 is strongest (body resonance amplification), then roughly 1/k rolloff.
# Full 12-partial table; n_harm is capped per register (see strings_sample).
_STR_HARM_FULL = [
    (1, 0.68), (2, 1.00), (3, 0.78), (4, 0.50),
    (5, 0.36), (6, 0.24), (7, 0.17), (8, 0.12),
    (9, 0.08), (10, 0.06), (11, 0.04), (12, 0.03),
]

def strings_sample(midi_note, velocity):
    freq = midi_to_hz(midi_note)
    vel  = velocity / 127.0
    n    = int(STRING_DURATION * SAMPLE_RATE)
    sr   = float(SAMPLE_RATE)

    # Register-adaptive partial count: MIDI 36 → 4, MIDI 84 → 12
    n_harm = max(4, min(12, 4 + (midi_note - 36) // 6))
    # Nyquist guard — drop partials that would alias
    while n_harm > 1 and freq * _STR_HARM_FULL[n_harm - 1][0] > sr * 0.45:
        n_harm -= 1

    raw = _STR_HARM_FULL[:n_harm]
    norm = sum(a for _, a in raw)
    harm_amps = [(h, a / norm) for h, a in raw]

    attack_tau = 0.25   # exponential bow-engagement time constant
    vib_onset  = 0.50   # seconds before vibrato begins
    vib_ramp   = 0.35   # vibrato fade-in duration

    phases = [[0.0] * n_harm for _ in range(_N_STR_VOICES)]
    _seed(midi_note * 31)

    samples = []
    for i in range(n):
        t   = i / sr
        atk = 1.0 - math.exp(-t / attack_tau)            # smooth bow engagement
        rel = max(0.0, min(1.0, (STRING_DURATION - t) / 0.6))
        vib_env = max(0.0, min(1.0, (t - vib_onset) / vib_ramp))

        s = 0.0
        for vi in range(_N_STR_VOICES):
            vib     = 1.0 + _STR_VIB_DEPTH * math.sin(
                2.0 * math.pi * _STR_VIB_RATES[vi] * t + _STR_VIB_PH[vi]) * vib_env
            # Slow bow-pressure flutter per voice — desynchronised ±3 % at ~1.7 Hz
            flutter = 1.0 + 0.030 * math.sin(
                2.0 * math.pi * 1.7 * t + _STR_VIB_PH[vi] * 1.3)
            f_base  = freq * (1.0 + _STR_DETUNES[vi]) * vib
            va      = _STR_V_AMPS[vi] * flutter
            for hi, (h, ha) in enumerate(harm_amps):
                phases[vi][hi] += 2.0 * math.pi * f_base * h / sr
                s += va * ha * math.sin(phases[vi][hi])

        tone = s * atk * rel * vel * 0.10
        # Bow-catch transient: loudest at t=0, gone by ~200 ms; NOT gated by atk
        bow_scrape = _lcg() * 0.12 * math.exp(-t * 15.0) * vel
        # Rosin roughness: tracks amplitude envelope throughout the note
        rosin      = _lcg() * (0.005 + vel * 0.004) * atk * rel
        samples.append(tone + bow_scrape + rosin)
    return samples

# ---------------------------------------------------------------------------
# Concert Flute  –  breath attack + vibrato tone
# ---------------------------------------------------------------------------
# v3 changes vs v2:
#   • Subtle envelope-gated sustained breathiness added back at 0.008 amplitude
#     (~0.6 % of signal at full volume).  This is far below the v1 hiss level
#     (0.02 * vel, constant) and follows the amplitude envelope so the noise
#     fades with the note — no noise tail, no static floor.
#   • Vibrato depth increased to ≈ ±9 cents (was ±5 cents); ramps in 0.1 s
#     sooner for a more expressive, natural-feeling tone.
# ---------------------------------------------------------------------------
FLUTE_DURATION = 3.0

def flute_sample(midi_note, velocity):
    freq       = midi_to_hz(midi_note)
    vel        = velocity / 127.0
    n          = int(FLUTE_DURATION * SAMPLE_RATE)
    sr         = float(SAMPLE_RATE)
    atk        = 0.035
    trem_depth = 0.016   # amplitude tremolo (slight, ramps in after 0.3 s)
    vib_depth  = 0.0050  # pitch vibrato depth (≈ ±9 cents; was ±5 cents)
    vib_rate   = 5.2

    _seed(midi_note * 97)

    # Phase accumulators for harmonics 1, 2, 3
    ph = [0.0, 0.0, 0.0]

    samples = []
    for i in range(n):
        t   = i / sr
        env = min(t / atk, 1.0) * max(0.0, min(1.0, (FLUTE_DURATION - t) / 0.25))

        # Pitch vibrato ramps in at 0.3 s (was 0.4 s) for a more expressive line.
        vib_env = max(0.0, min(1.0, (t - 0.30) / 0.35))
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

        # Attack breath (fast decay, gone by ~200 ms).
        breath_atk = _lcg() * (0.05 + vel * 0.04) * math.exp(-t * 8.0)
        # Sustained breathiness: envelope-gated so it fades with the note.
        # ~0.6 % of full-amplitude signal — adds organic air without hiss.
        breath_sus = _lcg() * 0.008

        samples.append((tone + breath_atk + breath_sus) * env * trem * vel)
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
