#!/bin/bash

# Binary capability manifests. Keep this list intentionally small: detailed
# behavior belongs in tests, not in fragile searches for debug-log strings.
SL_BLUE_MARKERS=(
    'snowLeopardBlueSelection=modular-v2'
    'compatibility=sequoia15'
    'topMenu=unified'
    'renderer=shared-exact35'
    'menuSurfaces=popup,context,dock'
    'snowLeopardSidebarSelection=modular-v2'
    'sidebarStrategy=native-first-with-row-fallback'
    'finderDeselection=post-original'
    'appStoreVibrancy=selected-only'
)

SL_UNIFIED_MARKERS=(
    'snowLeopardMenuBarUnified=modular-v2'
    'compatibility=sequoia15'
    'runtimeResources=0'
    'selectionOwner=unified-top-status-blueSelection-popup-dock-sidebar'
    'snowLeopardPopup=modular-v2'
    'snowLeopardSystemStatus=modular-v2'
    'snowLeopardExternalStatus=modular-v2'
    'snowLeopardStatusIcons=embedded-v2'
)


sl_require_markers() {
    local binary="$1" label="$2"
    shift 2
    local marker
    for marker in "$@"; do
        if ! /usr/bin/grep -aFq -- "${marker}" "${binary}"; then
            echo "ERROR: ${label} missing capability / falta la capacidad: ${marker}" >&2
            return 1
        fi
    done
}

sl_has_architecture() {
    local binary="$1" expected="$2" architecture
    for architecture in $(/usr/bin/lipo -archs "${binary}"); do
        [[ "${architecture}" == "${expected}" ]] && return 0
    done
    return 1
}

sl_require_universal_architectures() {
    local binary="$1" label="$2" architectures
    architectures="$(/usr/bin/lipo -archs "${binary}")"
    if ! sl_has_architecture "${binary}" arm64 ||
       ! sl_has_architecture "${binary}" arm64e; then
        echo "ERROR: ${label} requires arm64 + arm64e / requiere arm64 + arm64e: ${architectures}" >&2
        return 1
    fi
    printf '%s' "${architectures}"
}
