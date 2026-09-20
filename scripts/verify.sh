#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"

TWEAK_DIR="${SL_TWEAK_DIR}"
NAME="${SL_UNIFIED_NAME}"
DYLIB="${TWEAK_DIR}/${NAME}"
FILTER="${TWEAK_DIR}/${NAME}.blacklist"
BLUE_NAME="${SL_BLUE_NAME}"
BLUE_DYLIB="${TWEAK_DIR}/${BLUE_NAME}"
BLUE_FILTER="${TWEAK_DIR}/${BLUE_NAME}.blacklist"

sl_require_supported_macos

if [[ ! -f "${DYLIB}" ]]; then
    echo "ERROR: ${DYLIB} is not installed. / no está instalada ${DYLIB}" >&2
    exit 1
fi

if [[ ! -f "${FILTER}" ]]; then
    echo "ERROR: ${FILTER} is not installed. / no está instalada ${FILTER}" >&2
    exit 1
fi

if [[ ! -f "${BLUE_DYLIB}" || ! -f "${BLUE_FILTER}" ]]; then
    echo "ERROR: BlueSelection is not installed with its blacklist. / BlueSelection no está instalado con su blacklist." >&2
    exit 1
fi

/usr/bin/codesign --verify --strict --verbose=2 "${DYLIB}"
/usr/bin/codesign --verify --strict --verbose=2 "${BLUE_DYLIB}"

ARCHS="$(sl_require_universal_architectures "${DYLIB}" "unified dylib")"
BLUE_ARCHS="$(sl_require_universal_architectures "${BLUE_DYLIB}" "BlueSelection")"

sl_require_markers "${DYLIB}" "unified dylib" "${SL_UNIFIED_MARKERS[@]}"
sl_require_markers "${BLUE_DYLIB}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"

if /usr/bin/grep -Fxq 'ControlCenter' "${BLUE_FILTER}" ||
   /usr/bin/grep -Fxq 'SystemUIServer' "${BLUE_FILTER}"; then
    echo "ERROR: BlueSelection is blocked on the right side. / BlueSelection está bloqueado en el lado derecho." >&2
    exit 1
fi

STATUS_SPACING="$(/usr/bin/defaults -currentHost read -globalDomain "${SL_STATUS_SPACING_KEY}" 2>/dev/null || true)"
STATUS_PADDING="$(/usr/bin/defaults -currentHost read -globalDomain "${SL_STATUS_PADDING_KEY}" 2>/dev/null || true)"
SPOTLIGHT_POSITION="$(/usr/bin/defaults read "${SL_SPOTLIGHT_DOMAIN}" "${SL_SPOTLIGHT_POSITION_KEY}" 2>/dev/null || true)"
CLOCK_POSITION="$(/usr/bin/defaults read "${SL_CLOCK_DOMAIN}" "${SL_CLOCK_POSITION_KEY}" 2>/dev/null || true)"

if [[ "${STATUS_SPACING}" != "${SL_STATUS_SPACING}" || "${STATUS_PADDING}" != "${SL_STATUS_PADDING}" ]]; then
    echo "ERROR: unexpected right-side spacing: spacing=${STATUS_SPACING:-missing} padding=${STATUS_PADDING:-missing}. / separación derecha inesperada: spacing=${STATUS_SPACING:-ausente} padding=${STATUS_PADDING:-ausente}." >&2
    exit 1
fi

if [[ "${SPOTLIGHT_POSITION}" != "${SL_SPOTLIGHT_PERSISTED_POSITION}" || "${CLOCK_POSITION}" != "${SL_CLOCK_PERSISTED_POSITION}" ]]; then
    echo "ERROR: unexpected right-side order: Spotlight=${SPOTLIGHT_POSITION:-missing} Clock=${CLOCK_POSITION:-missing}. / orden derecho inesperado: Spotlight=${SPOTLIGHT_POSITION:-ausente} Clock=${CLOCK_POSITION:-ausente}." >&2
    exit 1
fi

OLD_PRESENT=0

for OLD in "${SL_LEGACY_DYLIBS[@]}"; do
    if [[ -e "${TWEAK_DIR}/${OLD}" ]]; then
        echo "ERROR: ${TWEAK_DIR}/${OLD} still exists. / todavía existe ${TWEAK_DIR}/${OLD}"
        OLD_PRESENT=1
    fi
done

if [[ "${OLD_PRESENT}" -ne 0 ]]; then
    exit 1
fi

echo
echo "Verification passed. / Verificación correcta."
echo "Unified: ${DYLIB} (${ARCHS})"
echo "BlueSelection: ${BLUE_DYLIB} (${BLUE_ARCHS})"
echo "Selection ownership: Unified=top-menu/status; BlueSelection=popup/context/Dock/sidebar. / Responsabilidad: Unified=menú superior/status; BlueSelection=popup/contexto/Dock/sidebar."
echo "Persisted layout: spacing=${SL_STATUS_SPACING}, padding=${SL_STATUS_PADDING}, Spotlight=${SL_SPOTLIGHT_PERSISTED_POSITION}, Clock=${SL_CLOCK_PERSISTED_POSITION}. / Layout persistido: spacing=${SL_STATUS_SPACING}, padding=${SL_STATUS_PADDING}, Spotlight=${SL_SPOTLIGHT_PERSISTED_POSITION}, Clock=${SL_CLOCK_PERSISTED_POSITION}."
echo "Legacy competing dylibs absent: ${#SL_LEGACY_DYLIBS[@]}. / Dylibs legacy competidoras ausentes: ${#SL_LEGACY_DYLIBS[@]}."

if [[ -f "${SL_DEBUG_LOG}" ]]; then
    echo
    echo "Recent debug loads (when debug logging was enabled) / Cargas de diagnóstico recientes (si el log estuvo habilitado):"
    /usr/bin/grep -E \
        'core install process=|system-status install process=|popup install process=|external-status installed process=|embedded status icons installed process=|embedded status icon attached' \
        "${SL_DEBUG_LOG}" 2>/dev/null | /usr/bin/tail -40 || true
fi
