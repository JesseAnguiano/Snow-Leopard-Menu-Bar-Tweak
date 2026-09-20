# Contributing / Contribuir

## English

Contributions are welcome under the project's MIT License.

Keep changes scoped to one runtime responsibility. Structural refactors should be separate from behavior changes, and private AppKit/WindowServer hooks should include process guards, method-encoding checks and cleanup/fallback behavior when practical.

Before opening a pull request:

```bash
make release-check
```

When runtime code changes, also build on macOS Sequoia 15.x and manually test the affected surfaces. Sidebar-hook changes should additionally run `make test-sidebar`.

Do not commit compiled binaries, generated headers, local backups, machine-specific paths, logs containing private data, or assets/code you are not authorized to redistribute. Reference projects may be used to understand public behavior or architecture, but do not copy source unless its license explicitly permits the intended use and attribution requirements are satisfied.

Keep English and Spanish documentation synchronized under `docs/en/` and `docs/es/`.

## Español

Las contribuciones son bienvenidas bajo la licencia MIT del proyecto.

Mantén cada cambio dentro de una sola responsabilidad de runtime. Las refactorizaciones estructurales deben separarse de los cambios de comportamiento, y los hooks privados de AppKit/WindowServer deberían incluir guards de proceso, validación de encodings y limpieza/fallback cuando sea práctico.

Antes de abrir un pull request:

```bash
make release-check
```

Cuando cambie código de runtime, compila también en macOS Sequoia 15.x y prueba manualmente las superficies afectadas. Los cambios de sidebar deberían ejecutar además `make test-sidebar`.

No incluyas binarios compilados, headers generados, backups locales, rutas específicas de una máquina, logs con datos privados ni assets/código que no tengas autorización para redistribuir. Los proyectos de referencia pueden usarse para comprender comportamiento o arquitectura, pero no copies source salvo que su licencia permita el uso previsto y se cumplan sus requisitos de atribución.

Mantén sincronizada la documentación en inglés y español dentro de `docs/en/` y `docs/es/`.
