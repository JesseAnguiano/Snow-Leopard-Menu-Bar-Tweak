# Recursos Aqua originales — Verificación

> [English version](../en/ASSETS.md)

ORIGINAL SNOW LEOPARD AQUA ASSETS — VERIFICACIÓN
================================================

Archivos suministrados
----------------------
ArtFile.bin
  5,946,480 bytes
  SHA-256 1ca5d946725e5815cb4fc34ef45006aab7220ef1f8e89128e65a5754359b4ec5

SArtFile.bin
  811,436 bytes
  SHA-256 62eb745beaafa0a24111c0ac3b3452cebfda4aeec5e56e51b054ae2d62f778b2

Extras.rsrc
  5,425,538 bytes
  SHA-256 a0866d6cf2d48fac7787e8cf9e90264071642c0d39aa809636e7d478016a9197

Extras2.rsrc
  5,425,538 bytes
  SHA-256 19b1c4e4ca09407af081f607e0d97e0ea65ebf9ef44ecd4aa66d6cd025ca6557

Resultado de la inspección
--------------------------
ArtFile.bin contiene 3,324 descriptores visuales. El descriptor
menubar-bar declara 22 x 22 puntos/píxeles, pero sus 484 píxeles ARGB son
transparentes (0,0,0,0). Las entradas menubar-selectiontab y
menubar-search-searchselectiontab también son transparentes. No deben
incrustarse como PNG visibles.

SArtFile.bin contiene en el índice 102 un recurso CoreUI de 1 x 21 con esta
rampa de muestras:

  239, 228, 224, 220, 216, 212, 208, 204, 201, 196, 193,
  189, 186, 183, 179, 175, 172, 169, 166, 161, 158

Esas muestras pertenecen al recurso, pero no equivalen directamente a la
opacidad blanca final: en 10.6 CoreUI y WindowServer todavía componen el
recurso con el escritorio. Usarlas como alpha puro en Sequoia blanquea el
fondo demasiado. La adaptación usa la conservación de color y la curva final
medidas en la captura 10.6, tras alinear el fondo Aurora y normalizar los
perfiles de color a sRGB:

  La adaptación actual dibuja esta curva sobre la franja superior del wallpaper
  activo, la escala al tamaño de pantalla, aplica gaussiano 9 y ajusta brillo
  0.02 y contraste 1.15.
  Los experimentos aditivos/filtros privados anteriores no forman parte del
  pipeline de producción.
  fila superior: 0.92437
  cuerpo: 0.83703, 0.82264, 0.80843, 0.79406, 0.77953,
          0.76442, 0.74930, 0.73393, 0.71861, 0.70359,
          0.68852, 0.67296, 0.65747, 0.64130, 0.62398,
          0.60799, 0.59552, 0.58004, 0.56290, 0.54446

La adaptación de Sequoia usa esa curva dentro de la geometría nativa que
entrega AppKit. La manzana normal se dibuja a 24.1290322581 x
23.1578947368; la seleccionada a 22 x 22; desplazamiento horizontal 0.5 y
centrado vertical. Los iconos de estado visibles usan escala 1.0 dentro de sus
bounds nativos.

La adaptación Retina reserva exactamente un píxel físico para el brillo
superior (0.5 puntos a escala 2x) y aplica el cuerpo al resto de la altura
nativa. No añade separador inferior, así que no aparece una costura entre la
barra y la ventana en 1440 x 900 Retina.

El desenfoque WindowServer se resuelve dinámicamente. Si no está disponible,
la película sigue siendo transparente, sin sustituirla por un relleno opaco.

Los binarios originales no se copian al sistema: el tweak contiene únicamente
los datos y métricas necesarios, evitando una dependencia externa en tiempo de
ejecución.

Nota sobre derechos
-------------------
La licencia MIT de este repositorio cubre el código del proyecto; no concede automáticamente derechos sobre artwork de terceros o de la plataforma. Antes de publicar o redistribuir artwork extraído/de referencia, confirma que tienes los derechos o permisos necesarios.
