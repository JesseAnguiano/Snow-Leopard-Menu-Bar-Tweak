# Technical notes

> [Versión en español](../es/TECHNICAL-NOTES.md)

These notes describe the current implementation only. Obsolete experiments belong in Git history, not in production guidance.

## Supported environment

The runtime is guarded for macOS Sequoia 15.x on Apple Silicon. Injected dylibs are built as `arm64 + arm64e` and depend on private AppKit/CoreAnimation/WindowServer behavior, so newer major releases are unsupported until the relevant classes, selectors and compositor assumptions are revalidated.

## Menu-bar rendering

`src/menubar/MenuBar.m` owns the menu-bar material and top-level selection. The wallpaper helper publishes only the top wallpaper payload required by injected processes. The menu-bar module applies calibrated color transfer, material behavior and the lower shadow without requiring every app to decode the full wallpaper.

## Popup menus

`src/menus/MenuPopup.m` owns popup surface geometry, mask, rounded corners, submenu placement and external shadow integration. It deliberately does not own popup selection.

`src/selection/MenuSelection.m` owns popup/context/Dock selection state, including submenu-parent text and indicator presentation. Blue pixels are rendered by the shared selection renderer.

## Selection renderer

`src/common/SelectionRenderer.m` contains the single classic blue gradient implementation. Edge rules use one physical pixel (`1 / backingScaleFactor`) so Retina and non-Retina output remain consistent.

Feature modules decide whether a surface is selected; they do not carry private copies of the palette.

## Sidebar selection

`src/selection/SidebarSelection.m` follows a native-first strategy: it lets AppKit construct the selection material, identifies the chromatic selection content, applies the shared classic renderer and synchronizes selected text/content color. A local row fallback is used only when the native material cannot be adapted safely.

Finder deselection follows the state resulting from AppKit's original selection call. App Store has a narrow compatibility path for selected text vibrancy.

## Status items and artwork

System-owned status items, external status items and artwork replacement are split across separate source files to keep process identity, interaction and artwork lookup independent.

Canonical artwork is stored under `assets/`, verified against `assets/manifest.json` and embedded at build time. No runtime asset directory is required by the dylibs.

## Runtime helpers

`Runtime` centralizes OS/process guards, exact process identity checks, owned method/ivar lookup, ABI encoding checks, inherited-method materialization, override installation/restoration and production-gated debug logging.

Generic hook mechanics should not be reimplemented inside feature modules.

## Optimization policy

The project optimizes for predictable runtime behavior rather than line-count reduction:

- one owner per surface;
- one shared selection renderer;
- centralized runtime lookups;
- event/state driven updates where possible;
- `-O2`, hidden C-symbol visibility and linker dead stripping;
- no unconditional hot-path file I/O;
- no LTO until validated against the complete private-hook matrix on the target macOS build.

## Verification limits

Static and deterministic regression tests can validate scripts, assets, rendering math, layout invariants and some performance assumptions. They cannot prove live WindowServer/menu-tracking behavior. Final validation requires the dylibs to be injected on the target macOS build.
