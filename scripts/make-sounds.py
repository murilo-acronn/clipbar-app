#!/usr/bin/env python3
"""Generates ClipBar's own feedback sounds.

Synthesised rather than downloaded on purpose: the result is an original work
with no third-party licence attached, and anyone can regenerate it byte for byte
from this script instead of trusting a binary in the repository.

Usage: python3 scripts/make-sounds.py
Writes Resources/Sounds/ClipBar Copiar.aiff and ClipBar Colar.aiff.
"""

import math
import pathlib
import struct
import subprocess
import tempfile
import wave

RATE = 44_100


def render(partials, duration, decay, attack=0.003, peak=0.32):
    """A couple of sine partials under an exponential decay.

    Short percussive blips: fast enough not to intrude when you copy in a loop,
    pitched high enough to cut through without being shrill.
    """
    frames = int(RATE * duration)
    samples = []
    for i in range(frames):
        t = i / RATE
        envelope = math.exp(-t / decay)
        if t < attack:  # raised cosine, so the onset does not click
            envelope *= 0.5 - 0.5 * math.cos(math.pi * t / attack)
        value = sum(gain * math.sin(2 * math.pi * freq * t) for freq, gain in partials)
        samples.append(int(max(-1.0, min(1.0, value * envelope * peak)) * 32_767))
    return samples


def write_aiff(samples, destination):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
        path = temporary.name
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(b"".join(struct.pack("<h", s) for s in samples))

    destination.parent.mkdir(parents=True, exist_ok=True)
    # afconvert ships with macOS; no third-party audio tooling required.
    subprocess.run(
        ["afconvert", "-f", "AIFF", "-d", "BEI16", path, str(destination)],
        check=True,
    )
    pathlib.Path(path).unlink()


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    sounds = root / "Resources" / "Sounds"

    # Copy: brighter and shorter — it fires often, so it has to stay out of the way.
    write_aiff(
        render([(1_245.0, 0.62), (1_868.0, 0.28)], duration=0.13, decay=0.030),
        sounds / "ClipBar Copiar.aiff",
    )
    # Paste: lower and rounder, so the two are told apart without looking.
    write_aiff(
        render([(660.0, 0.66), (990.0, 0.24)], duration=0.17, decay=0.045),
        sounds / "ClipBar Colar.aiff",
    )
    print("→", sounds)


if __name__ == "__main__":
    main()
