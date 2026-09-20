# Arquitectura

> [English version](../en/ARCHITECTURE.md)

El proyecto distribuye **dos dylibs inyectadas** y un helper de wallpaper. La separación es intencional: cada componente posee una superficie de runtime y un alcance de procesos distinto.

## Componentes de runtime

### `libSnowLeopardMenuBarUnified.dylib`

Controla la estructura de la barra de menús y popups:

- material de la barra adaptado al wallpaper y sombra inferior;
- geometría/artwork del menú Apple y selección de la barra superior;
- fondo, máscara, esquinas y posición de menús popup;
- apariencia de status items del sistema y externos;
- iconos de estado de reemplazo embebidos;
- coordinación de selección de status items.

Se compila desde `src/common/`, `src/menubar/`, `src/menus/` y `src/status/`.

### `libSnowLeopardBlueSelection.dylib`

Controla la selección fuera de la barra superior:

- selección de menús popup/contextuales/Dock;
- estado del texto e indicador del padre de un submenu;
- selección de source lists/sidebars en apps compatibles;
- rutas de compatibilidad para Finder/App Store.

Se compila desde `src/common/` y `src/selection/`.

Mantener BlueSelection separado limita el alcance de procesos y el impacto de sus hooks privados de AppKit.

### `SnowLeopardWallpaperSource.app`

Lee el wallpaper activo y publica únicamente el pequeño payload de la franja superior que necesitan los procesos inyectados. Así se evita decodificar el wallpaper completo repetidamente en cada app.

## Responsabilidades del source

| Responsabilidad | Source | Propietario |
|---|---|---|
| Helpers de ABI/runtime/proceso y logging | `src/common/Runtime.m` | Compartido |
| Renderer de selección azul clásica | `src/common/SelectionRenderer.m` | Compartido |
| Material de menubar y comportamiento del menú superior | `src/menubar/MenuBar.m` | Unified |
| Geometría/fondo/sombra de popups | `src/menus/MenuPopup.m` | Unified |
| Status items del sistema | `src/status/SystemStatusItems.m` | Unified |
| Status items externos | `src/status/ExternalStatusItems.m` | Unified |
| Artwork de status embebido | `src/status/StatusIcons.m` | Unified |
| Notificación de selección de status | `src/status/StatusSelectionIPC.m` | Unified |
| Selección popup/context/Dock | `src/selection/MenuSelection.m` | BlueSelection |
| Selección sidebar/source list | `src/selection/SidebarSelection.m` | BlueSelection |
| Helper de wallpaper | `src/wallpaper/WallpaperSource.m` | Helper |

## Reglas de diseño

1. **Un propietario por superficie.** No agregues un segundo pipeline de hooks para una vista que ya pertenece a otro módulo.
2. **Un renderer para la selección azul.** Los módulos deciden *cuándo* hay selección; `SelectionRenderer` decide *cómo* se dibuja.
3. **Helpers de runtime centralizados.** Los helpers genéricos de métodos/ivars/procesos pertenecen a `Runtime`.
4. **Guards para APIs privadas.** Resuelve clase/selector, valida encodings cuando sea práctico, mantén la instalación idempotente y conserva la implementación original.
5. **Los datos generados siguen siendo generados.** Headers y binarios de build pertenecen a `build/`/`dist/`, no al repositorio.
6. **Fallo local.** Si una clase privada no existe o cambia su ABI, debe desactivarse la función concreta y no ampliarse el alcance ni provocar crashes en apps no relacionadas.

## Límites de compilación

Todos los binarios propios comparten la política de compilación definida en `scripts/toolchain.sh`: slices universales Apple Silicon (`arm64 + arm64e`), ARC, `-O2`, warnings estrictos, visibilidad oculta de símbolos C y `dead_strip` del linker.

LTO no se activa por defecto. Los hooks privados Objective-C son sensibles a cambios de toolchain/runtime y una optimización de programa completo debe validarse en la build exacta de macOS antes de adoptarse.
