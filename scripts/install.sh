#!/bin/bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
source "${SCRIPT_DIR}/markers.sh"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
BUILD_DIR="${PROJECT_ROOT}/build"
BLACKLIST_DIR="${PROJECT_ROOT}"

AMMONIA_CORE="${SL_AMMONIA_CORE}"
TWEAK_DIR="${SL_TWEAK_DIR}"

UNIFIED_NAME="${SL_UNIFIED_NAME}"
UNIFIED_SOURCE="${BUILD_DIR}/${UNIFIED_NAME}"
UNIFIED_BLACKLIST_SOURCE="${BLACKLIST_DIR}/${UNIFIED_NAME}.blacklist"
BLUE_NAME="${SL_BLUE_NAME}"
BLUE_SOURCE="${BUILD_DIR}/${BLUE_NAME}"
BLUE_BLACKLIST_SOURCE="${BLACKLIST_DIR}/${BLUE_NAME}.blacklist"
STATUS_SPACING_KEY="${SL_STATUS_SPACING_KEY}"
STATUS_PADDING_KEY="${SL_STATUS_PADDING_KEY}"
SNOW_LEOPARD_STATUS_SPACING="${SL_STATUS_SPACING}"
SNOW_LEOPARD_STATUS_PADDING="${SL_STATUS_PADDING}"
SPOTLIGHT_DOMAIN="${SL_SPOTLIGHT_DOMAIN}"
SPOTLIGHT_POSITION_KEY="${SL_SPOTLIGHT_POSITION_KEY}"
SPOTLIGHT_EXTREME_RIGHT_POSITION="${SL_SPOTLIGHT_PERSISTED_POSITION}"
CLOCK_DOMAIN="${SL_CLOCK_DOMAIN}"
CLOCK_POSITION_KEY="${SL_CLOCK_POSITION_KEY}"
CLOCK_LEFT_OF_SPOTLIGHT_POSITION="${SL_CLOCK_PERSISTED_POSITION}"


sl_require_supported_macos

if [[ "${EUID}" -ne 0 ]]; then
    exec /usr/bin/sudo /bin/bash "${SCRIPT_PATH}" "$@"
fi

for REQUIRED in \
    "${UNIFIED_SOURCE}" \
    "${UNIFIED_BLACKLIST_SOURCE}" \
    "${BLUE_SOURCE}" \
    "${BLUE_BLACKLIST_SOURCE}"
do
    if [[ ! -f "${REQUIRED}" ]]; then
        echo "ERROR: missing ${REQUIRED}. Run ./scripts/build.sh first. / falta ${REQUIRED}. Ejecuta ./scripts/build.sh primero." >&2
        exit 1
    fi

    if [[ -L "${REQUIRED}" ]]; then
        echo "ERROR: ${REQUIRED} is a symbolic link. / ${REQUIRED} es un enlace simbólico." >&2
        exit 1
    fi
done

if [[ ! -d "${TWEAK_DIR}" ]]; then
    echo "ERROR: ${TWEAK_DIR} does not exist; Ammonia does not appear to be installed. / no existe ${TWEAK_DIR}; Ammonia no parece instalado." >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "${UNIFIED_SOURCE}"
/usr/bin/codesign --verify --strict "${BLUE_SOURCE}"
ARCHS="$(sl_require_universal_architectures "${UNIFIED_SOURCE}" "unified dylib")"
BLUE_ARCHS="$(sl_require_universal_architectures "${BLUE_SOURCE}" "BlueSelection")"

if /usr/bin/otool -L "${UNIFIED_SOURCE}" |
    /usr/bin/grep -q 'Glow'; then
    echo "ERROR: the unified dylib depends on Glow. / la dylib unificada depende de Glow." >&2
    exit 1
fi

sl_require_markers "${UNIFIED_SOURCE}" "unified dylib" "${SL_UNIFIED_MARKERS[@]}"
sl_require_markers "${BLUE_SOURCE}" "BlueSelection" "${SL_BLUE_MARKERS[@]}"

if [[ ! -s "${UNIFIED_BLACKLIST_SOURCE}" ]]; then
    echo "ERROR: unified blacklist is empty. / la blacklist unificada está vacía." >&2
    exit 1
fi

if [[ ! -s "${BLUE_BLACKLIST_SOURCE}" ]]; then
    echo "ERROR: BlueSelection blacklist is empty. / la blacklist de BlueSelection está vacía." >&2
    exit 1
fi

if /usr/bin/grep -Fxq 'ControlCenter' "${BLUE_BLACKLIST_SOURCE}" ||
   /usr/bin/grep -Fxq 'SystemUIServer' "${BLUE_BLACKLIST_SOURCE}"; then
    echo "ERROR: BlueSelection blacklist would block the right side. / la blacklist de BlueSelection bloquearía el lado derecho." >&2
    exit 1
fi

if /usr/bin/grep -Fxq 'ControlCenter' "${UNIFIED_BLACKLIST_SOURCE}" ||
   /usr/bin/grep -Fxq 'SystemUIServer' "${UNIFIED_BLACKLIST_SOURCE}"; then
    echo "ERROR: blacklist would block ControlCenter or SystemUIServer. / la blacklist bloquearía ControlCenter o SystemUIServer." >&2
    exit 1
fi

for REQUIRED_FILTER in "${SL_UNIFIED_SAFETY_FILTERS[@]}"; do
    if ! /usr/bin/grep -Fxq "${REQUIRED_FILTER}" "${UNIFIED_BLACKLIST_SOURCE}"; then
        echo "ERROR: missing safety exclusion / falta la exclusión de seguridad: ${REQUIRED_FILTER}" >&2
        exit 1
    fi
done

STAMP="$(/bin/date '+%Y%m%d-%H%M%S')-$$"
TRANSACTION_DIR="${AMMONIA_CORE}/backups/snow-leopard-menubar-unified/${STAMP}"
BACKUP_DIR="${TRANSACTION_DIR}/previous"
STAGE_DIR="${TRANSACTION_DIR}/stage"

/bin/mkdir -p "${BACKUP_DIR}" "${STAGE_DIR}"
/usr/sbin/chown -R root:wheel "${TRANSACTION_DIR}"
/bin/chmod 700 "${TRANSACTION_DIR}" "${BACKUP_DIR}" "${STAGE_DIR}"

CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
if [[ -z "${CONSOLE_USER}" || "${CONSOLE_USER}" == "root" ]]; then
    echo "ERROR: could not identify the graphical-session user. / no se pudo identificar al usuario de la sesión gráfica." >&2
    exit 1
fi

USER_DEFAULTS=(
    /usr/bin/sudo -H -u "${CONSOLE_USER}"
    /usr/bin/defaults
)

read_current_host_integer() {
    local key="$1"
    local value

    if ! value="$("${USER_DEFAULTS[@]}" -currentHost read -globalDomain "${key}" 2>/dev/null)"; then
        return 1
    fi

    if [[ ! "${value}" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: ${key} contains a non-integer value / contiene un valor no entero: ${value}" >&2
        exit 1
    fi

    /usr/bin/printf '%s' "${value}"
}

read_domain_integer() {
    local domain="$1"
    local key="$2"
    local value

    if ! value="$("${USER_DEFAULTS[@]}" read "${domain}" "${key}" 2>/dev/null)"; then
        return 1
    fi

    if [[ ! "${value}" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: ${domain}/${key} contains a non-integer value / contiene un valor no entero: ${value}" >&2
        exit 1
    fi

    /usr/bin/printf '%s' "${value}"
}

STATUS_SPACING_PRESENT=0
STATUS_PADDING_PRESENT=0
STATUS_SPACING_PREVIOUS=""
STATUS_PADDING_PREVIOUS=""
SPOTLIGHT_POSITION_PRESENT=0
CLOCK_POSITION_PRESENT=0
SPOTLIGHT_POSITION_PREVIOUS=""
CLOCK_POSITION_PREVIOUS=""

if STATUS_SPACING_PREVIOUS="$(read_current_host_integer "${STATUS_SPACING_KEY}")"; then
    STATUS_SPACING_PRESENT=1
fi

if STATUS_PADDING_PREVIOUS="$(read_current_host_integer "${STATUS_PADDING_KEY}")"; then
    STATUS_PADDING_PRESENT=1
fi

if SPOTLIGHT_POSITION_PREVIOUS="$(read_domain_integer "${SPOTLIGHT_DOMAIN}" "${SPOTLIGHT_POSITION_KEY}")"; then
    SPOTLIGHT_POSITION_PRESENT=1
fi

if CLOCK_POSITION_PREVIOUS="$(read_domain_integer "${CLOCK_DOMAIN}" "${CLOCK_POSITION_KEY}")"; then
    CLOCK_POSITION_PRESENT=1
fi

{
    /usr/bin/printf 'user=%s\n' "${CONSOLE_USER}"
    /usr/bin/printf '%s.present=%s\n' \
        "${STATUS_SPACING_KEY}" "${STATUS_SPACING_PRESENT}"
    /usr/bin/printf '%s.value=%s\n' \
        "${STATUS_SPACING_KEY}" "${STATUS_SPACING_PREVIOUS}"
    /usr/bin/printf '%s.present=%s\n' \
        "${STATUS_PADDING_KEY}" "${STATUS_PADDING_PRESENT}"
    /usr/bin/printf '%s.value=%s\n' \
        "${STATUS_PADDING_KEY}" "${STATUS_PADDING_PREVIOUS}"
} > "${TRANSACTION_DIR}/status-item-spacing-before.txt"

{
    /usr/bin/printf 'user=%s\n' "${CONSOLE_USER}"
    /usr/bin/printf 'spotlight.domain=%s\n' "${SPOTLIGHT_DOMAIN}"
    /usr/bin/printf 'spotlight.key=%s\n' "${SPOTLIGHT_POSITION_KEY}"
    /usr/bin/printf 'spotlight.present=%s\n' "${SPOTLIGHT_POSITION_PRESENT}"
    /usr/bin/printf 'spotlight.value=%s\n' "${SPOTLIGHT_POSITION_PREVIOUS}"
    /usr/bin/printf 'clock.domain=%s\n' "${CLOCK_DOMAIN}"
    /usr/bin/printf 'clock.key=%s\n' "${CLOCK_POSITION_KEY}"
    /usr/bin/printf 'clock.present=%s\n' "${CLOCK_POSITION_PRESENT}"
    /usr/bin/printf 'clock.value=%s\n' "${CLOCK_POSITION_PREVIOUS}"
} > "${TRANSACTION_DIR}/status-item-order-before.txt"

# Todo lo que pertenece a esta implementación, incluida la instalación
# independiente anterior y experimentos históricos que podrían competir.
MANAGED_NAMES=(
    "${UNIFIED_NAME}"
    "${UNIFIED_NAME}.blacklist"
    "${UNIFIED_NAME}.whitelist"
    "${BLUE_NAME}"
    "${BLUE_NAME}.blacklist"
    "${BLUE_NAME}.whitelist"
)
for LEGACY_DYLIB in "${SL_LEGACY_DYLIBS[@]}"; do
    MANAGED_NAMES+=(
        "${LEGACY_DYLIB}"
        "${LEGACY_DYLIB}.blacklist"
        "${LEGACY_DYLIB}.whitelist"
    )
done

for NAME in "${MANAGED_NAMES[@]}"; do
    LIVE_PATH="${TWEAK_DIR}/${NAME}"

    if [[ -L "${LIVE_PATH}" ]]; then
        echo "ERROR: installation cancelled; ${LIVE_PATH} is a symbolic link. / instalación cancelada; ${LIVE_PATH} es un enlace simbólico." >&2
        exit 1
    fi
done

/usr/bin/install \
    -o root \
    -g wheel \
    -m 755 \
    "${UNIFIED_SOURCE}" \
    "${STAGE_DIR}/${UNIFIED_NAME}"

/usr/bin/install \
    -o root \
    -g wheel \
    -m 644 \
    "${UNIFIED_BLACKLIST_SOURCE}" \
    "${STAGE_DIR}/${UNIFIED_NAME}.blacklist"

/usr/bin/install \
    -o root \
    -g wheel \
    -m 755 \
    "${BLUE_SOURCE}" \
    "${STAGE_DIR}/${BLUE_NAME}"

/usr/bin/install \
    -o root \
    -g wheel \
    -m 644 \
    "${BLUE_BLACKLIST_SOURCE}" \
    "${STAGE_DIR}/${BLUE_NAME}.blacklist"

/usr/bin/codesign \
    --force \
    --sign - \
    "${STAGE_DIR}/${UNIFIED_NAME}"

/usr/bin/codesign \
    --force \
    --sign - \
    "${STAGE_DIR}/${BLUE_NAME}"

/usr/bin/codesign \
    --verify \
    --strict \
    "${STAGE_DIR}/${UNIFIED_NAME}"

/usr/bin/codesign \
    --verify \
    --strict \
    "${STAGE_DIR}/${BLUE_NAME}"

STAGED_ARCHS="$(/usr/bin/lipo -archs "${STAGE_DIR}/${UNIFIED_NAME}")"
STAGED_BLUE_ARCHS="$(/usr/bin/lipo -archs "${STAGE_DIR}/${BLUE_NAME}")"

sl_require_universal_architectures "${STAGE_DIR}/${UNIFIED_NAME}" "staged unified dylib" >/dev/null

sl_require_universal_architectures "${STAGE_DIR}/${BLUE_NAME}" "staged BlueSelection" >/dev/null

MOVED_NAMES=()
INSTALLED_NAMES=()
BACKUP_COUNT=0
COMMIT_COMPLETE=0
PREFERENCES_CHANGED=0

rollback_install() {
    STATUS=$?
    trap - EXIT HUP INT TERM
    set +e

    if [[ "${COMMIT_COMPLETE}" -eq 0 ]]; then
        if [[ "${PREFERENCES_CHANGED}" -eq 1 ]]; then
            if [[ "${STATUS_SPACING_PRESENT}" -eq 1 ]]; then
                "${USER_DEFAULTS[@]}" -currentHost write -globalDomain \
                    "${STATUS_SPACING_KEY}" -int "${STATUS_SPACING_PREVIOUS}" >/dev/null
            else
                "${USER_DEFAULTS[@]}" -currentHost delete -globalDomain \
                    "${STATUS_SPACING_KEY}" >/dev/null 2>&1 || true
            fi

            if [[ "${STATUS_PADDING_PRESENT}" -eq 1 ]]; then
                "${USER_DEFAULTS[@]}" -currentHost write -globalDomain \
                    "${STATUS_PADDING_KEY}" -int "${STATUS_PADDING_PREVIOUS}" >/dev/null
            else
                "${USER_DEFAULTS[@]}" -currentHost delete -globalDomain \
                    "${STATUS_PADDING_KEY}" >/dev/null 2>&1 || true
            fi

            if [[ "${SPOTLIGHT_POSITION_PRESENT}" -eq 1 ]]; then
                "${USER_DEFAULTS[@]}" write "${SPOTLIGHT_DOMAIN}" \
                    "${SPOTLIGHT_POSITION_KEY}" -int \
                    "${SPOTLIGHT_POSITION_PREVIOUS}" >/dev/null
            else
                "${USER_DEFAULTS[@]}" delete "${SPOTLIGHT_DOMAIN}" \
                    "${SPOTLIGHT_POSITION_KEY}" >/dev/null 2>&1 || true
            fi

            if [[ "${CLOCK_POSITION_PRESENT}" -eq 1 ]]; then
                "${USER_DEFAULTS[@]}" write "${CLOCK_DOMAIN}" \
                    "${CLOCK_POSITION_KEY}" -int \
                    "${CLOCK_POSITION_PREVIOUS}" >/dev/null
            else
                "${USER_DEFAULTS[@]}" delete "${CLOCK_DOMAIN}" \
                    "${CLOCK_POSITION_KEY}" >/dev/null 2>&1 || true
            fi
        fi

        for NAME in "${INSTALLED_NAMES[@]}"; do
            /bin/rm -f "${TWEAK_DIR}/${NAME}"
        done

        for NAME in "${MOVED_NAMES[@]}"; do
            SAVED="${BACKUP_DIR}/${NAME}"
            if [[ -e "${SAVED}" ]]; then
                /bin/mv -f "${SAVED}" "${TWEAK_DIR}/${NAME}"
            fi
        done

        echo "Installation failed and the previous state was restored. / La instalación falló y se restauró el estado anterior." >&2
    fi

    exit "${STATUS}"
}

trap rollback_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for NAME in "${MANAGED_NAMES[@]}"; do
    LIVE_PATH="${TWEAK_DIR}/${NAME}"

    if [[ -e "${LIVE_PATH}" ]]; then
        MOVED_NAMES[${#MOVED_NAMES[@]}]="${NAME}"
        /bin/mv "${LIVE_PATH}" "${BACKUP_DIR}/${NAME}"
        BACKUP_COUNT=$((BACKUP_COUNT + 1))
    fi
done

# Los filtros se hacen visibles primero y las dylibs firmadas al final.
INSTALLED_NAMES[${#INSTALLED_NAMES[@]}]="${UNIFIED_NAME}.blacklist"
/bin/mv \
    "${STAGE_DIR}/${UNIFIED_NAME}.blacklist" \
    "${TWEAK_DIR}/${UNIFIED_NAME}.blacklist"

INSTALLED_NAMES[${#INSTALLED_NAMES[@]}]="${BLUE_NAME}.blacklist"
/bin/mv \
    "${STAGE_DIR}/${BLUE_NAME}.blacklist" \
    "${TWEAK_DIR}/${BLUE_NAME}.blacklist"

INSTALLED_NAMES[${#INSTALLED_NAMES[@]}]="${BLUE_NAME}"
/bin/mv \
    "${STAGE_DIR}/${BLUE_NAME}" \
    "${TWEAK_DIR}/${BLUE_NAME}"

INSTALLED_NAMES[${#INSTALLED_NAMES[@]}]="${UNIFIED_NAME}"
/bin/mv \
    "${STAGE_DIR}/${UNIFIED_NAME}" \
    "${TWEAK_DIR}/${UNIFIED_NAME}"

/bin/rmdir "${STAGE_DIR}"

/usr/bin/codesign \
    --verify \
    --strict \
    "${TWEAK_DIR}/${UNIFIED_NAME}"

/usr/bin/codesign \
    --verify \
    --strict \
    "${TWEAK_DIR}/${BLUE_NAME}"

LIVE_ARCHS="$(/usr/bin/lipo -archs "${TWEAK_DIR}/${UNIFIED_NAME}")"
LIVE_BLUE_ARCHS="$(/usr/bin/lipo -archs "${TWEAK_DIR}/${BLUE_NAME}")"

sl_require_universal_architectures "${TWEAK_DIR}/${UNIFIED_NAME}" "installed unified dylib" >/dev/null

sl_require_universal_architectures "${TWEAK_DIR}/${BLUE_NAME}" "installed BlueSelection" >/dev/null

for OLD_NAME in "${SL_LEGACY_DYLIBS[@]}"; do
    if [[ -e "${TWEAK_DIR}/${OLD_NAME}" ]]; then
        echo "ERROR: old dylib ${OLD_NAME} remained installed. / permaneció instalada la dylib antigua ${OLD_NAME}." >&2
        exit 1
    fi
done

PREFERENCES_CHANGED=1
"${USER_DEFAULTS[@]}" -currentHost write -globalDomain \
    "${STATUS_SPACING_KEY}" -int "${SNOW_LEOPARD_STATUS_SPACING}"
"${USER_DEFAULTS[@]}" -currentHost write -globalDomain \
    "${STATUS_PADDING_KEY}" -int "${SNOW_LEOPARD_STATUS_PADDING}"
"${USER_DEFAULTS[@]}" write "${SPOTLIGHT_DOMAIN}" \
    "${SPOTLIGHT_POSITION_KEY}" -int "${SPOTLIGHT_EXTREME_RIGHT_POSITION}"
"${USER_DEFAULTS[@]}" write "${CLOCK_DOMAIN}" \
    "${CLOCK_POSITION_KEY}" -int "${CLOCK_LEFT_OF_SPOTLIGHT_POSITION}"

COMMIT_COMPLETE=1
trap - EXIT HUP INT TERM

/usr/bin/killall Finder >/dev/null 2>&1 || true
/usr/bin/killall 'System Settings' >/dev/null 2>&1 || true
/usr/bin/killall Spotlight >/dev/null 2>&1 || true
/usr/bin/killall ControlCenter >/dev/null 2>&1 || true
/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true

echo
echo "======================================================"
echo "UNIFIED MENU BAR INSTALLED / MENÚ BAR UNIFICADA INSTALADA"
echo "======================================================"
echo
echo "Installed runtime / Runtime instalado:"
echo "  ${TWEAK_DIR}/${UNIFIED_NAME} (${LIVE_ARCHS})"
echo "  ${TWEAK_DIR}/${BLUE_NAME} (${LIVE_BLUE_ARCHS})"
echo "  ${TWEAK_DIR}/${UNIFIED_NAME}.blacklist"
echo "  ${TWEAK_DIR}/${BLUE_NAME}.blacklist"
echo
echo "Selection ownership: Unified=top-menu/status; BlueSelection=popup/context/Dock/sidebar. / Responsabilidad: Unified=menú superior/status; BlueSelection=popup/contexto/Dock/sidebar."
echo "Persisted layout: spacing=${SNOW_LEOPARD_STATUS_SPACING}, padding=${SNOW_LEOPARD_STATUS_PADDING}, Spotlight=${SPOTLIGHT_EXTREME_RIGHT_POSITION}, Clock=${CLOCK_LEFT_OF_SPOTLIGHT_POSITION}. / Layout persistido: spacing=${SNOW_LEOPARD_STATUS_SPACING}, padding=${SNOW_LEOPARD_STATUS_PADDING}, Spotlight=${SPOTLIGHT_EXTREME_RIGHT_POSITION}, Clock=${CLOCK_LEFT_OF_SPOTLIGHT_POSITION}."
echo "Legacy competing dylibs removed/backed up when present: ${#SL_LEGACY_DYLIBS[@]}. / Dylibs legacy competidoras retiradas/respaldadas cuando existían: ${#SL_LEGACY_DYLIBS[@]}."
echo "Previous files backed up / Archivos anteriores respaldados: ${BACKUP_COUNT}"
echo "Transactional backup / Respaldo transaccional: ${BACKUP_DIR}"
echo "Previous preferences / Preferencias anteriores: ${TRANSACTION_DIR}/status-item-spacing-before.txt"
echo "Previous ordering / Orden anterior: ${TRANSACTION_DIR}/status-item-order-before.txt"
echo
echo "Artwork is embedded in the Unified dylib; no runtime image folder was installed. / El artwork está embebido en la dylib Unified; no se instaló una carpeta de imágenes de runtime."
echo "Unrelated tweaks were not modified. / No se modificaron tweaks ajenos al proyecto."
echo "Reopen affected apps; log out/in to reload all injected system processes. / Reabre las apps afectadas; cierra/inicia sesión para recargar todos los procesos del sistema inyectados."
echo "Debug log (only when enabled) / Log de diagnóstico (sólo si se habilita): ${SL_DEBUG_LOG}"
