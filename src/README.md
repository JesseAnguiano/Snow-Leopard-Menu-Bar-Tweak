# Source / Código fuente

`src/` is organized by runtime responsibility. Directory names provide the context, so implementation filenames stay short and easy to scan.

`src/` está organizado por responsabilidad de runtime. Los directorios aportan el contexto, por eso los nombres de implementación se mantienen cortos y fáciles de recorrer.

```text
src/
├── common/
│   ├── Runtime.m
│   └── SelectionRenderer.m
├── include/
│   ├── ColorTransfer.h
│   ├── Performance.h
│   ├── Protocol.h
│   ├── Runtime.h
│   ├── SelectionRenderer.h
│   ├── StatusSelectionIPC.h
│   └── WallpaperWire.h
├── menubar/
│   ├── MenuBar.m
│   └── rendering/
│       ├── DirectWallpaper.inc
│       └── LowerShadow.inc
├── menus/
│   └── MenuPopup.m
├── selection/
│   ├── MenuSelection.m
│   └── SidebarSelection.m
├── status/
│   ├── ExternalStatusItems.m
│   ├── StatusIcons.m
│   ├── StatusSelectionIPC.m
│   └── SystemStatusItems.m
└── wallpaper/
    ├── Info.plist
    ├── LaunchAgent.plist
    └── WallpaperSource.m
```

## Ownership / Responsabilidades

| Area | Source | Runtime owner |
|---|---|---|
| Runtime helpers, ABI checks, process checks, logging | `common/Runtime.m` | Both dylibs |
| Classic Snow Leopard blue renderer | `common/SelectionRenderer.m` | Both dylibs |
| Menu-bar material, Apple item, top-menu selection | `menubar/MenuBar.m` | Unified |
| Menu-bar wallpaper and lower-shadow render pieces | `menubar/rendering/` | Unified |
| Popup background, mask and placement | `menus/MenuPopup.m` | Unified |
| System status items | `status/SystemStatusItems.m` | Unified |
| Third-party/external status items | `status/ExternalStatusItems.m` | Unified |
| Embedded Apple-owned status icons | `status/StatusIcons.m` | Unified |
| Cross-process status selection notification | `status/StatusSelectionIPC.m` | Unified |
| Popup/context/Dock menu selection | `selection/MenuSelection.m` | BlueSelection |
| Sidebar/source-list selection | `selection/SidebarSelection.m` | BlueSelection |
| Wallpaper feed helper | `wallpaper/WallpaperSource.m` | Helper app |

## Rules for changes / Reglas para cambios

1. **One owner per surface.** Unified owns top-menu and status-item selection. BlueSelection owns popup/context/Dock/sidebar selection.
2. **One renderer.** All Snow Leopard blue pixels come from `common/SelectionRenderer.m`.
3. **Validate private ABI before hooking.** Reuse `include/Runtime.h`; do not add ad-hoc generic swizzle/ivar helpers.
4. **Generated assets are not source.** Edit canonical files under `assets/` and `assets/manifest.json`; `build/generated/SnowLeopardEmbeddedAssets.h` is generated during the build.
5. **Keep unrelated typography out.** This tweak leaves system/app fonts alone.
6. **Keep production logging off by default.** Use `SNOW_LEOPARD_MENU_BAR_DEBUG=1` only for diagnosis.
7. **Optimize for maintainability.** Prefer smaller APIs, fewer owners and deleted dead branches over minification.
8. **Keep build policy centralized.** Compiler/architecture flags belong in `scripts/toolchain.sh`, not individual source modules.

## Build graph / Grafo de compilación

`libSnowLeopardMenuBarUnified.dylib` builds from `common/`, `menubar/`, `menus/`, and `status/`.

`libSnowLeopardBlueSelection.dylib` builds from `common/` and `selection/`.

The wallpaper helper is built separately from `wallpaper/`. The two injected dylibs remain separate because their process scope and private-hook risk are different.
