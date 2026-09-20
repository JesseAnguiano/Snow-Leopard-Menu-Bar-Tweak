#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/project-config.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/markers.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/toolchain.sh"

SRC_DIR="${PROJECT_ROOT}/src"
INCLUDE_DIR="${SRC_DIR}/include"
RENDERING_DIR="${SRC_DIR}/menubar/rendering"
ASSET_DIR="${PROJECT_ROOT}/assets"
BUILD_DIR="${PROJECT_ROOT}/build"
GENERATED_DIR="${BUILD_DIR}/generated"
ASSET_MANIFEST="${ASSET_DIR}/manifest.json"
ASSET_GENERATOR="${SCRIPT_DIR}/generate-embedded-assets.py"
ASSET_HEADER="${GENERATED_DIR}/SnowLeopardEmbeddedAssets.h"

UNIFIED_OUTPUT="${BUILD_DIR}/${SL_UNIFIED_NAME}"
BLUE_OUTPUT="${BUILD_DIR}/${SL_BLUE_NAME}"

COMMON_SOURCES=(
    "${SRC_DIR}/common/Runtime.m"
    "${SRC_DIR}/common/SelectionRenderer.m"
)
BLUE_SOURCES=(
    "${COMMON_SOURCES[@]}"
    "${SRC_DIR}/selection/MenuSelection.m"
    "${SRC_DIR}/selection/SidebarSelection.m"
)
UNIFIED_SOURCES=(
    "${COMMON_SOURCES[@]}"
    "${SRC_DIR}/status/StatusSelectionIPC.m"
    "${SRC_DIR}/menubar/MenuBar.m"
    "${SRC_DIR}/status/SystemStatusItems.m"
    "${SRC_DIR}/menus/MenuPopup.m"
    "${SRC_DIR}/status/ExternalStatusItems.m"
    "${SRC_DIR}/status/StatusIcons.m"
)

require_regular_file() {
    [[ -f "$1" && ! -L "$1" ]] || {
        echo "ERROR: missing or invalid source / fuente ausente o inválida: $1" >&2
        exit 1
    }
}

for source in "${BLUE_SOURCES[@]}" "${UNIFIED_SOURCES[@]}" \
    "${ASSET_MANIFEST}" "${ASSET_GENERATOR}"; do
    require_regular_file "${source}"
done

sl_resolve_toolchain
/bin/mkdir -p "${BUILD_DIR}" "${GENERATED_DIR}"
"${SL_PYTHON3}" "${ASSET_GENERATOR}" \
    "${ASSET_MANIFEST}" "${ASSET_DIR}" "${ASSET_HEADER}"

STAGE="$(mktemp -d "${BUILD_DIR}/.stage-runtime.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT HUP INT TERM
STAGED_BLUE="${STAGE}/${SL_BLUE_NAME}"
STAGED_UNIFIED="${STAGE}/${SL_UNIFIED_NAME}"

"${SL_CLANG}" \
    -dynamiclib \
    "${SL_COMMON_OBJC_FLAGS[@]}" \
    "${SL_ARCH_FLAGS[@]}" \
    -isysroot "${SL_SDKROOT}" \
    -I"${INCLUDE_DIR}" \
    -framework Cocoa \
    -framework QuartzCore \
    "${SL_COMMON_LINK_FLAGS[@]}" \
    -install_name "@rpath/${SL_BLUE_NAME}" \
    "${BLUE_SOURCES[@]}" \
    -o "${STAGED_BLUE}"

"${SL_CLANG}" \
    -dynamiclib \
    "${SL_COMMON_OBJC_FLAGS[@]}" \
    "${SL_ARCH_FLAGS[@]}" \
    -isysroot "${SL_SDKROOT}" \
    -I"${INCLUDE_DIR}" \
    -I"${RENDERING_DIR}" \
    -I"${GENERATED_DIR}" \
    -framework Cocoa \
    -framework QuartzCore \
    -framework CoreText \
    -framework CoreImage \
    -framework ImageIO \
    -framework CoreAudio \
    -framework IOKit \
    "${SL_COMMON_LINK_FLAGS[@]}" \
    -install_name "@rpath/${SL_UNIFIED_NAME}" \
    "${UNIFIED_SOURCES[@]}" \
    -o "${STAGED_UNIFIED}"

for binary in "${STAGED_BLUE}" "${STAGED_UNIFIED}"; do
    /usr/bin/codesign --force --sign - "${binary}"
    /usr/bin/codesign --verify --strict "${binary}"
done

BLUE_ARCHITECTURES="$(sl_require_universal_architectures "${STAGED_BLUE}" "BlueSelection")"
UNIFIED_ARCHITECTURES="$(sl_require_universal_architectures "${STAGED_UNIFIED}" "unified dylib")"
sl_require_markers "${STAGED_BLUE}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"
sl_require_markers "${STAGED_UNIFIED}" "unified dylib" "${SL_UNIFIED_MARKERS[@]}"

if /usr/bin/otool -L "${STAGED_UNIFIED}" | /usr/bin/grep -q 'Glow'; then
    echo "ERROR: the unified dylib depends on Glow. / la dylib unificada depende de Glow." >&2
    exit 1
fi

/bin/mv -f "${STAGED_BLUE}" "${BLUE_OUTPUT}"
/bin/mv -f "${STAGED_UNIFIED}" "${UNIFIED_OUTPUT}"

printf '\nRuntime build complete. / Compilación de runtime terminada.\n'
printf 'BlueSelection: %s (%s)\n' "${BLUE_OUTPUT}" "${BLUE_ARCHITECTURES}"
printf 'Unified: %s (%s)\n' "${UNIFIED_OUTPUT}" "${UNIFIED_ARCHITECTURES}"
