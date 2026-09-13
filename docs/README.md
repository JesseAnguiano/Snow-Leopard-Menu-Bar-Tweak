# Documentation / Documentación

The repository keeps the root intentionally small. User-facing entry points stay at the top level; implementation, assets, tooling, tests, and detailed documentation live in dedicated directories.

La raíz del repositorio se mantiene deliberadamente pequeña. Los puntos de entrada para el usuario quedan arriba; la implementación, assets, herramientas, pruebas y documentación detallada viven en directorios separados.

## Repository layout / Estructura del repositorio

```text
Snow-Leopard-Menu-Bar-Tweak/
├── .github/                 GitHub workflows and templates
├── assets/                  Canonical artwork + manifest
├── docs/                    English and Spanish documentation
├── scripts/                 Build, install and verification tools
├── src/                     Runtime source code
├── tests/                   Regression and diagnostic tests
├── Install.command          Guided installer
├── Uninstall.command        Guided uninstaller
├── Makefile                 Developer shortcuts
├── README.md                User-facing project overview
├── LICENSE                  Canonical MIT license
├── CONTRIBUTING.md          Contribution guide
├── libSnowLeopardMenuBarUnified.dylib.blacklist
└── libSnowLeopardBlueSelection.dylib.blacklist
```

## English

- [Installation](en/INSTALLATION.md)
- [Architecture](en/ARCHITECTURE.md)
- [Development](en/DEVELOPMENT.md)
- [Technical notes](en/TECHNICAL-NOTES.md)
- [Asset verification](en/ASSETS.md)
- [Changelog](en/CHANGELOG.md)
- [Publishing](en/PUBLISHING.md)

## Español

- [Instalación](es/INSTALLATION.md)
- [Arquitectura](es/ARCHITECTURE.md)
- [Desarrollo](es/DEVELOPMENT.md)
- [Notas técnicas](es/TECHNICAL-NOTES.md)
- [Verificación de assets](es/ASSETS.md)
- [Historial de cambios](es/CHANGELOG.md)
- [Publicación](es/PUBLISHING.md)
- [Traducción informativa de la licencia MIT](es/LICENSE.md)
