# Publicación en GitHub

> [English version](../en/PUBLISHING.md)

Antes del primer push público, revisa `LICENSE`, `SECURITY.md` y la nota de derechos de assets en `ASSETS.md`. La licencia MIT cubre el código del proyecto; no concede automáticamente derechos sobre artwork o material de referencia ajeno.

Validación recomendada antes del push:

```bash
make release-check
```

Después, en la build objetivo de macOS Sequoia, ejecuta también el build completo y las pruebas manuales:

```bash
make all
```

No incluyas `build/`, `dist/`, dylibs/apps/packages compilados, headers generados, logs locales, backups ni rutas específicas de una máquina. `scripts/audit-repository.py` forma parte de `make release-check` y busca fugas comunes de privacidad/rutas/metadata.

Un primer push típico:

```bash
git init
git add .
git commit -m "Initial public source import"
git branch -M main
git remote add origin git@github.com:YOUR-USER/Snow-Leopard-Menu-Bar-Tweak.git
git push -u origin main
```

Para distribuir binarios, crea el `.pkg` desde un commit etiquetado con `make package` y sube el paquete de `dist/` a GitHub Releases. Indica en las notas la build de macOS probada, arquitecturas y limitaciones conocidas.
