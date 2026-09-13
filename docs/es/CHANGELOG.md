# Historial de cambios

> [English version](../en/CHANGELOG.md)

## Flujo de PKG generado desde el repositorio — 12 de septiembre de 2026

- Añadió `Build-Package.command` y `make package` para generar un instalador autocontenido desde el source actual.
- El builder reutiliza las compilaciones normales del runtime/helper para evitar diferencias silenciosas entre la instalación desde source y los paquetes de release.
- El paquete generado contiene los componentes de runtime ya compilados, por lo que el Mac de destino no necesita Xcode ni Command Line Tools.
- Simplificó el staging del paquete y el `postinstall` conservando verificación de firmas, instalación protegida en Ammonia, rollback de preferencias, backup/restauración del helper y configuración del LaunchAgent.

## Limpieza de privacidad de metadata de assets — 11 de septiembre de 2026

- Eliminó metadata de documento/XMP de los 58 archivos PDF embebidos, incluidas rutas locales heredadas y campos de autor/creador de los archivos fuente originales.
- Verificó que cada PDF limpio se renderice píxel por píxel igual que su versión previa a 300 dpi.
- Conservó los datos técnicos de PNG/TIFF porque esos archivos no contienen metadata personal.
- Regeneró tamaños y hashes SHA-256 afectados del manifest y añadió una comprobación que rechaza metadata/rutas en PDFs futuros.

## Limpieza de estructura del repositorio — 11 de septiembre de 2026

- Simplificó la raíz del repositorio a los archivos orientados al usuario más `assets/`, `docs/`, `scripts/`, `src/` y `tests/`.
- Movió ambas blacklists de Ammonia a la raíz, siguiendo el estilo de distribución de tweaks pequeños de Ammonia.
- Movió el helper de wallpaper a `src/wallpaper/` y los fragmentos de render de la barra a `src/menubar/rendering/`.
- Acortó nombres de archivos de implementación/headers porque sus carpetas ya aportan el contexto de la función. Los símbolos de runtime y los nombres instalados de dylibs/helper no cambian.
- Renombró `resources/` a `assets/`, eliminó archivos puntero redundantes de documentación y movió las notas de procedencia de assets a la documentación por idioma.
- Es únicamente un cambio de árbol de source/legibilidad; el comportamiento de runtime y los destinos de instalación no cambian.

## Fix de compilación del logging Unified — 11 de septiembre de 2026

- Convirtió `SLLog` en un macro variádico para que el preprocesador C reconstruya correctamente expresiones Objective-C con comas de `stringWithFormat:`.
- Sustituyó las llamadas `AppendLog` heredadas restantes en los includes de renderizado por `SLLog`, conservando el I/O a archivo sólo en modo debug.
- Añadió comprobaciones del proyecto que rechazan una definición no variádica de `SLLog` o llamadas `AppendLog` antiguas antes de llegar al build de macOS.

## Fix de compilación de BlueSelection — 11 de septiembre de 2026

- Restauró el typedef local de puntero a función `SetBoolFn` en `SidebarSelection.m` después de separar BlueSelection en unidades de compilación.
- Corrige el fallo de Clang `unknown type name 'SetBoolFn'` sin cambiar el comportamiento de runtime de la sidebar.
- Añadió una comprobación de consistencia para aliases personalizados `*Fn` no declarados en las unidades Objective-C.

## Fix de compatibilidad del instalador — 11 de septiembre de 2026

- Corrigió el generador de assets embebidos para el runtime Python 3.9 que suele proporcionar Xcode Command Line Tools.
- Sustituyó la llamada más reciente `Path.write_text(..., newline=...)` por la ruta compatible `Path.open(..., newline=...)`.
- No cambió el comportamiento del tweak ni los bytes de los assets.

## Refactor de arquitectura/mantenibilidad — source actual

- Reorganizó el source de runtime por responsabilidad: `common/`, `menubar/`, `menus/`, `status/` y `selection/`.
- Separó BlueSelection en unidades de compilación independientes para selección de menús y selección de sidebars, manteniendo una sola dylib BlueSelection.
- Estableció un solo dueño de runtime por superficie: Unified controla selección de menú superior/status items; BlueSelection controla popup/contextual/Dock/sidebar.
- Sustituyó implementaciones duplicadas del gradiente azul por `SelectionRenderer`, incluyendo reglas de borde físicas de 1 píxel.
- Centralizó helpers reutilizables de runtime/ABI/procesos y logging en `Runtime`.
- Eliminó el pipeline duplicado de selección dentro del módulo de fondo de popup.
- Eliminó resolvers/dlopen innecesarios usados únicamente para llegar a renderers de selección duplicados.
- Sacó el artwork binario de Objective-C/Base64/headers generados versionados y lo convirtió en archivos canónicos bajo `assets/`.
- Añadió un único manifest de 63 assets embebidos (61 status icons + 2 PNG del menú Apple) con verificación de tamaño/SHA-256 y generación determinista del header durante el build.
- Eliminó manipulación de tipografía no relacionada; la tipografía del sistema/aplicaciones queda fuera de la responsabilidad de este proyecto.
- Centralizó constantes del proyecto/instalación en `scripts/project-config.sh` y redujo la verificación binaria a markers de capacidades estables en `scripts/markers.sh`.
- La optimización de build usa `-O2` más `-dead_strip`; LTO agresivo permanece desactivado hasta validarlo en runtime sobre el macOS objetivo.
- El I/O de diagnóstico a archivo permanece apagado salvo que se defina explícitamente `SNOW_LEOPARD_MENU_BAR_DEBUG=1`.
- Renombró la terminología interna histórica “Extras” a `SystemStatusItems` donde no era necesaria para limpieza legacy.

## Fix de regresión de sidebar

- Restauró la ruta native-first estable de sidebar después de que una estrategia antigua entrara accidentalmente en un paquete de GitHub.
- Conserva la sincronización de deselección post-original de Finder y la compatibilidad de vibrancy del texto seleccionado de App Store.
- Las comprobaciones de capacidades de build/install/verify evitan empaquetar accidentalmente la estrategia antigua incompatible.

## Trabajo de distribución del repositorio

- Usa el identificador neutral del helper de wallpaper `com.snowleopardmenubar.wallpapersource`.
- Incluye migración/limpieza de nombres antiguos de helper/tweak sin incrustar identificadores personales del desarrollador.
- Incluye documentación bilingüe para usuarios/desarrolladores, `Install.command`, `Uninstall.command`, blacklists de Ammonia y checks de GitHub.
- Usa la Licencia MIT.

## Comportamiento calibrado histórico

La implementación actual conserva la calibración aceptada de color/material Snow Leopard, comportamiento de sombra inferior, trabajo de layout de status items derechos, iconos de estado embebidos, fixes de sidebar de Finder/App Store y target universal `arm64 + arm64e`. Los pipelines experimentales obsoletos deben recuperarse desde el historial de Git y no copiarse de vuelta al source de producción.
