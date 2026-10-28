"""Synthesize a test piano piece (Ode to Joy, public domain) with human-ish timing.

Usage: python3 synth.py OUT_PREFIX  -> OUT_PREFIX.wav/.npy (22050 Hz mono) and OUT_PREFIX_truth.json.
"""
import json, sys, wave
import numpy as np

SR = 22050
rng = np.random.default_rng(7)

G2, A2, B2, C3, D3, E3, Fs3, G3, A3, B3 = 43, 45, 47, 48, 50, 52, 54, 55, 57, 59
G4, A4, B4, C5, D5 = 67, 69, 71, 72, 74
Fs2 = 42
D2 = 38

# (beat_position, beats, [pitches])  -- positions in quarter notes, 4/4
rh = []
def phrase(start, ending):
    seq = [(B4, 1), (B4, 1), (C5, 1), (D5, 1), (D5, 1), (C5, 1), (B4, 1), (A4, 1),
           (G4, 1), (G4, 1), (A4, 1), (B4, 1)] + ending
    t = start
    for p, d in seq:
        rh.append((t, d, [p]))
        t += d
phrase(0, [(B4, 1.5), (A4, 0.5), (A4, 2)])
phrase(16, [(A4, 1.5), (G4, 0.5), (G4, 2)])

lh = [
    (0, 2, [G2, D3]), (2, 2, [G2, D3]),
    (4, 2, [D3, Fs3]), (6, 2, [G2, D3]),
    (8, 2, [G2, D3]), (10, 2, [C3, E3]),
    (12, 4, [D3, Fs3]),
]
arps = [
    [G2, D3, G3, D3, G2, D3, G3, D3],
    [D3, Fs3, A3, Fs3, G2, D3, G3, D3],
    [G2, D3, G3, D3, C3, E3, G3, E3],
    [D3, Fs3, A3, Fs3],
]
for m, pats in enumerate(arps):
    for i, p in enumerate(pats):
        lh.append((16 + 4 * m + 0.5 * i, 0.5, [p]))
lh.append((30, 2, [G2, D3]))

BPM = 96.0

def beat_to_time(b):
    # slowly drifting tempo (+-3%) to exercise the beat tracker
    steps = np.linspace(0, b, 400)
    local = 60.0 / (BPM * (1 + 0.03 * np.sin(steps / 5.0)))
    return float(np.trapezoid(local, steps)) + 0.35  # 0.35 s lead-in silence

events = []
for part in (rh, lh):
    for pos, dur, pitches in part:
        start = beat_to_time(pos) + rng.normal(0, 0.010)
        end = beat_to_time(pos + dur) - 0.04
        vel = 0.75 if part is rh else 0.55
        for p in pitches:
            events.append((start, end, p, vel * rng.uniform(0.85, 1.0)))

total = max(e[1] for e in events) + 1.5
y = np.zeros(int(total * SR), dtype=np.float64)
for start, end, p, vel in events:
    f0 = 440.0 * 2 ** ((p - 69) / 12)
    n0 = int(start * SR)
    length = int((end - start + 0.25) * SR)
    t = np.arange(length) / SR
    tone = np.zeros(length)
    for k in range(1, 10):
        fk = f0 * k * np.sqrt(1 + 0.0004 * k * k)
        if fk > SR / 2 - 500:
            break
        tone += (1.0 / k ** 1.3) * np.exp(-t * (1.2 + 0.7 * k)) * np.sin(2 * np.pi * fk * t + rng.uniform(0, 6.28))
    env = np.minimum(1.0, t / 0.004)
    rel_start = end - start
    env *= np.where(t < rel_start, 1.0, np.exp(-(t - rel_start) / 0.05))
    y[n0:n0 + length] += vel * tone * env
y = (y / np.max(np.abs(y)) * 0.8).astype(np.float32)

out = sys.argv[1] if len(sys.argv) > 1 else "build/ode"
with wave.open(out + ".wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((y * 32767).astype(np.int16).tobytes())
np.save(out + ".npy", y)
json.dump(sorted(events), open(out + "_truth.json", "w"))
print("wrote", out, len(y) / SR, "s,", len(events), "notes")
