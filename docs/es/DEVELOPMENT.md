# Desarrollo

> [English version](../en/DEVELOPMENT.md)

## Requisitos

- macOS Sequoia 15.x
- Apple Silicon
- Xcode Command Line Tools
- Ammonia para pruebas de inyección real

## Flujo rápido

```bash
make check
make all
make test
```

Antes de publicar:

```bash
make release-check
```

`make help` muestra los targets principales.

## Estructura del source

```text
src/
├── common/       helpers de runtime + renderer compartido
├── include/      contratos internos
├── menubar/      material de menubar/comportamiento superior
│   └── rendering/ fragmentos de render enfocados
├── menus/        fondo/máscara/posición de popups
├── selection/    hooks de selección popup/Dock/sidebar
├── status/       status items del sistema/externos + iconos + IPC
└── wallpaper/    source del helper + plists
```

Las sondas de runtime para desarrollo viven en `tools/diagnostics/`; las regresiones deterministas permanecen en `tests/`.

## Política de compilación

`scripts/toolchain.sh` es la única fuente de verdad para los flags de los binarios propios. La política actual incluye:

- `arm64 + arm64e`;
- ARC + blocks;
- `-O2`;
- `-Wall -Wextra -Werror`;
- visibilidad oculta de símbolos C;
- `-fno-common`;
- `-dead_strip` del linker.

No agregues flags de optimización específicos por módulo sin una razón medida. LTO sigue siendo opt-in hasta validar con él toda la matriz de hooks privados en la build objetivo de macOS.

## Hooks privados

Antes de modificar un hook privado:

1. identifica el proceso y la superficie que realmente poseen el comportamiento;
2. inspecciona clase/selector en la build objetivo de macOS;
3. valida el encoding esperado cuando sea práctico;
4. reutiliza los helpers de `Runtime` en lugar de crear otro swizzler genérico;
5. conserva la implementación original;
6. haz idempotente la instalación;
7. prueba activación, deselection/cleanup y presentaciones repetidas;
8. prefiere callbacks/transiciones de estado a polling ilimitado;
9. agrega una regresión determinista cuando el comportamiento pueda aislarse de WindowServer.

Los proyectos de referencia pueden servir para comprender el comportamiento, pero la implementación de este repositorio debe escribirse de forma independiente salvo que una licencia compatible permita explícitamente reutilizar código.

## Assets

El artwork canónico vive en `assets/` y está fijado por `assets/manifest.json`. `scripts/generate-embedded-assets.py` valida tamaño/SHA-256 y genera `build/generated/SnowLeopardEmbeddedAssets.h` durante el build. Nunca incluyas el header generado en Git.

## Debug

El logging a archivo está desactivado por defecto. Actívalo sólo para diagnóstico con:

```bash
SNOW_LEOPARD_MENU_BAR_DEBUG=1
```

Usa `SLLog(...)` y elimina datos privados antes de compartir logs.

## Alcance de pruebas

`make test` cubre invariantes deterministas de render/layout/rendimiento. `make test-sidebar` ejecuta el harness opcional de sidebar después de compilar. Ninguno demuestra por sí solo el comportamiento real de WindowServer/tracking de menús.

Las pruebas manuales deberían incluir Finder, App Store, una app Cocoa normal, menús contextuales, menús del Dock, Control Center, Reloj, Spotlight, status items de terceros y, cuando sea posible, varios displays/wallpapers.
