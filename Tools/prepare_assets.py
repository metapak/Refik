#!/usr/bin/env python3
"""Source PNGs -> aligned transparent body/eye layers. Requires Pillow and numpy."""
from pathlib import Path
import unicodedata
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Resources" / "Mascots"
OUT.mkdir(parents=True, exist_ok=True)
FRAME = (427, 350, 827, 750)
STYLES = {"tatlı": (534, 623, 714, 665), "sert": (535, 614, 716, 660), "web ai": (574, 590, 679, 637)}
COLORS = {"running": (250, 247, 244), "waiting": (255, 177, 67), "completed": (121, 228, 150)}

files = {unicodedata.normalize("NFC", p.stem): p for p in ROOT.glob("*.png")}
for name, eyes in STYLES.items():
    for state, suffix in (("running", ""), ("waiting", " soru"), ("completed", " tamamlandı")):
        source = files[name + " maskot" + suffix]
        rgb = np.asarray(Image.open(source).convert("RGB").crop(FRAME)).astype(np.float32)
        # All originals have an opaque navy background. Keep line brightness,
        # discard low-frequency ground; preserve antialiased line edges.
        strength = np.max(rgb, axis=2)
        alpha = np.clip((strength - 50) / 145 * 255, 0, 255).astype(np.uint8)
        # Dark pixels inside line art should not turn into an opaque fill.
        alpha[strength < 60] = 0
        color = np.empty((*alpha.shape, 4), dtype=np.uint8)
        color[:, :, :3] = COLORS[state]
        color[:, :, 3] = alpha
        eye = np.zeros_like(color)
        x0, y0, x1, y1 = eyes
        eye[y0-FRAME[1]:y1-FRAME[1], x0-FRAME[0]:x1-FRAME[0]] = color[y0-FRAME[1]:y1-FRAME[1], x0-FRAME[0]:x1-FRAME[0]]
        body = color.copy()
        body[y0-FRAME[1]:y1-FRAME[1], x0-FRAME[0]:x1-FRAME[0], 3] = 0
        for layer, image in (("body", body), ("eyes", eye)):
            Image.fromarray(image).resize((400, 400), Image.Resampling.LANCZOS).save(OUT / f"{name.replace(' ', '-')}-{state}-{layer}.png")
print("Prepared", len(STYLES)*3*2, "transparent aligned layers in", OUT)
