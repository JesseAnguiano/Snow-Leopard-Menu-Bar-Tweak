"""Check the v8 material equation against the supplied matching grass images.

Usage: python3 tests/material-reference-fit-v8-historical.py REFERENCE WALLPAPER
Historical experiment only. v8 failed in WindowServer; not a production test.
Requires Pillow and NumPy.
"""
import io
import sys

import numpy as np
from PIL import Image, ImageCms, ImageFilter


def srgb(path):
    image = Image.open(path)
    profile = image.info.get("icc_profile")
    image = image.convert("RGB")
    if profile:
        image = ImageCms.profileToProfile(
            image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
            ImageCms.createProfile("sRGB"), outputMode="RGB")
    return image


body = np.array([0.76595, 0.74934, 0.74454, 0.72916, 0.72035,
                 0.70898, 0.69966, 0.68687, 0.67676, 0.66572,
                 0.65360, 0.64283, 0.63172, 0.61783, 0.60750,
                 0.59944, 0.58465, 0.57277, 0.55961, 0.54608])
assert len(body) == 20 and np.all(np.diff(body) <= 0)
reference = np.asarray(srgb(sys.argv[1]), dtype=float) / 255
wallpaper = srgb(sys.argv[2]).resize((1920, 1200), Image.Resampling.LANCZOS)
backdrop = np.asarray(wallpaper.filter(ImageFilter.GaussianBlur(3)), dtype=float)[:21, :500] / 255
assert reference.shape[:2] == (65, 500), "Use the original 500x65 grass reference"
luminance = backdrop @ np.array([0.2126, 0.7152, 0.0722])
transmitted = 0.5 * luminance[:, :, None] + 0.575 * (backdrop - luminance[:, :, None])
for row in (1, 5, 10, 15, 20):
    clean = reference[row].min(axis=1) > 0.4
    predicted = np.clip(transmitted[row] + body[row - 1], 0, 1)
    error = np.median(abs(predicted - reference[row])[clean]) * 255
    print(f"row={row:2d} median RGB error / error RGB mediano={error:.3f}/255")
    assert error < 5, (row, error)
print("PASS: monotonic illumination and calibrated reference rows / PASS: iluminación monótona y filas de referencia calibradas")
