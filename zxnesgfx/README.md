# ZXNESGFX — motor gráfico para ports de NES a ZX Spectrum 48K

Biblioteca para ZX Spectrum 48K (Z80, z88dk z80asm) pensada para portar juegos de NES con **scroll
horizontal y mirroring vertical**: los dos nametables uno al lado del otro. Es el caso de Super Mario
Bros y de la mayoría de plataformas de scroll lateral.

Hace tres cosas:

1. **Fondo con scroll alineado a carácter**, organizado igual que los nametables del NES. El port
   escribe las columnas nuevas donde las escribe el juego original y mueve la cámara igual que el
   scroll del NES.
2. **Redibujado por diferencias:** solo se pintan las celdas de pantalla que cambian.
3. **Sprites alineados a celda**, sin mezcla, con el color de papel del fondo, más un HUD en la fila 0.

Nació para el port de *Frog Prince* (`docs/` del proyecto tiene los estudios y las mediciones) y
toma ideas de `zxgfx.asm`: comparación con lo mostrado y tiles dinámicos en dos bancos.

```
lib/zxnesgfx/
  zxnesgfx.asm        el motor (un solo fichero, se incluye una vez)
  tools/zxconv.py     PNG -> datos: tilesets, metasprites, fuente
  tools/zxpal.py      paleta ZX y conversión NES -> ZX
  tools/mktap.py      binarios por sección -> imagen + .tap con cargador BASIC
  tools/scr2png.py    volcado de pantalla (6912 bytes) -> PNG
  tools/harness/      emulador Z80 mínimo para medir T-states y ejecutar pruebas
  tools/timing.py     resumen de tiempos por tick (marcadores del harness)
  tools/prof.py       perfil de T-states por rutina (con el .map de z80asm)
  test/               autotest de la biblioteca
```

---

## 1. El modelo

### Celdas y códigos

Todo lo que se ve son **celdas de 8×8** (la rejilla de atributos del Spectrum). Cada celda de la
pantalla muestra un **código** de 1 byte, que significa «este bitmap con este atributo»:

| Código | Significado | Cómo se pinta |
|---|---|---|
| `$00` | fondo vacío (backdrop) | solo atributo (tinta = papel) |
| `$01..PLAIN` | otras celdas de un solo color | solo atributo |
| `PLAIN+1..$7F` | celdas con bitmap | atributo + 8 bytes |
| `$80..$BE`, `$C0..$FE` | celdas de sprite (dos bancos alternos) | atributo + 8 bytes del sprite |

Las celdas «planas» son el truco más rentable. Como su tinta es igual al papel, los píxeles que
queden en la celda no se ven y basta con escribir el atributo: 1 byte en vez de 9. Diseñar los
fondos con zonas de color plano abarata el scroll.

Un **tileset** (generado desde un PNG) define los códigos `$00..$7F` de un tipo de escenario y,
opcionalmente, una tabla **metatile → 4 códigos** (arriba-izquierda, arriba-derecha,
abajo-izquierda, abajo-derecha), como los metatiles de 16×16 de los juegos de NES.

### CELLMAP = los dos nametables

`CELLMAP` guarda el fondo como códigos: **64 columnas × 24 filas**.

- **Columnas:** las 64 columnas *son* los dos nametables de un juego con mirroring vertical. La
  columna `n` del nametable `$2000` es la columna `n` de CELLMAP y la columna `n` de `$2400` es la
  `32+n`.
- **Cámara:** `ng_cam_cell` es el scroll horizontal del NES / 8. Solo importan sus 6 bits bajos.
- **Filas:** las 24 filas son las filas de tiles del NES que decidas mostrar. El NES tiene 30 y el
  Spectrum 24, así que el port decide qué recorta (en Frog Prince: el marcador y la fila inferior
  de suelo).
- **Memoria:** cada fila ocupa 128 bytes y las columnas 0-31 se repiten en 64-95. Así la ventana
  de 32 columnas que empieza en cualquier columna es contigua en memoria y el bucle de comparación
  no tiene que comprobar el salto de 63 a 0.

Consecuencia práctica: **el port escribe el fondo exactamente donde lo escribe el juego original.**
Si el NES escribe una columna nueva en el nametable por delante del scroll, el port escribe esa
columna en la misma columna de CELLMAP, también por delante de la cámara.

### Redibujado por diferencias

`SHOWN` guarda el código que se ve en cada una de las 768 celdas. `ng_draw` hace una de dos cosas:

- **Comparación completa** (cuando la cámara ha cambiado de celda, o tras `ng_cls`): compara la
  ventana de 32×24 con SHOWN y pinta solo las celdas distintas. La comparación está desenrollada y
  cuesta unos 25 K T; cada celda pintada, unos 300 T (115 T si es plana).
- **Parcial** (cámara quieta): solo mira las celdas tocadas por sprites este tick o el anterior, y
  las cambiadas con `ng_put_cell`.

### Sprites

- **Sin mezcla:** los sprites van **alineados a celda** y no se mezclan con el fondo ni entre sí.
  Una celda de sprite muestra el bitmap del sprite con el **PAPER (y BRIGHT) de la celda de fondo**
  y la **INK del sprite**. Si la tinta coincide con el papel, se invierte (xor 7) para que no
  desaparezca.
- **Prioridad:** si dos sprites caen en la misma celda, el último dibujado sustituye al anterior.
  El orden de dibujo es la prioridad.
- **Detrás del fondo:** con `ng_spr_behind = 1` el sprite no se dibuja sobre celdas de fondo no
  vacías. Sirve para la prioridad «detrás del fondo» del NES (una planta que sale de un tubo).
- **Sin copias:** un código de sprite no copia el bitmap, solo apunta a él. Hay 63 celdas de
  sprite por tick; las que sobran se descartan.
- **Volteo:** horizontal, al vuelo, con una tabla de inversión de bits (de ahí que **IY esté
  reservado**).

### HUD

Las celdas de la fila 0 marcadas en `ng_hud_mask` no las toca el motor: ni el fondo ni los sprites.
Se pintan con `ng_hud_char`.

---

## 2. Correspondencia NES → Spectrum

| NES | ZXNESGFX |
|---|---|
| Nametables `$2000` y `$2400` (mirroring vertical) | CELLMAP, columnas 0-31 y 32-63 |
| Scroll X | `ng_cam_cell` = scroll / 8 (`ng_set_camera`) |
| Escribir una columna de metatiles en el nametable | `ng_put_mt_column` (media columna de metatiles: izquierda o derecha) |
| Escribir un tile o un metatile suelto (bloque roto, moneda) | `ng_put_cell`, `ng_put_metatile` |
| Paleta de fondo + atributo de 16×16 | el atributo va dentro del código (tileset por tipo de escenario) |
| Sprites de OAM de 8×8 en cualquier píxel | metasprites alineados a celda (`ng_draw_meta`) |
| Prioridad de sprite detrás del fondo | `ng_spr_behind` |
| Barra de estado (split de scroll) | HUD en la fila 0 |
| NMI a 60 Hz | interrupción a 50 Hz que cuenta frames; un *tick* = N frames (`ng_wait_tick`) |

El scroll es por celdas (8 px). La lógica del juego puede seguir trabajando en píxeles: basta con
convertir las posiciones a celdas al dibujar.

---

## 3. Mapa de memoria y configuración

Valores por defecto. Para cambiarlos, define el símbolo antes del `include`. Todos los buffers deben
empezar en una página (byte bajo `$00`).

| Símbolo | Por defecto | Tamaño | Contenido |
|---|---|---|---|
| `NG_CM` | `$C000` | 3 KB | CELLMAP (24 filas × 128 bytes) |
| `NG_SHOWN` | `$CC00` | 768 B | código mostrado en cada celda (3 páginas = 3 tercios) |
| `NG_TATTR` | `$CF00` | 256 B | atributo de cada código |
| `NG_MT` | `$D200` | 1 KB | metatile → código: páginas TL, TR, BL, BR |
| `NG_REV` | `$D600` | 256 B | bytes con los bits invertidos (volteo de sprites) |
| `NG_TG` | `$D800` | 2 KB | bitmaps de los códigos, **una página por fila de píxeles**: fila `r` del código `c` en `NG_TG + r*256 + c`. Las mitades altas de las páginas 0-2 guardan las fichas de los sprites |
| `NG_IM2TAB`, `NG_ISRVEC` | `$FE00`, `$FDFD` | 260 B | tabla y vector de IM 2 |
| `NG_MT_ROWS` | 12 | — | filas de metatiles por columna que se muestran (×2 = filas de celdas) |

En total son unos 7,5 KB en `$C000-$DFFF` más la tabla IM 2. El código de la biblioteca ocupa unos
3 KB.

---

## 4. Uso: el bucle de un tick

```z80
        org $8000
        call ng_setup_im2       ; contador de frames a 50 Hz (IM 2)
        call ng_init            ; tabla de volteo; IY queda reservado
        ld hl,hud_cols
        call ng_hud_cells       ; columnas de la fila 0 que son HUD
        ld hl,mi_fuente
        ld (ng_font),hl
        ld hl,tileset_nivel1
        call ng_load_tileset
        ; ... escribir las columnas iniciales (ng_put_mt_column) ...
        call ng_cls             ; pantalla al color de fondo, redibujado completo

bucle:  ld a,3
        call ng_wait_tick       ; tick de 3 frames (16,7 Hz)
        call ng_draw            ; mostrar lo preparado en el tick anterior
        call ng_spr_begin       ; quitar los sprites del tick anterior
        ; --- lógica del juego: mover la cámara, escribir columnas y bloques
        ld hl,(scroll_x)        ; en píxeles
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        call ng_set_camera
        ; --- sprites de este tick, de atrás hacia delante
        ld hl,spr_enemigo_0
        ld b,fila
        ld c,columna
        call ng_draw_meta
        jp bucle

hud_cols: defb 0,1,2,29,30,31,$FF
        include "zxnesgfx.asm"
```

Orden obligatorio:
- `ng_draw` justo después de `ng_wait_tick`, mientras el haz está en el borde superior.
- `ng_spr_begin` **antes** de tocar el fondo o la cámara.
- Los sprites, al final.

---

## 5. Referencia

Salvo que se indique otra cosa, las rutinas destruyen AF, BC, DE y HL y respetan IX e IY.

### Frames y ticks
| Rutina / variable | Entrada | Efecto |
|---|---|---|
| `ng_setup_im2` | — | instala IM 2 con un ISR que cuenta frames en `ng_frames`; habilita interrupciones. Si tu juego tiene su propio ISR, incrementa `ng_frames` en él y no llames a esta |
| `ng_wait_tick` | A = frames por tick | espera a que pasen A frames desde la llamada anterior; deja en `ng_tick_used` los frames que tardó el tick anterior |
| `ng_frames` (dw) | — | contador de frames |

### Inicialización y tilesets
| Rutina | Entrada | Efecto |
|---|---|---|
| `ng_init` | — | tabla de volteo, `IY = NG_REV` (reservado desde ahí), limpia `ng_hud_mask` |
| `ng_load_tileset` | HL = tileset | carga bitmaps, atributos y tabla de metatiles; ajusta el límite de celdas planas; `ng_back_attr` = atributo del código 0 |
| `ng_cls` | — | borra la pantalla con `ng_back_attr` y fuerza un redibujado completo |
| `ng_invalidate` | — | fuerza un redibujado completo sin borrar |

### Cámara y fondo
| Rutina / variable | Entrada | Efecto |
|---|---|---|
| `ng_set_camera` | HL = columna de celda absoluta del borde izquierdo | si cambia, el próximo `ng_draw` compara toda la ventana |
| `ng_cam_cell` (dw), `ng_need_full` (db) | — | cámara actual; 1 = comparación completa pendiente |
| `ng_put_mt_column` | HL = `NG_MT_ROWS` ids de metatile, E = columna de CELLMAP (0-63), A = 0 mitad izquierda / 1 derecha | escribe una columna de celdas (y su espejo). Pensada para columnas **no visibles**, por delante de la cámara, como hace el NES |
| `ng_put_cell` | E = columna (0-63), B = fila (0-23), A = código | cambia una celda en cualquier momento entre `ng_spr_begin` y los sprites; si es visible, se repinta en el próximo `ng_draw` |
| `ng_put_metatile` | E = columna de metatile (0-31), B = fila de metatile, A = id | igual, para las 4 celdas de un metatile |

### Sprites
| Rutina / variable | Entrada | Efecto |
|---|---|---|
| `ng_spr_begin` | — | restaura el fondo bajo los sprites del tick anterior y empieza la lista nueva (alterna el banco de códigos) |
| `ng_draw_meta` | HL = frame, B = fila superior, C = columna izquierda (con signo: puede salirse por los lados) | dibuja un metasprite. Destruye todo salvo IX e IY |
| `ng_spr_cell` | B = fila, C = columna, HL = 8 bytes, A = tinta (0-7) | una celda suelta |
| `ng_spr_flip` (db) | — | 1 = voltear horizontalmente los siguientes sprites |
| `ng_spr_behind` (db) | — | 1 = no dibujar sobre celdas de fondo no vacías |

### HUD
| Rutina / variable | Entrada | Efecto |
|---|---|---|
| `ng_hud_cells` | HL = lista de columnas de la fila 0, terminada en `$FF` | las marca como HUD (llamar antes de `ng_cls`) |
| `ng_hud_mask` (32 bytes) | — | 1 = esa columna de la fila 0 es HUD |
| `ng_font` (dw) | — | dirección de la fuente (8 bytes por carácter) |
| `ng_hud_char` | A = carácter, C = columna, B = atributo | pinta un carácter en la fila 0, directamente en pantalla |

---

## 6. Formatos de datos (los genera `tools/zxconv.py`)

**Tileset** (`build_tileset`):
```
label:  defb n            ; códigos (1..128)
        defb plain        ; último código plano
        defb ...          ; n*8 bytes de bitmap (código a código, fila superior primero)
        defb ...          ; n atributos
        defb id,TL,TR,BL,BR   ; por metatile (opcional)
        defb $FF
```

**Metasprite** (`build_sprites`), por frame:
```
spr_<nombre>:    defw spr_<nombre>_0, spr_<nombre>_1, ...
spr_<nombre>_0:  defb w,h                 ; tamaño en celdas
                 ; w*h celdas, por filas: defb tinta, 8 bytes   o   defb $FF (vacía)
```

**Fuente** (`build_font`): 8 bytes por carácter.

### Reglas de los PNG

- **Fondos:** rejilla de casillas de 16×16, 16 por fila. La casilla (fila, col) es el metatile
  `fila*16+col`.
  - La casilla `$00` debe ser de un solo color: es el fondo vacío (código 0).
  - Cada celda de 8×8 lleva colores ZX exactos, **2 como máximo** y un solo BRIGHT (el negro vale
    para los dos).
  - Con dos colores, el **más oscuro es PAPER** (`paper_rule='dark'`: orden negro < azul < rojo <
    magenta < verde < cian < amarillo < blanco) o el color de fondo (`'backdrop'`). Con la regla
    `dark` los sprites, que llevan su tinta sobre el papel, se ven bien si son claros.
  - Las celdas de un solo color son planas.
  - Las celdas idénticas comparten código.
- **Sprites:** `<nombre>_<W>x<H>.png`, frames en orden de presentación de izquierda a derecha, fondo
  transparente, **una tinta por celda**.
- **Juegos sin metatiles** (que escriben tiles sueltos): usa una casilla por tile o ignora la tabla
  de metatiles y escribe con `ng_put_cell`.

`tools/zxpal.py` tiene una tabla NES → ZX para hacer la primera conversión desde la ROM.

---

## 7. Herramientas

```
python tools/mktap.py juego.tap nombre 8000 juego_data.bin@6000 juego_code.bin@8000
python tools/scr2png.py pantalla.scr pantalla.png 2
zxrun -load juego.img@6000 -entry 8000 -frames 1000 [-dump prefijo 100,200] [-out stream.bin] [-prof] [-space 300 600]
python tools/timing.py log.txt
python tools/prof.py prof.bin juego.map 30
```

**`mktap.py`:** une las secciones de z80asm (`-b` genera un `.bin` por `SECTION`) en una imagen
contigua y crea un `.tap` con el cargador `CLEAR inicio-1: LOAD ""CODE: RANDOMIZE USR entrada`.

**Harness `zxrun`:** compila con `gcc -O2 -o zxrun zxrun.c z80.c`. Usa el núcleo Z80 de superzazu,
licencia MIT, incluida.
- Emula 64 KB de RAM, la interrupción de 50 Hz y la contención de la ULA (aproximada).
- `OUT ($FF),a` registra un marcador con su T-state; el valor `$EE` termina.
- `OUT ($FD),a` añade un byte al fichero `-out`.
- `-prof` guarda los T-states por dirección.
- `-space a b` simula ESPACIO pulsado entre esos frames.

**`timing.py`:** espera estos marcadores por tick: 1 = inicio, 5/6 = diff parcial/completo,
2 = pantalla hecha, 3 = lógica hecha, 4 = sprites hechos.

---

## 8. Rendimiento medido (Frog Prince)

Tick de 3 frames = 209.664 T. Scroll continuo a 7,5 px por tick y 28 celdas de sprite:

| | Media | p95 |
|---|---|---|
| Comparar + pintar con scroll (exteriores) | 74 K | 81 K |
| Comparar + pintar con scroll (todas las áreas) | 76 K | 100 K |
| Sprites (28 celdas) | 19–21 K | 23–25 K |
| Tick sin scroll | 51–55 K | 57–75 K |

Una celda de sprite cuesta unos 560 T al componerla y unos 300 T al pintarla.

---

## 9. Adaptarlo a otro juego de NES

1. Decide qué 24 filas del nametable se ven y dónde va el HUD.
2. Haz un PNG de metatiles (o tiles) por tipo de escenario y genera los tilesets con `zxconv.py`.
3. Donde el juego original escribe columnas en el nametable, llama a `ng_put_mt_column` (o a
   `ng_put_cell` por tile) con la misma columna.
4. Donde actualiza el scroll, llama a `ng_set_camera` con scroll / 8.
5. Donde cambia un bloque del fondo durante el juego, llama a `ng_put_metatile` / `ng_put_cell`.
6. Convierte los sprites del OAM en metasprites y dibújalos con `ng_draw_meta` en posiciones
   redondeadas a celda.

## 10. Autotest

```
cd lib/zxnesgfx/test
python test_putcell.py      (necesita ZASM y ZXRUN)
```

Comprueba la pantalla vacía, `ng_put_cell` y `ng_put_metatile` con redibujado parcial, y la cámara
pasando por las columnas espejo.
