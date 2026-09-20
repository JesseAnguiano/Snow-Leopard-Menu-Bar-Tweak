#!/bin/bash

# Shared compiler configuration for all project-owned binaries.
# Keep optimization/warning/architecture flags in one place so the helper and
# injected dylibs cannot silently drift apart.

SL_ARCH_FLAGS=(
    -arch arm64
    -arch arm64e
)

SL_COMMON_OBJC_FLAGS=(
    -fobjc-arc
    -fblocks
    -O2
    -Wall
    -Wextra
    -Werror
    -fvisibility=hidden
    -fno-common
    -mmacosx-version-min=15.0
)

SL_COMMON_LINK_FLAGS=(
    -Wl,-dead_strip
)

sl_resolve_toolchain() {
    SL_CLANG="$(/usr/bin/xcrun --find clang 2>/dev/null)" || {
        echo "ERROR: install Xcode Command Line Tools before building. / instala Xcode Command Line Tools antes de compilar." >&2
        return 1
    }
    SL_SDKROOT="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null)" || return 1
    if [[ ! -d "${SL_SDKROOT}" ]]; then
        echo "ERROR: macOS SDK could not be located. / no se pudo localizar el SDK de macOS." >&2
        return 1
    fi
    SL_PYTHON3="$(/usr/bin/xcrun --find python3 2>/dev/null)" || {
        echo "ERROR: Python 3 from Xcode Command Line Tools is required. / se requiere Python 3 de Xcode Command Line Tools." >&2
        return 1
    }
}
