# Contributing / Contribuir

## English

Thanks for your interest in Snow Leopard Menu Bar Tweak.

Contributions are made under the project's **MIT License**. By submitting a contribution, you agree that it may be distributed under the terms in `LICENSE`.

For code changes, keep structural refactors separate from behavior changes, run `./scripts/check-project.sh` and the relevant regression suite (`make test`, plus `make test-sidebar` for sidebar-hook changes), and describe the exact macOS build and hardware used for runtime testing. Changes involving private AppKit hooks should include the observed method encoding/class assumptions and a fallback or guard when practical.

Do not commit compiled binaries, local backups, machine-specific paths, or proprietary assets that cannot be redistributed.

When changing documentation, keep the English and Spanish versions synchronized under `docs/en/` and `docs/es/`.

## Español

Gracias por tu interés en Snow Leopard Menu Bar Tweak.

Las contribuciones se realizan bajo la **Licencia MIT** del proyecto. Al enviar una contribución, aceptas que pueda distribuirse bajo los términos indicados en `LICENSE`.

Para cambios de código, mantén las refactorizaciones estructurales separadas de los cambios de comportamiento, ejecuta `./scripts/check-project.sh` y la suite de regresión correspondiente (`make test`, además de `make test-sidebar` para cambios de hooks de sidebar), e indica la versión/build exacta de macOS y el hardware usado para las pruebas en runtime. Los cambios que afecten hooks privados de AppKit deberían incluir los encodings/clases observados y, cuando sea práctico, un fallback o guard.

No incluyas binarios compilados, respaldos locales, rutas específicas de una máquina ni recursos propietarios que no puedan redistribuirse.

Cuando modifiques documentación, mantén sincronizadas las versiones en inglés y español dentro de `docs/en/` y `docs/es/`.
