#!/bin/bash

# Stable project-wide configuration. Runtime implementation details belong in
# Objective-C modules; installation paths and supported platform live here.
SL_SUPPORTED_MACOS_MAJOR=15
SL_AMMONIA_CORE='/private/var/ammonia/core'
SL_TWEAK_DIR="${SL_AMMONIA_CORE}/tweaks"
SL_BACKUP_ROOT="${SL_AMMONIA_CORE}/backups"

SL_UNIFIED_NAME='libSnowLeopardMenuBarUnified.dylib'
SL_BLUE_NAME='libSnowLeopardBlueSelection.dylib'
SL_WALLPAPER_LABEL='com.snowleopardmenubar.wallpapersource'
SL_DEBUG_LOG='/private/tmp/SnowLeopardMenuBar.log'

# Installer-package metadata. Override only SL_PACKAGE_VERSION at build time;
# the public identifier and basename stay stable across releases.
SL_PACKAGE_IDENTIFIER='com.snowleopardmenubar.tweak'
SL_PACKAGE_BASENAME='Snow-Leopard-Menu-Bar-Tweak'
SL_DEFAULT_PACKAGE_VERSION='1.0.0'

SL_STATUS_SPACING_KEY='NSStatusItemSpacing'
SL_STATUS_PADDING_KEY='NSStatusItemSelectionPadding'
SL_STATUS_SPACING=6
SL_STATUS_PADDING=6
SL_SPOTLIGHT_DOMAIN='com.apple.Spotlight'
SL_SPOTLIGHT_POSITION_KEY='NSStatusItem Preferred Position Item-0'
# Persisted defaults seed AppKit's initial order. Runtime hooks may expose a
# different preferred-position value after integrating the visual right margin.
SL_SPOTLIGHT_PERSISTED_POSITION=41
SL_CLOCK_DOMAIN='com.apple.controlcenter'
SL_CLOCK_POSITION_KEY='NSStatusItem Preferred Position Clock'
SL_CLOCK_PERSISTED_POSITION=218

SL_UNIFIED_SAFETY_FILTERS=(
    launchd
    WindowServer
    Dock
    NotificationCenter
    com.apple.WebKit.WebContent
)

SL_LEGACY_DYLIBS=(
    # Previous production splits.
    libSnowLeopardMenuBarStandalone.dylib
    libSnowLeopardMenuBarExtras.dylib
    libSnowLeopardMenuPopupStandalone.dylib
    libSnowLeopardExternalStatusItems.dylib

    # Historical experiments/probes that can install competing hooks.
    libSnowLeopardMenuSystem.dylib
    libSnowLeopardMenuTextV2.dylib
    libSnowLeopardStatusIcons.dylib
    libSnowLeopardMenuBar.dylib
    libMenuBarDrawInspector.dylib
    libMenuBarItemInspector.dylib
    libSnowLeopardPopupSelection.dylib
    libSnowLeopardPopupGeometry.dylib
)


sl_require_supported_macos() {
    local version
    version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    case "${version}" in
        "${SL_SUPPORTED_MACOS_MAJOR}."*) return 0 ;;
        *)
            echo "ERROR: macOS Sequoia ${SL_SUPPORTED_MACOS_MAJOR}.x is required; detected: ${version:-unknown}. / se requiere macOS Sequoia ${SL_SUPPORTED_MACOS_MAJOR}.x; detectado: ${version:-desconocido}." >&2
            return 1
            ;;
    esac
}
