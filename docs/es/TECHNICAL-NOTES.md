# Notas técnicas

> [English version](../en/TECHNICAL-NOTES.md)

Estas notas describen la **arquitectura actual**. Los experimentos históricos no se conservan como guía activa de implementación; para pipelines obsoletos debe consultarse el historial de Git.

## 1. Entorno soportado

El runtime está protegido para macOS Sequoia 15.x en Apple Silicon. Ambas dylibs inyectadas se compilan como `arm64 + arm64e` y usan comportamiento privado de AppKit/CoreAnimation, por lo que una futura versión de macOS debe considerarse no soportada hasta volver a validar clases/selectores/layers relevantes.

## 2. Render de barra de menús

`src/menubar/MenuBar.m` controla el material de barra y la selección superior. El helper de wallpaper publica el payload superior; Core aplica la ruta calibrada de transferencia/material y la sombra inferior separada sin hacer que cada proceso inyectado decodifique el wallpaper completo.

El item Apple conserva su geometría/artwork específicos del proyecto. El proyecto **no** controla la tipografía de las aplicaciones.

## 3. Menús popup

`src/menus/MenuPopup.m` controla únicamente fondo/máscara/esquinas/posición del popup. Intencionalmente no instala un pipeline de selección competidor.

El estado de selección popup/contextual/Dock pertenece a `src/selection/MenuSelection.m`, mientras los píxeles azules reales salen del renderer compartido.

## 4. Renderer azul de selección

`src/common/SelectionRenderer.m` contiene el único gradiente azul exacto de 35 stops usado por todas las superficies soportadas. Las reglas de borde se dibujan como un píxel físico (`1 / backingScaleFactor`) y no como un punto lógico, para mantener consistencia en Retina y no Retina.

Los módulos funcionales deciden cuándo una vista está seleccionada; no deben mantener copias privadas de la paleta.

## 5. Selección de sidebar/source list

`src/selection/SidebarSelection.m` usa una estrategia native-first:

1. dejar que AppKit cree/actualice el material normal de selección;
2. localizar el `NSVisualEffectView` del material de selección activo;
3. localizar el sublayer cromático sin asumir un índice fijo;
4. reemplazar ese contenido cromático con el gradiente Snow Leopard;
5. sincronizar el color del contenido seleccionado;
6. usar un fallback local por fila sólo cuando no se puede usar el material nativo.

La deselección de Finder se sincroniza después de la implementación original de AppKit de `setSelected:`, usando el estado real resultante de la fila. El hook no mantiene artificialmente una fila seleccionada.

App Store tiene una compatibilidad muy acotada para `AppStoreKit.DynamicTypeTextField`: las filas seleccionadas desactivan temporalmente vibrancy en ese campo y restauran su valor original al deseleccionar.

## 6. Status items

Los status items propiedad del sistema están aislados en `SystemStatusItems.m`; los pertenecientes a aplicaciones/terceros se manejan en `ExternalStatusItems.m`. El reemplazo de iconos está aislado de nuevo en `StatusIcons.m`.

Esta separación evita mezclar sondeo de hardware/estado, interacción de menú, identidad de proceso y lookup de artwork dentro de Core.

El proyecto conserva rutas de refresco acotadas/justificadas y evita polling perpetuo de alta frecuencia cuando puede usarse un evento o transición de estado.

## 7. Artwork embebido

El repositorio contiene 61 archivos canónicos de status icons y 2 PNG del menú Apple. `assets/manifest.json` fija tamaño y SHA-256 de los 63 assets. El generador verifica el manifest antes de emitir los arrays temporales de bytes C que consume el build de Unified.

No se versiona en Git un header generado de múltiples megabytes y la dylib no requiere una carpeta externa de recursos en runtime.

## 8. Helpers de runtime y hooks

`Runtime` centraliza:

- guards de OS/proceso;
- comprobaciones exactas de identidad de Control Center/SystemUIServer/Spotlight;
- lookup de métodos/ivars propios;
- comparación de encodings;
- materialización de métodos heredados;
- instalación/restauración de overrides;
- detección de ventana de menú superior;
- logging de diagnóstico habilitable sólo en desarrollo.

Es intencional: la mecánica de hooks no debe reimplementarse de manera distinta en cada módulo funcional.

## 9. Diagnóstico

El log a archivo está desactivado salvo que `SNOW_LEOPARD_MENU_BAR_DEBUG=1` exista en el entorno del proceso objetivo. Las rutas calientes deben usar `SLLog(...)` y no escrituras incondicionales.

## 10. Política de optimización

La optimización actual de build es `-O2` más `-dead_strip` del linker. Una optimización de programa completo más agresiva no es automáticamente mejor para un tweak que depende de puntos de entrada privados del runtime Objective-C. LTO sólo debe considerarse después de compilar y probar toda la matriz de hooks en el build objetivo de Sequoia.

La optimización de source prioriza eliminar dueños duplicados, renderers duplicados, recorridos repetidos del runtime, ramas muertas y datos binarios pegados como texto. No considera formato comprimido como una optimización.

## 11. Límites de verificación

Los tests estáticos/de regresión pueden validar lógica determinista de imagen/layout, manifests, scripts, markers de capacidades y algunas invariantes de rendimiento. No pueden demostrar comportamiento real de WindowServer/tracking de menús. La validación final debe hacerse en macOS con las dylibs realmente inyectadas.
