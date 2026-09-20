#!/bin/bash
# Snow Leopard Menu Bar Tweak — standalone uninstaller
# Desinstalador independiente
set -euo pipefail

LABEL="com.snowleopardmenubar.wallpapersource"

SUPPORT_DIR="${HOME}/Library/Application Support/SnowLeopardMenuBar"
APP="${SUPPORT_DIR}/SnowLeopardWallpaperSource.app"

AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST="${AGENTS_DIR}/${LABEL}.plist"

TWEAK_DIR="/private/var/ammonia/core/tweaks"

UNIFIED="libSnowLeopardMenuBarUnified.dylib"
BLUE="libSnowLeopardBlueSelection.dylib"

STATUS_SPACING_KEY="NSStatusItemSpacing"
STATUS_PADDING_KEY="NSStatusItemSelectionPadding"

SPOTLIGHT_DOMAIN="com.apple.Spotlight"
SPOTLIGHT_POSITION_KEY="NSStatusItem Preferred Position Item-0"

CLOCK_DOMAIN="com.apple.controlcenter"
CLOCK_POSITION_KEY="NSStatusItem Preferred Position Clock"

CURRENT_UID="$(/usr/bin/id -u)"
CURRENT_GID="$(/usr/bin/id -g)"

if [[ "${EUID}" -eq 0 ]]; then
    echo
    echo "ERROR: run this uninstaller as your normal macOS user, not with sudo."
    echo "ERROR: ejecuta este desinstalador como tu usuario normal de macOS, no con sudo."
    echo
    exit 1
fi

cat <<'TXT'

============================================================
 Snow Leopard Menu Bar Tweak
 Uninstaller / Desinstalador
============================================================

This removes the Snow Leopard Menu Bar Tweak runtime files,
wallpaper helper and menu-bar preferences installed by the tweak.

Esto elimina los archivos de ejecución del tweak,
el helper de wallpaper y las preferencias de la barra instaladas
por Snow Leopard Menu Bar Tweak.

Ammonia itself will NOT be removed.
Ammonia NO será eliminado.

TXT

read -r -p "Uninstall? [y/N] / ¿Desinstalar? [s/N]: " answer

case "${answer}" in
    y|Y|yes|YES|s|S|si|SI|sí|Sí)
        ;;
    *)
        echo
        echo "Cancelled. / Cancelado."
        exit 0
        ;;
esac

echo
echo "Administrator authentication may be required."
echo "Puede ser necesaria la contraseña de administrador."
echo

/usr/bin/sudo -v

DOMAIN="gui/${CURRENT_UID}"

echo
echo "[1/5] Stopping wallpaper helper..."
echo "      Deteniendo helper de wallpaper..."

if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    /bin/launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
fi

/usr/bin/pkill \
    -u "${CURRENT_UID}" \
    -x SnowLeopardWallpaperSource \
    >/dev/null 2>&1 || true

echo
echo "[2/5] Removing LaunchAgent and helper..."
echo "      Eliminando LaunchAgent y helper..."

if [[ -L "${AGENTS_DIR}" ]]; then
    echo
    echo "ERROR: ${AGENTS_DIR} is a symbolic link."
    echo "ERROR: ${AGENTS_DIR} es un enlace simbólico."
    exit 1
fi

if [[ -d "${AGENTS_DIR}" ]]; then
    AGENTS_OWNER_UID="$(
        /usr/bin/stat -f '%u' "${AGENTS_DIR}" 2>/dev/null || true
    )"

    if [[ "${AGENTS_OWNER_UID}" == "0" ]]; then
        echo "Repairing LaunchAgents ownership..."
        echo "Corrigiendo propietario de LaunchAgents..."

        /usr/bin/sudo /usr/sbin/chown \
            "${CURRENT_UID}:${CURRENT_GID}" \
            "${AGENTS_DIR}"
    elif [[ -n "${AGENTS_OWNER_UID}" &&
            "${AGENTS_OWNER_UID}" != "${CURRENT_UID}" ]]; then
        echo
        echo "ERROR: ${AGENTS_DIR} belongs to another user."
        echo "ERROR: ${AGENTS_DIR} pertenece a otro usuario."
        exit 1
    fi
fi

if [[ -e "${PLIST}" || -L "${PLIST}" ]]; then
    if ! /bin/rm -f "${PLIST}" 2>/dev/null; then
        echo "LaunchAgent requires administrator permission."
        echo "El LaunchAgent requiere permiso de administrador."

        /usr/bin/sudo /bin/rm -f "${PLIST}"
    fi
fi

if [[ -e "${APP}" || -L "${APP}" ]]; then
    if ! /bin/rm -rf "${APP}" 2>/dev/null; then
        echo "Wallpaper helper requires administrator permission."
        echo "El helper de wallpaper requiere permiso de administrador."

        /usr/bin/sudo /bin/rm -rf "${APP}"
    fi
fi

echo
echo "[3/5] Removing Ammonia tweak files..."
echo "      Eliminando archivos del tweak de Ammonia..."

FILES_TO_REMOVE=(
    "${UNIFIED}"
    "${UNIFIED}.blacklist"
    "${UNIFIED}.whitelist"

    "${BLUE}"
    "${BLUE}.blacklist"
    "${BLUE}.whitelist"

    "libSnowLeopardMenuBarStandalone.dylib"
    "libSnowLeopardMenuBarStandalone.dylib.blacklist"
    "libSnowLeopardMenuBarStandalone.dylib.whitelist"

    "libSnowLeopardMenuBarExtras.dylib"
    "libSnowLeopardMenuBarExtras.dylib.blacklist"
    "libSnowLeopardMenuBarExtras.dylib.whitelist"

    "libSnowLeopardMenuPopupStandalone.dylib"
    "libSnowLeopardMenuPopupStandalone.dylib.blacklist"
    "libSnowLeopardMenuPopupStandalone.dylib.whitelist"

    "libSnowLeopardExternalStatusItems.dylib"
    "libSnowLeopardExternalStatusItems.dylib.blacklist"
    "libSnowLeopardExternalStatusItems.dylib.whitelist"

    "libSnowLeopardMenuSystem.dylib"
    "libSnowLeopardMenuSystem.dylib.blacklist"
    "libSnowLeopardMenuSystem.dylib.whitelist"

    "libSnowLeopardMenuTextV2.dylib"
    "libSnowLeopardMenuTextV2.dylib.blacklist"
    "libSnowLeopardMenuTextV2.dylib.whitelist"

    "libSnowLeopardStatusIcons.dylib"
    "libSnowLeopardStatusIcons.dylib.blacklist"
    "libSnowLeopardStatusIcons.dylib.whitelist"

    "libSnowLeopardMenuBar.dylib"
    "libSnowLeopardMenuBar.dylib.blacklist"
    "libSnowLeopardMenuBar.dylib.whitelist"

    "libMenuBarDrawInspector.dylib"
    "libMenuBarDrawInspector.dylib.blacklist"
    "libMenuBarDrawInspector.dylib.whitelist"

    "libMenuBarItemInspector.dylib"
    "libMenuBarItemInspector.dylib.blacklist"
    "libMenuBarItemInspector.dylib.whitelist"

    "libSnowLeopardPopupSelection.dylib"
    "libSnowLeopardPopupSelection.dylib.blacklist"
    "libSnowLeopardPopupSelection.dylib.whitelist"

    "libSnowLeopardPopupGeometry.dylib"
    "libSnowLeopardPopupGeometry.dylib.blacklist"
    "libSnowLeopardPopupGeometry.dylib.whitelist"
)

for name in "${FILES_TO_REMOVE[@]}"; do
    /usr/bin/sudo /bin/rm -f "${TWEAK_DIR}/${name}"
done

/usr/bin/sudo /bin/rm -f \
    "/private/tmp/SnowLeopardMenuBar.log" \
    >/dev/null 2>&1 || true

echo
echo "[4/5] Restoring native macOS menu-bar settings..."
echo "      Restaurando ajustes nativos de la barra de menús..."

if /usr/bin/defaults -currentHost read -globalDomain \
    "${STATUS_SPACING_KEY}" >/dev/null 2>&1; then

    /usr/bin/defaults -currentHost delete -globalDomain \
        "${STATUS_SPACING_KEY}" >/dev/null 2>&1 || true
fi

if /usr/bin/defaults -currentHost read -globalDomain \
    "${STATUS_PADDING_KEY}" >/dev/null 2>&1; then

    /usr/bin/defaults -currentHost delete -globalDomain \
        "${STATUS_PADDING_KEY}" >/dev/null 2>&1 || true
fi

if /usr/bin/defaults read \
    "${SPOTLIGHT_DOMAIN}" \
    "${SPOTLIGHT_POSITION_KEY}" >/dev/null 2>&1; then

    /usr/bin/defaults delete \
        "${SPOTLIGHT_DOMAIN}" \
        "${SPOTLIGHT_POSITION_KEY}" >/dev/null 2>&1 || true
fi

if /usr/bin/defaults read \
    "${CLOCK_DOMAIN}" \
    "${CLOCK_POSITION_KEY}" >/dev/null 2>&1; then

    /usr/bin/defaults delete \
        "${CLOCK_DOMAIN}" \
        "${CLOCK_POSITION_KEY}" >/dev/null 2>&1 || true
fi

echo
echo "[5/5] Reloading macOS UI processes..."
echo "      Recargando procesos de interfaz de macOS..."

for process in \
    Finder \
    "System Settings" \
    Spotlight \
    ControlCenter \
    SystemUIServer \
    Dock
do
    /usr/bin/killall "${process}" >/dev/null 2>&1 || true
done

echo
echo "============================================================"
echo " Uninstallation complete / Desinstalación completa"
echo "============================================================"
echo
echo "Snow Leopard Menu Bar Tweak has been removed."
echo "Snow Leopard Menu Bar Tweak ha sido eliminado."
echo
echo "Ammonia was not removed."
echo "Ammonia no fue eliminado."
echo
echo "Log out and sign back in for a complete reload."
echo "Cierra sesión y vuelve a entrar para una recarga completa."
echo
