"""
Builds the sounds of HeadsUp (HeadsUp/Sounds/*.ogg): six short bell-like sounds, each one in three
levels (1 = soft, 2 = normal, 3 = loud). They are made here from nothing (a sum of decaying tones),
so they are our own: no copyright and full control of the loudness.

The game cannot change the volume of a sound, so the three levels are three files: the loud one
uses the whole range, the normal one is half of it (-6 dB), the soft one a quarter (-12 dB).

Needs:  pip install numpy soundfile       Run:  python tools/make_sounds.py
"""
import os
import numpy as np
import soundfile as sf

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "HeadsUp", "Sounds")
LEVELS = {1: 0.25, 2: 0.50, 3: 0.90}   # peak of each level (soft, normal, loud)


def bell(freq, seconds, ratios=(1.0, 2.0, 2.76, 5.4, 8.9), amps=(1.0, 0.6, 0.4, 0.25, 0.12),
         decays=(0.9, 0.6, 0.4, 0.25, 0.15)):
    """One strike of a bell: tones at inharmonic ratios, each one dying away on its own."""
    t = np.arange(int(RATE * seconds)) / RATE
    out = np.zeros_like(t)
    for ratio, amp, decay in zip(ratios, amps, decays):
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / (decay * seconds / 0.9 * 0.35))
    return out


def tone(freq, seconds, harmonics=(1.0, 0.5, 0.25), decay=0.18):
    """A clean, glassy note (harmonic tones), for the chime."""
    t = np.arange(int(RATE * seconds)) / RATE
    out = np.zeros_like(t)
    for n, amp in enumerate(harmonics, start=1):
        out += amp * np.sin(2 * np.pi * freq * n * t)
    return out * np.exp(-t / decay)


def place(canvas, sound, start):
    """Add a sound to the canvas at a time (in seconds)."""
    i = int(RATE * start)
    end = min(len(canvas), i + len(sound))
    canvas[i:end] += sound[: end - i]


def make(name):
    if name == "ding":            # one clear bell
        return bell(880, 0.9)
    if name == "dingdong":        # two notes, like a door bell
        c = np.zeros(int(RATE * 1.2))
        place(c, bell(880, 0.8), 0.0)
        place(c, bell(659, 0.8), 0.30)
        return c
    if name == "double":          # ding ding, quick
        c = np.zeros(int(RATE * 0.8))
        place(c, bell(988, 0.5), 0.0)
        place(c, bell(988, 0.5), 0.17)
        return c
    if name == "chime":           # three rising notes
        c = np.zeros(int(RATE * 0.9))
        for i, freq in enumerate((784, 988, 1319)):
            place(c, tone(freq, 0.6), 0.11 * i)
        return c
    if name == "ping":            # short and bright
        return bell(1760, 0.40, ratios=(1.0, 2.0, 3.0), amps=(1.0, 0.5, 0.25), decays=(0.5, 0.3, 0.2))
    if name == "gong":            # low and metallic
        return bell(220, 1.3, ratios=(1.0, 2.32, 3.11, 4.75, 6.4), amps=(1.0, 0.7, 0.5, 0.3, 0.2),
                    decays=(1.0, 0.8, 0.6, 0.4, 0.3))
    raise ValueError(name)


def finish(signal, peak):
    """Make it dense (so it sounds loud), smooth the ends, and set the peak."""
    signal = np.tanh(1.8 * signal / np.max(np.abs(signal))) / np.tanh(1.8)
    fade_in = int(RATE * 0.002)
    fade_out = int(RATE * 0.02)
    signal[:fade_in] *= np.linspace(0, 1, fade_in)
    signal[-fade_out:] *= np.linspace(1, 0, fade_out)
    return (signal / np.max(np.abs(signal)) * peak).astype(np.float32)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in ("ding", "dingdong", "double", "chime", "ping", "gong"):
        raw = make(name)
        for level, peak in LEVELS.items():
            data = finish(raw.copy(), peak)
            path = os.path.join(OUT, "%s_%d.ogg" % (name, level))
            sf.write(path, data, RATE, format="OGG", subtype="VORBIS")
            rms = float(np.sqrt(np.mean(data ** 2)))
            print("%-14s %4.2f s  peak %.2f  rms %.3f  %d bytes" % (
                os.path.basename(path), len(data) / RATE, peak, rms, os.path.getsize(path)))


if __name__ == "__main__":
    main()
