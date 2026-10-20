; ZXNESGFX self-test: ng_put_cell / ng_put_metatile / camera / mirror columns.
; Streams the screen (OUT ($FD)) after each stage; checked by test_putcell.py.
        org $8000
start:  di
        ld sp,$FDF0
        call ng_init
        ld hl,ts
        call ng_load_tileset
        call ng_cls
        call ng_draw            ; stage A: empty screen (full compare)
        call dump
        ld e,5                  ; visible cell
        ld b,10
        ld a,1
        call ng_put_cell
        ld e,10                 ; visible metatile -> cells 20-21, rows 6-7
        ld b,3
        ld a,1
        call ng_put_metatile
        ld e,40                 ; not visible: no redraw now
        ld b,10
        ld a,1
        call ng_put_cell
        call ng_draw            ; stage B: partial redraw of the changed cells
        call dump
        ld hl,40                ; camera to column 40: window = torus 40..71
        call ng_set_camera
        call ng_draw            ; stage C: full compare, col 5 seen through its mirror (69)
        call dump
        ld a,$EE
        out ($ff),a
        halt
dump:   ld hl,$4000
        ld bc,6912
dl:     ld a,(hl)
        out ($fd),a
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,dl
        ret
ts:     defb 2, 0                               ; 2 codes, code 0 plain
        defb 0,0,0,0,0,0,0,0                    ; code 0
        defb $81,$42,$24,$18,$18,$24,$42,$81    ; code 1
        defb $3F, $3A                           ; attributes
        defb 1, 1,1,1,1                         ; metatile 1 -> code 1 x4
        defb $FF
        include "zxnesgfx.asm"
