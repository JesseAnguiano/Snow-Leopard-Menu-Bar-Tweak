# Documentation / Documentación

The repository keeps user entry points at the root and separates runtime code, assets, tooling, tests and diagnostics by responsibility.

La raíz contiene los puntos de entrada para el usuario y separa el runtime, assets, herramientas, pruebas y diagnósticos por responsabilidad.

```text
Snow-Leopard-Menu-Bar-Tweak/
├── .github/                 GitHub workflow + templates
├── assets/                  Canonical artwork + manifest
├── docs/                    English/Spanish documentation
├── packaging/               Source-only Installer templates
├── scripts/                 Build/install/audit tooling
├── src/                     Runtime + wallpaper-helper source
├── tests/                   Deterministic regressions/harnesses
├── tools/diagnostics/       Developer-only runtime probes
├── Install.sh
├── Build-Package.sh
├── Uninstall.sh
├── Makefile
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
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
