"""Generate placeholder WAV files for Make it Fit.
Run from the project root: python gen_audio.py
Replace the files with real SFX from Freesound (CC0) when ready.
"""
import struct, math, random, os

SR = 44100

def wav(path, samples):
    n = len(samples)
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + n * 2))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<I", 16))
        f.write(struct.pack("<HH", 1, 1))       # PCM, mono
        f.write(struct.pack("<II", SR, SR * 2)) # sample rate, byte rate
        f.write(struct.pack("<HH", 2, 16))      # block align, bits
        f.write(b"data")
        f.write(struct.pack("<I", n * 2))
        for s in samples:
            f.write(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))))

def sine(freq, dur, amp=0.5):
    n = int(SR * dur)
    return [amp * math.sin(2 * math.pi * freq * i / SR) * (1 - i / n) for i in range(n)]

def env(s, attack=0.01, release=0.15):
    n = len(s)
    a = int(SR * attack)
    r = int(SR * release)
    out = []
    for i, v in enumerate(s):
        if i < a:
            out.append(v * i / a)
        elif i > n - r:
            out.append(v * (n - i) / r)
        else:
            out.append(v)
    return out

def noise(dur, amp=0.4):
    n = int(SR * dur)
    return [amp * (random.random() * 2 - 1) * (1 - i / n) for i in range(n)]

def mix(*signals):
    n = max(len(s) for s in signals)
    out = [0.0] * n
    for s in signals:
        for i, v in enumerate(s):
            out[i] += v
    mx = max(abs(x) for x in out) or 1
    return [x / mx * 0.9 for x in out]

os.makedirs("assets/audio", exist_ok=True)

# ui_click — short crisp tick
wav("assets/audio/ui_click.wav",
    env(sine(1400, 0.04, 0.55) + sine(900, 0.03, 0.30), attack=0.002, release=0.03))

# place_furniture — soft wooden thud
thud = noise(0.10, 0.45)
low  = [thud[i] * math.exp(-i * 30 / len(thud)) for i in range(len(thud))]
wav("assets/audio/place_furniture.wav", env(low, attack=0.002, release=0.06))

# rotate — quick high swoosh
n = int(SR * 0.09)
sweep = [0.40 * math.sin(2 * math.pi * (300 + 1200 * i / n) * i / SR) * (1 - i / n)
         for i in range(n)]
wav("assets/audio/rotate.wav", env(sweep, attack=0.004, release=0.04))

# error — short buzz
wav("assets/audio/error.wav",
    env(mix(sine(130, 0.18, 0.38), sine(145, 0.18, 0.30)), attack=0.003, release=0.07))

# sell — two-tone coin
wav("assets/audio/sell.wav", env(mix(sine(880, 0.09, 0.40), sine(1320, 0.09, 0.30)),
    attack=0.003, release=0.06))

# success — ascending four-note arpeggio
notes = [523, 659, 784, 1047]
arp = []
for note in notes:
    arp += env(sine(note, 0.10, 0.38), attack=0.005, release=0.05)
wav("assets/audio/success.wav", arp)

# demolish — impact + debris rattle
impact = [0.70 * (random.random() * 2 - 1) * math.exp(-i * 18 / int(SR * 0.28))
          for i in range(int(SR * 0.28))]
wav("assets/audio/demolish.wav", env(impact, attack=0.001, release=0.08))

# ambient_rain — 4-second filtered noise loop (keep it short; AudioManager loops it)
random.seed(42)
raw = [random.random() * 2 - 1 for _ in range(SR * 4)]
alpha = 0.06
filt = [raw[0]]
for i in range(1, len(raw)):
    filt.append(alpha * raw[i] + (1 - alpha) * filt[-1])
mx = max(abs(x) for x in filt) or 1
rain = [x / mx * 0.18 for x in filt]
wav("assets/audio/ambient_rain.wav", rain)

print("Generated 8 placeholder WAV files in assets/audio/")
print("Replace with CC0 SFX from freesound.org or kenney.nl when ready.")
