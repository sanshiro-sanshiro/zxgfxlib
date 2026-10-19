; ============================================================================
;  ZXGFX demo: scrolling world + two pixel-positioned sprites that overlap
;  Build:  C:\z88dk\bin\z80asm.exe -b -m demo.asm      -> demo.bin (org $8000)
;  Run:    load demo.bin at $8000, jp $8000  (or from BASIC: LOAD ""CODE: RANDOMIZE USR 32768)
;
;  What it shows, in the order of the per-tick protocol described in zxgfx.asm:
;    - setup: IM2 timer, tile RAM, shift tables, palette, window
;    - a world made with world_put / world_block (one dirty flag set for all)
;    - HUD text, number, icon, cell picture and attribute fill drawn directly
;    - a loop with: wait_frames, diff_draw, logic, build_want, spr_begin, sprites
; ============================================================================
        org $8000
        jp start
        include "zxgfx.asm"     ; (the library first: its constants, e.g. GFX_NTILES, are used below)

font        equ $3D00           ; the Spectrum ROM font (ASCII 32..127, 8 bytes each)
                                ; is a free source for print_str / print_chr

start:
        di
        ld sp,$BFF0             ; stack just below SPRBUF ($C000)
        call setup_im2          ; 50 Hz frame counter
        call init_tiles         ; static tile bitmaps -> TILEGFX
        call init_shift         ; shift tables for the blitter
        ld a,1                  ; round background: blue paper, not bright
        call set_round_attrs
        ld a,(bg_attr)
        call cls_attr           ; clear screen, force full redraw
        call init_window        ; HUD rows reserved, black side borders

        ; --- build the world ----------------------------------------------
        ld hl,WORLD             ; clear the 896 cells
        ld de,WORLD+1
        ld bc,895
        ld (hl),0
        ldir
        ld c,0                  ; ground: top bevel on row 21, bricks on row 22
gr_l:   ld b,21
        ld a,2
        call world_put
        ld b,22
        ld a,1
        call world_put
        inc c
        ld a,c
        cp 32
        jr nz,gr_l
        ld hl,plat1             ; a 4 x 1 platform of bricks at col 10,row 15
        ld bc,15*256+10
        ld de,4*256+1           ; D = width 4, E = height 1
        call world_block
        ld hl,plat2             ; a 3 x 2 block at col 20,row 12
        ld bc,12*256+20
        ld de,3*256+2
        call world_block

        ; --- HUD, drawn directly to the screen ---------------------------
        ld hl,txt_hud
        ld bc,0                 ; row 0, col 0
        ld a,$47                ; bright white on black
        call print_str
        ld hl,1234              ; number, 5 wide
        ld bc,12
        ld a,5
        call print_num
        ld hl,spr_a             ; the sprite's first 8 pixel lines as an icon
        ld bc,23*256+1          ; row 23, col 1
        ld e,1
        call draw_icon
        ld a,$46
        ld bc,23*256+1
        ld de,2*256+1           ; 2 x 1 cells
        call fill_attr
        ld hl,tile_gfx_src+8    ; tiles 1 and 2 as a 2 x 1 "picture"
        ld bc,23*256+5
        ld de,2*256+1
        call draw_cells
        ld a,$44
        ld bc,23*256+5
        ld de,2*256+1
        call fill_attr

        call prime              ; first frame: build_want, spr_begin, sprites
loop:
        ld a,3                  ; 16.7 ticks per second
        call wait_frames
        call diff_draw          ; show the frame prepared last time
        ld hl,tick
        inc (hl)
        ld a,(hl)
        and 7
        jr nz,no_scroll         ; every 8 ticks the camera moves one cell
        ld hl,view_x
        inc (hl)
        ld a,(hl)
        and 31
        ld (hl),a
no_scroll:
        call prime
        jr loop

; Prepare the next frame: world window and sprites.
prime:
        call build_want
        call spr_begin
        ld a,(view_x)
        add a,a
        add a,a
        add a,a                 ; world x of the screen's left edge
        ld d,a
        ld a,(tick)
        and 63
        add a,a
        add a,40
        add a,d
        ld b,a                  ; sprite A: sweeps 2 px per tick
        ld c,100
        ld a,7                  ; white
        ld (dg_ink),a
        ld hl,spr_a
        ld a,24
        call draw_gfx
        ld a,(view_x)
        add a,a
        add a,a
        add a,a
        add a,100
        ld b,a                  ; sprite B: fixed on screen, not on a cell boundary
        ld c,108
        ld a,2                  ; red, drawn last: its colour wins where they overlap
        ld (dg_ink),a
        ld hl,spr_a
        ld a,24
        jp draw_gfx

tick:       defb 0
txt_hud:    defb "ZXGFX DEMO  SCORE",0
plat1:      defb 1,1,1,1
plat2:      defb 2,2,2, 1,1,1

; a 16 x 24 sprite: rounded body with eyes
spr_a:
        defb $07,$E0, $1F,$F8, $3F,$FC
        defb $7F,$FE, $7F,$FE, $FF,$FF
        defb $E6,$67, $E6,$67, $FF,$FF
        defb $FF,$FF, $FF,$FF, $FF,$FF
        defb $E0,$07, $E0,$07, $E0,$07
        defb $FF,$FF, $7F,$FE, $7F,$FE
        defb $3F,$FC, $1F,$F8, $0F,$F0
        defb $18,$18, $38,$1C, $78,$1E

; static tiles (GFX_NTILES = $A0 of them; only 3 are defined)
tile_gfx_src:
        defb 0,0,0,0,0,0,0,0                    ; $00 empty
        defb $FF,$80,$80,$80,$FF,$08,$08,$08    ; $01 brick
        defb $FF,$FF,$FF,$00,$00,$00,$00,$00    ; $02 top bevel
        defs GFX_NTILES*8-24, 0
tile_cls:
        defb $80                ; $00 empty
        defb $46                ; $01 fixed attribute: bright yellow on black
        defb $81                ; $02 top bevel: white ink on the round paper
        defs GFX_NTILES-3, $80

