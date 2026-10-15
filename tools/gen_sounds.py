"""Synthesizes the game's own sound effects into assets/audio/*.wav.

    python tools/gen_sounds.py

Original work for this project (CC0, like the Kenney packs next to them).
They are small, soft UI sounds meant to sit under the Kenney set; replace any
file with a recorded one of the same name and nothing else needs to change.
Needs numpy. Output is deterministic (fixed noise seed).
"""
import os
import wave

import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "audio")
rng = np.random.default_rng(7)


def t(sec):
    return np.arange(int(SR * sec)) / SR


def env(n, attack, release):
    """Linear attack, exponential release, over n samples."""
    a = max(1, int(SR * attack))
    e = np.ones(n)
    e[:a] = np.linspace(0, 1, a)
    rel = np.exp(-np.arange(n - a) / (SR * release))
    e[a:] = rel
    return e


def lowpass(x, cutoff):
    """One-pole lowpass; cutoff may be a per-sample array."""
    cutoff = np.broadcast_to(cutoff, x.shape)
    y = np.zeros_like(x)
    acc = 0.0
    for i in range(len(x)):
        k = 1.0 - np.exp(-2 * np.pi * cutoff[i] / SR)
        acc += k * (x[i] - acc)
        y[i] = acc
    return y


def tone(freqs, sec, harmonics=(1.0,)):
    """A tone gliding along `freqs` (array or scalar), with optional harmonics."""
    n = int(SR * sec)
    f = np.broadcast_to(np.asarray(freqs, dtype=float), (n,)) if np.ndim(freqs) else np.full(n, float(freqs))
    phase = 2 * np.pi * np.cumsum(f) / SR
    return sum(a * np.sin(phase * (i + 1)) for i, a in enumerate(harmonics))


def saw(freqs, sec):
    return tone(freqs, sec, harmonics=tuple(1.0 / k for k in range(1, 14)))


def faded(sig, ms=4):
    """Short fades at both ends, so a segment never starts or stops with a click."""
    sig = sig.copy()
    n = min(int(SR * ms / 1000), len(sig) // 2)
    sig[:n] *= np.linspace(0, 1, n)
    sig[-n:] *= np.linspace(1, 0, n)
    return sig


def place_at(total, parts):
    out = np.zeros(int(SR * total))
    for start, sig in parts:
        sig = faded(sig)
        s = int(SR * start)
        e = min(len(out), s + len(sig))
        out[s:e] += sig[: e - s]
    return out


def save(name, x, peak=0.5):
    x = faded(x / (np.max(np.abs(x)) + 1e-9) * peak, 3)
    data = (x * 32767).astype(np.int16)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", os.path.relpath(path, ROOT), "%.2fs" % (len(x) / SR))


def fold():
    # A hinge giving way and the piece settling: two clacks and a soft thump.
    def clack(bright):
        n = int(SR * 0.03)
        return lowpass(rng.standard_normal(n), bright) * env(n, 0.001, 0.006)
    thump = tone(np.linspace(140, 90, int(SR * 0.09)), 0.09) * env(int(SR * 0.09), 0.002, 0.03)
    return place_at(0.24, [(0.0, clack(2600)), (0.07, clack(1900) * 0.8), (0.08, thump * 1.4)])


def whoosh():
    # Air past the ear: noise through a filter that opens and closes.
    sec = 0.5
    n = int(SR * sec)
    x = np.linspace(0, 1, n)
    cutoff = 250 + 2600 * np.sin(np.pi * x) ** 2
    shape = np.sin(np.pi * x) ** 1.5
    return lowpass(rng.standard_normal(n), cutoff) * shape


def fax():
    # A fax picking up: answer tone, two handshake chirps, then paper feeding.
    def beep(f, sec):
        return tone(f, sec, (1.0, 0.0, 0.25)) * env(int(SR * sec), 0.005, sec * 0.8)
    n_feed = int(SR * 0.4)
    feed = lowpass(rng.standard_normal(n_feed), 900) * (0.55 + 0.45 * np.sign(np.sin(2 * np.pi * 26 * t(0.4))))
    feed *= env(n_feed, 0.03, 0.25)
    return place_at(0.95, [(0.0, beep(1100, 0.13)), (0.17, beep(2100, 0.1)), (0.3, beep(1650, 0.05)),
                           (0.37, beep(1850, 0.05)), (0.44, beep(1650, 0.05)), (0.53, feed * 0.6)])


def grumble():
    # "Hmph": a short voiced grunt, falling, a little rough.
    sec = 0.32
    n = int(SR * sec)
    f0 = np.linspace(175, 112, n) * (1 + 0.03 * np.sin(2 * np.pi * 23 * t(sec)))
    voice = lowpass(saw(f0, sec), 850)
    return voice * env(n, 0.02, 0.12)


def happy():
    # Two bright rising blips.
    def blip(f0, f1, sec):
        n = int(SR * sec)
        return tone(np.linspace(f0, f1, n), sec, (1.0, 0.3, 0.1)) * env(n, 0.004, sec * 0.5)
    return place_at(0.3, [(0.0, blip(660, 880, 0.09)), (0.1, blip(990, 1320, 0.16))])


def huh():
    # "Hm?": a voiced murmur that rises like a question.
    sec = 0.38
    n = int(SR * sec)
    f0 = np.concatenate([np.full(n // 2, 150.0), np.linspace(150, 245, n - n // 2)])
    voice = lowpass(saw(f0, sec), 700)
    return voice * env(n, 0.03, 0.2)


if __name__ == "__main__":
    save("fold", fold(), 0.55)
    save("whoosh", whoosh(), 0.4)
    save("fax", fax(), 0.35)
    save("grumble", grumble(), 0.45)
    save("happy", happy(), 0.35)
    save("huh", huh(), 0.4)
