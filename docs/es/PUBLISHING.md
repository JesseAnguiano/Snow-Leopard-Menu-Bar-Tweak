# Publicar en GitHub

> [English version](../en/PUBLISHING.md)

Este repositorio se distribuye bajo la **Licencia MIT**. Revisa [`LICENSE`](../../LICENSE) antes de publicar y conserva el aviso de copyright y de permiso en las copias o partes sustanciales del software.

Un primer push típico sería:

```bash
git init
git add .
git commit -m "Initial public source import"
git branch -M main
git remote add origin git@github.com:YOUR-USER/Snow-Leopard-Menu-Bar-Tweak.git
git push -u origin main
```

No añadas `build/` ni dylibs compiladas a commits normales. Para distribuir binarios, compila desde un commit etiquetado y sube los artefactos a un GitHub Release. Registra en las notas del release el commit exacto, la versión de macOS probada, arquitecturas y limitaciones conocidas.

Comprobaciones recomendadas antes de hacer push:

```bash
./scripts/check-project.sh
./tests/run-menubar-regressions.sh
```

El segundo comando requiere macOS Sequoia y Xcode Command Line Tools.
