#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"
BUILD_DIR="${PROJECT_ROOT}/build"
BLACKLIST_DIR="${PROJECT_ROOT}"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
TWEAK_DIR="${SL_TWEAK_DIR}"
NAME="${SL_BLUE_NAME}"
SOURCE="${BUILD_DIR}/${NAME}"
BLACKLIST_SOURCE="${BLACKLIST_DIR}/${NAME}.blacklist"

sl_require_supported_macos

if [[ "${EUID}" -ne 0 ]]; then
    exec /usr/bin/sudo /bin/bash "${SCRIPT_PATH}" "$@"
fi

for REQUIRED in "${SOURCE}" "${BLACKLIST_SOURCE}"; do
    if [[ ! -f "${REQUIRED}" || -L "${REQUIRED}" ]]; then
        echo "ERROR: invalid required file / archivo requerido inválido: ${REQUIRED}" >&2
        exit 1
    fi
done

if [[ ! -d "${TWEAK_DIR}" || -L "${TWEAK_DIR}" ]]; then
    echo "ERROR: Ammonia does not appear to be installed correctly. / Ammonia no parece estar instalado correctamente." >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "${SOURCE}"
ARCHS="$(sl_require_universal_architectures "${SOURCE}" "BlueSelection")"

sl_require_markers "${SOURCE}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"

if [[ ! -s "${BLACKLIST_SOURCE}" ]]; then
    echo "ERROR: blacklist is empty. / la blacklist está vacía." >&2
    exit 1
fi
if /usr/bin/grep -Fxq 'Finder' "${BLACKLIST_SOURCE}" ||
   /usr/bin/grep -Fxq 'System Settings' "${BLACKLIST_SOURCE}"; then
    echo "ERROR: blacklist would block Finder or System Settings. / la blacklist bloquearía Finder o Configuración del Sistema." >&2
    exit 1
fi

STAMP="$(/bin/date '+%Y%m%d-%H%M%S')-$$"
TRANSACTION_DIR="${SL_BACKUP_ROOT}/BlueSelection-sidebar/${STAMP}"
BACKUP_DIR="${TRANSACTION_DIR}/previous"
STAGE_DIR="${TRANSACTION_DIR}/stage"
/bin/mkdir -p "${BACKUP_DIR}" "${STAGE_DIR}"
/usr/sbin/chown -R root:wheel "${TRANSACTION_DIR}"
/bin/chmod 700 "${TRANSACTION_DIR}" "${BACKUP_DIR}" "${STAGE_DIR}"

for LIVE in \
    "${TWEAK_DIR}/${NAME}" \
    "${TWEAK_DIR}/${NAME}.blacklist" \
    "${TWEAK_DIR}/${NAME}.whitelist"
do
    if [[ -L "${LIVE}" ]]; then
        echo "ERROR: installation cancelled; ${LIVE} is a symbolic link. / instalación cancelada; ${LIVE} es un enlace simbólico." >&2
        exit 1
    fi
done

/usr/bin/install -o root -g wheel -m 755 \
    "${SOURCE}" "${STAGE_DIR}/${NAME}"
/usr/bin/install -o root -g wheel -m 644 \
    "${BLACKLIST_SOURCE}" "${STAGE_DIR}/${NAME}.blacklist"
/usr/bin/codesign --force --sign - "${STAGE_DIR}/${NAME}"
/usr/bin/codesign --verify --strict "${STAGE_DIR}/${NAME}"

MOVED=()
INSTALLED=()
COMMITTED=0

rollback() {
    STATUS=$?
    trap - EXIT HUP INT TERM
    set +e
    if [[ "${COMMITTED}" -eq 0 ]]; then
        for ITEM in "${INSTALLED[@]}"; do
            /bin/rm -f "${TWEAK_DIR}/${ITEM}"
        done
        for ITEM in "${MOVED[@]}"; do
            if [[ -e "${BACKUP_DIR}/${ITEM}" ]]; then
                /bin/mv "${BACKUP_DIR}/${ITEM}" "${TWEAK_DIR}/${ITEM}"
            fi
        done
        echo "Installation failed; the previous BlueSelection was restored. / La instalación falló; se restauró BlueSelection anterior." >&2
    fi
    exit "${STATUS}"
}

trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for ITEM in "${NAME}" "${NAME}.blacklist" "${NAME}.whitelist"; do
    if [[ -e "${TWEAK_DIR}/${ITEM}" ]]; then
        MOVED[${#MOVED[@]}]="${ITEM}"
        /bin/mv "${TWEAK_DIR}/${ITEM}" "${BACKUP_DIR}/${ITEM}"
    fi
done

INSTALLED[${#INSTALLED[@]}]="${NAME}.blacklist"
/bin/mv "${STAGE_DIR}/${NAME}.blacklist" \
    "${TWEAK_DIR}/${NAME}.blacklist"
INSTALLED[${#INSTALLED[@]}]="${NAME}"
/bin/mv "${STAGE_DIR}/${NAME}" "${TWEAK_DIR}/${NAME}"
/bin/rmdir "${STAGE_DIR}"

/usr/bin/codesign --verify --strict "${TWEAK_DIR}/${NAME}"
/usr/bin/cmp "${BLACKLIST_SOURCE}" "${TWEAK_DIR}/${NAME}.blacklist"

COMMITTED=1
trap - EXIT HUP INT TERM

/usr/bin/killall Finder >/dev/null 2>&1 || true
/usr/bin/killall 'System Settings' >/dev/null 2>&1 || true

echo
echo "BlueSelection installed. / BlueSelection instalado."
echo "Finder restarted; reopen System Settings. / Finder se reinició; vuelve a abrir Configuración del Sistema."
echo "Other applications will show the change when reopened. / Las demás aplicaciones mostrarán el cambio cuando se vuelvan a abrir."
echo "Recoverable backup / Respaldo recuperable: ${BACKUP_DIR}"
echo "Log / Registro: ${SL_DEBUG_LOG}"
