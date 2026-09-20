#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

printf '\n============================================================\n'
printf ' Snow Leopard Menu Bar Tweak — PKG Builder\n'
printf ' Compilador del instalador PKG\n'
printf '============================================================\n\n'

./scripts/build-package.sh

printf '\nDone. The installable package is in dist/.\n'
printf 'Listo. El paquete instalable está en dist/.\n'
