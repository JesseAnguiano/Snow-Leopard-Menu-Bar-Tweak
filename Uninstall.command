#!/bin/bash
# Snow Leopard Menu Bar Tweak — uninstaller / desinstalador
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
source "${PROJECT_ROOT}/scripts/project-config.sh"
LABEL="${SL_WALLPAPER_LABEL}"
APP="${HOME}/Library/Application Support/SnowLeopardMenuBar/SnowLeopardWallpaperSource.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
TWEAK_DIR="${SL_TWEAK_DIR}"

pause_before_exit() {
    local status="$?"
    echo
    read -r -p "Press Return to close this window. / Pulsa Return para cerrar esta ventana. " _ || true
    exit "${status}"
}
trap pause_before_exit EXIT

if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: open this uninstaller as your normal macOS user, not with sudo."
    echo "ERROR: abre este desinstalador como tu usuario normal de macOS, no con sudo."
    exit 1
fi

cat <<'TXT'
This removes the Snow Leopard Menu Bar Tweak runtime files installed by this project.
Esto elimina los archivos de ejecución de Snow Leopard Menu Bar Tweak instalados por este proyecto.

It does not delete the repository or Ammonia itself.
No elimina el repositorio ni Ammonia.
TXT

echo
read -r -p "Uninstall? [y/N] / ¿Desinstalar? [s/N]: " answer
case "${answer}" in
    y|Y|yes|YES|s|S|si|SI|sí|Sí) ;;
    *) echo "Cancelled. / Cancelado."; exit 0 ;;
esac

DOMAIN="gui/$(/usr/bin/id -u)"
if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    /bin/launchctl bootout "${DOMAIN}/${LABEL}" || true
fi

/bin/rm -f "${PLIST}"
/bin/rm -rf "${APP}"

/usr/bin/sudo /bin/rm -f \
    "${TWEAK_DIR}/${SL_UNIFIED_NAME}" \
    "${TWEAK_DIR}/${SL_UNIFIED_NAME}.blacklist" \
    "${TWEAK_DIR}/${SL_BLUE_NAME}" \
    "${TWEAK_DIR}/${SL_BLUE_NAME}.blacklist"

"${PROJECT_ROOT}/scripts/restore-native-spacing.sh"

/usr/bin/killall Finder >/dev/null 2>&1 || true
/usr/bin/killall 'System Settings' >/dev/null 2>&1 || true
/usr/bin/killall Spotlight >/dev/null 2>&1 || true
/usr/bin/killall ControlCenter >/dev/null 2>&1 || true
/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true

echo
echo "Uninstallation complete. / Desinstalación completa."
echo "Log out and sign back in for a full reload. / Cierra sesión y vuelve a entrar para una recarga completa."
