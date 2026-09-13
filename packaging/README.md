# PKG packaging

[English](#english) · [Español](#español)

## English

The repository can build a self-contained macOS Installer package from the current source tree.

Run either:

```bash
./Build-Package.command
```

or:

```bash
make package
```

The builder performs the normal project checks, compiles both universal dylibs (`arm64 + arm64e`), builds `SnowLeopardWallpaperSource.app`, then embeds those already-compiled artifacts in a script-only `.pkg` under `dist/`.

The **machine building the package** needs the Xcode Command Line Tools because it compiles the project. The **machine installing the generated package does not**: the `.pkg` only copies/verifies the precompiled dylibs and helper, installs the Ammonia blacklists, installs/starts the LaunchAgent, and applies the menu-bar layout defaults.

Default output:

```text
dist/Snow-Leopard-Menu-Bar-Tweak-1.0.0.pkg
```

Set a package version without editing files:

```bash
SL_PACKAGE_VERSION=1.2.0 ./scripts/build-package.sh
```

For a Developer ID Installer signed package, provide an installer identity already present in the builder Mac's keychain:

```bash
SL_INSTALLER_IDENTITY="Developer ID Installer: Example (TEAMID)" \
SL_PACKAGE_VERSION=1.2.0 \
./scripts/build-package.sh
```

Without `SL_INSTALLER_IDENTITY`, the builder creates an unsigned local package suitable for local testing. Signing the package is separate from the ad-hoc code signatures used by the injected runtime binaries.

Do not commit `build/`, `dist/`, dylibs, app bundles, or generated `.pkg` files. Releases should be built from a clean source checkout.

## Español

El repositorio puede generar un paquete instalador de macOS autocontenido a partir del source actual.

Ejecuta:

```bash
./Build-Package.command
```

o:

```bash
make package
```

El builder ejecuta las comprobaciones normales del proyecto, compila las dos dylibs universales (`arm64 + arm64e`), compila `SnowLeopardWallpaperSource.app` y después incluye esos componentes **ya compilados** dentro de un `.pkg` de instalación en `dist/`.

El **Mac que crea el paquete** sí necesita Xcode Command Line Tools porque está compilando el proyecto. El **Mac que instala el `.pkg` generado no los necesita**: el instalador sólo copia/verifica las dylibs y el helper precompilados, instala las blacklists de Ammonia, instala/inicia el LaunchAgent y aplica los valores de layout de la barra.

Salida predeterminada:

```text
dist/Snow-Leopard-Menu-Bar-Tweak-1.0.0.pkg
```

Puedes cambiar la versión sin editar archivos:

```bash
SL_PACKAGE_VERSION=1.2.0 ./scripts/build-package.sh
```

Para firmar el paquete con Developer ID Installer, usa una identidad de instalador que ya exista en el llavero del Mac donde se compila:

```bash
SL_INSTALLER_IDENTITY="Developer ID Installer: Example (TEAMID)" \
SL_PACKAGE_VERSION=1.2.0 \
./scripts/build-package.sh
```

Si no defines `SL_INSTALLER_IDENTITY`, se genera un paquete local sin firma de Developer ID, adecuado para pruebas locales. La firma del `.pkg` es independiente de las firmas ad-hoc de los binarios de runtime inyectados.

No subas al repositorio `build/`, `dist/`, dylibs, bundles `.app` ni paquetes `.pkg` generados. Los releases deben crearse desde un checkout limpio del source.
