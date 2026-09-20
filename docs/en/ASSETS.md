# Original Snow Leopard Aqua Assets — Verification

> [Versión en español](../es/ASSETS.md)

## Supplied files

`ArtFile.bin`
- 5,946,480 bytes
- SHA-256 `1ca5d946725e5815cb4fc34ef45006aab7220ef1f8e89128e65a5754359b4ec5`

`SArtFile.bin`
- 811,436 bytes
- SHA-256 `62eb745beaafa0a24111c0ac3b3452cebfda4aeec5e56e51b054ae2d62f778b2`

`Extras.rsrc`
- 5,425,538 bytes
- SHA-256 `a0866d6cf2d48fac7787e8cf9e90264071642c0d39aa809636e7d478016a9197`

`Extras2.rsrc`
- 5,425,538 bytes
- SHA-256 `19b1c4e4ca09407af081f607e0d97e0ea65ebf9ef44ecd4aa66d6cd025ca6557`

## Inspection results

`ArtFile.bin` contains 3,324 visual descriptors. The `menubar-bar` descriptor declares 22 × 22 points/pixels, but its 484 ARGB pixels are transparent `(0,0,0,0)`. The `menubar-selectiontab` and `menubar-search-searchselectiontab` entries are also transparent. They must not be embedded as visible PNG images.

`SArtFile.bin` contains a 1 × 21 CoreUI resource at index 102 with this sample ramp:

```text
239, 228, 224, 220, 216, 212, 208, 204, 201, 196, 193,
189, 186, 183, 179, 175, 172, 169, 166, 161, 158
```

Those samples belong to the resource, but they do not directly equal final white opacity: on 10.6, CoreUI and WindowServer still composite the resource with the desktop. Using them as pure alpha on Sequoia makes the background too white. The adaptation uses color preservation and the final curve measured from the 10.6 capture after aligning the Aurora background and normalizing color profiles to sRGB:

- The current adaptation draws this curve over the top strip of the active wallpaper, scales it to the screen size, diffuses it with Gaussian 9, and adjusts brightness by 0.02 and contrast by 1.15.
- Earlier additive/private-filter experiments are not part of the production path.
- top row: `0.92437`
- body: `0.83703, 0.82264, 0.80843, 0.79406, 0.77953, 0.76442, 0.74930, 0.73393, 0.71861, 0.70359, 0.68852, 0.67296, 0.65747, 0.64130, 0.62398, 0.60799, 0.59552, 0.58004, 0.56290, 0.54446`

The Sequoia adaptation uses that curve inside the native geometry supplied by AppKit. The normal Apple icon is drawn at `24.1290322581 × 23.1578947368`; the selected icon at `22 × 22`; horizontal offset is `0.5`, with vertical centering. Visible status icons use scale `1.0` inside their native bounds.

The Retina adaptation reserves exactly one physical pixel for the top highlight (`0.5` points at 2× scale) and applies the body to the remainder of the native height. It adds no lower separator, preventing a seam between the bar and the window at 1440 × 900 Retina.

WindowServer blur is resolved dynamically. If it is unavailable, the film remains transparent instead of being replaced by an opaque fill.

The original binaries are not copied to the system: the tweak contains only the required data and metrics, avoiding an external runtime dependency.

## Rights note

The MIT License in this repository covers project code, not third-party or platform artwork automatically. Before publishing or redistributing extracted/reference artwork, confirm that you have the necessary rights or permission for that material.
