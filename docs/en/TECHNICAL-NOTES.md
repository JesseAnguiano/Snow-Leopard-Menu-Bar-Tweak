# Technical notes

> [Versión en español](../es/TECHNICAL-NOTES.md)

These notes describe the **current architecture**. Historical experiments are intentionally not kept as active implementation guidance; Git history is the place for obsolete pipelines.

## 1. Supported environment

The runtime is guarded for macOS Sequoia 15.x on Apple Silicon. Both injected dylibs are built as `arm64 + arm64e` and use private AppKit/CoreAnimation behavior, so a future macOS release must be treated as unsupported until the relevant classes/selectors/layers are revalidated.

## 2. Menu-bar rendering

`src/menubar/MenuBar.m` owns the menu-bar material and top-level selection. The wallpaper helper publishes the top wallpaper payload; Core applies the calibrated color-transfer/material path and the separate lower shadow without making every injected process decode the full wallpaper.

The Apple item keeps its project-specific geometry/artwork. The project does **not** own application typography.

## 3. Popup menus

`src/menus/MenuPopup.m` owns popup background/mask/corner/placement behavior only. It intentionally does not install a competing selection pipeline.

Popup/context/Dock selection state is owned by `src/selection/MenuSelection.m`, while the actual blue pixels come from the shared renderer.

## 4. Blue selection renderer

`src/common/SelectionRenderer.m` contains the single exact 35-stop blue gradient used by every supported surface. Edge rules are drawn as a physical pixel (`1 / backingScaleFactor`) rather than one logical point so Retina and non-Retina rendering stay consistent.

Feature modules decide when a view is selected; they must not carry private copies of the palette.

## 5. Sidebar/source-list selection

`src/selection/SidebarSelection.m` uses a native-first strategy:

1. let AppKit create/update the normal selection material;
2. locate the active `NSVisualEffectView` selection material;
3. locate the chromatic sublayer rather than assuming a fixed layer index;
4. replace that chromatic content with the Snow Leopard gradient;
5. synchronize selected content color;
6. use a local row fallback only when the native material cannot be used.

Finder deselection is synchronized after AppKit's original `setSelected:` implementation, using the actual resulting row state. The hook does not artificially keep a row selected.

App Store has a narrow compatibility path for `AppStoreKit.DynamicTypeTextField`: selected rows temporarily disable vibrancy for that field and restore the original value when deselected.

## 6. Status items

System-owned status items are isolated in `SystemStatusItems.m`; third-party/application-owned items are handled in `ExternalStatusItems.m`. Icon replacement is isolated again in `StatusIcons.m`.

This split avoids mixing hardware/status polling, menu interaction, process identity, and artwork lookup into the menu-bar Core.

The project keeps bounded/reasoned refresh paths and avoids perpetual high-frequency polling where an event/state transition can be used.

## 7. Embedded artwork

The repository contains 61 canonical status-icon files plus 2 Apple-menu PNGs. `assets/manifest.json` pins byte size and SHA-256 for all 63 assets. The generator verifies the manifest before emitting the temporary C byte arrays consumed by the Unified build.

No generated multi-megabyte byte header is tracked in Git and no external runtime asset folder is required by the dylib.

## 8. Runtime helpers and hooks

`Runtime` centralizes:

- OS/process guards;
- exact Control Center/SystemUIServer/Spotlight identity checks;
- owned-method/ivar lookup;
- method-encoding comparison;
- inherited-method materialization;
- override installation/restoration;
- top-menu-window detection;
- production-gated debug logging.

This is deliberate: hook mechanics should not be reimplemented differently in every feature module.

## 9. Diagnostics

Debug file logging is disabled unless `SNOW_LEOPARD_MENU_BAR_DEBUG=1` is present in the target process environment. Hot paths should use `SLLog(...)` rather than unconditional writes.

## 10. Optimization policy

Current build optimization is `-O2` plus linker `-dead_strip`. More aggressive whole-program optimization is not automatically better for a tweak whose behavior depends on private Objective-C runtime entry points. LTO should be considered only after compiling and testing the complete hook matrix on the target Sequoia build.

Source optimization prioritizes removing duplicate owners, duplicate renderers, repeated runtime scans, dead branches and embedded binary text. It does not treat compressed formatting as an optimization.

## 11. Verification limits

Static/regression tests can validate deterministic image/layout logic, manifests, scripts, capability markers and some performance invariants. They cannot prove real WindowServer/menu tracking behavior. Final validation must occur on macOS with the dylibs actually injected.
