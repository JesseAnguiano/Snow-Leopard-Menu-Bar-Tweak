#!/bin/bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"

TWEAK_DIR="${SL_TWEAK_DIR}"
DYLIB="${TWEAK_DIR}/${SL_BLUE_NAME}"
FILTER="${DYLIB}.blacklist"

[[ -f "${DYLIB}" ]] || { echo "ERROR: BlueSelection is not installed. / BlueSelection no está instalado." >&2; exit 1; }
[[ -f "${FILTER}" ]] || { echo "ERROR: missing blacklist. / falta la blacklist." >&2; exit 1; }
/usr/bin/codesign --verify --strict --verbose=2 "${DYLIB}"
ARCHS="$(sl_require_universal_architectures "${DYLIB}" "BlueSelection")"

sl_require_markers "${DYLIB}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"

echo "BlueSelection sidebar verified. Architectures: ${ARCHS} / BlueSelection sidebar verificado. Arquitecturas: ${ARCHS}"
echo "Log / Registro: ${SL_DEBUG_LOG}"
