#!/usr/bin/env python3
"""Compose the approved sweet mascot into a standard macOS app icon."""
from pathlib import Path
from PIL import Image, ImageDraw
import subprocess
import shutil

root = Path(__file__).resolve().parents[1]
iconset = root / "Resources" / "refik.iconset"
iconset.mkdir(exist_ok=True)
body = Image.open(root / "Resources/Mascots/tatlı-running-body.png").convert("RGBA")
eyes = Image.open(root / "Resources/Mascots/tatlı-running-eyes.png").convert("RGBA")
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        canvas = Image.new("RGBA", (px, px))
        ground = Image.new("RGBA", (px, px))
        draw = ImageDraw.Draw(ground)
        draw.rounded_rectangle((1, 1, px - 2, px - 2), radius=px // 5, fill=(24, 24, 35, 255))
        canvas.alpha_composite(ground)
        image = Image.alpha_composite(body, eyes).resize((int(px * 0.96), int(px * 0.96)), Image.Resampling.LANCZOS)
        canvas.alpha_composite(image, ((px-image.width)//2, (px-image.height)//2))
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        canvas.save(iconset / name)
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources/refik.icns")], check=True)
shutil.rmtree(iconset)
print("Generated Resources/refik.icns")
