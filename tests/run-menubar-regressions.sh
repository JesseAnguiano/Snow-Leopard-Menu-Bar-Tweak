#!/bin/bash
set -euo pipefail
PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED="${PROJECT}/build/generated"
PYTHON3="$(xcrun --find python3)"
mkdir -p "${GENERATED}"
"${PYTHON3}" "${PROJECT}/scripts/generate-embedded-assets.py" \
    "${PROJECT}/assets/manifest.json" \
    "${PROJECT}/assets" \
    "${GENERATED}/SnowLeopardEmbeddedAssets.h"
STAGE="$(mktemp -d /private/tmp/sl-menubar-tests.XXXXXX)"
COMMON_SOURCES=(
    "${PROJECT}/src/common/Runtime.m"
    "${PROJECT}/src/common/SelectionRenderer.m"
    "${PROJECT}/src/status/StatusSelectionIPC.m"
)
trap 'rm -f "${STAGE}/menu-layout-regression" "${STAGE}/wallpaper-regression" "${STAGE}/lower-shadow-regression" "${STAGE}/status-performance-regression" "${STAGE}/status-icon-batch-regression"; rmdir "${STAGE}"' EXIT
for TEST in menu-layout-regression wallpaper-regression lower-shadow-regression status-performance-regression status-icon-batch-regression; do
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -arch arm64 \
        -mmacosx-version-min=15.0 -I"${PROJECT}/src/include" -I"${PROJECT}/src/menubar/rendering" -I"${GENERATED}" -framework Cocoa -framework QuartzCore \
        -framework CoreText -framework CoreImage -framework ImageIO -framework CoreAudio -framework IOKit \
        "${COMMON_SOURCES[@]}" "${PROJECT}/tests/${TEST}.m" -o "${STAGE}/${TEST}"
    "${STAGE}/${TEST}"
done
