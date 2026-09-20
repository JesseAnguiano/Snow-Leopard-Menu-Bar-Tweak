# Changelog

> [Versión en español](../es/CHANGELOG.md)

## Unreleased

### Runtime

- Keeps the stable menu-bar, popup geometry/shadow, BlueSelection, submenu indicator/text and sidebar behavior.
- Keeps menu-bar and BlueSelection process scope separated into two dylibs.
- Centralizes shared compiler policy and hides non-required C symbols while preserving Objective-C runtime metadata.
- Simplifies shared object-ivar lookup without changing its public contract.

### Repository

- Adds a dependency-free repository privacy/release audit.
- Separates developer-only runtime probes from deterministic regression tests.
- Removes obsolete calibration/experiment scripts from the release tree; Git history remains the source for historical experiments.
- Adds `.editorconfig`, `SECURITY.md` and clearer architecture/development/publishing documentation.
- Strengthens checks for generated output, stale paths, private metadata and source ownership.

### Build

- Keeps binary capability markers exported so linker dead stripping cannot remove build-verification identifiers.
- Uses one shared `scripts/toolchain.sh` policy for the injected dylibs and wallpaper helper.
- Keeps `-O2`, strict warnings, Apple Silicon `arm64 + arm64e`, hidden C-symbol visibility and linker dead stripping.
- Keeps LTO disabled until it is validated against the complete private-hook matrix on the target macOS build.
