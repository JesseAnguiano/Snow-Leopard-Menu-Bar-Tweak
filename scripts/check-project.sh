#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

required=(
    ".editorconfig"
    "README.md"
    "CONTRIBUTING.md"
    "SECURITY.md"
    "LICENSE"
    "Install.command"
    "Build-Package.command"
    "Uninstall.command"
    "src/README.md"
    "src/common/Runtime.m"
    "src/common/SelectionRenderer.m"
    "src/include/Runtime.h"
    "src/include/SelectionRenderer.h"
    "src/include/StatusSelectionIPC.h"
    "src/include/ColorTransfer.h"
    "src/include/Performance.h"
    "src/include/Protocol.h"
    "src/include/WallpaperWire.h"
    "src/menubar/MenuBar.m"
    "src/menubar/rendering/DirectWallpaper.inc"
    "src/menubar/rendering/LowerShadow.inc"
    "src/menus/MenuPopup.m"
    "src/status/SystemStatusItems.m"
    "src/status/ExternalStatusItems.m"
    "src/status/StatusIcons.m"
    "src/status/StatusSelectionIPC.m"
    "src/selection/MenuSelection.m"
    "src/selection/SidebarSelection.m"
    "src/wallpaper/WallpaperSource.m"
    "src/wallpaper/Info.plist"
    "src/wallpaper/LaunchAgent.plist"
    "assets/manifest.json"
    "scripts/audit-repository.py"
    "scripts/generate-embedded-assets.py"
    "scripts/markers.sh"
    "scripts/project-config.sh"
    "scripts/toolchain.sh"
    "scripts/build-package.sh"
    "packaging/scripts/postinstall"
    "packaging/README.md"
    "tools/diagnostics/README.md"
    "tools/diagnostics/InspectSwiftUIClasses.m"
    "tools/diagnostics/inspect-swiftui-classes.sh"
    "libSnowLeopardMenuBarUnified.dylib.blacklist"
    "libSnowLeopardBlueSelection.dylib.blacklist"
    "docs/README.md"
    "docs/en/ARCHITECTURE.md"
    "docs/en/DEVELOPMENT.md"
    "docs/en/INSTALLATION.md"
    "docs/en/ASSETS.md"
    "docs/en/PUBLISHING.md"
    "docs/es/ARCHITECTURE.md"
    "docs/es/DEVELOPMENT.md"
    "docs/es/INSTALLATION.md"
    "docs/es/ASSETS.md"
    "docs/es/PUBLISHING.md"
    "docs/es/LICENSE.md"
)

for rel in "${required[@]}"; do
    [[ -f "${ROOT}/${rel}" && ! -L "${ROOT}/${rel}" ]] || {
        echo "ERROR: missing or invalid / ausente o inválido: ${rel}" >&2
        exit 1
    }
done

# Paths removed from the release tree should stay removed. Historical experiments
# belong in Git history, not beside production regression tests.
stale=(
    filters helper resources src/rendering INSTALLATION.md LICENSE.es.md
    tests/calibrate-v14.py tests/material-reference-fit-v8-historical.py
    tests/verify-v14-render.py tests/InspectSwiftUIClasses.m
    tests/inspect-swiftui-classes.sh
)
for rel in "${stale[@]}"; do
    if [[ -e "${ROOT}/${rel}" || -L "${ROOT}/${rel}" ]]; then
        echo "ERROR: stale repository path returned / volvió una ruta antigua: ${rel}" >&2
        exit 1
    fi
done

# Finder/archive metadata is harmless locally but should never block installation
# or reach GitHub.
if find "${ROOT}" -path "${ROOT}/.git" -prune -o \
    \( -name '.DS_Store' -o -name '._*' -o -name '.AppleDouble' -o \
       -name '.LSOverride' -o -name '__MACOSX' \) -print -quit | grep -q .; then
    echo "Cleaning local Finder/archive metadata... / Limpiando metadata local de Finder/archivos..."
    find "${ROOT}" -path "${ROOT}/.git" -prune -o \
        \( -type f -o -type l \) \
        \( -name '.DS_Store' -o -name '._*' -o -name '.AppleDouble' -o -name '.LSOverride' \) \
        -exec rm -f -- {} \;
    find "${ROOT}" -path "${ROOT}/.git" -prune -o -type d \
        \( -name '__MACOSX' -o -name '.AppleDouble' \) -prune \
        -exec rm -rf -- {} \;
fi

while IFS= read -r -d '' script; do
    /bin/bash -n "${script}"
done < <(find "${ROOT}" -type f \
    \( -name '*.sh' -o -name '*.command' \) \
    -not -path '*/.git/*' -not -path '*/build/*' -not -path '*/dist/*' -print0)

PLUTIL="$(command -v plutil || true)"
[[ -n "${PLUTIL}" ]] || {
    echo "ERROR: plutil is required. / se requiere plutil." >&2
    exit 1
}
"${PLUTIL}" -lint "${ROOT}/src/wallpaper/Info.plist" >/dev/null
"${PLUTIL}" -lint "${ROOT}/src/wallpaper/LaunchAgent.plist" >/dev/null

# Build output is allowed only in ignored build/dist directories.
if find "${ROOT}" -path "${ROOT}/build" -prune -o -path "${ROOT}/dist" -prune -o \
    \( -name '*.dylib' -o -name '*.app' -o -name '*.o' -o -name '*.pkg' \) -print | grep -q .; then
    echo "ERROR: compiled products are present in the source tree. / hay productos compilados dentro del source." >&2
    exit 1
fi
if find "${ROOT}" -path "${ROOT}/build" -prune -o \
    -name 'SnowLeopardEmbeddedAssets.h' -print | grep -q .; then
    echo "ERROR: generated embedded-asset header is present outside build/. / el header generado de assets existe fuera de build/." >&2
    exit 1
fi

if grep -RInE --exclude-dir=.git --exclude-dir=build --exclude-dir=dist \
    'SnowLeopardShared|generate-embedded-icons\.py|SnowLeopardEmbeddedStatusIcons\.h|Lucida ?Grande' \
    "${ROOT}/src" "${ROOT}/docs" >/dev/null; then
    echo "ERROR: stale architecture/typography references remain. / quedan referencias antiguas de arquitectura/tipografía." >&2
    exit 1
fi

if ! grep -Fq 'com.snowleopardmenubar.wallpapersource' "${ROOT}/src/wallpaper/Info.plist" ||
   ! grep -Fq 'com.snowleopardmenubar.wallpapersource' "${ROOT}/src/wallpaper/LaunchAgent.plist"; then
    echo "ERROR: wallpaper helper distribution identifier is missing. / falta el identificador público del helper de wallpaper." >&2
    exit 1
fi

if find "${ROOT}/packaging" \( -name '*.dylib' -o -name '*.app' -o -name '*.pkg' \) -print | grep -q .; then
    echo "ERROR: compiled artifacts exist under packaging/. / hay artefactos compilados dentro de packaging/." >&2
    exit 1
fi
if ! grep -Fq -- '--nopayload' "${ROOT}/scripts/build-package.sh" ||
   ! grep -Fq 'project-config.sh' "${ROOT}/scripts/build-package.sh" ||
   ! grep -Fq 'SnowLeopardWallpaperSource.app' "${ROOT}/packaging/scripts/postinstall"; then
    echo "ERROR: PKG builder/install template is incomplete. / el builder/template del PKG está incompleto." >&2
    exit 1
fi

for blacklist in \
    "${ROOT}/libSnowLeopardMenuBarUnified.dylib.blacklist" \
    "${ROOT}/libSnowLeopardBlueSelection.dylib.blacklist"; do
    duplicates="$(LC_ALL=C sort "${blacklist}" | uniq -d)"
    if [[ -n "${duplicates}" ]]; then
        echo "ERROR: duplicate blacklist entries in ${blacklist##*/}: ${duplicates}" >&2
        exit 1
    fi
done

if ! grep -Fq '#define SLLog(...)' "${ROOT}/src/include/Runtime.h"; then
    echo "ERROR: SLLog must remain variadic. / SLLog debe seguir siendo variádico." >&2
    exit 1
fi
if ! grep -Fq '#define SL_CAPABILITY_EXPORT __attribute__((used, visibility("default")))' "${ROOT}/src/include/Runtime.h"; then
    echo "ERROR: capability markers must survive linker dead stripping. / los marcadores de capacidad deben sobrevivir dead_strip." >&2
    exit 1
fi
for capability_source in \
    "${ROOT}/src/selection/MenuSelection.m" \
    "${ROOT}/src/selection/SidebarSelection.m" \
    "${ROOT}/src/menubar/MenuBar.m" \
    "${ROOT}/src/menus/MenuPopup.m" \
    "${ROOT}/src/status/SystemStatusItems.m" \
    "${ROOT}/src/status/ExternalStatusItems.m" \
    "${ROOT}/src/status/StatusIcons.m"; do
    if ! grep -Eq 'const char [A-Za-z0-9_]+\[\] SL_CAPABILITY_EXPORT =' "${capability_source}"; then
        echo "ERROR: capability marker is not exported in ${capability_source#${ROOT}/}. / el marcador de capacidad no está exportado." >&2
        exit 1
    fi
done
if grep -RInE '\bAppendLog\(' "${ROOT}/src" >/dev/null; then
    echo "ERROR: legacy AppendLog calls remain; use SLLog. / quedan llamadas AppendLog antiguas; usa SLLog." >&2
    exit 1
fi

PYTHON3="$(command -v python3 || true)"
[[ -n "${PYTHON3}" ]] || {
    echo "ERROR: Python 3 is required for repository checks. / se requiere Python 3 para las comprobaciones." >&2
    exit 1
}
    CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sl-project-check.XXXXXX")"
    trap 'rm -rf "${CHECK_TMP}"' EXIT

    PYTHONPYCACHEPREFIX="${CHECK_TMP}/pycache" "${PYTHON3}" - "${ROOT}" <<'PYCODE'
import py_compile
from pathlib import Path
import sys

root = Path(sys.argv[1])
for base in (root / "scripts", root / "tests", root / "tools"):
    for path in base.rglob("*.py"):
        py_compile.compile(str(path), doraise=True)
PYCODE

    "${PYTHON3}" - "${ROOT}" <<'PYCODE'
import re
from pathlib import Path
import sys

root = Path(sys.argv[1])
project_headers = "\n".join(
    path.read_text(errors="replace")
    for path in (root / "src" / "include").rglob("*.h")
)
for source in (root / "src").rglob("*.m"):
    text = source.read_text(errors="replace")
    aliases = set(re.findall(r"\b[A-Z][A-Za-z0-9_]*Fn\b", text))
    for alias in sorted(aliases):
        local_typedef = re.search(rf"typedef[^;]*\b{re.escape(alias)}\b\s*\)", text, re.S)
        header_typedef = re.search(rf"typedef[^;]*\b{re.escape(alias)}\b\s*\)", project_headers, re.S)
        if not local_typedef and not header_typedef:
            raise SystemExit(f"{source.relative_to(root)} uses {alias} without a visible project typedef")
PYCODE

    "${PYTHON3}" - "${ROOT}" <<'PYCODE'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
assets = root / "assets"
payload = json.loads((assets / "manifest.json").read_text())
entries = payload.get("assets", [])
manifest_paths = {entry["path"] for entry in entries}
canonical_paths = {
    str(path.relative_to(assets))
    for folder in (assets / "status-icons", assets / "apple-menu")
    for path in folder.rglob("*")
    if path.is_file()
}
if payload.get("version") != 1 or len(entries) != 63:
    raise SystemExit(f"assets/manifest.json must contain exactly 63 version-1 assets; found {len(entries)}")
if len(manifest_paths) != len(entries):
    raise SystemExit("assets/manifest.json contains duplicate paths")
if manifest_paths != canonical_paths:
    missing = sorted(canonical_paths - manifest_paths)
    extra = sorted(manifest_paths - canonical_paths)
    raise SystemExit(f"embedded asset manifest mismatch; missing={missing} extra={extra}")
PYCODE

    TMP_HEADER="${CHECK_TMP}/SnowLeopardEmbeddedAssets.h"
    "${PYTHON3}" "${ROOT}/scripts/generate-embedded-assets.py" \
        "${ROOT}/assets/manifest.json" "${ROOT}/assets" "${TMP_HEADER}"
    grep -Fq 'SLEmbeddedAssetCount' "${TMP_HEADER}" || {
        echo "ERROR: embedded asset generator validation failed. / falló la validación del generador de assets." >&2
        exit 1
    }

    "${PYTHON3}" "${ROOT}/scripts/audit-repository.py" "${ROOT}"

    rm -rf "${CHECK_TMP}"
    trap - EXIT

echo "Project structure checks passed. / Las comprobaciones de estructura pasaron correctamente."
