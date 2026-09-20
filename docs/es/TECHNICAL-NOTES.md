# Notas técnicas

> [English version](../en/TECHNICAL-NOTES.md)

Estas notas describen únicamente la implementación actual. Los experimentos obsoletos pertenecen al historial de Git, no a la guía de producción.

## Entorno compatible

El runtime está limitado a macOS Sequoia 15.x en Apple Silicon. Las dylibs se compilan como `arm64 + arm64e` y dependen de comportamiento privado de AppKit/CoreAnimation/WindowServer, por lo que una versión mayor posterior no se considera compatible hasta volver a validar clases, selectores y supuestos del compositor.

## Render de la barra de menús

`src/menubar/MenuBar.m` controla el material de la menubar y la selección superior. El helper del wallpaper publica sólo el payload de la franja superior que necesitan los procesos inyectados. El módulo aplica transferencia de color calibrada, material y sombra inferior sin obligar a cada app a decodificar el wallpaper completo.

## Menús popup

`src/menus/MenuPopup.m` controla la superficie del popup, máscara, esquinas redondeadas, posición de submenus e integración de la sombra externa. Intencionalmente no controla la selección del popup.

`src/selection/MenuSelection.m` controla la selección popup/context/Dock, incluido el texto e indicador del padre de un submenu. Los píxeles azules provienen del renderer compartido.

## Renderer de selección

`src/common/SelectionRenderer.m` contiene la única implementación del gradiente azul clásico. Las reglas del borde usan un píxel físico (`1 / backingScaleFactor`) para mantener consistencia entre Retina y no Retina.

Los módulos deciden si una superficie está seleccionada; no mantienen copias privadas de la paleta.

## Selección de sidebar

`src/selection/SidebarSelection.m` sigue una estrategia native-first: permite que AppKit cree el material de selección, identifica el contenido cromático, aplica el renderer clásico compartido y sincroniza el color del contenido/texto seleccionado. Sólo usa un fallback local de fila cuando el material nativo no puede adaptarse de forma segura.

La deselection de Finder sigue el estado resultante de la llamada original de AppKit. App Store tiene una ruta de compatibilidad estrecha para vibrancy del texto seleccionado.

## Status items y artwork

Los status items del sistema, los externos y el reemplazo de artwork están separados en archivos distintos para mantener independientes identidad de proceso, interacción y búsqueda de assets.

El artwork canónico vive en `assets/`, se valida con `assets/manifest.json` y se embebe durante el build. Las dylibs no requieren una carpeta de recursos en runtime.

## Helpers de runtime

`Runtime` centraliza guards de OS/proceso, identidad exacta de procesos, lookup de métodos/ivars propios, validación de ABI, materialización de métodos heredados, instalación/restauración de overrides y logging de diagnóstico desactivado por defecto.

La mecánica genérica de hooks no debe reimplementarse dentro de módulos de funciones.

## Política de optimización

El proyecto optimiza para comportamiento predecible, no para reducir líneas artificialmente:

- un propietario por superficie;
- un renderer compartido;
- lookups de runtime centralizados;
- actualizaciones por eventos/estado cuando sea posible;
- `-O2`, visibilidad oculta de símbolos C y `dead_strip`;
- sin I/O de archivo incondicional en hot paths;
- sin LTO hasta validarlo contra toda la matriz de hooks privados en la build objetivo de macOS.

## Límites de verificación

Las pruebas estáticas y regresiones deterministas pueden validar scripts, assets, matemática de render, invariantes de layout y algunos supuestos de rendimiento. No pueden demostrar el comportamiento real de WindowServer/tracking de menús. La validación final requiere inyectar las dylibs en la build objetivo de macOS.
