#!/bin/bash
# Build only. Does not install or start a background service.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER_DIR="${PROJECT_ROOT}/src/wallpaper"
INCLUDE_DIR="${PROJECT_ROOT}/src/include"
BUILD_DIR="${PROJECT_ROOT}/build"
FINAL="${BUILD_DIR}/SnowLeopardWallpaperSource.app"

mkdir -p "${BUILD_DIR}"
STAGE="$(mktemp -d "${BUILD_DIR}/.stage-wallpaper.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT HUP INT TERM
APP="${STAGE}/SnowLeopardWallpaperSource.app"
mkdir -p "${APP}/Contents/MacOS"
cp "${HELPER_DIR}/Info.plist" "${APP}/Contents/Info.plist"

xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
    -arch arm64 -arch arm64e -mmacosx-version-min=15.0 \
    -I"${INCLUDE_DIR}" \
    -framework Cocoa -framework ImageIO \
    "${HELPER_DIR}/WallpaperSource.m" \
    -o "${APP}/Contents/MacOS/SnowLeopardWallpaperSource"

codesign --force --sign - "${APP}"
codesign --verify --strict "${APP}"
[[ ! -L "${FINAL}" ]] || { echo 'ERROR: destination helper is a symbolic link. / helper destino es un enlace.' >&2; exit 1; }
rm -rf "${FINAL}"
mv "${APP}" "${FINAL}"
echo "Helper built (not installed): ${FINAL} / Helper compilado (sin instalar): ${FINAL}"
