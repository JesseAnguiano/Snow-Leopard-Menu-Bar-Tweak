#!/bin/bash
# Build only. Does not install or start a background service.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/toolchain.sh"

HELPER_DIR="${PROJECT_ROOT}/src/wallpaper"
INCLUDE_DIR="${PROJECT_ROOT}/src/include"
BUILD_DIR="${PROJECT_ROOT}/build"
FINAL="${BUILD_DIR}/SnowLeopardWallpaperSource.app"

for source in "${HELPER_DIR}/WallpaperSource.m" "${HELPER_DIR}/Info.plist"; do
    [[ -f "${source}" && ! -L "${source}" ]] || {
        echo "ERROR: missing or invalid helper source / fuente del helper ausente o inválida: ${source}" >&2
        exit 1
    }
done

sl_resolve_toolchain
mkdir -p "${BUILD_DIR}"
STAGE="$(mktemp -d "${BUILD_DIR}/.stage-wallpaper.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT HUP INT TERM
APP="${STAGE}/SnowLeopardWallpaperSource.app"
mkdir -p "${APP}/Contents/MacOS"
cp "${HELPER_DIR}/Info.plist" "${APP}/Contents/Info.plist"

"${SL_CLANG}" \
    "${SL_COMMON_OBJC_FLAGS[@]}" \
    "${SL_ARCH_FLAGS[@]}" \
    -isysroot "${SL_SDKROOT}" \
    -I"${INCLUDE_DIR}" \
    -framework Cocoa \
    -framework ImageIO \
    "${SL_COMMON_LINK_FLAGS[@]}" \
    "${HELPER_DIR}/WallpaperSource.m" \
    -o "${APP}/Contents/MacOS/SnowLeopardWallpaperSource"

/usr/bin/codesign --force --sign - "${APP}"
/usr/bin/codesign --verify --strict "${APP}"
[[ ! -L "${FINAL}" ]] || {
    echo 'ERROR: destination helper is a symbolic link. / helper destino es un enlace.' >&2
    exit 1
}
rm -rf "${FINAL}"
mv "${APP}" "${FINAL}"
printf 'Helper built (not installed): %s / Helper compilado (sin instalar): %s\n' "${FINAL}" "${FINAL}"
