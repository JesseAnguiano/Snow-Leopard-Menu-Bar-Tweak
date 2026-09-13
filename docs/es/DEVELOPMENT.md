# Desarrollo

> [English version](../en/DEVELOPMENT.md)

## Empieza aquí

Lee [`src/README.md`](../../src/README.md) antes de modificar código de runtime. Ahí se define qué módulo controla cada superficie visual. Muchas regresiones de este tipo de tweak aparecen al añadir un segundo dueño, no por el renderer en sí.

## Requisitos

- macOS Sequoia 15.x
- Apple Silicon
- Xcode Command Line Tools
- Ammonia para pruebas de runtime

Las comprobaciones del repositorio pueden ejecutarse sin instalar el tweak:

```bash
./scripts/check-project.sh
```

## Compilación

```bash
make all
```

o por componentes:

```bash
./scripts/build.sh
./scripts/build-wallpaper-source.sh
```

Las dylibs inyectadas apuntan a `arm64 + arm64e`, usan `-O2`, `-Wall -Wextra -Werror` y enlazan con `-dead_strip`. LTO/optimización de programa completo no se activa hasta validar su comportamiento con hooks privados en el build objetivo de macOS.

## Crear un paquete instalador

Para crear un Installer autocontenido a partir del source actual:

```bash
make package
```

Esto ejecuta primero las comprobaciones/compilación normales y después incluye las dylibs resultantes y el helper de wallpaper dentro de un `.pkg` de instalación en `dist/`. El Mac de destino no necesita Command Line Tools. Los detalles del empaquetado están en [`packaging/README.md`](../../packaging/README.md).

## Organización del source

```text
src/
├── common/       helpers de runtime + renderer compartido de selección
├── include/      headers/contratos internos compartidos
├── menubar/      material de barra/comportamiento de menú superior
│   └── rendering/ fragmentos de wallpaper + sombra inferior
├── menus/        fondo/máscara/posición de popup
├── selection/    hooks de selección popup/Dock/sidebar
├── status/       status items del sistema/externos + iconos + IPC
└── wallpaper/    source y plists del helper de wallpaper
```

Es preferible añadir un archivo pequeño en la responsabilidad correcta que hacer que un módulo grande conozca otra superficie no relacionada.

## Añadir o cambiar un hook privado

Antes de guardar un cambio de hook:

1. identifica los procesos exactos que lo necesitan;
2. identifica clase/selector exactos en runtime;
3. registra/valida el encoding esperado;
4. usa `SLInstallOverrideHook` o el helper más específico que ya use ese módulo;
5. conserva la implementación original;
6. haz que la instalación sea idempotente;
7. evita polling si existe una transición/callback de estado;
8. prueba selección y deselección/limpieza;
9. añade o actualiza un test de regresión cuando el comportamiento pueda ejercitarse fuera de WindowServer.

No copies helpers genéricos del runtime Objective-C dentro de módulos funcionales.

## Render de selección

Todos los píxeles azules clásicos deben pasar por `SelectionRenderer`. La paleta de 35 stops, creación sRGB y reglas físicas de 1 píxel pertenecen ahí. Los módulos funcionales deciden **cuándo y dónde** aparece la selección, no cómo se implementa el gradiente.

## Artwork embebido

El artwork canónico se guarda como archivos normales dentro de `assets/`. El manifest es `assets/manifest.json`.

Para añadir o reemplazar un asset embebido:

1. coloca el archivo canónico dentro de `assets/`;
2. actualiza su entrada del manifest (`name`, `path`, `symbol`, `sha256`, `size`);
3. ejecuta `./scripts/check-project.sh`;
4. compila normalmente.

`scripts/build.sh` ejecuta `scripts/generate-embedded-assets.py`, que verifica cada entrada y genera `build/generated/SnowLeopardEmbeddedAssets.h`. Nunca edites ni subas ese header generado.

## Markers de capacidades

`scripts/markers.sh` contiene únicamente un conjunto pequeño de capacidades binarias estables usadas por build/install/verify. No uses frases de logs de diagnóstico como API o marker de versión. Los detalles de comportamiento pertenecen a tests y documentación.

## Configuración

Rutas de instalación, versión mayor soportada de macOS, nombres de tweaks, defaults de layout y nombres de limpieza legacy viven en `scripts/project-config.sh`. No introduzcas rutas específicas de una máquina en source o scripts.

## Log de diagnóstico

El logging de producción está desactivado por defecto. Define:

```bash
SNOW_LEOPARD_MENU_BAR_DEBUG=1
```

sólo en el entorno de un proceso mientras diagnosticas comportamiento. Evita I/O a archivo incondicional en rutas calientes.

## Tests

Ejecuta la suite determinista de regresión:

```bash
make test
```

Después de compilar BlueSelection, el harness opcional de sidebar es:

```bash
make test-sidebar
```

La suite cubre comportamiento determinista de render/layout/rendimiento. No sustituye pruebas manuales de composición de WindowServer, Spaces, múltiples pantallas, Control Center, Finder, App Store o tracking real de menús.

Smoke test manual recomendado después de cambios en hooks:

- seleccionar/deseleccionar sidebar de Finder y navegar a una carpeta que no esté en sidebar;
- selección/texto de sidebar de App Store;
- selección de sidebar de Música/Ajustes del Sistema;
- menús popup/contextuales de aplicaciones;
- menú contextual del Dock;
- menú Apple/selección superior;
- Clock, Spotlight, Control Center y status items de terceros;
- múltiples pantallas/wallpapers si están disponibles.

## Política de estilo y optimización

Optimiza buscando **un dueño, un renderer, una implementación de helpers de runtime y menos recorridos de runtime**. No optimices minificando, mezclando responsabilidades no relacionadas ni borrando guards sólo para reducir líneas. Un guard legible alrededor de una API privada cuesta menos que un crash en todos los procesos inyectados.
