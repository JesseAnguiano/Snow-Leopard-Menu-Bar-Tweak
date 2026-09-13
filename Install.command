#!/bin/bash
# Snow Leopard Menu Bar Tweak — guided installer / instalador guiado
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
source "${PROJECT_ROOT}/scripts/project-config.sh"
INSTALL_COMPLETE=0
INSTALL_CANCELLED=0

pause_before_exit() {
    local status="$?"
    echo
    if [[ "${INSTALL_CANCELLED}" -eq 1 ]]; then
        echo "Installation cancelled. / Instalación cancelada."
    elif [[ "${status}" -eq 0 && "${INSTALL_COMPLETE}" -eq 1 ]]; then
        echo "Installation completed successfully. / Instalación completada correctamente."
    elif [[ "${status}" -ne 0 ]]; then
        echo "Installation stopped with an error. / La instalación se detuvo por un error."
    fi
    echo
    read -r -p "Press Return to close this window. / Pulsa Return para cerrar esta ventana. " _ || true
    exit "${status}"
}
trap pause_before_exit EXIT

if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: open this installer as your normal macOS user, not with sudo."
    echo "ERROR: abre este instalador como tu usuario normal de macOS, no con sudo."
    exit 1
fi

sl_require_supported_macos

if [[ ! -d "${SL_TWEAK_DIR}" ]]; then
    echo "ERROR: Ammonia does not appear to be installed at ${SL_TWEAK_DIR}."
    echo "ERROR: Ammonia no parece estar instalado en ${SL_TWEAK_DIR}."
    exit 1
fi

cat <<'TXT'
============================================================
 Snow Leopard Menu Bar Tweak
 Guided installer / Instalador guiado
============================================================

This installer will / Este instalador va a:

  1. Check the repository / Comprobar el repositorio
  2. Build both tweak dylibs / Compilar ambas dylibs
  3. Build and install the wallpaper helper / Compilar e instalar el helper
  4. Install both Ammonia dylibs and both .blacklist files
     Instalar ambas dylibs de Ammonia y ambos archivos .blacklist
  5. Verify the installed files / Verificar los archivos instalados

Runtime destinations / Destinos finales:

  /private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib
  /private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib.blacklist
  /private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib
  /private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib.blacklist

  ~/Library/Application Support/SnowLeopardMenuBar/SnowLeopardWallpaperSource.app
  ~/Library/LaunchAgents/com.snowleopardmenubar.wallpapersource.plist

Administrator authentication is required only for the Ammonia files.
La contraseña de administrador sólo se necesita para los archivos de Ammonia.
TXT

echo
read -r -p "Continue? [y/N] / ¿Continuar? [s/N]: " answer
case "${answer}" in
    y|Y|yes|YES|s|S|si|SI|sí|Sí) ;;
    *)
        INSTALL_CANCELLED=1
        exit 0
        ;;
esac

cd "${PROJECT_ROOT}"

echo
echo "[1/6] Checking project / Comprobando proyecto..."
"${PROJECT_ROOT}/scripts/check-project.sh"

echo
echo "[2/6] Building tweak dylibs / Compilando dylibs del tweak..."
"${PROJECT_ROOT}/scripts/build.sh"

echo
echo "[3/6] Building wallpaper helper / Compilando helper de wallpaper..."
"${PROJECT_ROOT}/scripts/build-wallpaper-source.sh"

echo
echo "[4/6] Installing wallpaper helper / Instalando helper de wallpaper..."
"${PROJECT_ROOT}/scripts/install-wallpaper-source.sh"

echo
echo "[5/6] Installing Ammonia files / Instalando archivos de Ammonia..."
"${PROJECT_ROOT}/scripts/install.sh"

echo
echo "[6/6] Verifying installation / Verificando instalación..."
"${PROJECT_ROOT}/scripts/verify.sh"
"${PROJECT_ROOT}/scripts/verify-blueselection.sh"

cat <<'TXT'

============================================================
 Installation complete / Instalación completa
============================================================

The tweak, blacklists and wallpaper helper are installed.
El tweak, las blacklists y el helper de wallpaper están instalados.

For the cleanest reload, log out and sign back in.
Para una recarga completa, cierra sesión y vuelve a iniciarla.
TXT
INSTALL_COMPLETE=1
