#!/bin/bash
# Build the current source tree and package the compiled runtime for macOS Installer.
# The generated PKG does not compile anything on the destination Mac.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/project-config.sh"

BUILD_DIR="${PROJECT_ROOT}/build"
DIST_DIR="${PROJECT_ROOT}/dist"
PACKAGE_VERSION="${SL_PACKAGE_VERSION:-${SL_DEFAULT_PACKAGE_VERSION}}"
PACKAGE_OUTPUT="${DIST_DIR}/${SL_PACKAGE_BASENAME}-${PACKAGE_VERSION}.pkg"
INSTALLER_IDENTITY="${SL_INSTALLER_IDENTITY:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" && ! -L "$1" ]] || fail "missing or invalid file / archivo ausente o inválido: $1"
}

case "${PACKAGE_VERSION}" in
    ''|*[!0-9A-Za-z._-]*)
        fail "invalid package version / versión de paquete inválida: ${PACKAGE_VERSION}"
        ;;
esac

[[ -x /usr/bin/pkgbuild ]] || fail "pkgbuild is unavailable. / pkgbuild no está disponible."
require_file "${PROJECT_ROOT}/packaging/scripts/postinstall"
require_file "${PROJECT_ROOT}/src/wallpaper/LaunchAgent.plist"
require_file "${SCRIPT_DIR}/project-config.sh"

# Reuse the normal source build so direct installs and package builds contain
# the same runtime implementation.
"${SCRIPT_DIR}/check-project.sh"
"${SCRIPT_DIR}/build.sh"
"${SCRIPT_DIR}/build-wallpaper-source.sh"

UNIFIED="${BUILD_DIR}/${SL_UNIFIED_NAME}"
BLUE="${BUILD_DIR}/${SL_BLUE_NAME}"
HELPER="${BUILD_DIR}/SnowLeopardWallpaperSource.app"
UNIFIED_BLACKLIST="${PROJECT_ROOT}/${SL_UNIFIED_NAME}.blacklist"
BLUE_BLACKLIST="${PROJECT_ROOT}/${SL_BLUE_NAME}.blacklist"

for file in \
    "${UNIFIED}" \
    "${BLUE}" \
    "${UNIFIED_BLACKLIST}" \
    "${BLUE_BLACKLIST}"
do
    require_file "${file}"
done
[[ -d "${HELPER}" && ! -L "${HELPER}" ]] || fail "missing wallpaper helper build / falta el helper de wallpaper compilado."

/usr/bin/codesign --verify --strict "${UNIFIED}"
/usr/bin/codesign --verify --strict "${BLUE}"
/usr/bin/codesign --verify --deep --strict "${HELPER}"

/bin/mkdir -p "${DIST_DIR}"
STAGE="$(mktemp -d "${BUILD_DIR}/.stage-pkg.XXXXXX")"
trap '/bin/rm -rf "${STAGE}"' EXIT HUP INT TERM

PKG_SCRIPTS="${STAGE}/scripts"
PKG_FILES="${PKG_SCRIPTS}/files"
/bin/mkdir -p "${PKG_FILES}"

/usr/bin/install -m 755 "${UNIFIED}" "${PKG_FILES}/${SL_UNIFIED_NAME}"
/usr/bin/install -m 755 "${BLUE}" "${PKG_FILES}/${SL_BLUE_NAME}"
/usr/bin/install -m 644 "${UNIFIED_BLACKLIST}" "${PKG_FILES}/${SL_UNIFIED_NAME}.blacklist"
/usr/bin/install -m 644 "${BLUE_BLACKLIST}" "${PKG_FILES}/${SL_BLUE_NAME}.blacklist"
/usr/bin/install -m 644 "${PROJECT_ROOT}/src/wallpaper/LaunchAgent.plist" "${PKG_FILES}/LaunchAgent.plist"
/usr/bin/install -m 644 "${SCRIPT_DIR}/project-config.sh" "${PKG_FILES}/project-config.sh"
/usr/bin/ditto "${HELPER}" "${PKG_FILES}/SnowLeopardWallpaperSource.app"
/usr/bin/install -m 755 "${PROJECT_ROOT}/packaging/scripts/postinstall" "${PKG_SCRIPTS}/postinstall"

STAGED_PKG="${STAGE}/${SL_PACKAGE_BASENAME}-${PACKAGE_VERSION}.pkg"
PKGBUILD_ARGS=(
    --nopayload
    --scripts "${PKG_SCRIPTS}"
    --identifier "${SL_PACKAGE_IDENTIFIER}"
    --version "${PACKAGE_VERSION}"
    --install-location /
)
[[ -z "${INSTALLER_IDENTITY}" ]] || PKGBUILD_ARGS+=(--sign "${INSTALLER_IDENTITY}")
PKGBUILD_ARGS+=("${STAGED_PKG}")

/usr/bin/pkgbuild "${PKGBUILD_ARGS[@]}"
[[ -s "${STAGED_PKG}" ]] || fail "pkgbuild did not create a package. / pkgbuild no creó el paquete."
/bin/mv -f "${STAGED_PKG}" "${PACKAGE_OUTPUT}"

HASH="$(/usr/bin/shasum -a 256 "${PACKAGE_OUTPUT}" | /usr/bin/awk '{print $1}')"
printf '\nPackage built successfully. / Paquete compilado correctamente.\n'
printf 'Output / Salida: %s\nVersion / Versión: %s\nSHA-256: %s\n' \
    "${PACKAGE_OUTPUT}" "${PACKAGE_VERSION}" "${HASH}"
if [[ -n "${INSTALLER_IDENTITY}" ]]; then
    printf 'Installer signature / Firma del instalador: %s\n' "${INSTALLER_IDENTITY}"
else
    printf 'Installer signature / Firma del instalador: unsigned local package / paquete local sin firma Developer ID\n'
fi
printf '\nThe destination Mac does not need Xcode or Command Line Tools.\n'
printf 'El Mac de destino no necesita Xcode ni Command Line Tools.\n'
