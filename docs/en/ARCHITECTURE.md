# Architecture

> [Versión en español](../es/ARCHITECTURE.md)

The project intentionally ships **two injected dylibs** plus one wallpaper helper. The split is based on runtime ownership and failure scope, not on historical file boundaries.

## Runtime components

### `libSnowLeopardMenuBarUnified.dylib`

Owns surfaces that belong to the menu bar itself:

- wallpaper-aware menu-bar material and lower shadow;
- Apple menu item geometry/artwork and top-level menu selection;
- popup-menu background, mask, corners, and placement;
- Apple/system status items in Control Center, SystemUIServer, and Spotlight;
- third-party/external status-item styling;
- embedded replacement status icons;
- cross-process status-selection notification.

It is built from `src/common/`, `src/menubar/`, `src/menus/`, and `src/status/`.

### `libSnowLeopardBlueSelection.dylib`

Owns selection state outside the top menu-bar/status-item surface:

- popup/context/Dock menu selection;
- Finder/App Store/Music/System Settings source-list/sidebar selection;
- Finder deselection synchronization;
- App Store selected-text vibrancy compatibility.

It is built from `src/common/` and `src/selection/`.

Keeping this dylib separate lets it use a different Ammonia process filter and limits the blast radius of private AppKit hooks.

### `SnowLeopardWallpaperSource.app`

A background helper that reads the current wallpaper and publishes the small top-of-screen payload needed by injected processes. This avoids having every injected process independently decode the full wallpaper.

## Source ownership

| Surface | Owner | Source |
|---|---|---|
| Runtime/ABI helpers, process checks, debug logging | Shared | `src/common/Runtime.m` |
| Exact 35-stop blue renderer | Shared | `src/common/SelectionRenderer.m` |
| Menu-bar material, Apple item, top-menu selection | Unified | `src/menubar/MenuBar.m` |
| Popup background/mask/placement | Unified | `src/menus/MenuPopup.m` |
| Control Center/SystemUIServer/Spotlight | Unified | `src/status/SystemStatusItems.m` |
| External/third-party status items | Unified | `src/status/ExternalStatusItems.m` |
| Replacement status icons | Unified | `src/status/StatusIcons.m` |
| Status-selection notification | Unified | `src/status/StatusSelectionIPC.m` |
| Popup/context/Dock menu selection | BlueSelection | `src/selection/MenuSelection.m` |
| Sidebar/source-list selection | BlueSelection | `src/selection/SidebarSelection.m` |
| Wallpaper payload helper | Helper app | `src/wallpaper/WallpaperSource.m` |

The shorter map in [`src/README.md`](../../src/README.md) is the preferred starting point when changing code.

## One owner per surface

A major source of past regressions was duplicated hook pipelines. The current rule is strict:

- Unified owns **top-menu and status-item** selection.
- BlueSelection owns **popup/context/Dock/sidebar** selection.
- `SelectionRenderer.m` owns all Snow Leopard blue pixels.

Do not add another hook pipeline merely because another module can see the same view.

## Embedded assets

The repository tracks canonical artwork as normal files under `assets/`:

- 61 status-icon assets under `assets/status-icons/`;
- 2 Apple-menu PNGs under `assets/apple-menu/`.

`assets/manifest.json` records each asset's path, C symbol, byte size, and SHA-256. `scripts/generate-embedded-assets.py` verifies those values and creates `build/generated/SnowLeopardEmbeddedAssets.h` during the build. The generated header is intentionally excluded from Git.

The final dylib therefore keeps `runtimeResources=0`: the artwork is embedded in the compiled binary, while the repository remains readable.

## Private API safety model

Private AppKit hooks are installed only after:

1. checking macOS Sequoia 15.x;
2. checking the intended process identity/type;
3. resolving the target class/selector;
4. validating the observed method encoding;
5. materializing an owned method when required;
6. storing the original `IMP` so a partial installation can be rolled back.

Reusable operations live in `Runtime`. New modules should not create their own generic swizzle/ivar helpers.

## Build-time generated data

Generated files belong under `build/` only. Source modules must not contain Base64/hex dumps of binary artwork, and generated C headers must not be committed.

## Why the project is not one dylib

Merging the two injected dylibs would reduce one file on disk but would couple unrelated process filters and private hooks. The current split is smaller operationally: a sidebar failure cannot force every menu-bar process to load the same selection hook set, and Dock coverage does not have to be added to the Unified filter.
