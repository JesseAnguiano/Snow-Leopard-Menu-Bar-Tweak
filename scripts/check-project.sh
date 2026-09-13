#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

required=(
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
    "src/menus/MenuPopup.m"
    "src/status/SystemStatusItems.m"
    "src/status/ExternalStatusItems.m"
    "src/status/StatusIcons.m"
    "src/status/StatusSelectionIPC.m"
    "src/selection/MenuSelection.m"
    "src/selection/SidebarSelection.m"
    "src/menubar/rendering/DirectWallpaper.inc"
    "src/menubar/rendering/LowerShadow.inc"
    "assets/manifest.json"
    "scripts/generate-embedded-assets.py"
    "scripts/markers.sh"
    "scripts/project-config.sh"
    "scripts/build-package.sh"
    "packaging/scripts/postinstall"
    "packaging/README.md"
    "src/wallpaper/WallpaperSource.m"
    "src/wallpaper/Info.plist"
    "src/wallpaper/LaunchAgent.plist"
    "libSnowLeopardMenuBarUnified.dylib.blacklist"
    "libSnowLeopardBlueSelection.dylib.blacklist"
    "docs/README.md"
    "docs/en/INSTALLATION.md"
    "docs/en/ASSETS.md"
    "docs/es/INSTALLATION.md"
    "docs/es/ASSETS.md"
    "docs/es/LICENSE.md"
)

for rel in "${required[@]}"; do
    [[ -f "${ROOT}/${rel}" && ! -L "${ROOT}/${rel}" ]] || {
        echo "ERROR: missing or invalid / ausente o inválido: ${rel}" >&2
        exit 1
    }
done

# Keep the public tree compact. These legacy directories/files were folded into
# the current layout and should not reappear.
for stale in filters helper resources src/rendering INSTALLATION.md LICENSE.es.md; do
    if [[ -e "${ROOT}/${stale}" || -L "${ROOT}/${stale}" ]]; then
        echo "ERROR: stale repository path returned / volvió una ruta antigua: ${stale}" >&2
        exit 1
    fi
done
if find "${ROOT}" -path "${ROOT}/.git" -prune -o \
    \( -name '.DS_Store' -o -name '__MACOSX' \) -print | grep -q .; then
    echo "ERROR: local archive/Finder metadata is present. / hay metadata local de Finder/archivos en el repositorio." >&2
    exit 1
fi

for script in "${ROOT}"/scripts/*.sh "${ROOT}"/tests/*.sh "${ROOT}"/packaging/scripts/*; do
    /bin/bash -n "${script}"
done
/bin/bash -n "${ROOT}/Install.command"
/bin/bash -n "${ROOT}/Build-Package.command"
/bin/bash -n "${ROOT}/Uninstall.command"

PLUTIL="$(command -v plutil || true)"
[[ -n "${PLUTIL}" ]] || {
    echo "ERROR: plutil is required. / se requiere plutil." >&2
    exit 1
}
"${PLUTIL}" -lint "${ROOT}/src/wallpaper/Info.plist" >/dev/null
"${PLUTIL}" -lint "${ROOT}/src/wallpaper/LaunchAgent.plist" >/dev/null

# Build products and generated headers belong under build/ only.
if find "${ROOT}" -path "${ROOT}/build" -prune -o \
    \( -name '*.dylib' -o -name '*.app' -o -name '*.o' \) -print | grep -q .; then
    echo "ERROR: compiled products are present outside build/. / hay productos compilados fuera de build/." >&2
    exit 1
fi
if find "${ROOT}" -path "${ROOT}/build" -prune -o \
    -name 'SnowLeopardEmbeddedAssets.h' -print | grep -q .; then
    echo "ERROR: generated embedded-asset header is present outside build/. / el header generado de assets existe fuera de build/." >&2
    exit 1
fi

# Keep public source free of machine-specific paths and superseded architecture names.
if grep -RIn --exclude-dir=.git --exclude-dir=build --exclude=check-project.sh \
    '/Users/' "${ROOT}" >/dev/null; then
    echo "ERROR: local absolute user paths remain in the repository. / quedan rutas absolutas locales en el repositorio." >&2
    exit 1
fi
if grep -RIn --exclude-dir=.git --exclude-dir=build --exclude=check-project.sh \
    '/home/' "${ROOT}" >/dev/null; then
    echo "ERROR: local home-directory paths remain in the repository. / quedan rutas locales de directorios personales en el repositorio." >&2
    exit 1
fi
if grep -RInE --exclude-dir=.git --exclude-dir=build \
    'SnowLeopardShared|generate-embedded-icons\.py|SnowLeopardEmbeddedStatusIcons\.h|Lucida ?Grande' \
    "${ROOT}/src" "${ROOT}/docs" >/dev/null; then
    echo "ERROR: stale architecture/typography references remain in source/docs. / quedan referencias antiguas de arquitectura/tipografía en source/docs." >&2
    exit 1
fi

if ! grep -Fq 'com.snowleopardmenubar.wallpapersource' "${ROOT}/src/wallpaper/Info.plist" ||
   ! grep -Fq 'com.snowleopardmenubar.wallpapersource' "${ROOT}/src/wallpaper/LaunchAgent.plist"; then
    echo "ERROR: wallpaper helper distribution identifier is missing. / falta el identificador público del helper de wallpaper." >&2
    exit 1
fi

# Keep the package builder source-only: release artifacts are generated under
# build/ and dist/ and must never be committed into the packaging templates.
if find "${ROOT}/packaging" \
    \( -name '*.dylib' -o -name '*.app' -o -name '*.pkg' \) -print | grep -q .; then
    echo "ERROR: compiled artifacts exist under packaging/. / hay artefactos compilados dentro de packaging/." >&2
    exit 1
fi
if ! grep -Fq -- '--nopayload' "${ROOT}/scripts/build-package.sh" ||
   ! grep -Fq 'project-config.sh' "${ROOT}/scripts/build-package.sh" ||
   ! grep -Fq 'SnowLeopardWallpaperSource.app' "${ROOT}/packaging/scripts/postinstall" ||
   ! grep -Fq 'project-config.sh' "${ROOT}/packaging/scripts/postinstall"; then
    echo "ERROR: PKG builder/install template is incomplete. / el builder/template del PKG está incompleto." >&2
    exit 1
fi

if ! grep -Fq '#define SLLog(...)' "${ROOT}/src/include/Runtime.h"; then
    echo "ERROR: SLLog must remain variadic so Objective-C format expressions with commas compile. / SLLog debe seguir siendo variádico para compilar expresiones Objective-C con comas." >&2
    exit 1
fi
if grep -RInE '\bAppendLog\(' "${ROOT}/src" >/dev/null; then
    echo "ERROR: legacy AppendLog calls remain; use SLLog. / quedan llamadas AppendLog antiguas; usa SLLog." >&2
    exit 1
fi

PYTHON3="$(command -v python3 || true)"
if [[ -n "${PYTHON3}" ]]; then
    CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sl-project-check.XXXXXX")"
    trap 'rm -rf "${CHECK_TMP}"' EXIT

    PYTHONPYCACHEPREFIX="${CHECK_TMP}/pycache" \
        "${PYTHON3}" -m py_compile \
        "${ROOT}/scripts/generate-embedded-assets.py" \
        "${ROOT}"/tests/*.py

    "${PYTHON3}" - "${ROOT}" <<'PYCODE'
import re
from pathlib import Path
import sys

root = Path(sys.argv[1])
text_suffixes = {
    ".c", ".command", ".h", ".inc", ".json", ".m", ".md", ".plist",
    ".py", ".sh", ".txt", ".yml", ".yaml",
}
email_re = re.compile(r"(?<![\w.+-])[A-Z0-9._%+-]+@[A-Z][A-Z0-9.-]*\.[A-Z]{2,}(?![\w.-])", re.I)
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts or "build" in path.parts or "dist" in path.parts:
        continue
    if path.name == "check-project.sh" or path.suffix.lower() not in text_suffixes:
        continue
    text = path.read_text(errors="replace")
    emails = {match.group(0) for match in email_re.finditer(text)} - {"git@github.com"}
    if emails:
        raise SystemExit(f"personal-looking email address in {path.relative_to(root)}: {sorted(emails)}")

project_headers = "\n".join(
    path.read_text(errors="replace")
    for path in (root / "src" / "include").rglob("*.h")
)
for source in (root / "src").rglob("*.m"):
    text = source.read_text(errors="replace")
    aliases = set(re.findall(r"\b[A-Z][A-Za-z0-9_]*Fn\b", text))
    for alias in sorted(aliases):
        local_typedef = re.search(
            rf"typedef[^;]*\b{re.escape(alias)}\b\s*\)", text, re.S
        )
        header_typedef = re.search(
            rf"typedef[^;]*\b{re.escape(alias)}\b\s*\)", project_headers, re.S
        )
        if not local_typedef and not header_typedef:
            raise SystemExit(
                f"{source.relative_to(root)} uses {alias} without a visible project typedef"
            )
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
    raise SystemExit(
        f"assets/manifest.json must contain exactly 63 version-1 assets; found {len(entries)}"
    )
if len(manifest_paths) != len(entries):
    raise SystemExit("assets/manifest.json contains duplicate paths")
if manifest_paths != canonical_paths:
    missing = sorted(canonical_paths - manifest_paths)
    extra = sorted(manifest_paths - canonical_paths)
    raise SystemExit(
        f"embedded asset manifest mismatch; missing={missing} extra={extra}"
    )

privacy_markers = (
    b"/Users/",
    b"/home/",
    b"<stRef:filePath>",
    b"/Author",
    b"/Creator",
    b"/CreationDate",
    b"/ModDate",
    b"/Metadata",
    b"<x:xmpmeta",
)
for asset_path in sorted(canonical_paths):
    path = assets / asset_path
    if path.suffix.lower() != ".pdf":
        continue
    data = path.read_bytes()
    found = [marker.decode("ascii") for marker in privacy_markers if marker in data]
    if found:
        raise SystemExit(
            f"PDF asset contains document/privacy metadata: {asset_path}: {found}"
        )
PYCODE

    TMP_HEADER="${CHECK_TMP}/SnowLeopardEmbeddedAssets.h"
    "${PYTHON3}" "${ROOT}/scripts/generate-embedded-assets.py" \
        "${ROOT}/assets/manifest.json" \
        "${ROOT}/assets" \
        "${TMP_HEADER}"
    grep -Fq 'SLEmbeddedAssetCount' "${TMP_HEADER}" || {
        echo "ERROR: embedded asset generator validation failed. / falló la validación del generador de assets." >&2
        exit 1
    }

    rm -rf "${CHECK_TMP}"
    trap - EXIT
fi



echo "Project structure checks passed. / Las comprobaciones de estructura pasaron correctamente."
