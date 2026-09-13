# Arquitectura

> [English version](../en/ARCHITECTURE.md)

El proyecto distribuye intencionalmente **dos dylibs inyectadas** y un helper de wallpaper. La separación se basa en responsabilidad de runtime y alcance de fallos, no en límites históricos de archivos.

## Componentes de runtime

### `libSnowLeopardMenuBarUnified.dylib`

Es responsable de las superficies que pertenecen a la propia barra de menús:

- material de barra basado en wallpaper y sombra inferior;
- geometría/arte del menú Apple y selección de menú superior;
- fondo, máscara, esquinas y posición de menús popup;
- status items de Apple/sistema en Control Center, SystemUIServer y Spotlight;
- estilo de status items externos/de terceros;
- iconos de estado de reemplazo embebidos;
- notificación entre procesos para selección de status items.

Se compila desde `src/common/`, `src/menubar/`, `src/menus/` y `src/status/`.

### `libSnowLeopardBlueSelection.dylib`

Es responsable del estado de selección fuera de la superficie de menú superior/status items:

- selección de menús popup/contextuales/Dock;
- selección de source lists/sidebars de Finder, App Store, Música y Ajustes del Sistema;
- sincronización de deselección de Finder;
- compatibilidad de vibrancy del texto seleccionado en App Store.

Se compila desde `src/common/` y `src/selection/`.

Mantenerla separada permite usar otro filtro de procesos de Ammonia y limita el alcance de fallos de hooks privados de AppKit.

### `SnowLeopardWallpaperSource.app`

Helper en segundo plano que lee el wallpaper actual y publica el pequeño payload de la parte superior de la pantalla que necesitan los procesos inyectados. Así cada proceso no tiene que decodificar el wallpaper completo por separado.

## Responsabilidad del source

| Superficie | Dueño | Source |
|---|---|---|
| Helpers de runtime/ABI, procesos y log de diagnóstico | Compartido | `src/common/Runtime.m` |
| Renderer azul exacto de 35 stops | Compartido | `src/common/SelectionRenderer.m` |
| Material de barra, item Apple, selección superior | Unified | `src/menubar/MenuBar.m` |
| Fondo/máscara/posición de popup | Unified | `src/menus/MenuPopup.m` |
| Control Center/SystemUIServer/Spotlight | Unified | `src/status/SystemStatusItems.m` |
| Status items externos/de terceros | Unified | `src/status/ExternalStatusItems.m` |
| Iconos de estado de reemplazo | Unified | `src/status/StatusIcons.m` |
| Notificación de selección de status items | Unified | `src/status/StatusSelectionIPC.m` |
| Selección popup/contextual/Dock | BlueSelection | `src/selection/MenuSelection.m` |
| Selección de sidebar/source list | BlueSelection | `src/selection/SidebarSelection.m` |
| Helper de payload de wallpaper | Helper app | `src/wallpaper/WallpaperSource.m` |

El mapa corto de [`src/README.md`](../../src/README.md) es el mejor punto de partida para modificar código.

## Un dueño por superficie

Una causa importante de regresiones anteriores fueron pipelines de hooks duplicados. La regla actual es estricta:

- Unified controla selección de **menú superior y status items**.
- BlueSelection controla selección **popup/contextual/Dock/sidebar**.
- `SelectionRenderer.m` controla todos los píxeles azules Snow Leopard.

No añadas un segundo pipeline sólo porque otro módulo pueda ver la misma vista.

## Assets embebidos

El repositorio guarda el artwork canónico como archivos normales dentro de `assets/`:

- 61 assets de status icons en `assets/status-icons/`;
- 2 PNG del menú Apple en `assets/apple-menu/`.

`assets/manifest.json` registra ruta, símbolo C, tamaño y SHA-256 de cada asset. `scripts/generate-embedded-assets.py` verifica esos valores y crea `build/generated/SnowLeopardEmbeddedAssets.h` durante la compilación. Ese header generado no se versiona en Git.

La dylib final conserva `runtimeResources=0`: el artwork queda embebido en el binario compilado mientras el repositorio sigue siendo legible.

## Modelo de seguridad para APIs privadas

Los hooks privados de AppKit sólo se instalan después de:

1. comprobar macOS Sequoia 15.x;
2. comprobar identidad/tipo del proceso esperado;
3. resolver clase y selector objetivo;
4. validar el encoding observado del método;
5. materializar un método propio cuando hace falta;
6. guardar el `IMP` original para poder revertir una instalación parcial.

Las operaciones reutilizables viven en `Runtime`. Los módulos nuevos no deben crear sus propios helpers genéricos de swizzle/ivars.

## Datos generados al compilar

Los archivos generados pertenecen únicamente a `build/`. Los módulos fuente no deben contener volcados Base64/hex de artwork binario y los headers C generados no deben subirse a Git.

## Por qué no se usa una sola dylib

Unir las dos dylibs reduciría un archivo en disco, pero acoplaría filtros de procesos y hooks privados que no tienen el mismo alcance. La separación actual es operativamente más simple: un fallo de sidebar no obliga a todos los procesos de barra a cargar esos hooks y la cobertura del Dock no tiene que añadirse al filtro de Unified.
