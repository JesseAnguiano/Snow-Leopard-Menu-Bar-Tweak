# Development

> [Versión en español](../es/DEVELOPMENT.md)

## Start here

Read [`src/README.md`](../../src/README.md) before changing runtime code. It defines which module owns each visual surface. Most regressions in this kind of tweak come from adding a second owner rather than from the renderer itself.

## Requirements

- macOS Sequoia 15.x
- Apple Silicon
- Xcode Command Line Tools
- Ammonia for runtime testing

Repository-only checks can run without installing the tweak:

```bash
./scripts/check-project.sh
```

## Build

```bash
make all
```

or build the pieces directly:

```bash
./scripts/build.sh
./scripts/build-wallpaper-source.sh
```

The injected dylibs target `arm64 + arm64e`, use `-O2`, `-Wall -Wextra -Werror`, and link with `-dead_strip`. Whole-program/LTO optimization is intentionally not enabled until private-hook behavior is validated with it on the target macOS build.

## Build an installer package

To create a self-contained Installer package from the current source:

```bash
make package
```

This runs the normal source checks/builds first and then embeds the resulting dylibs and wallpaper helper in a script-only `.pkg` under `dist/`. The destination machine does not need Command Line Tools. Package-specific details are documented in [`packaging/README.md`](../../packaging/README.md).

## Source layout

```text
src/
├── common/       runtime helpers + shared selection renderer
├── include/      shared internal headers/contracts
├── menubar/      menu-bar material/top-menu behavior
│   └── rendering/ wallpaper + lower-shadow render fragments
├── menus/        popup background/mask/placement
├── selection/    popup/Dock/sidebar selection hooks
├── status/       system/external status items + icons + IPC
└── wallpaper/    background wallpaper helper source + plists
```

Prefer adding a small file to the matching responsibility over making an unrelated large module aware of another surface.

## Adding or changing a private hook

Before committing a hook change:

1. identify the exact process(es) that need it;
2. identify the exact class/selector at runtime;
3. record/validate the expected method encoding;
4. use `SLInstallOverrideHook` or the narrower helper already used by that module;
5. preserve the original implementation;
6. make installation idempotent;
7. avoid polling when a state transition/callback is available;
8. test both selection and deselection/cleanup paths;
9. add or update a regression test when the behavior can be exercised outside WindowServer.

Do not copy generic Objective-C runtime helpers into feature modules.

## Selection rendering

All classic blue selection pixels must go through `SelectionRenderer`. The 35-stop palette, sRGB creation, and physical 1-pixel edge rules belong there. Feature modules own **when and where** selection appears, not the gradient implementation.

## Embedded artwork

Canonical artwork is stored as normal files under `assets/`. The manifest is `assets/manifest.json`.

To add or replace an embedded asset:

1. place the canonical file under `assets/`;
2. update its manifest entry (`name`, `path`, `symbol`, `sha256`, `size`);
3. run `./scripts/check-project.sh`;
4. build normally.

`scripts/build.sh` invokes `scripts/generate-embedded-assets.py`, which verifies every manifest entry and generates `build/generated/SnowLeopardEmbeddedAssets.h`. Never edit or commit that generated header.

## Capability markers

`scripts/markers.sh` contains only a small set of stable binary capabilities used by build/install/verify. Do not use debug-log sentences as API/version markers. Behavioral details belong in tests and documentation.

## Configuration

Installation paths, supported macOS major version, tweak names, layout defaults, and legacy cleanup names live in `scripts/project-config.sh`. Keep machine-specific paths out of source and scripts.

## Debug logging

Production logging is disabled by default. Set:

```bash
SNOW_LEOPARD_MENU_BAR_DEBUG=1
```

in the environment of a process only while diagnosing runtime behavior. Avoid adding unconditional hot-path file I/O.

## Tests

Run the deterministic regression suite:

```bash
make test
```

After building BlueSelection, the optional sidebar harness is:

```bash
make test-sidebar
```

The regression suite covers deterministic rendering/layout/performance behavior. It cannot replace manual testing of WindowServer composition, Spaces, multi-display behavior, Control Center, Finder, App Store, or live menu tracking.

Recommended manual smoke test after any hook change:

- Finder sidebar select/deselect and navigation into a non-sidebar folder;
- App Store sidebar selection/text visibility;
- Music/System Settings sidebar selection;
- application popup/context menus;
- Dock contextual menu;
- Apple menu/top menu selection;
- Clock, Spotlight, Control Center and third-party status items;
- multiple displays/wallpapers if available.

## Style and optimization policy

Optimize for **one owner, one renderer, one runtime helper implementation, and fewer runtime scans**. Do not optimize by minifying, merging unrelated responsibilities, or removing guards only to reduce line count. A readable guard around a private API is cheaper than a crash across every injected process.
