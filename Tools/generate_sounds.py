#!/usr/bin/env python3
"""Generate three quiet, short notification sounds using only Python stdlib."""
from pathlib import Path
import math, struct, wave

out = Path(__file__).resolve().parents[1] / "Resources" / "Sounds"
out.mkdir(parents=True, exist_ok=True)
for name, frequency in (("Glass", 880), ("Pop", 660), ("Tink", 1047)):
    with wave.open(str(out / f"{name}.wav"), "wb") as file:
        file.setnchannels(1); file.setsampwidth(2); file.setframerate(22050)
        frames = []
        for i in range(int(0.17 * 22050)):
            t = i / 22050
            envelope = min(1.0, t / 0.008) * math.exp(-t * 22)
            sample = math.sin(2 * math.pi * frequency * t) * envelope * 0.25
            frames.append(struct.pack("<h", int(sample * 32767)))
        file.writeframes(b"".join(frames))
print("Generated", len(list(out.glob("*.wav"))), "sounds")
