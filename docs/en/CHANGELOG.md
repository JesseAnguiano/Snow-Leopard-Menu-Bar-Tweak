# Changelog

> [Versión en español](../es/CHANGELOG.md)

## Repository-built PKG workflow — September 12, 2026

- Added `Build-Package.command` and `make package` for generating a self-contained Installer package from the current source tree.
- The package builder reuses the normal runtime/helper builds so source installs and release packages cannot silently diverge.
- The generated package contains precompiled runtime components, so the destination Mac does not need Xcode or Command Line Tools.
- Simplified the package staging and `postinstall` paths while preserving signature checks, protected Ammonia installation, user preference rollback, helper backup/restore, and LaunchAgent setup.

## Asset metadata privacy cleanup — September 11, 2026

- Removed document/XMP metadata from all 58 embedded PDF artwork files, including legacy local filesystem paths and author/creator fields from the original source files.
- Verified every cleaned PDF renders pixel-for-pixel identically to its pre-cleanup version at 300 dpi.
- Preserved PNG/TIFF technical image data because those files contain no personal metadata.
- Regenerated all affected manifest byte sizes and SHA-256 hashes and added a project check that rejects PDF metadata/path markers in future assets.

## Repository layout cleanup — September 11, 2026

- Simplified the repository root to the user-facing files plus `assets/`, `docs/`, `scripts/`, `src/`, and `tests/`.
- Moved both Ammonia blacklists to the repository root, matching the distribution style used by small Ammonia tweaks.
- Moved the wallpaper helper source under `src/wallpaper/` and menu-bar render fragments under `src/menubar/rendering/`.
- Shortened implementation/header filenames because their directories already provide the feature context. Public/runtime symbol names and installed dylib/helper names are unchanged.
- Renamed `resources/` to `assets/`, reduced documentation pointer files, and moved asset provenance notes into the language-specific documentation.
- This is a source-tree/readability change only; runtime behavior and installation destinations are unchanged.

## Unified logging compile fix — September 11, 2026

- Made `SLLog` a variadic macro so Objective-C message expressions containing `stringWithFormat:` commas are reconstructed correctly by the C preprocessor.
- Replaced the remaining legacy `AppendLog` calls in rendering includes with `SLLog`, preserving debug-only file I/O.
- Added project checks that reject a non-variadic `SLLog` definition or legacy `AppendLog` calls before the macOS build step.

## BlueSelection compile fix — September 11, 2026

- Restored the local `SetBoolFn` function-pointer typedef in `SidebarSelection.m` after the BlueSelection translation-unit split.
- Fixes the Clang `unknown type name 'SetBoolFn'` build failure without changing sidebar runtime behavior.
- Added a project consistency check for unresolved custom `*Fn` function-pointer aliases across Objective-C translation units.

## Installer compatibility fix — September 11, 2026

- Fixed the embedded-asset generator for the Python 3.9 runtime commonly provided through Xcode Command Line Tools.
- Replaced the newer `Path.write_text(..., newline=...)` call with the older-compatible `Path.open(..., newline=...)` path.
- No runtime tweak behavior or asset bytes were changed.

## Architecture/maintainability refactor — current source

- Reorganized runtime source by responsibility: `common/`, `menubar/`, `menus/`, `status/`, and `selection/`.
- Split BlueSelection into independent menu-selection and sidebar-selection translation units while keeping a single BlueSelection dylib.
- Established one runtime owner per visual surface: Unified owns top-menu/status-item selection; BlueSelection owns popup/context/Dock/sidebar selection.
- Replaced duplicated blue-gradient implementations with `SelectionRenderer`, including physical 1-pixel edge rules.
- Centralized reusable Objective-C runtime/ABI/process guards and debug logging in `Runtime`.
- Removed the duplicate popup-selection pipeline from the popup-background module.
- Removed unnecessary runtime resolver/dlopen paths used only to reach duplicated selection renderers.
- Moved binary artwork out of Objective-C/Base64/generated tracked headers and into canonical files under `assets/`.
- Added a single 63-entry embedded-asset manifest (61 status icons + 2 Apple-menu PNGs) with byte-size/SHA-256 verification and deterministic build-time header generation.
- Removed unrelated font manipulation from this project; application/system typography is outside its responsibility.
- Centralized project/install constants in `scripts/project-config.sh` and reduced binary verification to stable capability markers in `scripts/markers.sh`.
- Build optimization is `-O2` plus `-dead_strip`; aggressive LTO remains intentionally disabled pending target-macOS runtime validation.
- Production diagnostic file I/O remains disabled unless `SNOW_LEOPARD_MENU_BAR_DEBUG=1` is explicitly set.
- Renamed remaining internal historical “Extras” terminology to `SystemStatusItems` where it was not needed for legacy cleanup.

## Sidebar regression fix

- Restored the stable native-first sidebar path after an older selection strategy accidentally re-entered a GitHub package.
- Keeps post-original Finder deselection synchronization and the App Store selected-text vibrancy compatibility path.
- Build/install/verify capability checks prevent packaging the older incompatible strategy by accident.

## Repository distribution work

- Uses the neutral wallpaper helper identifier `com.snowleopardmenubar.wallpapersource`.
- Includes migration/cleanup for older helper/tweak installation names without embedding developer-specific identifiers.
- Provides bilingual user/developer documentation, `Install.command`, `Uninstall.command`, Ammonia blacklists, and GitHub checks.
- Uses the MIT License.

## Historical calibrated behavior

The current implementation preserves the accepted Snow Leopard color/material calibration, lower-shadow behavior, right-side status layout work, embedded status icon behavior, Finder/App Store sidebar fixes, and universal `arm64 + arm64e` build target. Obsolete experimental pipelines should be recovered from Git history rather than copied back into production source.
