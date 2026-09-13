#pragma once
#include <stdint.h>
#include <stddef.h>
#include <math.h>

// Empirical sRGB model of the supplied 10.6 screenshot, NOT an Apple API or
// claim about the original compositor. Source registration was checked below
// the menu: Aurora resized to 1920x1200, then shifted upward by 59 pixels.
// Fit columns 410..919; validation used independent columns 920..1499.
// Separate illumination and source transmission. A source-over white film
// forces transmission = 1 - illumination, which washes out the source here.
static inline void SLMenuBarColorTransferCoefficients(size_t row, size_t height,
                                                      double *gain, double *bias) {
    if (row == 0 || height < 2) {
        *gain = 0.326467807;
        *bias = 0.880107414;
        return;
    }
    double t = height > 2 ? (double)(row - 1) / (double)(height - 2) : 0;
    t = fmin(1.0, fmax(0.0, t));
    *gain = 0.677393939 - 0.171043664 * t;
    *bias = 0.743842437 - 0.193929446 * t;
}

// RGBA8, premultiplied, sRGB bitmap. Its row zero is the image's top row.
// This is the single final composition; no extra white film is drawn over it.
static inline void SLMenuBarApplyColorTransfer(uint8_t *pixels, size_t width,
                                              size_t height, size_t stride) {
    if (!pixels || !width || !height || width > SIZE_MAX / 4 || stride < width * 4) return;
    for (size_t row = 0; row < height; row++) {
        double gain, bias;
        SLMenuBarColorTransferCoefficients(row, height, &gain, &bias);
        uint8_t *scan = pixels + row * stride;
        for (size_t x = 0; x < width; x++) {
            // Opaque wallpaper is provided by the helper. Premultiplied values
            // also make a transparent input fall back to the illuminated base.
            for (size_t c = 0; c < 3; c++)
                scan[x * 4 + c] = (uint8_t)lround(fmin(255.0, gain * scan[x * 4 + c] + bias * 255.0));
            scan[x * 4 + 3] = 255;
        }
    }
}
