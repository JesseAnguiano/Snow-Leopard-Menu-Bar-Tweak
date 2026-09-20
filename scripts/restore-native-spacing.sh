#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/project-config.sh"

/usr/bin/defaults -currentHost delete -globalDomain \
    "${SL_STATUS_SPACING_KEY}" >/dev/null 2>&1 || true
/usr/bin/defaults -currentHost delete -globalDomain \
    "${SL_STATUS_PADDING_KEY}" >/dev/null 2>&1 || true
/usr/bin/defaults delete "${SL_SPOTLIGHT_DOMAIN}" \
    "${SL_SPOTLIGHT_POSITION_KEY}" >/dev/null 2>&1 || true
/usr/bin/defaults delete "${SL_CLOCK_DOMAIN}" \
    "${SL_CLOCK_POSITION_KEY}" >/dev/null 2>&1 || true

/usr/bin/killall Spotlight >/dev/null 2>&1 || true
/usr/bin/killall ControlCenter >/dev/null 2>&1 || true
/usr/bin/killall SystemUIServer >/dev/null 2>&1 || true

echo "Native macOS spacing and ordering restored. / Separación y orden nativos de macOS restaurados."
echo "Log out and back in to reload all items. / Cierra sesión y vuelve a entrar para recargar todos los elementos."
