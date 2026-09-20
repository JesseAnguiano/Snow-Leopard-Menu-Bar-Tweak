# Architecture

> [Versión en español](../es/ARCHITECTURE.md)

The project ships **two injected dylibs** plus one wallpaper helper. The split is deliberate: each component owns a distinct runtime surface and process scope.

## Runtime components

### `libSnowLeopardMenuBarUnified.dylib`

Owns menu-bar and popup structure:

- wallpaper-aware menu-bar material and lower shadow;
- Apple menu item geometry/artwork and top-level menu selection;
- popup background, mask, corners and placement;
- system and external status-item styling;
- embedded replacement status icons;
- status-selection coordination.

Built from `src/common/`, `src/menubar/`, `src/menus/` and `src/status/`.

### `libSnowLeopardBlueSelection.dylib`

Owns selection behavior outside the top menu bar:

- popup/context/Dock menu selection;
- submenu parent text/indicator state;
- source-list/sidebar selection in supported apps;
- Finder/App Store compatibility paths.

Built from `src/common/` and `src/selection/`.

Keeping BlueSelection separate limits the process scope and failure radius of its private AppKit hooks.

### `SnowLeopardWallpaperSource.app`

Reads the active wallpaper once and publishes the small top-of-screen payload needed by injected processes. This avoids repeated full-wallpaper decoding across applications.

## Source ownership

| Responsibility | Source | Runtime owner |
|---|---|---|
| ABI/runtime/process helpers and debug logging | `src/common/Runtime.m` | Shared |
| Classic blue selection renderer | `src/common/SelectionRenderer.m` | Shared |
| Menu-bar material and top-menu behavior | `src/menubar/MenuBar.m` | Unified |
| Popup geometry/background/shadow integration | `src/menus/MenuPopup.m` | Unified |
| System status items | `src/status/SystemStatusItems.m` | Unified |
| External status items | `src/status/ExternalStatusItems.m` | Unified |
| Embedded status artwork | `src/status/StatusIcons.m` | Unified |
| Status-selection notification | `src/status/StatusSelectionIPC.m` | Unified |
| Popup/context/Dock menu selection | `src/selection/MenuSelection.m` | BlueSelection |
| Sidebar/source-list selection | `src/selection/SidebarSelection.m` | BlueSelection |
| Wallpaper payload helper | `src/wallpaper/WallpaperSource.m` | Helper |

## Design rules

1. **One owner per surface.** Do not add a second hook pipeline for a view already owned by another module.
2. **One renderer for blue selection.** Feature modules decide *when* selection is active; `SelectionRenderer` decides *how* it looks.
3. **Centralized runtime helpers.** Generic method/ivar/process helpers belong in `Runtime`, not copied into feature modules.
4. **Guard private APIs.** Resolve the intended class/selector, validate encodings where practical, keep installation idempotent and retain the original implementation.
5. **Generated data stays generated.** Build-time headers and binaries belong under `build/`/`dist/`, never in source control.
6. **Fail locally.** A missing private class or incompatible ABI should disable the narrow feature rather than broaden process scope or crash unrelated apps.

## Build boundaries

All project-owned binaries share compiler policy through `scripts/toolchain.sh`: Apple Silicon universal slices (`arm64 + arm64e`), ARC, `-O2`, strict warnings, hidden C-symbol visibility and linker dead stripping.

LTO is intentionally not enabled by default. Private Objective-C hook behavior is sensitive to toolchain/runtime changes and must be validated on the exact target macOS build before enabling more aggressive whole-program optimization.
