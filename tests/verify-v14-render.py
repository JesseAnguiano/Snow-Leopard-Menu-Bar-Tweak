#!/usr/bin/env python3
import argparse
import io
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
    return np.asarray(image, dtype=float)

parser = argparse.ArgumentParser(description="Compare a production render against a Snow Leopard reference image.")
parser.add_argument("actual", help="Production PNG to verify")
parser.add_argument("reference", help="Snow Leopard reference PNG")
args = parser.parse_args()

ref = srgb(args.reference)[:21]
actual = srgb(args.actual)
assert actual.shape == ref.shape, f"shape mismatch: actual={actual.shape} reference={ref.shape}"
error = abs(actual[:, 920:1500] - ref[:, 920:1500])
print("Production PNG vs reference / PNG de producción vs referencia, held-out columns / columnas 920..1499")
print("Median RGB error / Error RGB mediano:", np.median(error), "P90:", np.percentile(error, 90))
for row in [0, 1, 5, 10, 16, 20]:
    print("row", row, "median", np.median(error[row]), "p90", np.percentile(error[row], 90))
assert np.median(error) < 2
assert np.percentile(error, 90) < 4
print("PASS: production pixel path matches held-out reference within thresholds. / PASS: la ruta de píxeles de producción coincide con la referencia dentro de los umbrales.")
