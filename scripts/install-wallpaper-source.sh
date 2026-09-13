#!/bin/bash
# Installs only this project's wallpaper helper in the current user's session.
# No sudo, privacy changes, general clipboard, screen capture or network.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/project-config.sh"
HELPER_DIR="${PROJECT}/src/wallpaper"
BUILD_DIR="${PROJECT}/build"
case "${1:-}" in ''|--check) ;; *) echo 'Usage / Uso: install-wallpaper-source.sh [--check]' >&2; exit 2;; esac
[[ "${EUID}" -ne 0 ]] || { echo 'Run as your normal user, without sudo. / Ejecuta como tu usuario, sin sudo.' >&2; exit 1; }
USER_LIBRARY="${HOME}/Library"
ROOT="${USER_LIBRARY}/Application Support/SnowLeopardMenuBar"
AGENTS="${USER_LIBRARY}/LaunchAgents"
LABEL="${SL_WALLPAPER_LABEL}"
APP="${ROOT}/SnowLeopardWallpaperSource.app"
PLIST="${AGENTS}/${LABEL}.plist"
SOURCE="${BUILD_DIR}/SnowLeopardWallpaperSource.app"
for PATH_TO_CHECK in "${USER_LIBRARY}" "${USER_LIBRARY}/Application Support" "${ROOT}" "${ROOT}/backups" "${AGENTS}" "${APP}" "${PLIST}" "${SOURCE}"; do
    [[ ! -L "${PATH_TO_CHECK}" ]] || { echo "ERROR: symbolic link / enlace simbólico: ${PATH_TO_CHECK}" >&2; exit 1; }
done
[[ -d "${SOURCE}" ]] || { echo 'Run ./scripts/build-wallpaper-source.sh first. / Ejecuta ./scripts/build-wallpaper-source.sh primero.' >&2; exit 1; }
codesign --verify --strict "${SOURCE}"
plutil -lint "${HELPER_DIR}/LaunchAgent.plist"
if [[ "${1:-}" == --check ]]; then
    echo "Helper verified; expected destination: ${APP}. No changes. / Helper verificado; destino previsto: ${APP}. Sin cambios."
    exit 0
fi
mkdir -p "${ROOT}/backups" "${AGENTS}"
BACKUP="$(mktemp -d "${ROOT}/backups/wallpaper-source.XXXXXX")"
STAGE="$(mktemp -d "${ROOT}/.install.XXXXXX")"
ditto "${SOURCE}" "${STAGE}/SnowLeopardWallpaperSource.app"
codesign --verify --strict "${STAGE}/SnowLeopardWallpaperSource.app"
cp "${HELPER_DIR}/LaunchAgent.plist" "${STAGE}/agent.plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${APP}/Contents/MacOS/SnowLeopardWallpaperSource" "${STAGE}/agent.plist"
plutil -lint "${STAGE}/agent.plist"
DOMAIN="gui/$(id -u)"
# Migrate older development LaunchAgents without embedding a developer name
# in the public repository. Only the exact historical suffix is accepted.
LEGACY_INDEX=0
for LEGACY_PLIST in "${AGENTS}"/local.*.SnowLeopardMenuBar.WallpaperSource.plist; do
    [[ -e "${LEGACY_PLIST}" ]] || continue
    [[ ! -L "${LEGACY_PLIST}" ]] || { echo "ERROR: symbolic legacy LaunchAgent / LaunchAgent antiguo simbólico: ${LEGACY_PLIST}" >&2; exit 1; }
    LEGACY_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "${LEGACY_PLIST}" 2>/dev/null || true)"
    case "${LEGACY_LABEL}" in
        local.*.SnowLeopardMenuBar.WallpaperSource) ;;
        *) continue ;;
    esac
    if launchctl print "${DOMAIN}/${LEGACY_LABEL}" >/dev/null 2>&1; then
        launchctl bootout "${DOMAIN}/${LEGACY_LABEL}" || true
    fi
    LEGACY_INDEX=$((LEGACY_INDEX + 1))
    mv "${LEGACY_PLIST}" "${BACKUP}/legacy-agent-${LEGACY_INDEX}.plist"
done
if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "${DOMAIN}/${LABEL}"
fi
[[ ! -e "${APP}" ]] || mv "${APP}" "${BACKUP}/SnowLeopardWallpaperSource.app"
[[ ! -e "${PLIST}" ]] || mv "${PLIST}" "${BACKUP}/agent.plist"
mv "${STAGE}/SnowLeopardWallpaperSource.app" "${APP}"
mv "${STAGE}/agent.plist" "${PLIST}"
chmod 644 "${PLIST}"
rmdir "${STAGE}"
if ! launchctl bootstrap "${DOMAIN}" "${PLIST}"; then
    # Keep failed artifacts recoverable; restore only our previous helper.
    mv "${APP}" "${BACKUP}/failed-helper.app"
    mv "${PLIST}" "${BACKUP}/failed-agent.plist"
    [[ ! -e "${BACKUP}/SnowLeopardWallpaperSource.app" ]] || mv "${BACKUP}/SnowLeopardWallpaperSource.app" "${APP}"
    if [[ -e "${BACKUP}/agent.plist" ]]; then
        mv "${BACKUP}/agent.plist" "${PLIST}"
        launchctl bootstrap "${DOMAIN}" "${PLIST}" || true
    fi
    echo "ERROR: helper did not start. Backups and diagnostics: ${BACKUP} / el helper no arrancó. Respaldos y diagnóstico: ${BACKUP}" >&2
    exit 1
fi
launchctl print "${DOMAIN}/${LABEL}"
echo "Helper registered. Backup: ${BACKUP}. This does not yet confirm Safari pixels. / Helper registrado. Respaldo: ${BACKUP}. Esto no confirma aún los píxeles de Safari."
