# Instalación

> [English version](../en/INSTALLATION.md)

## Requisitos

Requisitos de runtime:

- macOS Sequoia 15.x
- Mac con Apple Silicon
- Ammonia instalado y funcionando

Xcode Command Line Tools sólo son necesarios para **compilar desde source** o **crear un `.pkg` desde el repositorio**. Un `.pkg` precompilado no los necesita en el Mac de destino.

## Instalar un `.pkg` precompilado

1. Asegúrate de que Ammonia ya esté instalado.
2. Abre el `.pkg` del release con Installer de macOS.
3. Autentícate cuando Installer lo solicite.
4. Reabre las apps afectadas o cierra/inicia sesión después de instalar si es necesario.

El paquete contiene las dos dylibs universales (`arm64 + arm64e`) ya compiladas, las dos blacklists de Ammonia y el helper de wallpaper compilado. No ejecuta `clang`, `xcrun` ni necesita el SDK de macOS en el Mac de destino.

## Compilar e instalar directamente desde source

1. Instala Xcode Command Line Tools (`xcode-select --install`).
2. Descarga y descomprime el repositorio/source.
3. Haz doble clic en `Install.sh`.
4. Si Gatekeeper lo bloquea, haz clic derecho y selecciona **Abrir**.
5. Introduce la contraseña de administrador sólo cuando Terminal la solicite.

El instalador desde source valida el repositorio, compila las dos dylibs universales, compila el helper de wallpaper, instala las blacklists de Ammonia, firma/verifica los componentes instalados e inicia el helper.

No ejecutes `Install.sh` con `sudo`; eleva únicamente las operaciones que escriben en el directorio protegido de Ammonia.

## Crear un `.pkg` instalable desde el repositorio

En un Mac de desarrollo/build con Xcode Command Line Tools:

```bash
./Build-Package.sh
```

o:

```bash
make package
```

El builder compila el mismo runtime que usa `Install.sh` y genera un paquete autocontenido dentro de `dist/`. Después puedes copiar ese `.pkg` a otro Mac Apple Silicon compatible con Sequoia e instalarlo allí sin Command Line Tools.

Consulta [`packaging/README.md`](../../packaging/README.md) para cambiar la versión del paquete y, opcionalmente, firmarlo con Developer ID Installer.

## Destinos de runtime

```text
/private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib
/private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib.blacklist
/private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib
/private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib.blacklist

~/Library/Application Support/SnowLeopardMenuBar/SnowLeopardWallpaperSource.app
~/Library/LaunchAgents/com.snowleopardmenubar.wallpapersource.plist
```

Los archivos fuente y el artwork canónico son entradas de compilación y no se copian individualmente a Ammonia.

En cada build, `scripts/generate-embedded-assets.py` verifica `assets/manifest.json` y produce el header temporal `build/generated/SnowLeopardEmbeddedAssets.h`. Ese header se compila dentro de la dylib Unified y no es un recurso de runtime instalado.

## Compilación manual

```bash
./scripts/check-project.sh
./scripts/build.sh
./scripts/build-wallpaper-source.sh
```

Los productos locales resultantes se guardan dentro de `build/`.

## Scripts de instalación manual

Instalar todo:

```bash
./scripts/install.sh
```

Instalar únicamente la dylib Unified después de compilarla:

```bash
./scripts/install-unified-only.sh
```

Instalar/actualizar únicamente BlueSelection después de compilarla:

```bash
./scripts/install-blueselection.sh
```

Instalar/recargar únicamente el helper de wallpaper:

```bash
./scripts/install-wallpaper-source.sh
```

## Verificación

```bash
make verify
```

o:

```bash
./scripts/verify.sh
./scripts/verify-blueselection.sh
```

La verificación comprueba archivos instalados, firmas, arquitecturas `arm64 + arm64e`, filtros y markers de capacidades estables.

## Después de actualizar dylibs

Los procesos ya abiertos conservan el código que cargaron al arrancar. Reabre las aplicaciones afectadas. Para procesos de barra del sistema, cerrar sesión y volver a entrar es la forma más segura de que todos carguen el mismo build.

## Desinstalación

Haz doble clic en `Uninstall.sh`. Elimina únicamente componentes propiedad de este proyecto; no desinstala Ammonia.
