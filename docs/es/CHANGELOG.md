# Historial de cambios

> [English version](../en/CHANGELOG.md)

## Sin publicar

### Runtime

- Conserva el comportamiento estable de menubar, geometría/sombra de popups, BlueSelection, texto/indicador de submenus y sidebars.
- Mantiene separados el alcance de procesos de menubar y BlueSelection en dos dylibs.
- Centraliza la política de compilación y oculta símbolos C no necesarios sin afectar metadata Objective-C de runtime.
- Simplifica el lookup compartido de ivars de objeto sin cambiar su contrato.

### Repositorio

- Añade una auditoría de privacidad/release sin dependencias externas.
- Separa las sondas de runtime para desarrolladores de las regresiones deterministas.
- Elimina scripts obsoletos de calibración/experimentos del árbol de release; el historial de Git conserva el trabajo histórico.
- Añade `.editorconfig`, `SECURITY.md` y documentación más clara de arquitectura/desarrollo/publicación.
- Refuerza los checks de output generado, rutas antiguas, metadata privada y responsabilidades del source.

### Build

- Mantiene exportados los marcadores de capacidad para que `dead_strip` no elimine los identificadores usados para verificar las dylibs.
- Usa una sola política `scripts/toolchain.sh` para las dylibs y el helper de wallpaper.
- Mantiene `-O2`, warnings estrictos, `arm64 + arm64e`, visibilidad oculta de símbolos C y `dead_strip`.
- LTO permanece desactivado hasta validarlo contra toda la matriz de hooks privados en la build objetivo de macOS.
