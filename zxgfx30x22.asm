; ============================================================================
;  ZXGFX - tile + pixel-sprite graphics engine for the ZX Spectrum 48K (Z80)
;  Assembler: z88dk z80asm.
; ============================================================================
;
;  WHAT IT IS
;  ----------
;  A small, fast, flicker-free "tile engine with attribute-clash-aware sprites"
;  that never draws directly to the screen while compositing.  Everything is
;  expressed as 8x8 CELLS (the Spectrum attribute grid, 32 x 24 cells):
;
;     * A scrolling background of 8x8 tiles lives in a 32 x 28 "world map"
;       (one byte per tile code).  It wraps around in both axes (a torus), so
;       endless scrolling needs no special cases.
;     * Sprites are 1-bit bitmaps with ONE ink colour each, placed at ANY pixel
;       position.  The engine cuts each sprite into 8x8 pieces, turns every
;       piece into a temporary ("dynamic") tile, ORs it with whatever
;       background tile is below, and writes the dynamic tile code into the
;       WANT buffer exactly as if it were a background tile.
;     * One diff pass (diff_draw) compares WANT (what should be on screen)
;       with SHOWN (what is on screen) and redraws ONLY the cells that
;       changed.  Because backgrounds and sprites go through the same path,
;       there is no sprite erase/restore step, no XOR, no flicker, and the
;       cost per tick is proportional to what moved, not to the screen size.
;
;  Measured in the game (3.5 MHz 48K, 16.7 ticks/s): idle 2 frames/tick, a full
;  scroll about 3 frames/tick, with 46 sprite cells on screen.
;
;
;  FILES
;  -----
;     zxgfx.asm   this file.  `include` it ONCE in your program (see PROGRAM
;                 SKELETON).  It contains code AND its working variables, so
;                 it must be placed in RAM (it is not position dependent; the
;                 only fixed addresses are the buffers listed below).
;     demo.asm    a ~150 line example that scrolls a world and moves two
;                 overlapping pixel-positioned sprites.  Read it first.
;
;
;  YOU PROVIDE (labels referenced by this file)
;  --------------------------------------------
;     tile_gfx_src   GFX_NTILES * 8 bytes: bitmaps of static tiles $00.. ,
;                    8 bytes per tile (top row first).  Tile $00 must be the
;                    EMPTY tile (all zeros).
;     tile_cls       GFX_NTILES bytes: the "class" / attribute of each tile:
;                       $80        empty/background tile        -> attribute
;                                  with ink = paper (invisible ink)
;                       $81        "top bevel" tile             -> ink white
;                       $82        "side bevel" tile            -> ink cyan
;                       anything   a fixed ZX attribute byte
;                       else       (bit 6 bright, bits 5-3 paper, bits 2-0 ink)
;                    $81/$82 are an example of per-round palette tricks (see
;                    set_round_attrs); if you don't need them, never use
;                    those two values and set_round_attrs just copies your
;                    attributes.  Do NOT use attribute bytes $80,$81,$82 as
;                    fixed attributes (flash+paper... values) - they are
;                    reserved class codes.
;     (GFX_NTILES is $A0 by default: static tiles are codes $00-$9F.)
;     font           64 * 8 bytes: 8x8 characters ASCII 32..95 (space .. '_'),
;                    only needed by the text routines (section 8).
;     die_tiles etc. are NOT needed: game-object code is not part of this file.
;
;
;  MEMORY MAP (all addresses are overridable with IFNDEF, see below)
;  -----------------------------------------------------------------
;  Every buffer except the sprite ones must start on a 256-byte page.  The
;  defaults are the ones the game uses (high RAM, above your code):
;
;     SPRBUF   $C000  3 pages (768 B)  sprite shift buffer, one plane per page
;     SHTAB    $D000  16 pages (4 KB)  lookup tables  v>>s  and  v<<(8-s)
;     TILEGFX  $E000  256 * 8  (2 KB)  tile bitmaps in RAM: static tiles are
;                                      copied here by init_tiles; dynamic
;                                      sprite tiles are written into codes
;                                      $A0-$CD and $D0-$FD
;     TILEATTR $E800  256 B            attribute byte of every tile code
;     WORLD    $F000  32 * 28 = 896 B  background map (row-major, 32/row)
;     WANT     $F400  768 B            desired screen: 1 tile code per cell
;     SHOWN    = WANT + $300  768 B    what is on the screen right now
;                                      (derived: MUST be WANT+$300)
;     IM2TABLE $FE00  257 B            interrupt vector table (all $FD)
;     ISRADDR  $FDFD  3 B              "jp isr" lives here (IM2 vector $FDFD)
;
;  Your code, stack, and your own data can live anywhere else; keep them out
;  of those ranges.  The 48K layout leaves $6000-$BFFF (24 KB) for code/data.
;
;
;  TILE CODE SPACE (one byte per cell in WANT / WORLD)
;  ---------------------------------------------------
;     $00        empty tile (must be blank)
;     $01-$9F    your static tiles
;     $A0-$CD    dynamic sprite tiles, bank 0   (46 of them)
;     $D0-$FD    dynamic sprite tiles, bank 1   (46 of them)
;     $CE-$CF    free for you; $CF (BORDER_TILE) is used by init_window for
;                the blank border columns
;     $FE        used in SHOWN as "invalid, force a redraw"
;     $FF        in WANT: "cell is a sprite cell, drawn elsewhere"; never
;                actually stored by this engine except as an internal flag
;
;  The two banks are alternated on every tick (spr_begin).  This is what makes
;  the diff work: a cell showing sprite tile $A3 this tick and $D3 last tick is
;  different, so it is always redrawn; the codes of the sprites that vanished
;  are restored to the background by build_want.  Hard limit: 46 sprite cells
;  per tick (spr_cell silently ignores extra cells, i.e. the farthest sprites
;  drawn last just disappear).  A 16x24 sprite at an arbitrary position costs
;  up to 3 x 4 = 12 cells.  Static tiles must therefore be < $A0.
;
;
;  SCREEN LAYOUT
;  -------------
;  The 32 x 24 cell screen is split in a fixed way:
;     row 0         free for your HUD  (drawn by you directly into video RAM)
;     rows 1..22    the scrolling PLAYFIELD (22 rows)
;     row 23        free for your HUD / time bar
;     col 0 and 31  always blank border columns (not scrolled, no sprites)
;     cols 1..30    the playfield (30 columns)
;  build_want copies world columns view_x+1..view_x+30 and rows
;  view_y+1..view_y+22 (all modulo the 32 x 28 world) into WANT rows 1..22,
;  cols 1..30.  Sprites are clipped to the same window by spr_cell.  The
;  reason for the blank columns: sprites can start on any pixel, so a sprite
;  entering from the side would need a partial cell outside the playfield.
;  If you need a different window, edit the constants marked "WINDOW" in
;  build_want and spr_cell (they are few).
;
;
;  PER-TICK PROTOCOL (the order matters; see demo.asm for working code)
;  --------------------------------------------------------------------
;     once:   setup_im2, init_tiles, init_shift, load WORLD, set view_x/y,
;             a = round attribute -> set_round_attrs, a = (bg_attr) -> cls_attr,
;             then "prime": build_want / spr_begin / (draw sprites).
;     loop:   wait_frames          - sync to the interrupt (frame pacing)
;             diff_draw            - put the frame prepared LAST iteration on
;                                    the screen.  Do this first, right after
;                                    the frame interrupt, so the beam has not
;                                    reached the cells yet (no tearing).
;             <your game logic>    - movement, collisions... (view_x/y too)
;             build_want           - restore the sprite-covered cells and,
;                                    if the view or world changed, rebuild
;                                    all of WANT
;             spr_begin            - start a sprite list (flips the bank)
;             draw_gfx/spr_*       - add the sprites (any number of calls)
;             jp loop
;     Whenever you modify WORLD or want WANT fully rebuilt, set (bw_dirty)=1.
;     Scrolling (changing view_x / view_y) is detected automatically.
;
;
;  PUBLIC ROUTINES
;  ---------------
;   setup_im2        di; installs a 50 Hz frame counter ISR (IM 2); ei.
;   wait_frames      A = frames to wait since the previous call (frame pacing)
;   init_tiles       copies static tile bitmaps into TILEGFX.        (once)
;   init_shift       builds the SHTAB shift tables.                  (once)
;   set_round_attrs  A = background (paper colour in bits 0-2, bright bit 6):
;                    builds TILEATTR for all static tiles; sets the variables
;                    bg_paper, bg_attr, top_attr, side_attr.
;   cls_attr         A = attribute: clears the screen, forces a full redraw.
;   build_want       see protocol above.
;   diff_draw        see protocol above.
;   spr_begin        begin the sprite list of this tick.
;   draw_gfx         HL = bitmap (2 bytes per pixel row, width 16 px), B = x
;                    and C = y in WORLD PIXELS (x 0..255, y 0..223, both
;                    wrapping like the world), A = number of rows (1..24),
;                    ink in (dg_ink).  Pixel-exact position, one colour.
;                    Clobbers everything.  Sprites wider than 16 px: call it
;                    several times with x offset by 16 and the matching half
;                    of the data (it is only the 16 px column that needs a 2
;                    byte stride).
;   spr_world        C = world col, B = world row, D = width (cells),
;                    E = height (cells), HL = cells (8 bytes each, row-major),
;                    A = ink.  Cell-aligned sprite in world cells.
;   spr_screen       same but C/B are SCREEN cell col/row.
;   spr_cell         C = screen col, B = screen row, HL = 8-byte bitmap,
;                    A = ink.  The primitive all the others use.
;   scr_x / scr_y    A = world pixel coordinate -> A = screen pixel coordinate
;                    (clobbers HL).  Used by draw_gfx; handy for your own
;                    collision / clipping code.
;
;  World map access / dirty management (section 4b):
;   world_at         C = col, B = row (any values, wrapped) -> HL = address
;   world_put        C,B = cell, A = tile: writes it and sets bw_dirty.
;   world_block      C,B = top-left, D = w, E = h, HL = w*h tile codes
;                    (row-major): writes them (wrapping) and sets bw_dirty.
;   wrap_world       HL = address past the map end -> wrapped back into it.
;   off_to_cb        HL = cell offset (0..895) -> C = col, B = row.
;   redraw_all       force every cell of the screen to be repainted at the
;                    next diff_draw (use after drawing over the playfield).
;   init_window      reserve the HUD rows and paint the blank border columns.
;   (opt) autotile_all / autotile_code / autotile_k   neighbour-based tile
;                    selection, enabled by `GFX_AUTOTILE equ 1` (see 4c).
;
;  Direct-to-screen drawing (section 8; bypasses the tile engine, for HUD,
;  title, menus and any row/column outside the playfield window):
;   cell_addr        B = row, C = col -> DE = address of the cell's top pixel row
;   print_str        HL = zero-terminated string, B = row, C = col, A = attribute
;   print_chr        A = char, B = row, C = col, attribute in (ps_attr)
;   print_num        HL = 16-bit number, A = width, B = row, C = col, (ps_attr)
;   clear_row        B = row, A = attribute: blank a whole text row
;   draw_icon        HL = pixel rows (2 bytes/row), B = row, C = col, E = cells
;                    high: a 16-px wide picture (e.g. player lives icon)
;   draw_cells       HL = 8-byte cells row-major, B = row, C = col, D = w, E = h
;                    cells (e.g. a big title logo)
;   fill_attr        A = attribute, B = row, C = col, D = w, E = h cells
;
;
;  COLOUR MODEL (how attribute clash is handled)
;  ---------------------------------------------
;  A cell has ONE attribute, so two things in the same cell share colours.
;  spr_cell decides the attribute of the new dynamic tile like this:
;    1. Background cell is EMPTY (its attribute has ink = paper)
;          -> attribute = round paper (+ bright) with the sprite ink.  If the
;             ink equals the paper the ink is inverted (xor 7) so the sprite
;             never becomes invisible.
;    2. Background cell has CONTENT (a static tile with visible ink)
;          -> the background attribute is kept; the sprite bitmap is ORed
;             onto the tile bitmap and takes the tile's colours.
;    3. Background cell is ANOTHER SPRITE CELL (code >= $A0)
;          -> the two bitmaps are ORed (sprites merge instead of cutting
;             holes in each other) and the colour of the sprite drawn LATER
;             wins for that cell.
;  Drawing order is therefore also colour priority: draw the thing that should
;  win last.
;
;
;  NAME MAPPING TO THE GAME (engine.asm / game.asm), in case you diff them
;  ----------------------------------------------------------------------
;     This file is the game's graphics code with the game logic removed
;     (score/HUD content, timing with sound, level decoding, dice, enemies)
;     and the memory map made overridable.  The dead routine spr_draw is gone.
;     Routine names are unchanged:
;       engine.asm : setup_im2 isr wait_frames cls_attr init_tiles
;                    set_round_attrs wrap_world world_at autotile_* off_to_cb
;                    build_want diff_draw dd_* spr_begin spr_cell spr_world
;                    spr_screen
;       game.asm   : scr_x scr_y draw_gfx zero_rows spr_planes init_shift
;       gen/blit.asm : the unrolled blitter (same bytes)
;       text.asm   : print_str print_chr cell_addr print_num clear_row
;       status.asm : hud_init  -> init_window (generalised)
;       screens.asm/bonus.asm : draw_head / bs_icon / title logo loop
;                    -> draw_icon, draw_cells, fill_attr (generalised)
;     NOT included on purpose: place_die (dice drawing; use world_block),
;     bar_draw (time bar), hud_draw/hud_score (HUD contents), fmt7/print_val
;     (BCD score formatting), draw_player/draw_enemies/bs_draw (they just
;     pick bitmap + ink and call draw_gfx).
; ============================================================================


; ----------------------------------------------------------------------------
;  CONFIGURATION - define any of these BEFORE including this file to override
; ----------------------------------------------------------------------------
        IFNDEF SPRBUF
SPRBUF      equ $C000       ; 3 pages: sprite shift buffer
        ENDIF
        IFNDEF SHTAB
SHTAB       equ $D000       ; 16 pages: shift tables
        ENDIF
        IFNDEF TILEGFX
TILEGFX     equ $E000       ; 256 tiles x 8 bytes
        ENDIF
        IFNDEF TILEATTR
TILEATTR    equ $E800       ; 256 attribute bytes
        ENDIF
        IFNDEF WORLD
WORLD       equ $F000       ; 32 x 28 background map
        ENDIF
        IFNDEF WANT
WANT        equ $F400       ; 768 desired codes
        ENDIF
SHOWN       equ WANT+$0300  ; 768 shown codes (fixed offset from WANT!)
WORLD_END   equ WORLD+896   ; 32 x 28 cells
        IFNDEF IM2TABLE
IM2TABLE    equ $FE00       ; 257 bytes of $FD
        ENDIF
        IFNDEF ISRADDR
ISRADDR     equ $FDFD       ; the vector formed by the table: $FDFD
        ENDIF
        IFNDEF BORDER_TILE
BORDER_TILE equ $CF         ; blank tile used for the border columns
        ENDIF
        IFNDEF GFX_NTILES
GFX_NTILES  equ $A0         ; number of static tiles (must be <= $A0)
        ENDIF

SPR_BANK0   equ $A0         ; first dynamic code of bank 0 (even ticks)
SPR_BANK1   equ $D0         ; first dynamic code of bank 1 (odd ticks)
SPR_MAX     equ 46          ; sprite cells per tick: banks hold 46 codes each
SCR_ROWS    equ 24          ; screen height in cells (do not change)


; ============================================================================
;  1. FRAME TIMER  (interrupt mode 2)
; ============================================================================
; The Spectrum generates a maskable interrupt 50 times a second at the start
; of the frame (when the beam is at the top).  We use IM 2 with the classic
; 257-byte table of $FD so the vector is always $FDFD, where a 3-byte
; "jp isr" is stored.  The ISR only increments the 16-bit counter `frames`.
; `halt` in wait_frames sleeps until the next interrupt (saves nothing but
; keeps frame alignment exact).
;
; If you already have your own interrupt (music player, keyboard...), skip
; this section: just keep a frame counter and call diff_draw right after the
; interrupt for tear-free updates.

; Installs the interrupt.  Interrupts end enabled.  Clobbers AF, BC, DE, HL.
setup_im2:
        di
        ld hl,IM2TABLE
        ld (hl),$FD
        ld de,IM2TABLE+1
        ld bc,256
        ldir                    ; fill 257 bytes with $FD
        ld a,$C3                ; opcode of "jp"
        ld (ISRADDR),a
        ld hl,isr
        ld (ISRADDR+1),hl       ; "jp isr" at $FDFD
        ld a,IM2TABLE/256
        ld i,a                  ; vector table page
        im 2
        ei
        ret

; 50 Hz interrupt service routine: frames++
isr:
        push af
        push hl
        ld hl,(frames)
        inc hl
        ld (frames),hl
        pop hl
        pop af
        ei
        reti

frames:     defw 0              ; frames since boot (wraps at 65536)
last_frame: defw 0              ; value of `frames` at the previous wait_frames

; wait until at least A frames have passed since the last call.
; Tick rate = 50 / A.  (The game uses A = 3 -> 16.7 ticks/s.)
; If the work took longer than A frames it returns immediately; the next
; call then measures from the moment this one returned.
; Clobbers AF, B, DE, HL.
wait_frames:
        ld b,a
wf_loop:
        ld hl,(frames)
        ld de,(last_frame)
        or a
        sbc hl,de               ; hl = frames elapsed
        ld a,l
        cp b
        jr nc,wf_done           ; (only the low byte is compared: A < 256)
        halt                    ; sleep to the next interrupt
        jr wf_loop
wf_done:
        ld hl,(frames)
        ld (last_frame),hl
        ret


; ============================================================================
;  2. INITIALISATION
; ============================================================================

; Copy the static tile bitmaps from ROM-like data (tile_gfx_src) to TILEGFX.
; Must be done once before the first diff_draw (and again if you ever swap
; the tile set).  Clobbers AF, BC, DE, HL.
init_tiles:
        ld hl,tile_gfx_src
        ld de,TILEGFX
        ld bc,GFX_NTILES*8
        ldir
        ret

; Build the shift tables used by the pixel blitter (once, ~20000 T-states).
;   SHTAB page s      (s = 0..7): byte >> s      (pixels that stay in the
;                                                 byte column)
;   SHTAB page 8 + s  (s = 0..7): byte << (8-s)  (pixels that spill into the
;                                                 next byte column)
; A table lookup is the fastest way on a Z80 to shift a byte by a variable
; amount, and the blitter uses 2 lookups per byte per plane.
; Clobbers AF, BC, DE, HL.
init_shift:
        ld c,0                  ; c = shift amount s
is_s:   ld a,SHTAB/256
        add a,c
        ld h,a                  ; h = page of the ">>" table for this s
        add a,8
        ld d,a                  ; d = page of the "<<" table for this s
        ld l,0                  ; l = e = value 0..255 being tabulated
        ld e,0
is_v:   ld a,l
        ld b,c
        inc b
        dec b                   ; set Z if s = 0
        jr z,is_h0
is_h:   srl a                   ; a = value >> s
        djnz is_h
is_h0:  ld (hl),a
        ld a,8
        sub c
        ld b,a                  ; b = 8 - s
        ld a,l
is_l:   add a,a                 ; a = value << (8 - s)  (low 8 bits)
        djnz is_l
        ld (de),a
        inc l
        inc e
        jr nz,is_v              ; all 256 values
        inc c
        ld a,c
        cp 8
        jr nz,is_s              ; all 8 shifts
        ret


; ============================================================================
;  3. SCREEN HELPERS: palette and clear
; ============================================================================

; Clear the whole screen: attribute A everywhere, pixels 0, and invalidate
; SHOWN so the next diff_draw repaints every cell.  Also marks WANT dirty.
; Clobbers AF, BC, DE, HL.
cls_attr:
        ld hl,bw_dirty
        ld (hl),1
        ld hl,$5800
        ld de,$5801
        ld bc,767
        ld (hl),a
        ldir                    ; attributes
        ld hl,$4000
        ld de,$4001
        ld bc,6143
        ld (hl),0
        ldir                    ; bitmap
        ld hl,SHOWN
        ld de,SHOWN+1
        ld bc,767
        ld (hl),$FE             ; $FE = never equal to a real code
        ldir
        ret

; Build TILEATTR (the attribute byte of every STATIC tile) for a given round
; background.  A = background attribute: paper colour in bits 0-2 and the
; bright flag in bit 6 (e.g. 0 = black, 1 = blue, $41 = bright blue).
;
;   class $80  -> "empty" attribute: paper = bg, ink = bg  (ink = paper so a
;                 blank tile looks like pure background and spr_cell can
;                 recognise it as empty)
;   class $81  -> paper = bg, ink white (black if bg is white)    [top bevel]
;   class $82  -> paper = bg, ink cyan  (white if bg cyan, blue if bg white)
;                                                                 [side bevel]
;   other      -> the byte from tile_cls verbatim (fixed colours)
;
; This lets the same tile set be re-used with a different background colour
; on every level while the outlines keep contrasting.  Call it before
; cls_attr; both together define the look of a level.
; Outputs: bg_paper (paper+bright bits shifted into bits 3-6), bg_attr
; (empty attribute), top_attr, side_attr.  Clobbers AF, BC, DE, HL.
set_round_attrs:
        ld c,a
        and 7
        ld b,a                  ; b = bg colour 0..7
        ld a,c
        and $40
        ld c,a                  ; c = bright bit
        ld a,b
        add a,a
        add a,a
        add a,a                 ; colour << 3 = paper bits
        or c
        ld (bg_paper),a
        or b
        ld (bg_attr),a          ; empty attr: ink = paper
        ld a,7                  ; top bevel ink: white, black if bg is white
        ld e,a
        ld a,b
        cp 7
        jr nz,sra_t1
        ld e,0
sra_t1: ld a,(bg_paper)
        or e
        ld (top_attr),a
        ld e,5                  ; side bevel ink: cyan; white on cyan; blue on white
        ld a,b
        cp 5
        jr nz,sra_s1
        ld e,7
sra_s1: cp 7
        jr nz,sra_s2
        ld e,1
sra_s2: ld a,(bg_paper)
        or e
        ld (side_attr),a
        ld hl,tile_cls          ; fill the table
        ld de,TILEATTR          ; (TILEATTR is page aligned: only e is incremented)
        ld b,GFX_NTILES
sra_loop:
        ld a,(hl)
        cp $80
        jr nz,sra_n0
        ld a,(bg_attr)
        jr sra_put
sra_n0: cp $81
        jr nz,sra_n1
        ld a,(top_attr)
        jr sra_put
sra_n1: cp $82
        jr nz,sra_put
        ld a,(side_attr)
sra_put:
        ld (de),a
        inc hl
        inc e
        djnz sra_loop
        ret

bg_paper:   defb 0              ; background paper+bright, already in bit 3-6 position
bg_attr:    defb 0              ; attribute of an empty cell (ink = paper)
top_attr:   defb 0
side_attr:  defb 0


; ============================================================================
;  4. WORLD -> WANT  (the scrolling background)
; ============================================================================
; The camera is (view_x, view_y) in CELLS, i.e. the world cell shown at the
; top-left corner of the screen.  view_x counts 0..31 and view_y 0..27; both
; wrap.  Scrolling is by whole cells (8 px); sprites keep their pixel
; precision, which is why scrolling looks smooth enough at this tick rate.
;
; Screen cell (col, row) shows world cell
;     x = (view_x + col) mod 32,   y = (view_y + row) mod 28
; with the exception of the reserved border/HUD cells, see SCREEN LAYOUT.
view_x:     defb 0
view_y:     defb 0

; Make WANT reflect WORLD + camera, and remember which cells the sprites of
; the previous tick covered.  Two modes, chosen automatically:
;
;  FULL     (bw_dirty set, or the camera moved):  copy the whole 30 x 22
;           window from WORLD into WANT (fast LDIR per row, handling the
;           horizontal wrap with a second LDIR) and make diff_draw do a full
;           compare (dd_full = 1).
;  PARTIAL  (nothing moved): WANT still contains last tick's sprite codes.
;           Walk the sprite record list backwards and put the original
;           background codes back; then swap the two record lists so the
;           sprites of THIS tick record into the other list, and set
;           sr_ob..sr_oe (old) / sr_base..sr_p (new) so diff_draw (dd_part)
;           only looks at cells touched this tick or last tick.
;
; A sprite record is 3 bytes: WANT address (2) and the background code that
; was there (1) - written by spr_cell, read here.
; Call it BEFORE spr_begin each tick.  Clobbers everything.
build_want:
        ld a,(bw_dirty)         ; world changed? (set by you or cls_attr)
        or a
        jr nz,bw_full
        ld a,(view_x)           ; camera moved?
        ld hl,bw_vx
        cp (hl)
        jr nz,bw_full
        ld a,(view_y)
        inc hl
        cp (hl)
        jr nz,bw_full
        ; ---- partial: undo last tick's sprites -------------------------
        ld hl,(sr_p)            ; end of the current record list
bw_rs:  ld de,(sr_base)         ; start of it
        or a
        sbc hl,de
        add hl,de
        jr z,bw_rd              ; list empty -> done restoring
        dec hl                  ; pop a record (stored addr lo, addr hi, code)
        ld a,(hl)               ; original background code
        dec hl
        ld d,(hl)
        dec hl
        ld e,(hl)               ; de = WANT address
        ld (de),a               ; restore the background code
        jr bw_rs
bw_rd:  ld hl,(sr_base)         ; the list just restored becomes the "old" one
        ld (sr_ob),hl
        ld hl,(sr_p)
        ld (sr_oe),hl
        ld hl,(sr_base)         ; swap lists: this tick records into the other
        ld de,sr_list
        or a
        sbc hl,de
        ld hl,sr_list2
        jr z,bw_sw
        ld hl,sr_list
bw_sw:  ld (sr_base),hl
        ld (sr_p),hl
        xor a
        ld (dd_full),a          ; diff_draw may use the partial walk
        ret
        ; ---- full rebuild ----------------------------------------------
bw_full:
        ld hl,(sr_base)         ; discard the sprite records, start anew
        ld (sr_p),hl
        ld (sr_ob),hl
        ld (sr_oe),hl
        ld a,1
        ld (dd_full),a
        xor a
        ld (bw_dirty),a
        ld a,(view_x)
        ld (bw_vx),a
        ld a,(view_y)
        ld (bw_vy),a
        ; WINDOW: playfield = columns 1..30 -> world columns view_x+1 .. view_x+30
        ld a,(view_x)
        inc a
        and 31
        ld (bw_c),a             ; first world column
        ld c,a
        ld a,32
        sub c                   ; columns until the world's right edge
        cp 30
        jr c,bw_n
        ld a,30                 ; (never more than the 30 we need)
bw_n:   ld (bw_n1),a            ; part 1: columns before the wrap
        ld c,a
        ld a,30
        sub c
        ld (bw_n2),a            ; part 2: columns after the wrap (0 if none)
        ld de,WANT+33           ; WINDOW: first playfield cell = row 1, col 1
        ld a,(view_y)
        inc a                   ; WINDOW: first world row = view_y + 1
        cp 28
        jr c,bw_s0
        xor a
bw_s0:  ld b,SCR_ROWS-2         ; WINDOW: 22 playfield rows
bw_row: push bc
        push af
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; hl = world row * 32
        ld bc,WORLD
        add hl,bc               ; hl = start of that world row
        push hl
        ld a,(bw_c)
        or l                    ; (WORLD page aligned: low byte = row*32 mod 256 ... so OR is an add)
        ld l,a
        ld a,(bw_n1)
        ld c,a
        ld b,0
        ldir                    ; part 1
        ld a,(bw_n2)
        or a
        jr z,bw_skip
        ld c,a
        pop hl                  ; wrapped part comes from world column 0
        ldir                    ; part 2
        jr bw_end
bw_skip:
        pop hl
bw_end: inc de                  ; skip the blank border columns 31 (end) ...
        inc de                  ; ... and 0 (start of next row)
        pop af
        inc a                   ; next world row, wrapping at 28
        cp 28
        jr c,bw_r
        xor a
bw_r:   pop bc
        djnz bw_row
        ret

bw_vx:      defb 0              ; camera at the last full rebuild
bw_vy:      defb 0
bw_dirty:   defb 1              ; set to 1 to force a full rebuild (e.g. world edited)
bw_c:       defb 0              ; scratch
bw_n1:      defb 0
bw_n2:      defb 0

; Sprite record lists (double buffered).
;   sr_p      write pointer of the current list (spr_cell appends here)
;   sr_base   start of the current list
;   sr_ob/oe  start/end of the PREVIOUS tick's list (for dd_part)
;   dd_full   1 -> diff_draw compares everything, 0 -> only recorded cells
; Size: 46 records x 3 bytes (+3 slack).
sr_p:       defw sr_list
sr_base:    defw sr_list
sr_ob:      defw sr_list
sr_oe:      defw sr_list
dd_full:    defb 1
dp_end:     defw 0
sr_list:    defs SPR_MAX*3+3
sr_list2:   defs SPR_MAX*3+3


; ============================================================================
;  5. DIFF + DRAW  (WANT -> screen)
; ============================================================================
; The only routine that touches video RAM during normal play.
; Call it right after the frame interrupt (wait_frames) so the beam is above
; the cells being redrawn.
;
;  dd_full = 1: compare the 768 WANT bytes with SHOWN, call dd_cell for each
;               difference.
;  dd_full = 0: only the cells in the old and new sprite record lists can be
;               different (everything else is unchanged by construction), so
;               visit just those: typically 0-46 cells instead of 768.
; Clobbers everything.
diff_draw:
        ld a,(dd_full)
        or a
        jp z,dd_part
        ld hl,WANT
        ld de,SHOWN
        ld c,3                  ; 3 pages = 768 cells
dd_page:
        ld b,0
dd_loop:
        ld a,(de)
        cp (hl)
        jr nz,dd_dc
dd_next:
        inc l
        inc e
        djnz dd_loop
        inc h
        inc d
        dec c
        jr nz,dd_page
        ret
dd_dc:  call dd_cell
        jr dd_next

; Partial pass: first the previous tick's records, then the current ones.
dd_part:
        ld hl,(sr_ob)
        ld de,(sr_oe)
        call dd_plist
        ld hl,(sr_base)
        ld de,(sr_p)
dd_plist:
        ld (dp_end),de
dp_l:   ld de,(dp_end)
        or a
        sbc hl,de
        add hl,de
        ret z                   ; reached the end of the list
        push hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                ; hl = WANT address of the cell
        ld d,h
        ld e,l
        ld a,d
        add a,3                 ; SHOWN = WANT + $300
        ld d,a                  ; de = SHOWN address
        ld a,(de)
        cp (hl)
        call nz,dd_cell         ; only if it really differs
        pop hl
        inc hl
        inc hl
        inc hl                  ; next 3-byte record
        jr dp_l

; Draw one cell.  HL = address in WANT, DE = same cell in SHOWN, they differ.
; Updates SHOWN, then writes the attribute and the 8 bitmap bytes.  The Spectrum
; screen is split into 3 "thirds" (rows 0-7, 8-15, 16-23); the cell offset
; inside WANT (0..767) is converted to: attribute address $5800 + offset, and
; bitmap address $4000 + third*$800 + (offset mod 256), with consecutive pixel
; rows of a cell $100 apart (hence `inc d`).  The 8 bytes copy is unrolled.
dd_cell:
        ld a,(hl)
        ld (de),a               ; SHOWN = WANT
        cp $FF
        ret z                   ; $FF = not ours to draw
        push hl
        push de
        push bc
        ld b,a                  ; b = tile code
        ld a,h
        sub WANT/256
        ld c,a                  ; c = third 0..2
        add a,$58
        ld d,a
        ld e,l                  ; de = attribute address
        ld h,TILEATTR/256
        ld l,b
        ld a,(hl)               ; attribute of this tile code
        ld (de),a
        ld a,b
        or a
        jr z,dd_done            ; empty tile: attribute only (pixels are
                                ; already 0 - see note below)
        ld a,c                  ; bitmap address high byte = $40 + third*8
        add a,a
        add a,a
        add a,a
        add a,$40
        ld d,a                  ; de = first pixel row of the cell
        ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl               ; code * 8
        ld a,h
        add a,TILEGFX/256
        ld h,a                  ; hl = tile bitmap
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
        inc l
        inc d
        ld a,(hl)
        ld (de),a
dd_done:
        pop bc
        pop de
        pop hl
        ret
; NOTE on the "empty tile: attribute only" shortcut: it is valid for the game
; because a cell that becomes empty is always one whose pixels are invisible
; anyway (ink = paper in the empty attribute), so stale pixels cannot show.
; If your empty tile must also CLEAR the pixels (e.g. different attributes
; on empty tiles), delete the `or a / jr z,dd_done` pair.


; ============================================================================
;  6. SPRITE CELLS  (the compositor)
; ============================================================================
; Sprite cells are written straight into WANT as dynamic tiles, so the same
; diff pass draws background and sprites together.  Dynamic tile bitmaps live in
; TILEGFX at the dynamic codes (bank 0: $A0.. on one tick, bank 1: $D0.. on
; the next) and their attributes in TILEATTR.
spr_count:  defb 0              ; sprite cells used this tick
spr_bank:   defb 0              ; 0/1: which bank this tick uses

; Start a new sprite list: reset the cell counter and flip the bank.  Call
; once per tick, after build_want and before the first sprite.
; Clobbers AF.
spr_begin:
        xor a
        ld (spr_count),a
        ld a,(spr_bank)
        xor 1
        ld (spr_bank),a
        ret

; Add ONE 8x8 sprite cell.
;   C = screen column (0..31)      B = screen row (0..23)
;   HL = 8 bytes of bitmap          A = ink colour 0..7
; Nothing is drawn immediately: the cell is turned into a dynamic tile and
; its code is written into WANT; diff_draw puts it on screen later.
; Silently ignored if: the bitmap is all zero, column 0 or 31, row 0 or 23
; (WINDOW), or SPR_MAX cells were already used this tick.
; Clobbers AF, BC, DE, HL.
spr_cell:
        ld (sc_ink),a
        push hl                 ; skip completely blank cells (OR of 8 bytes)
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        pop hl
        ret z
        ld a,c                  ; WINDOW: blank border columns 0 and 31
        or a
        ret z
        cp 31
        ret z
        ld a,b                  ; WINDOW: only rows 1..22
        or a
        ret z
        cp SCR_ROWS-1
        ret nc
        ld a,(spr_count)        ; budget of dynamic tiles
        cp SPR_MAX
        ret nc
        ld e,a                  ; code = bank base + count
        inc a
        ld (spr_count),a
        ld a,(spr_bank)
        or a
        ld a,SPR_BANK0
        jr z,sc_b
        ld a,SPR_BANK1
sc_b:   add a,e
        ld e,a                  ; e = our dynamic tile code
        push hl                 ; (keeps the bitmap pointer)
        ; hl = &WANT[row*32 + col]
        ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,c
        and 31
        or l
        ld l,a
        ld a,h
        add a,WANT/256
        ld h,a
        ld a,(hl)               ; a = code currently in that cell (background
                                ; tile, or another sprite's dynamic tile)
        ld (hl),e               ; put our code in WANT
        ld (sc_bg),a
        push de
        push hl
        ld hl,(sr_p)            ; append the record: WANT addr, previous code
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),a
        inc hl
        ld (sr_p),hl
        pop de                  ; e = our code again
        xor a
        ld (sc_mix),a           ; assume "no OR needed"
        ld a,(sc_bg)
        cp SPR_BANK0
        jr nc,sc_ovl            ; (3) overlapping another sprite cell: OR
        ld h,TILEATTR/256
        ld l,a
        ld a,(hl)               ; background tile attribute
        ld b,a
        rrca
        rrca
        rrca                    ; paper -> ink position
        xor b
        and 7                   ; zero if ink == paper
        jr z,sc_plain           ; (1) empty background cell
        ld a,1                  ; (2) background has content: OR the sprite onto
        ld (sc_mix),a           ;     it and keep the tile's colours
        ld a,b
        jr sc_seta
sc_ovl: ld a,1                  ; (3) sprite over sprite: OR bitmaps, the colour of
        ld (sc_mix),a           ;     the later sprite (this one) wins
sc_plain:
        ; attribute = round paper (+bright) | sprite ink (inverted if it equals paper)
        ld a,(bg_paper)
        and $78
        ld d,a                  ; paper + bright bits
        rrca
        rrca
        rrca
        and 7                   ; paper colour 0..7
        ld hl,sc_ink
        cp (hl)
        ld a,(hl)
        jr nz,sc_i
        xor 7                   ; ink would equal paper: use the contrast colour
sc_i:   or d
sc_seta:
        ld hl,TILEATTR          ; TILEATTR[code] = attribute
        ld l,e
        ld (hl),a
        ld l,e                  ; hl = &TILEGFX[code*8]
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,h
        add a,TILEGFX/256
        ld h,a
        ex de,hl                ; de = destination bitmap
        pop hl                  ; hl = sprite bitmap
        ld bc,8
        ldir                    ; copy it into the dynamic tile (de = dest + 8)
        ld a,(sc_mix)
        or a
        ret z                   ; no OR needed: done
        ld a,e                  ; de = dest + 8 -> back to dest
        sub 8
        ld e,a
        jr nc,sc_m0
        dec d
sc_m0:  ld a,(sc_bg)            ; hl = bitmap of the code that was there before
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,h
        add a,TILEGFX/256
        ld h,a
        ld b,8
sc_m1:  ld a,(de)               ; dest |= background bitmap (8 bytes)
        or (hl)
        ld (de),a
        inc hl
        inc de
        djnz sc_m1
        ret
sc_bg:      defb 0              ; code that was in WANT before this cell
sc_mix:     defb 0              ; 1 -> OR with the background bitmap
sc_ink:     defb 0              ; ink of the sprite being added

; Add a rectangular sprite of w x h cells, whose bitmaps are stored one after
; another (8 bytes per cell, ROW-MAJOR: row 0 left to right, then row 1...).
;   C = world column, B = world row (cells), D = width, E = height (cells),
;   HL = cell data, A = ink.
; The position is converted to screen cells relative to the camera, wrapping
; at 32 columns and 28 rows.  Cells outside the playfield are clipped by
; spr_cell.  Clobbers everything.
spr_world:
        ld (sw_ink),a
        ld a,(view_x)           ; screen col = (c - view_x) & 31
        neg
        add a,c
        and 31
        ld c,a
        ld a,(view_y)           ; screen row = (b - view_y) mod 28
        neg
        add a,b
        jr nc,sw_y0             ; borrow means b < view_y
        jr sw_y1
sw_y0:  add a,28
sw_y1:  cp 28
        jr c,sw_y2
        sub 28
sw_y2:  ld b,a
        ld a,(sw_ink)           ; fall through into spr_screen
; Same as spr_world but C = SCREEN column, B = SCREEN row (0..27: rows >= 28
; wrap), no camera conversion.
spr_screen:
        ld (sw_ink),a
ss_row: push bc                 ; remember start of row
        push de                 ; d = columns left, e = rows left
ss_col: push bc
        push de
        push hl
        ld a,b
        cp 28
        jr c,ss_r
        sub 28
        ld b,a
ss_r:   ld a,(sw_ink)
        call spr_cell
        pop hl
        ld de,8
        add hl,de               ; next cell bitmap
        pop de
        pop bc
        inc c                   ; next column (wrap at 32)
        ld a,c
        and 31
        ld c,a
        dec d
        jr nz,ss_col
        pop de
        pop bc
        inc b                   ; next row
        dec e
        jr nz,ss_row
        ret
sw_ink:     defb 0


; ============================================================================
;  7. PIXEL-PRECISE SPRITES  (draw_gfx)
; ============================================================================
; A 16 px wide sprite at an arbitrary x spans up to 3 byte columns.  The
; blitter shifts the sprite into three "planes" (page-aligned arrays in
; SPRBUF: plane 0 = left byte column, 1 = middle, 2 = right), one byte per
; pixel row, 256 bytes apart so one `inc d` moves between planes.  The shifted
; planes are then cut into 8x8 cells and given to spr_cell.
;
; For each source row (2 bytes: the left and right half) and shift s = x & 7:
;     plane0 = L >> s
;     plane1 = (L << (8-s)) | (R >> s)
;     plane2 = R << (8-s)
; Each of those is two SHTAB lookups.  The code is 24 identical copies
; of one row (z80asm has no REPT), exactly 24 bytes of code per row, starting
; at "blit_start", so a
; sprite of N rows enters the unrolled code at `blit_start + 24*(24-N)` and
; falls off the end into `jp sb_done`.  blit_tab holds those 25 entry points
; (index = row count 0..24).
;
; Register convention inside the unrolled code:
;     HL = source (reads 2 bytes per row)
;     B  = SHTAB page (table pair for this shift), C = value being looked up
;     DE = destination: D = plane page, E = pixel row
;     AF' holds the intermediate "<< (8-s)" byte of the left half.

; draw_gfx: HL = bitmap, B = world x, C = world y, A = rows (1..24).
; Ink in (dg_ink).  Clobbers everything.
draw_gfx:
        ld (dg_src),hl
        ld (dg_rows),a
        ld a,b
        call scr_x              ; world x -> screen x (pixels)
        cp 248
        ret nc                  ; fully past the right edge
        ld b,a
        ld a,c
        call scr_y              ; world y -> screen y (pixels)
        ld c,a
        ld a,b
        and 7                   ; s = x mod 8
        add a,SHTAB/256
        ld (dg_pg),a            ; table page for this shift
        ld a,b
        rrca
        rrca
        rrca
        and 31
        ld (dg_col),a           ; first cell column
        ld a,c
        rrca
        rrca
        rrca
        and 31
        ld (dg_row),a           ; first cell row
        ld a,c
        and 7
        ld (dg_sy),a            ; y mod 8: rows of padding above the sprite
        ld hl,dg_rows
        add a,(hl)
        add a,7
        rrca
        rrca
        rrca
        and 31
        ld (dg_h),a             ; cells per plane = ceil((sy + rows) / 8)
        ld de,SPRBUF
        ld a,(dg_sy)
        or a
        call nz,zero_rows       ; blank rows above the sprite
        ld a,(dg_rows)
        add a,a
        ld l,a
        ld h,0
        ld bc,blit_tab
        add hl,bc
        ld c,(hl)
        inc hl
        ld b,(hl)               ; bc = entry point for this height
        push bc                 ; "return" into the unrolled rows
        ld a,(dg_pg)
        ld b,a
        ld hl,(dg_src)
        ret                     ; jumps into blit_start+...; ends at sb_done
sb_done:
        ld a,(dg_h)             ; blank rows below the sprite up to the cell edge
        add a,a
        add a,a
        add a,a
        ld hl,dg_sy
        sub (hl)
        ld hl,dg_rows
        sub (hl)
        call nz,zero_rows
        ld a,(dg_row)           ; hand the planes to the cell compositor
        ld b,a
        ld a,(dg_col)
        ld c,a
        ld a,(dg_h)
        ld e,a
        ld hl,SPRBUF
        ld a,(dg_ink)
        jp spr_planes

; A pixel rows of zeros into the three planes at DE (D = plane 0 page,
; E = first row); on return E is advanced by A.
zero_rows:
        ld c,a
        xor a
zr_l:   ld (de),a
        inc d
        ld (de),a
        inc d
        ld (de),a
        dec d
        dec d
        inc e
        dec c
        jr nz,zr_l
        ret

; Cut the three planes at HL (SPRBUF) into 8x8 cells and feed spr_cell:
; C = column of plane 0, B = row of the first cell, E = cells per plane,
; A = ink.  Plane k goes to column C+k (mod 32).
spr_planes:
        ld (sw_ink),a
        ld d,3                  ; 3 planes
sp_col: push bc
        push de
        push hl
sp_row: push bc
        push de
        push hl
        ld a,b
        cp 28
        jr c,sp_r
        sub 28
        ld b,a                  ; wrap rows at the world height
sp_r:   ld a,(sw_ink)
        call spr_cell
        pop hl
        ld de,8
        add hl,de               ; next cell down (8 pixel rows)
        pop de
        pop bc
        inc b
        dec e
        jr nz,sp_row
        pop hl
        inc h                   ; next plane = next page
        pop de
        pop bc
        inc c
        ld a,c
        and 31
        ld c,a
        dec d
        jr nz,sp_col
        ret

; World pixel -> screen pixel.  A in/out.  Clobbers HL.
; scr_x: (x - view_x*8) mod 256.
scr_x:  ld l,a
        ld a,(view_x)
        add a,a
        add a,a
        add a,a                 ; view_x * 8
        ld h,a
        ld a,l
        sub h
        ret
; scr_y: (y - view_y*8) mod 224   (28 world rows * 8)
scr_y:  ld l,a
        ld a,(view_y)
        add a,a
        add a,a
        add a,a
        ld h,a
        ld a,l
        sub h
        jr nc,scy1
        add a,224               ; wrapped below zero
scy1:   cp 224
        ret c
        sub 224
        ret

dg_src:     defw 0              ; draw_gfx variables
dg_rows:    defb 0
dg_sy:      defb 0
dg_col:     defb 0
dg_row:     defb 0
dg_h:       defb 0
dg_pg:      defb 0
dg_ink:     defb 7              ; ink for draw_gfx (set before calling it)

; The unrolled row shifter: 24 rows x 24 bytes.
blit_start:
        ; ---- row 1 of 24 (commented) ----
        ld c,(hl)               ; c = L
        inc hl
        ld a,(bc)               ; a = L >> s                (table page B)
        ld (de),a               ; plane0[row] = L >> s
        set 3,b                 ; switch to the "<< (8-s)" table page
        ld a,(bc)               ; a = L << (8-s)
        ex af,af'               ; keep it in AF'
        ld c,(hl)               ; c = R
        inc hl
        ld a,(bc)               ; a = R << (8-s)
        inc d
        inc d                   ; plane 2
        ld (de),a               ; plane2[row] = R << (8-s)
        dec d                   ; plane 1
        res 3,b                 ; back to the ">>" table page
        ld a,(bc)               ; a = R >> s
        ld c,a
        ex af,af'               ; a = L << (8-s)
        or c                    ; a = (L << (8-s)) | (R >> s)
        ld (de),a               ; plane1[row]
        dec d                   ; plane 0
        inc e                   ; next pixel row
        ; ---- rows 2..24: identical copies (z80asm has no REPT) ----
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        ld c,(hl)
        inc hl
        ld a,(bc)
        ld (de),a
        set 3,b
        ld a,(bc)
        ex af,af'
        ld c,(hl)
        inc hl
        ld a,(bc)
        inc d
        inc d
        ld (de),a
        dec d
        res 3,b
        ld a,(bc)
        ld c,a
        ex af,af'
        or c
        ld (de),a
        dec d
        inc e
        jp sb_done

blit_tab:                       ; entry point for N rows = blit_start + 24*(24-N)
        defw blit_start+24*24
        defw blit_start+24*23
        defw blit_start+24*22
        defw blit_start+24*21
        defw blit_start+24*20
        defw blit_start+24*19
        defw blit_start+24*18
        defw blit_start+24*17
        defw blit_start+24*16
        defw blit_start+24*15
        defw blit_start+24*14
        defw blit_start+24*13
        defw blit_start+24*12
        defw blit_start+24*11
        defw blit_start+24*10
        defw blit_start+24*9
        defw blit_start+24*8
        defw blit_start+24*7
        defw blit_start+24*6
        defw blit_start+24*5
        defw blit_start+24*4
        defw blit_start+24*3
        defw blit_start+24*2
        defw blit_start+24*1
        defw blit_start+24*0


; ============================================================================
;  4b. WORLD MAP ACCESS AND DIRTY MANAGEMENT
; ============================================================================
; "Dirty" handling in this engine has three levels, from coarse to fine:
;
;   bw_dirty = 1     the WORLD (or anything else WANT is built from) changed:
;                    the next build_want copies the whole window again and the
;                    next diff_draw compares all 768 cells.  Cost ~ a full
;                    scroll.  Set it whenever you edit WORLD (world_put and
;                    world_block do it for you).  cls_attr sets it too.
;   camera move      detected automatically by build_want (view_x/view_y
;                    differ from the values at the last full rebuild).
;   sprite lists     (sr_list / sr_list2) always on: only the cells touched by
;                    sprites this tick and last tick are visited by dd_part
;                    when nothing else is dirty.  Nothing for you to do.
;
; SHOWN is the ground truth of what is on the screen.  Only dd_cell writes it.
; If YOU draw directly to the playfield (print_str over it, etc.), call
; redraw_all afterwards so the engine repaints those cells.

; Force a full repaint at the next diff_draw without clearing the screen.
; Clobbers AF, BC, DE, HL.
redraw_all:
        ld a,1
        ld (bw_dirty),a
        ld hl,SHOWN
        ld de,SHOWN+1
        ld bc,767
        ld (hl),$FE
        ldir
        ret

; Reserve the HUD rows and paint the border columns.  Call once after the
; screen was cleared (cls_attr) at the start of each screen / round.
;   WANT row 0 and row 23 := $FF   (diff_draw never touches them: draw your HUD
;                                   there directly with the section 8 routines)
;   WANT col 0 and col 31 (rows 1..22) := BORDER_TILE, a blank tile with
;                                   attribute 0 (black), forming the side margins
; Clobbers AF, BC, DE, HL.
init_window:
        ld hl,WANT
        ld de,WANT+1
        ld bc,31
        ld (hl),$FF
        ldir                    ; row 0
        ld hl,WANT+736
        ld de,WANT+737
        ld bc,31
        ld (hl),$FF
        ldir                    ; row 23
        xor a
        ld (TILEATTR+BORDER_TILE),a     ; black on black
        ld hl,TILEGFX+BORDER_TILE*8
        ld b,8
iw_g:   ld (hl),0               ; blank bitmap
        inc hl
        djnz iw_g
        ld hl,WANT+32           ; (row 1, col 0)
        ld de,32
        ld b,22
        ld a,BORDER_TILE
iw_b:   ld (hl),a               ; col 0
        push hl
        add hl,de
        dec hl
        ld (hl),a               ; col 31 of the same row
        pop hl
        add hl,de
        djnz iw_b
        ret

; ---------------------------------------------------------------------------
; World addressing.  The map is 32 columns x 28 rows, byte per cell,
; offset = row * 32 + col (0..895), address = WORLD + offset.

; Wrap an address HL that ran past the end of the map back into it (-896).
; Clobbers AF, HL (DE preserved).
wrap_world:
        push de
        ld de,WORLD_END
        or a
        sbc hl,de
        jr c,ww_low
        ld de,WORLD
        add hl,de               ; >= end: result = WORLD + (hl - end)
        pop de
        ret
ww_low: add hl,de               ; below end: restore
        pop de
        ret

; HL = address of world cell (col C, row B).  Both wrap (col & 31, row mod 28),
; so negative offsets work (use C = 255 for "one left of col 0").
; world_at_a: same with the row in A.  Clobbers AF, HL.
world_at:
        ld a,b
world_at_a:
wa_wrap:
        cp 28
        jr c,wa_ok
        sub 28
        jr wa_wrap
wa_ok:  ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; row * 32
        ld a,c
        and 31
        or l
        ld l,a                  ; + col
        ld a,h
        add a,WORLD/256
        ld h,a
        ret

; Offset HL (any value, taken modulo 896) -> C = col, B = row.
; Clobbers AF, DE, HL.
off_to_cb:
        ld de,896
otc_w:  or a
        sbc hl,de
        jr nc,otc_w
        add hl,de
        ld a,l
        and 31
        ld c,a                  ; col = offset mod 32
        add hl,hl
        add hl,hl
        add hl,hl
        ld b,h                  ; row = offset / 32  (h after 3 doublings of a 10-bit value)
        ret

; Write tile A at world cell (col C, row B) and mark the world dirty.
; Clobbers AF, HL.
world_put:
        push af
        call world_at
        pop af
        ld (hl),a
        ld a,1
        ld (bw_dirty),a
        ret

; Write a D x E block of tile codes (row-major at HL) with its top-left at
; world cell (col C, row B), wrapping at the map edges, and mark the world
; dirty.  Typical use: a 3 x 3 object made of tiles (a door, a die, a bridge).
; Clobbers everything except IX/IY.
world_block:
        ld a,1
        ld (bw_dirty),a
wb_row: push bc
        push de
wb_col: push bc
        push de
        push hl
        call world_at           ; hl = destination (clobbers a, hl only)
        ex de,hl                ; de = destination
        pop hl                  ; hl = tile list
        ld a,(hl)
        inc hl
        ld (de),a
        pop de
        pop bc
        inc c                   ; next column
        dec d
        jr nz,wb_col
        pop de
        pop bc
        inc b                   ; next row
        dec e
        jr nz,wb_row
        ret


; ============================================================================
;  4c. OPTIONAL: AUTOTILING (define GFX_AUTOTILE equ 1 before the include)
; ============================================================================
; Chooses the correct "edge" tile of a non-solid cell from its three
; neighbours below / right / below-right, the way the original game draws
; the floor outlines.  Convention: a world cell with bit 7 set is SOLID
; (e.g. $80); every other cell is background and is replaced by
; c7a_table[k], where k (0..7) = bit2: cell below solid, bit1: cell below-
; right solid, bit0: cell right solid.  c7a_table gives the tile codes
; $00..$06 of the edge pieces - edit it to match your tile set.
        IFDEF GFX_AUTOTILE
; replace every non-solid cell of WORLD by its autotile code
autotile_all:
        ld hl,WORLD
        ld b,0                  ; row
at_row: ld c,0                  ; col
at_col: ld a,(hl)
        bit 7,a
        jr nz,at_next
        push hl
        call autotile_code
        pop hl
        ld (hl),a
at_next:
        inc hl
        inc c
        ld a,c
        cp 32
        jr nz,at_col
        inc b
        ld a,b
        cp 28
        jr nz,at_row
        ret

; neighbour index k (0..7) of cell (col C, row B) -> A
autotile_k:
        push bc
        push hl
        ld e,0
        inc b                   ; below
        call world_at
        bit 7,(hl)
        jr z,ak1
        set 2,e
ak1:    inc c                   ; below-right
        call world_at
        bit 7,(hl)
        jr z,ak2
        set 1,e
ak2:    dec b                   ; right
        call world_at
        bit 7,(hl)
        jr z,ak3
        set 0,e
ak3:    ld a,e
        pop hl
        pop bc
        ret

; tile code for cell (C,B) -> A
autotile_code:
        call autotile_k
        ld e,a
        ld d,0
        ld hl,c7a_table
        add hl,de
        ld a,(hl)
        ret

c7a_table:  defb $00,$04,$02,$06,$01,$05,$03,$05
        ENDIF


; ============================================================================
;  8. DIRECT-TO-SCREEN DRAWING  (text, icons, logos, attribute fills)
; ============================================================================
; These write video RAM immediately and know nothing about WANT/SHOWN.  Use
; them for the HUD rows 0 and 23, whole-screen pages (title, game over) and
; the border columns.  If you draw on a playfield cell this way the engine
; will not know: call redraw_all afterwards (or cls_attr before a new page).
;
; Spectrum video RAM layout reminder:
;   bitmap: $4000 + (row & $18) * 256  +  (row & 7) * 32  +  col  for pixel
;           line 0 of the cell; pixel line n is n * 256 higher (hence `inc d`).
;   attribute: $5800 + row * 32 + col.
;   attribute byte = flash(7) bright(6) paper(5-3) ink(2-0).

; Address of the top pixel row of cell (row B, col C) -> DE.
; Clobbers AF, DE.  (B, C preserved.)
cell_addr:
        ld a,b
        and $18
        or $40
        ld d,a                  ; $40 + third * 8
        ld a,b
        and 7
        rrca
        rrca
        rrca                    ; (row & 7) * 32
        or c
        ld e,a
        ret

; Print the zero-terminated string at HL, starting at row B, column C, with
; attribute A.  Characters are 8x8 cells from `font` (ASCII 32..95; lower case
; is shown as upper case; anything below 32 prints a space).  The string does
; not wrap: keep it inside the row.  Sets (ps_attr).
print_str:
        ld (ps_attr),a
ps_loop:
        ld a,(hl)
        or a
        ret z
        push hl
        push bc
        call print_chr
        pop bc
        pop hl
        inc hl
        inc c
        jr ps_loop
ps_attr:    defb 7              ; attribute used by print_chr / print_num

; Print character A at row B, col C with attribute (ps_attr).
; Clobbers AF, DE, HL.
print_chr:
        cp 96
        jr c,pc_ok
        sub 32                  ; lower case -> upper
pc_ok:  sub 32                  ; font starts at space
        jr nc,pc_ok2
        xor a                   ; control characters -> space
pc_ok2: ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl               ; * 8 bytes per glyph
        ld de,font
        add hl,de
        push hl
        call cell_addr
        pop hl                  ; hl = glyph, de = screen
        push de
        ld b,8
pc_row: ld a,(hl)
        ld (de),a
        inc hl
        inc d                   ; next pixel line
        djnz pc_row
        pop de
        ld a,d                  ; attribute address: $58 + third
        rrca
        rrca
        rrca
        and 3
        or $58
        ld d,a
        ld a,(ps_attr)
        ld (de),a
        ret

; Print the unsigned 16-bit number HL in decimal, right aligned in A digits
; (A = 1..5, leading zeros shown as spaces, the last digit is always shown) at
; row B, column C, with attribute (ps_attr).  A number wider than A is cut at
; the left.
print_num:
        push bc
        ld (pn_width),a
        ld de,pn_buf
        ld bc,-10000
        call pn_digit
        ld bc,-1000
        call pn_digit
        ld bc,-100
        call pn_digit
        ld bc,-10
        call pn_digit
        ld bc,-1
        call pn_digit
        ld hl,pn_buf            ; leading zeros -> spaces (keep the last digit)
        ld b,4
pn_lz:  ld a,(hl)
        cp '0'
        jr nz,pn_lzd
        ld (hl),' '
        inc hl
        djnz pn_lz
pn_lzd: ld a,(pn_width)         ; start = buf + 5 - width
        ld c,a
        ld a,5
        sub c
        ld e,a
        ld d,0
        ld hl,pn_buf
        add hl,de
        pop bc
        ld a,(ps_attr)
        jp print_str
pn_digit:                       ; repeated subtraction: one decimal digit
        ld a,'0'-1
pnd1:   inc a
        add hl,bc
        jr c,pnd1
        sbc hl,bc
        ld (de),a
        inc de
        ret
pn_width:   defb 5
pn_buf:     defs 5
            defb 0              ; terminator for print_str

; Blank text row B (all 8 pixel lines, 32 cells) and give it attribute A.
; Clobbers everything.
clear_row:
        push af
        ld c,0
        call cell_addr
        ld b,8
cr_l:   push bc
        push de
        ld h,d
        ld l,e
        inc de
        ld (hl),0
        ld bc,31
        ldir                    ; one pixel line
        pop de
        pop bc
        inc d
        djnz cr_l
        dec d                   ; back to the last pixel line, to derive the attribute row
        ld a,d
        rrca
        rrca
        rrca
        and 3
        or $58
        ld d,a
        pop af
        ld h,d
        ld l,e
        inc de
        ld (hl),a
        ld bc,31
        ldir
        ret

; Draw a picture 2 cells wide and E cells high, stored as PIXEL ROWS (2 bytes
; per pixel line, left byte then right byte, 8*E lines), at row B, column C.
; This is the same format draw_gfx takes, so sprites can double as icons
; (the game draws the player's lives icon from the player sprite frame).
; Bitmap only: colour it with fill_attr.  Clobbers everything.
draw_icon:
        ld a,e
        ld (di_n),a
di_r:   push bc                 ; one cell row of the picture
        push hl
        call cell_addr
        pop hl
        ld b,8
di_l:   ld a,(hl)
        ld (de),a               ; left cell
        inc hl
        inc e
        ld a,(hl)
        ld (de),a               ; right cell
        inc hl
        dec e
        inc d                   ; next pixel line
        djnz di_l
        pop bc
        inc b
        ld a,(di_n)
        dec a
        ld (di_n),a
        jr nz,di_r
        ret
di_n:       defb 0

; Draw a D x E cell picture stored CELL BY CELL, row-major, 8 bytes per cell
; (the same layout spr_world / spr_screen take; a 17 x 5 cell title logo is
; an example), with its top-left at row B, column C.  Bitmap only.
; Clobbers everything.
draw_cells:
        ld a,d
        ld (dc_w),a
        ld a,e
        ld (dc_h),a
dc_r:   push bc                 ; start of this row of cells
        ld a,(dc_w)
        ld (dc_n),a
dc_c:   push bc
        push hl
        call cell_addr
        pop hl
        ld b,8
dc_b:   ld a,(hl)
        ld (de),a
        inc hl
        inc d
        djnz dc_b
        pop bc
        inc c                   ; next cell to the right
        ld a,(dc_n)
        dec a
        ld (dc_n),a
        jr nz,dc_c
        pop bc
        inc b                   ; next row of cells
        ld a,(dc_h)
        dec a
        ld (dc_h),a
        jr nz,dc_r
        ret
dc_w:       defb 0
dc_h:       defb 0
dc_n:       defb 0

; Fill a rectangle of attributes: A = attribute, B = row, C = col, D = width,
; E = height (cells; width and height >= 1).  Clobbers everything.
fill_attr:
        ld (fa_a),a
        ld a,e
        ld (fa_h),a
        ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; row * 32
        ld a,l
        or c
        ld l,a                  ; + col (row*32 has zero low 5 bits)
        ld a,h
        add a,$58
        ld h,a                  ; + $5800
fa_r:   push hl
        ld b,d
        ld a,(fa_a)
fa_c:   ld (hl),a
        inc hl
        djnz fa_c
        pop hl
        ld bc,32                ; next row
        add hl,bc
        ld a,(fa_h)
        dec a
        ld (fa_h),a
        jr nz,fa_r
        ret
fa_a:       defb 0
fa_h:       defb 0
