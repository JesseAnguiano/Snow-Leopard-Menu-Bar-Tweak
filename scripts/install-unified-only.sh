#!/bin/bash
# Update only the already-installed unified dylib. Preferences, blacklists,
# BlueSelection and the wallpaper helper are intentionally untouched.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"

SOURCE="${PROJECT_ROOT}/build/${SL_UNIFIED_NAME}"
TARGET="${SL_TWEAK_DIR}/${SL_UNIFIED_NAME}"

case "${1:-}" in
    ''|--check) ;;
    *) echo 'Usage / Uso: bash scripts/install-unified-only.sh [--check]' >&2; exit 2 ;;
esac
sl_require_supported_macos

for item in "${SOURCE}" "${TARGET}"; do
    [[ -f "${item}" && ! -L "${item}" ]] || {
        echo "ERROR: missing file or symbolic link / archivo ausente o enlace simbólico: ${item}" >&2
        exit 1
    }
done
for dir in "${SL_TWEAK_DIR}" "${SL_BACKUP_ROOT}"; do
    [[ -d "${dir}" && ! -L "${dir}" ]] || {
        echo "ERROR: invalid directory / directorio no válido: ${dir}" >&2
        exit 1
    }
done

/usr/bin/codesign --verify --strict "${SOURCE}"
ARCHS="$(sl_require_universal_architectures "${SOURCE}" 'unified dylib')"
sl_require_markers "${SOURCE}" 'unified dylib' "${SL_UNIFIED_MARKERS[@]}"
echo "Preflight passed (${ARCHS}); visual correctness still requires a live test. / Preflight correcto (${ARCHS}); la fidelidad visual requiere una prueba real."
[[ "${1:-}" == '--check' ]] && exit 0

if [[ "${EUID}" -ne 0 ]]; then
    exec /usr/bin/sudo /bin/bash "${BASH_SOURCE[0]}"
fi

BACKUP="$(/usr/bin/mktemp -d "${SL_BACKUP_ROOT}/snow-leopard-unified.XXXXXX")"
STAGED="$(/usr/bin/mktemp "${SL_TWEAK_DIR}/.snow-leopard-unified.XXXXXX")"
trap '/bin/rm -f "${STAGED}"' EXIT
/bin/cp -p "${TARGET}" "${BACKUP}/${SL_UNIFIED_NAME}"
/usr/bin/install -o root -g wheel -m 755 "${SOURCE}" "${STAGED}"
/usr/bin/codesign --verify --strict "${STAGED}"
/usr/bin/cmp -s "${SOURCE}" "${STAGED}"
/bin/mv -f "${STAGED}" "${TARGET}"

if ! /usr/bin/cmp -s "${SOURCE}" "${TARGET}"; then
    /bin/cp -p "${BACKUP}/${SL_UNIFIED_NAME}" "${TARGET}"
    echo "ERROR: verification failed; restored ${BACKUP}/${SL_UNIFIED_NAME}. / verificación fallida; se restauró el respaldo." >&2
    exit 1
fi

echo "Unified dylib installed. Backup: ${BACKUP}/${SL_UNIFIED_NAME} / Dylib unificada instalada. Respaldo: ${BACKUP}/${SL_UNIFIED_NAME}"
echo 'Log out/in to reload every process. / Cierra e inicia sesión para recargar todos los procesos.'
