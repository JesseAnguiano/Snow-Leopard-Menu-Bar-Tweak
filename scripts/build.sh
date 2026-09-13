#!/bin/bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"
SRC_DIR="${PROJECT_ROOT}/src"
INCLUDE_DIR="${SRC_DIR}/include"
RENDERING_DIR="${SRC_DIR}/menubar/rendering"
ASSET_DIR="${PROJECT_ROOT}/assets"
BLACKLIST_DIR="${PROJECT_ROOT}"
BUILD_DIR="${PROJECT_ROOT}/build"
GENERATED_DIR="${BUILD_DIR}/generated"

RUNTIME_SOURCE="${SRC_DIR}/common/Runtime.m"
RENDERER_SOURCE="${SRC_DIR}/common/SelectionRenderer.m"
RUNTIME_HEADER="${INCLUDE_DIR}/Runtime.h"
RENDERER_HEADER="${INCLUDE_DIR}/SelectionRenderer.h"
STATUS_IPC_SOURCE="${SRC_DIR}/status/StatusSelectionIPC.m"
STATUS_IPC_HEADER="${INCLUDE_DIR}/StatusSelectionIPC.h"
CORE_SOURCE="${SRC_DIR}/menubar/MenuBar.m"
EXTRAS_SOURCE="${SRC_DIR}/status/SystemStatusItems.m"
POPUP_SOURCE="${SRC_DIR}/menus/MenuPopup.m"
EXTERNAL_SOURCE="${SRC_DIR}/status/ExternalStatusItems.m"
ICON_SOURCE="${SRC_DIR}/status/StatusIcons.m"
ASSET_MANIFEST="${ASSET_DIR}/manifest.json"
ASSET_GENERATOR="${SCRIPT_DIR}/generate-embedded-assets.py"
ASSET_HEADER="${GENERATED_DIR}/SnowLeopardEmbeddedAssets.h"
MENU_SELECTION_SOURCE="${SRC_DIR}/selection/MenuSelection.m"
SIDEBAR_SELECTION_SOURCE="${SRC_DIR}/selection/SidebarSelection.m"
BLUE_BINARY="${BUILD_DIR}/${SL_BLUE_NAME}"
BLUE_BLACKLIST="${BLACKLIST_DIR}/${SL_BLUE_NAME}.blacklist"
RESTORE_SPACING="${SCRIPT_DIR}/restore-native-spacing.sh"

OUTPUT_NAME="${SL_UNIFIED_NAME}"
OUTPUT="${BUILD_DIR}/${OUTPUT_NAME}"
/bin/mkdir -p "${BUILD_DIR}"


for SOURCE in \
    "${RUNTIME_SOURCE}" \
    "${RENDERER_SOURCE}" \
    "${RUNTIME_HEADER}" \
    "${RENDERER_HEADER}" \
    "${STATUS_IPC_SOURCE}" \
    "${STATUS_IPC_HEADER}" \
    "${CORE_SOURCE}" \
    "${EXTRAS_SOURCE}" \
    "${POPUP_SOURCE}" \
    "${EXTERNAL_SOURCE}" \
    "${ICON_SOURCE}" \
    "${MENU_SELECTION_SOURCE}" \
    "${SIDEBAR_SELECTION_SOURCE}" \
    "${BLUE_BLACKLIST}" \
    "${RESTORE_SPACING}" \
    "${ASSET_MANIFEST}" \
    "${ASSET_GENERATOR}"
do
    if [[ ! -f "${SOURCE}" ]]; then
        echo "ERROR: source does not exist / no existe ${SOURCE}" >&2
        exit 1
    fi

    if [[ -L "${SOURCE}" ]]; then
        echo "ERROR: ${SOURCE} is a symbolic link. / ${SOURCE} es un enlace simbólico." >&2
        exit 1
    fi
done

if ! CLANG="$(/usr/bin/xcrun --find clang 2>/dev/null)"; then
    echo "ERROR: install Xcode Command Line Tools before building. / instala Xcode Command Line Tools antes de compilar." >&2
    exit 1
fi

if ! SDKROOT="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null)" ||
   [[ ! -d "${SDKROOT}" ]]; then
    echo "ERROR: macOS SDK could not be located. / no se pudo localizar el SDK de macOS." >&2
    exit 1
fi

if ! PYTHON3="$(/usr/bin/xcrun --find python3 2>/dev/null)"; then
    echo "ERROR: Python 3 from Xcode Command Line Tools is required. / se requiere Python 3 de Xcode Command Line Tools." >&2
    exit 1
fi

/bin/mkdir -p "${GENERATED_DIR}"
"${PYTHON3}" "${ASSET_GENERATOR}" \
    "${ASSET_MANIFEST}" \
    "${ASSET_DIR}" \
    "${ASSET_HEADER}"

# Build in an isolated, uniquely created directory. Preserve the previous
# deliverables if compilation, signing, or validation fails.
FINAL_OUTPUT="${OUTPUT}"
FINAL_BLUE_BINARY="${BLUE_BINARY}"
BUILD_STAGE="$(mktemp -d "${BUILD_DIR}/.stage-menubar.XXXXXX")"
OUTPUT="${BUILD_STAGE}/${OUTPUT_NAME}"
BLUE_BINARY="${BUILD_STAGE}/${SL_BLUE_NAME}"
cleanup_build_stage() {
    # Exact files owned by this invocation only; never remove a project root.
    /bin/rm -f "${OUTPUT}" "${BLUE_BINARY}"
    /bin/rmdir "${BUILD_STAGE}" 2>/dev/null || true
}
trap cleanup_build_stage EXIT

"${CLANG}" \
    -dynamiclib \
    -fobjc-arc \
    -fblocks \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -arch arm64 \
    -arch arm64e \
    -isysroot "${SDKROOT}" \
    -mmacosx-version-min=15.0 \
    -I"${INCLUDE_DIR}" \
    -framework Cocoa \
    -framework QuartzCore \
    -Wl,-dead_strip \
    -install_name '@rpath/libSnowLeopardBlueSelection.dylib' \
    "${RUNTIME_SOURCE}" \
    "${RENDERER_SOURCE}" \
    "${MENU_SELECTION_SOURCE}" \
    "${SIDEBAR_SELECTION_SOURCE}" \
    -o "${BLUE_BINARY}"

/usr/bin/codesign \
    --force \
    --sign - \
    "${BLUE_BINARY}"

"${CLANG}" \
    -dynamiclib \
    -fobjc-arc \
    -fblocks \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -arch arm64 \
    -arch arm64e \
    -isysroot "${SDKROOT}" \
    -mmacosx-version-min=15.0 \
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
    -Wl,-dead_strip \
    -install_name "@rpath/${OUTPUT_NAME}" \
    "${RUNTIME_SOURCE}" \
    "${RENDERER_SOURCE}" \
    "${STATUS_IPC_SOURCE}" \
    "${CORE_SOURCE}" \
    "${EXTRAS_SOURCE}" \
    "${POPUP_SOURCE}" \
    "${EXTERNAL_SOURCE}" \
    "${ICON_SOURCE}" \
    -o "${OUTPUT}"

/usr/bin/codesign \
    --force \
    --sign - \
    "${OUTPUT}"

/usr/bin/codesign \
    --verify \
    --strict \
    --verbose=2 \
    "${OUTPUT}"

ARCHITECTURES="$(sl_require_universal_architectures "${OUTPUT}" "unified dylib")"

if /usr/bin/otool -L "${OUTPUT}" |
    /usr/bin/grep -q 'Glow'; then
    echo "ERROR: the unified dylib depends on Glow. / la dylib unificada depende de Glow." >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "${BLUE_BINARY}"
BLUE_ARCHITECTURES="$(sl_require_universal_architectures "${BLUE_BINARY}" "BlueSelection")"

sl_require_markers "${BLUE_BINARY}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"
sl_require_markers "${OUTPUT}" "unified dylib" "${SL_UNIFIED_MARKERS[@]}"

/usr/bin/file "${OUTPUT}"

/bin/mv -f "${OUTPUT}" "${FINAL_OUTPUT}"
/bin/mv -f "${BLUE_BINARY}" "${FINAL_BLUE_BINARY}"

echo
echo "Unified dylib built and signed. / Dylib unificada compilada y firmada."
echo "Architectures / Arquitecturas: ${ARCHITECTURES}"
echo "BlueSelection included / BlueSelection incluido: ${BLUE_ARCHITECTURES}"
echo "Output / Salida: ${FINAL_OUTPUT}"
