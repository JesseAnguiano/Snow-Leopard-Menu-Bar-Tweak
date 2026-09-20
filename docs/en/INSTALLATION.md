# Installation

> [Versión en español](../es/INSTALLATION.md)

## Requirements

Runtime requirements:

- macOS Sequoia 15.x
- Apple Silicon Mac
- Ammonia installed and working

Xcode Command Line Tools are required only for **building from source** or **building a `.pkg` from the repository**. A prebuilt `.pkg` does not need them on the destination Mac.

## Install a prebuilt `.pkg`

1. Make sure Ammonia is already installed.
2. Open the release `.pkg` with macOS Installer.
3. Authenticate when Installer asks.
4. Reopen affected apps or log out/in after installation if necessary.

The package contains both precompiled universal dylibs (`arm64 + arm64e`), both Ammonia blacklists, and the compiled wallpaper helper. It does not invoke `clang`, `xcrun`, or the macOS SDK on the destination Mac.

## Build and install directly from source

1. Install Xcode Command Line Tools (`xcode-select --install`).
2. Download and extract the repository/source archive.
3. Double-click `Install.sh`.
4. If Gatekeeper blocks it, right-click the file and choose **Open**.
5. Enter the administrator password only when Terminal requests it.

The source installer validates the repository, builds both universal dylibs, builds the wallpaper helper, installs the Ammonia blacklists, signs/verifies installed components, and starts the helper.

Do **not** run `Install.sh` with `sudo`; it elevates only the operations that write to Ammonia's protected directory.

## Build an installable `.pkg` from the repository

On a development/build Mac with Xcode Command Line Tools:

```bash
./Build-Package.sh
```

or:

```bash
make package
```

The builder compiles the same runtime used by `Install.sh` and writes a self-contained package to `dist/`. The resulting `.pkg` can then be copied to another compatible Sequoia Apple Silicon Mac and installed there without Command Line Tools.

See [`packaging/README.md`](../../packaging/README.md) for package versioning and optional Developer ID Installer signing.

## Runtime destinations

```text
/private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib
/private/var/ammonia/core/tweaks/libSnowLeopardMenuBarUnified.dylib.blacklist
/private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib
/private/var/ammonia/core/tweaks/libSnowLeopardBlueSelection.dylib.blacklist

~/Library/Application Support/SnowLeopardMenuBar/SnowLeopardWallpaperSource.app
~/Library/LaunchAgents/com.snowleopardmenubar.wallpapersource.plist
```

Source files and canonical artwork are build inputs and are not copied individually into Ammonia.

During each build, `scripts/generate-embedded-assets.py` verifies `assets/manifest.json` and produces the temporary header `build/generated/SnowLeopardEmbeddedAssets.h`. The generated header is compiled into the Unified dylib and is not an installed runtime resource.

## Manual build

```bash
./scripts/check-project.sh
./scripts/build.sh
./scripts/build-wallpaper-source.sh
```

The resulting local products are placed under `build/`.

## Manual installation scripts

Install everything:

```bash
./scripts/install.sh
```

Install only the Unified dylib after building it:

```bash
./scripts/install-unified-only.sh
```

Install/update only BlueSelection after building it:

```bash
./scripts/install-blueselection.sh
```

Install/reload only the wallpaper helper:

```bash
./scripts/install-wallpaper-source.sh
```

## Verification

```bash
make verify
```

or:

```bash
./scripts/verify.sh
./scripts/verify-blueselection.sh
```

Verification checks the installed files, code signatures, `arm64 + arm64e` architectures, filters, and stable capability markers.

## After updating dylibs

Already-running processes keep the code that was loaded when they started. Reopen affected applications. For system menu-bar processes, logging out and back in is the safest way to ensure every process loads the same build.

## Uninstall

Double-click `Uninstall.sh`. It removes only components owned by this project; it does not uninstall Ammonia.
