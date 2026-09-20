# Development

> [Versión en español](../es/DEVELOPMENT.md)

## Requirements

- macOS Sequoia 15.x
- Apple Silicon
- Xcode Command Line Tools
- Ammonia for live injection tests

## Fast path

```bash
make check
make all
make test
```

Before publishing:

```bash
make release-check
```

`make help` lists the common targets.

## Source layout

```text
src/
├── common/       shared runtime helpers + selection renderer
├── include/      internal contracts
├── menubar/      menu-bar material/top-menu behavior
│   └── rendering/ focused rendering fragments
├── menus/        popup background/mask/placement
├── selection/    popup/Dock/sidebar selection hooks
├── status/       system/external status items + icons + IPC
└── wallpaper/    wallpaper helper source + plists
```

Developer-only runtime probes live in `tools/diagnostics/`; deterministic regressions stay under `tests/`.

## Compiler policy

`scripts/toolchain.sh` is the single source of truth for project-owned binary flags. Current policy includes:

- `arm64 + arm64e`;
- ARC + blocks;
- `-O2`;
- `-Wall -Wextra -Werror`;
- hidden C-symbol visibility;
- `-fno-common`;
- linker `-dead_strip`.

Do not add module-specific optimization flags without a measured reason. LTO remains opt-in until the complete private-hook matrix is validated with it on the target macOS build.

## Private hooks

Before changing a private hook:

1. identify the exact process and surface that own the behavior;
2. inspect the runtime class/selector on the target macOS build;
3. validate the expected method encoding where practical;
4. reuse `Runtime` helpers instead of adding another generic swizzle implementation;
5. preserve the original implementation;
6. make installation idempotent;
7. test activation, deselection/cleanup and repeated presentation;
8. prefer callbacks/state transitions over unbounded polling;
9. add a deterministic regression when the behavior can be isolated from WindowServer.

Reference projects may be useful for understanding behavior, but implementation in this repository should be independently written unless a compatible license explicitly permits reuse.

## Assets

Canonical artwork lives under `assets/` and is pinned by `assets/manifest.json`. `scripts/generate-embedded-assets.py` validates byte size/SHA-256 and emits `build/generated/SnowLeopardEmbeddedAssets.h` during the build. Never commit the generated header.

## Debugging

Production file logging is disabled by default. Enable it only for diagnosis by setting:

```bash
SNOW_LEOPARD_MENU_BAR_DEBUG=1
```

Use `SLLog(...)` for diagnostic output and remove private data before sharing logs.

## Test scope

`make test` covers deterministic rendering/layout/performance invariants. `make test-sidebar` exercises the optional sidebar harness after a build. Neither can prove live WindowServer/menu-tracking behavior.

Manual smoke testing should include Finder, App Store, a normal Cocoa app, contextual menus, Dock menus, Control Center, Clock, Spotlight, third-party status items and multi-display/wallpaper behavior when available.
