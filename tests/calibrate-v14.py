#!/usr/bin/env python3
"""Fit the v14 color-transfer model from user-supplied reference images.

Held-out columns are never used to fit. The script reads original images only
and prints coefficients; it does not edit screenshots.
"""
import argparse
import io
import json
import numpy as np
from PIL import Image, ImageCms

def srgb(path):
    image = Image.open(path)
    profile = image.info.get("icc_profile")
    image = image.convert("RGB")
    if profile:
        image = ImageCms.profileToProfile(
            image,
            ImageCms.ImageCmsProfile(io.BytesIO(profile)),
            ImageCms.createProfile("sRGB"),
            outputMode="RGB",
        )
    return image

parser = argparse.ArgumentParser(description="Fit the Snow Leopard v14 color transfer.")
parser.add_argument("reference", help="Snow Leopard menu-bar reference image")
parser.add_argument("wallpaper", help="Source Snow Leopard wallpaper image")
args = parser.parse_args()

ref = np.asarray(srgb(args.reference), float) / 255
wall = srgb(args.wallpaper).resize((1920, 1200), Image.Resampling.LANCZOS)
source = np.asarray(wall, float)[59:] / 255
coefficients = []
for row in range(21):
    s, t = source[row, 410:920].reshape(-1), ref[row, 410:920].reshape(-1)
    valid = (t < .98) & (t > .30)
    gain, bias = np.linalg.lstsq(
        np.stack([s[valid], np.ones(valid.sum())], axis=1), t[valid], rcond=None
    )[0]
    coefficients.append([float(gain), float(bias)])
    held = np.clip(source[row, 920:1500] * gain + bias, 0, 1)
    err = np.abs(held - ref[row, 920:1500]) * 255
    print(f"row={row:2} gain={gain:.6f} bias={bias:.6f} heldoutMedian={np.median(err):.3f} heldoutP90={np.percentile(err,90):.3f}")
print("COEFFICIENTS=" + json.dumps(coefficients))

design, targets = [], []
for row in range(1, 21):
    s, t = source[row, 410:920].reshape(-1), ref[row, 410:920].reshape(-1)
    valid = (t < .98) & (t > .30)
    y = (row - 1) / 19
    design.append(np.stack([s[valid], s[valid] * y, np.ones(valid.sum()), np.full(valid.sum(), y)], axis=1))
    targets.append(t[valid])
x, target = np.concatenate(design), np.concatenate(targets)
coeff = np.linalg.lstsq(x, target, rcond=None)[0]
for _ in range(8):
    residual = abs(x @ coeff - target)
    weights = np.sqrt(np.minimum(1, (1 / 255) / np.maximum(residual, 1e-9)))
    coeff = np.linalg.lstsq(x * weights[:, None], target * weights, rcond=None)[0]
print("SMOOTH=" + json.dumps(coeff.tolist()))
for row in [1, 5, 10, 16, 20]:
    y = (row - 1) / 19
    prediction = np.clip(source[row, 920:1500] * (coeff[0] + coeff[1] * y) + coeff[2] + coeff[3] * y, 0, 1)
    error = abs(prediction - ref[row, 920:1500]) * 255
    print("smooth heldout / suavizado reservado", row, "median", round(np.median(error), 3), "p90", round(np.percentile(error, 90), 3))
