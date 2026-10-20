; ============================================================================
;  ZXNESGFX - scrolling tile engine for ZX Spectrum 48K ports of NES games
;  with VERTICAL MIRRORING (two name tables side by side, horizontal scroll)
;
;  Assembler: z88dk z80asm.   Documentation: README.md next to this file.
;  Origin: written for the Frog Prince (Super Mario Bros hack) port; derived
;  from the ideas of zxgfx.asm (diff drawing, dynamic sprite tiles).
; ============================================================================
;
;  THE MODEL IN ONE PAGE
;  ---------------------
;  * Everything on screen is 8x8 CELLS with ONE BYTE "code" each.  A code
;    stands for a bitmap (8 bytes) + a ZX attribute.  Codes come from a
;    TILESET made from PNGs by tools/zxconv.py.
;  * CELLMAP is the background: 64 columns x 24 rows of codes.  The 64
;    columns ARE the two NES name tables of a vertically mirrored game: NES
;    name table column 0-31 of $2000 = cell column 0-31, of $2400 = 32-63.
;    So a port writes new background columns exactly where the NES game
;    writes them, and the camera ("cam_cell") is the NES horizontal scroll / 8.
;    Each CELLMAP row is 128 bytes and columns 0-31 are repeated at 64-95, so
;    the 32-column window starting at any column is linear in memory.
;  * The screen is redrawn by DIFF: SHOWN holds the code shown in each of the
;    768 screen cells.  When the camera moves, the whole window is compared
;    with SHOWN and only the different cells are drawn (ng_draw); otherwise
;    only the cells touched by sprites or by ng_put_cell are checked.
;  * Codes:   $00            empty (backdrop) cell: ink = paper
;             $01..PLAIN     other plain-colour cells: ink = paper
;             PLAIN+1..$7F   cells with a bitmap
;             $80..$BE, $C0..$FE  sprite cells (two banks, alternate ticks)
;             $FE in SHOWN = "unknown, redraw";  $FF in SHOWN = HUD cell
;    Plain cells (all codes 0..PLAIN) are drawn by writing ONLY the attribute:
;    whatever pixels are left in the cell are invisible because ink = paper.
;  * Sprites are CHARACTER ALIGNED and do NOT MIX: a sprite cell shows the
;    sprite bitmap with the PAPER (+BRIGHT) of the background cell under it and
;    the INK of the sprite (inverted if it equals the paper).  A later sprite
;    in the same cell replaces the earlier one (drawing order = priority).
;    "Behind" sprites (ng_spr_behind = 1) are not drawn over non-empty cells.
;    A sprite code does not copy anything: it points to the sprite bitmap.
;  * Row 0 can hold a HUD: cells marked in ng_hud_mask are never touched by
;    the engine; you draw them with ng_hud_char.
;
;  PER-TICK PROTOCOL (see README for an example)
;  ---------------------------------------------
;     ng_wait_tick (A = frames per tick)   sync
;     ng_draw                              show what was prepared last tick
;     ng_spr_begin                         take last tick's sprites away
;     <game logic: move camera (ng_set_camera), write columns
;      (ng_put_mt_column / ng_put_cell / ng_put_metatile)>
;     ng_draw_meta / ng_spr_cell ...       this tick's sprites, back to front
;
;  REGISTERS: IY is reserved by the engine (IYH = page of the bit-reverse
;  table, used to mirror sprites).  Do not change IY after ng_init.
; ============================================================================

; ---------------------------------------------------------------- configuration
; Define any of these before including this file to move the buffers.
; All of them must be page aligned (low byte $00).
        IFNDEF NG_CM
NG_CM       equ $C000           ; CELLMAP: 24 rows x 128 bytes          (3 KB)
        ENDIF
        IFNDEF NG_SHOWN
NG_SHOWN    equ $CC00           ; codes on screen: 3 pages = 3 thirds  (768 B)
        ENDIF
        IFNDEF NG_TATTR
NG_TATTR    equ $CF00           ; attribute of every code              (256 B)
        ENDIF
        IFNDEF NG_MT
NG_MT       equ $D200           ; metatile id -> code: 4 pages TL,TR,BL,BR (1 KB)
        ENDIF
        IFNDEF NG_REV
NG_REV      equ $D600           ; bit-reversed bytes (sprite mirroring)  (256 B)
        ENDIF
        IFNDEF NG_TG
NG_TG       equ $D800           ; tile bitmaps, one page per pixel row:  (2 KB)
        ENDIF                   ;   row r of code c at NG_TG + r*256 + c
                                ;   (upper halves of pages 0-2: sprite slots)
        IFNDEF NG_IM2TAB
NG_IM2TAB   equ $FE00           ; IM 2 table (257 bytes of $FD)
        ENDIF
        IFNDEF NG_ISRVEC
NG_ISRVEC   equ $FDFD           ; "jp isr" at the IM 2 vector
        ENDIF
        IFNDEF NG_MT_ROWS
NG_MT_ROWS  equ 12              ; metatile rows of a column shown (2 cell rows each)
        ENDIF

NG_ROWS     equ 24              ; screen rows (fixed)
NG_DYN0     equ $80             ; first code of sprite bank 0
NG_DYN1     equ $C0             ; first code of sprite bank 1
NG_DYN_MAX  equ 63              ; sprite cells per tick
NG_HUDCODE  equ $FF             ; SHOWN value of a HUD cell
NG_DIRTY_MAX equ 24             ; ng_put_cell changes kept for the partial diff

; ============================================================================
;  1. FRAME COUNTER (interrupt mode 2)
; ============================================================================
; Install a 50 Hz interrupt that only counts frames.  Interrupts enabled.
; If your game has its own interrupt (music...), increment ng_frames in it.
ng_setup_im2:
        di
        ld hl,NG_IM2TAB
        ld (hl),$FD
        ld de,NG_IM2TAB+1
        ld bc,256
        ldir
        ld a,$C3                ; jp ngx_isr
        ld (NG_ISRVEC),a
        ld hl,ngx_isr
        ld (NG_ISRVEC+1),hl
        ld a,NG_IM2TAB/256
        ld i,a
        im 2
        ei
        ret

ngx_isr:
        push af
        push hl
        ld hl,(ng_frames)
        inc hl
        ld (ng_frames),hl
        pop hl
        pop af
        ei
        reti

ng_frames:      defw 0          ; frames since start
ngx_last_tick:  defw 0
ng_tick_used:   defb 0          ; frames the previous tick took

; Wait until at least A frames have passed since the previous call.
; Draw (ng_draw) right after this, while the beam is still in the top border.
ng_wait_tick:
        ld (ngx_wt_n+1),a
ngx_wt_l:
        ld hl,(ng_frames)
        ld de,(ngx_last_tick)
        or a
        sbc hl,de
        ld a,l
ngx_wt_n:
        cp 3                    ; (patched)
        jr nc,ngx_wt_ok
        halt
        jr ngx_wt_l
ngx_wt_ok:
        ld (ng_tick_used),a
        ld hl,(ng_frames)
        ld (ngx_last_tick),hl
        ret

; ============================================================================
;  2. INITIALISATION, TILESETS, SCREEN
; ============================================================================
; Call once: builds the bit-reverse table and sets IY.  Clears the HUD mask.
ng_init:
        ld hl,NG_REV
ngx_ir: ld a,l
        ld b,8
        ld c,0
ngx_irb:
        rra
        rl c
        djnz ngx_irb
        ld (hl),c
        inc l
        jr nz,ngx_ir
        ld iy,NG_REV            ; IY reserved from now on
        ld hl,ng_hud_mask
        ld b,32
ngx_ih: ld (hl),0
        inc hl
        djnz ngx_ih
        ret

; Load a tileset (format made by tools/zxconv.py build_tileset):
;     defb n            number of codes (1..128)
;     defb plain        last plain code (codes 0..plain: attribute only)
;     defb ...          n*8 bitmap bytes (code by code, top row first)
;     defb ...          n attributes
;     defb id,TL,TR,BL,BR ...  metatile -> 4 codes (optional), then $FF
; HL = tileset.  Unknown metatile ids map to code 0.
ng_load_tileset:
        ld a,(hl)
        ld (ngx_lt_n),a
        inc hl
        ld a,(hl)
        inc a
        ld (ngx_dt0_cp+1),a     ; patch the "plain" limit of the cell drawers
        ld (ngx_dt1_cp+1),a
        ld (ngx_dt2_cp+1),a
        inc hl
        ld c,0                  ; bitmaps -> one page per pixel row
ngx_lt_c:
        ld b,8
        ld d,NG_TG/256
        ld e,c
ngx_lt_r:
        ld a,(hl)
        ld (de),a
        inc hl
        inc d
        djnz ngx_lt_r
        inc c
        ld a,(ngx_lt_n)
        cp c
        jr nz,ngx_lt_c
        ld de,NG_TATTR          ; attributes
        ld b,0
        ld c,a
        ldir
        ld a,(NG_TATTR)
        ld (ng_back_attr),a
        push hl                 ; metatile tables
        ld hl,NG_MT
        ld de,NG_MT+1
        ld bc,4*256-1
        ld (hl),0
        ldir
        pop hl
ngx_lt_m:
        ld a,(hl)
        cp $FF
        ret z
        inc hl
        ld e,a
        ld d,NG_MT/256
        ld b,4
ngx_lt_4:
        ld a,(hl)
        ld (de),a
        inc hl
        inc d
        djnz ngx_lt_4
        jr ngx_lt_m
ngx_lt_n:       defb 0
ng_back_attr:   defb 0          ; attribute of code 0 (backdrop)

; Clear the screen to the backdrop attribute and force a full redraw.
ng_cls:
        ld hl,$4000
        ld de,$4001
        ld bc,6143
        ld (hl),0
        ldir
        ld hl,$5800
        ld de,$5801
        ld bc,767
        ld a,(ng_back_attr)
        ld (hl),a
        ldir
; Forget what is on screen: the next ng_draw redraws every cell (but the HUD).
ng_invalidate:
        ld hl,NG_SHOWN
        ld de,NG_SHOWN+1
        ld bc,767
        ld (hl),$FE
        ldir
        ld hl,ng_hud_mask
        ld de,NG_SHOWN
        ld b,32
ngx_iv: ld a,(hl)
        or a
        jr z,ngx_ivn
        ld a,NG_HUDCODE
        ld (de),a
ngx_ivn:
        inc hl
        inc e
        djnz ngx_iv
        ld a,1
        ld (ng_need_full),a
        ret

; ============================================================================
;  3. CAMERA AND BACKGROUND WRITES
; ============================================================================
ng_cam_cell:    defw 0          ; absolute cell column at the left screen edge
                                ; (= NES scroll / 8; only bits 0-5 matter)
ng_need_full:   defb 1          ; 1 = compare the whole window at the next draw

; HL = new camera cell.  Marks a full compare if it changed.
ng_set_camera:
        ld de,(ng_cam_cell)
        or a
        sbc hl,de
        ret z
        add hl,de
        ld (ng_cam_cell),hl
        ld a,1
        ld (ng_need_full),a
        ret

; Write one half of a METATILE COLUMN into CELLMAP column E (0..63).
;   HL = NG_MT_ROWS metatile ids, top to bottom
;   A  = 0 left half (TL/BL codes), 1 right half (TR/BR codes)
; Use it for columns that are NOT visible (ahead of the camera), like the NES
; writes name table columns ahead of the scroll.  Clobbers everything but IY.
ng_put_mt_column:
        add a,NG_MT/256
        ld (ngx_pm_top+1),a
        add a,2
        ld (ngx_pm_bot+1),a
        ld b,h
        ld c,l
        ld d,NG_CM/256
        ld a,NG_MT_ROWS
ngx_pm_l:
        push af
        ld a,(bc)
        inc bc
        ld l,a
ngx_pm_top:
        ld h,NG_MT/256          ; (patched)
        ld a,(hl)
        ld (de),a               ; even cell row
        bit 5,e
        jr nz,ngx_pm_1
        set 6,e
        ld (de),a               ; mirror (+64)
        res 6,e
ngx_pm_1:
ngx_pm_bot:
        ld h,NG_MT/256+2        ; (patched)
        ld a,(hl)
        set 7,e
        ld (de),a               ; odd cell row (+128)
        bit 5,e
        jr nz,ngx_pm_2
        set 6,e
        ld (de),a
        res 6,e
ngx_pm_2:
        res 7,e
        inc d
        pop af
        dec a
        jr nz,ngx_pm_l
        ret

; Change ONE background cell at any time between ng_spr_begin and the
; sprites (a broken brick, a collected coin...).
;   E = CELLMAP column (0..63), B = cell row (0..23), A = code
; If the cell is visible it is redrawn at the next ng_draw.
; Clobbers AF, BC, DE, HL.
ng_put_cell:
        ld c,a
        ld a,b                  ; HL = CM + row*128 + col (canonical)
        srl a
        add a,NG_CM/256
        ld h,a
        ld a,b
        rrca
        and $80
        or e
        ld l,a
        ld (hl),c
        bit 5,e
        jr nz,ngx_pc_nm
        set 6,l
        ld (hl),c               ; mirror
        res 6,l
ngx_pc_nm:
        ld a,(ng_need_full)
        or a
        ret nz                  ; full compare coming anyway
        ld a,(ng_cam_cell)      ; visible?  rel = (col - c0) & 63 < 32
        and 63
        ld d,a
        ld a,e
        sub d
        and 63
        cp 32
        ret nc
        ld (ngx_pc_col),a
        ld e,a                  ; e = screen column
        ld a,b
        or a
        jr nz,ngx_pc_nh
        push hl                 ; HUD cell: not ours
        ld hl,ng_hud_mask
        ld a,l
        add a,e
        ld l,a
        jr nc,ngx_pc_hm
        inc h
ngx_pc_hm:
        ld a,(hl)
        pop hl
        or a
        ret nz
ngx_pc_nh:
        ld a,l                  ; address the diff reads: row base + c0 + screen col
        and $80
        add a,d
        add a,e
        ld l,a
        push hl
        ld hl,ngx_dirty
        ld a,(hl)
        cp NG_DIRTY_MAX
        jr c,ngx_pc_add
        pop hl
        ld a,1                  ; list full: compare everything
        ld (ng_need_full),a
        ret
ngx_pc_add:
        inc (hl)
        add a,a
        add a,a
        inc a
        add a,l
        ld l,a
        jr nc,ngx_pc_a2
        inc h
ngx_pc_a2:
        pop de                  ; DE = CELLMAP address
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld a,b                  ; SHOWN low = (row & 7)*32 + screen col
        and 7
        rrca
        rrca
        rrca
        ld b,a
        ld a,(ngx_pc_col)
        or b
        ld (hl),a
        ret
ngx_pc_col:     defb 0

; Change one METATILE (4 cells): E = metatile column (0..31), B = metatile
; row (0..NG_MT_ROWS-1), A = metatile id.  Same rules as ng_put_cell.
ng_put_metatile:
        ld (ngx_pt_id),a
        ld a,e
        add a,a
        ld (ngx_pt_col),a
        ld a,b
        add a,a
        ld (ngx_pt_row),a
        ld c,0                  ; TL, TR, BL, BR
ngx_pt_l:
        push bc
        ld a,(ngx_pt_id)
        ld l,a
        ld a,c
        add a,NG_MT/256
        ld h,a
        ld a,(hl)               ; code
        push af
        ld a,c
        and 1
        ld e,a
        ld a,(ngx_pt_col)
        add a,e
        and 63
        ld e,a
        ld a,c
        srl a
        ld b,a
        ld a,(ngx_pt_row)
        add a,b
        ld b,a
        pop af
        call ng_put_cell
        pop bc
        inc c
        ld a,c
        cp 4
        jr nz,ngx_pt_l
        ret
ngx_pt_id:      defb 0
ngx_pt_col:     defb 0
ngx_pt_row:     defb 0

; ============================================================================
;  4. DIFF AND DRAW
; ============================================================================
; Draw the cell whose CELLMAP address is HL and SHOWN address is DE, in
; screen third P.  Preserves HL, DE.  Clobbers A, BC.
;   codes 0..PLAIN : attribute only (PLAIN patched by ng_load_tileset)
;   ..$7F          : attribute + 8 bytes from NG_TG
;   $80..          : attribute + 8 bytes from the sprite bitmap (slot)
MACRO NGX_DRAWCELL third, dc_cp, dc_end, dc_spr, dc_flip
        ld a,(hl)
        ld (de),a               ; SHOWN = new code
        push hl
        ld l,a
        ld h,NG_TATTR/256
        ld c,(hl)
        ld h,$58+third
        ld l,e
        ld (hl),c               ; attribute
dc_cp:  cp 1                    ; (patched: PLAIN+1)
        jr c,dc_end
        ld h,$40+third*8
        ld c,a
        ld b,NG_TG/256
        or a
        jp m,dc_spr
        REPT 7
        ld a,(bc)
        ld (hl),a
        inc b
        inc h
        ENDR
        ld a,(bc)
        ld (hl),a
dc_end: pop hl
        ret
dc_spr: push de                 ; slot: TG[code] = bitmap lo, TG+256 = hi, TG+512 = flip
        ld a,(bc)
        ld e,a
        inc b
        ld a,(bc)
        ld d,a
        inc b
        ld a,(bc)
        or a
        jr nz,dc_flip
        REPT 7
        ld a,(de)
        ld (hl),a
        inc de
        inc h
        ENDR
        ld a,(de)
        ld (hl),a
        pop de
        pop hl
        ret
dc_flip:
        REPT 7
        ld a,(de)
        ld iyl,a
        ld a,(iy+0)
        ld (hl),a
        inc de
        inc h
        ENDR
        ld a,(de)
        ld iyl,a
        ld a,(iy+0)
        ld (hl),a
        pop de
        pop hl
        ret
ENDM

ngx_draw_t0: NGX_DRAWCELL 0, ngx_dt0_cp, ngx_dt0_end, ngx_dt0_spr, ngx_dt0_flip
ngx_draw_t1: NGX_DRAWCELL 1, ngx_dt1_cp, ngx_dt1_end, ngx_dt1_spr, ngx_dt1_flip
ngx_draw_t2: NGX_DRAWCELL 2, ngx_dt2_cp, ngx_dt2_end, ngx_dt2_spr, ngx_dt2_flip

ngx_draw_any:                   ; third from D
        ld a,d
        sub NG_SHOWN/256
        jp z,ngx_draw_t0
        dec a
        jp z,ngx_draw_t1
        jp ngx_draw_t2

; one row of 32 cells, unrolled.  HL = CELLMAP, DE = SHOWN.
MACRO NGX_DIFFROW third
        REPT 31
        ld a,(de)
        cp (hl)
        call nz,ngx_draw_t0+third*(ngx_draw_t1-ngx_draw_t0)
        inc l
        inc e
        ENDR
        ld a,(de)
        cp (hl)
        call nz,ngx_draw_t0+third*(ngx_draw_t1-ngx_draw_t0)
ENDM

; Put the prepared frame on the screen.  Call right after ng_wait_tick.
ng_draw:
        ld a,(ng_need_full)
        or a
        jp z,ngx_diff_part

ngx_diff_full:
        xor a
        ld (ng_need_full),a
        ld (ngx_dirty),a        ; (full compare covers them)
        ld a,(ng_cam_cell)
        and 63
        ld (ngx_df_c0),a
        ld l,a                  ; ---- row 0: masked by the HUD
        ld h,NG_CM/256
        ld de,NG_SHOWN
        ld ix,ng_hud_mask
        ld b,32
ngx_df_r0:
        ld a,(ix+0)
        or a
        jr nz,ngx_df_r0n
        ld a,(de)
        cp (hl)
        push bc
        call nz,ngx_draw_t0
        pop bc
ngx_df_r0n:
        inc ix
        inc l
        inc e
        djnz ngx_df_r0
        ld b,1                  ; ---- rows 1..23
ngx_df_row:
        push bc
        ld a,b                  ; HL = CM + row*128 + c0
        rra
        ld a,(ngx_df_c0)
        jr nc,ngx_df_ev
        add a,128
ngx_df_ev:
        ld l,a
        ld a,b
        srl a
        add a,NG_CM/256
        ld h,a
        ld a,b                  ; DE = SHOWN + (row>>3)*256 + (row&7)*32
        and 7
        rrca
        rrca
        rrca
        ld e,a
        ld a,b
        rrca
        rrca
        rrca
        and 3
        add a,NG_SHOWN/256
        ld d,a
        sub NG_SHOWN/256
        jr z,ngx_df_0
        dec a
        jr z,ngx_df_1
        call ngx_df_row2
        jr ngx_df_nx
ngx_df_0:
        call ngx_df_row0
        jr ngx_df_nx
ngx_df_1:
        call ngx_df_row1
ngx_df_nx:
        pop bc
        inc b
        ld a,b
        cp NG_ROWS
        jr nz,ngx_df_row
        ret
ngx_df_c0:      defb 0
ngx_df_row0:    NGX_DIFFROW 0
        ret
ngx_df_row1:    NGX_DIFFROW 1
        ret
ngx_df_row2:    NGX_DIFFROW 2
        ret

; Partial: previous and current sprite cells + cells changed by ng_put_cell.
ngx_diff_part:
        ld hl,(ngx_sl_prev)
        call ngx_dp_list
        ld hl,(ngx_sl_cur)
        call ngx_dp_list
        ld hl,ngx_dirty
        call ngx_dp_list
        xor a
        ld (ngx_dirty),a
        ret
ngx_dp_list:                    ; HL = count, then records: CM addr, old, SHOWN low
        ld a,(hl)
        or a
        ret z
        ld b,a
        inc hl
ngx_dp_l:
        push bc
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        inc hl
        ld c,(hl)
        inc hl
        push hl
        ex de,hl                ; HL = CELLMAP cell
        ld a,h                  ; row = 2*(H - CM page) + bit 7 of L
        sub NG_CM/256
        add a,a
        bit 7,l
        jr z,ngx_dp_ev
        inc a
ngx_dp_ev:
        srl a                   ; third
        srl a
        srl a
        add a,NG_SHOWN/256
        ld d,a
        ld e,c
        ld a,(de)
        cp (hl)
        call nz,ngx_draw_any
        pop hl
        pop bc
        djnz ngx_dp_l
        ret

ngx_dirty:      defs 1+NG_DIRTY_MAX*4

; ============================================================================
;  5. SPRITES
; ============================================================================
; record lists: count, then per cell: CELLMAP address (2), code under it (1),
; SHOWN low byte (1)
ngx_sl_a:       defs 1+NG_DYN_MAX*4
ngx_sl_b:       defs 1+NG_DYN_MAX*4
ngx_sl_cur:     defw ngx_sl_a
ngx_sl_prev:    defw ngx_sl_b
ngx_sl_wp:      defw ngx_sl_a+1
ngx_bank:       defb 0
ngx_next:       defb NG_DYN0
ngx_end:        defb NG_DYN0+NG_DYN_MAX
ng_spr_flip:    defb 0          ; 1 = mirror the next sprites horizontally
ng_spr_behind:  defb 0          ; 1 = do not draw over non-empty background

; Take the previous tick's sprites out of CELLMAP and start a new list.
; Call once per tick, BEFORE changing the background or the camera.
ng_spr_begin:
        ld hl,(ngx_sl_cur)
        ld a,(hl)
        or a
        jr z,ngx_sb_sw
        ld b,a                  ; walk the records backwards
        ld e,a
        ld d,0
        ex de,hl
        add hl,hl
        add hl,hl
        add hl,de               ; -> last byte of the last record
ngx_sb_l:
        dec hl
        ld c,(hl)
        dec hl
        ld d,(hl)
        dec hl
        ld e,(hl)
        ld a,c
        ld (de),a
        dec hl
        djnz ngx_sb_l
ngx_sb_sw:
        ld hl,(ngx_sl_cur)
        ld de,(ngx_sl_prev)
        ld (ngx_sl_prev),hl
        ld (ngx_sl_cur),de
        xor a
        ld (de),a
        inc de
        ld (ngx_sl_wp),de
        ld a,(ngx_bank)
        xor 1
        ld (ngx_bank),a
        ld a,NG_DYN0
        jr z,ngx_sb_b
        ld a,NG_DYN1
ngx_sb_b:
        ld (ngx_next),a
        add a,NG_DYN_MAX
        ld (ngx_end),a
        ret

; One 8x8 sprite cell.
;   B = screen row (0..23), C = screen column (0..31; outside = clipped)
;   HL = 8 bitmap bytes (top row first), A = ink (bits 0-2)
; Clobbers AF, BC, DE, HL.
ng_spr_cell:
        ld (ngx_ink),a
        ld a,c
        cp 32
        ret nc
        ld a,b
        cp NG_ROWS
        ret nc
        or a
        jr nz,ngx_sc_nh
        push hl                 ; row 0: HUD cells are not ours
        ld hl,ng_hud_mask
        ld a,l
        add a,c
        ld l,a
        jr nc,ngx_sc_hm
        inc h
ngx_sc_hm:
        ld a,(hl)
        pop hl
        or a
        ret nz
ngx_sc_nh:
        ld a,c
        ld (ngx_col),a
        ex de,hl                ; DE = bitmap
        ld a,(ng_cam_cell)      ; HL = CM + row*128 + c0 + col
        and 63
        add a,c
        bit 0,b
        jr z,ngx_sc_ev
        add a,128
ngx_sc_ev:
        ld l,a
        ld a,b
        srl a
        add a,NG_CM/256
        ld h,a
        ld a,(hl)
        cp NG_DYN0
        jr nc,ngx_sc_re         ; another sprite here this tick: replace it
        ld c,a
        or a
        jr z,ngx_sc_new
        ld a,(ng_spr_behind)
        or a
        ret nz
ngx_sc_new:
        ld a,(ngx_end)          ; allocate a code
        push bc
        ld b,a
        ld a,(ngx_next)
        cp b
        pop bc
        ret z                   ; none left: cell dropped
        ld (ngx_code),a
        inc a
        ld (ngx_next),a
        dec a
        ld (hl),a
        push de                 ; record
        ex de,hl
        ld hl,(ngx_sl_wp)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld a,b
        and 7
        rrca
        rrca
        rrca
        ld b,a
        ld a,(ngx_col)
        or b
        ld (hl),a
        inc hl
        ld (ngx_sl_wp),hl
        ld hl,(ngx_sl_cur)
        inc (hl)
        pop de
        ld l,c
        ld h,NG_TATTR/256
        ld a,(hl)
        jr ngx_sc_slot
ngx_sc_re:
        ld (ngx_code),a
        ld l,a
        ld h,NG_TATTR/256
        ld a,(hl)
ngx_sc_slot:
        call ngx_mkattr
        ld c,a
        ld a,(ngx_code)
        ld l,a
        ld h,NG_TATTR/256
        ld (hl),c
        ld h,NG_TG/256          ; slot
        ld (hl),e
        inc h
        ld (hl),d
        inc h
        ld a,(ng_spr_flip)
        ld (hl),a
        ret

; A = attribute with the paper (+bright) -> same paper/bright, ink (ngx_ink)
; (xor 7 if it equals the paper).  Clobbers only AF.
ngx_mkattr:
        push bc
        and $78
        ld b,a
        rrca
        rrca
        rrca
        and 7
        ld c,a
        ld a,(ngx_ink)
        and 7
        cp c
        jr nz,ngx_mk1
        xor 7
ngx_mk1:
        or b
        pop bc
        ret
ngx_ink:        defb 0
ngx_col:        defb 0
ngx_code:       defb 0

; A metasprite frame (format made by tools/zxconv.py build_sprites):
;     defb w, h         size in cells
;     then w*h cells, row by row: defb ink, 8 bitmap bytes   or   defb $FF (empty)
; B = top row, C = left column (signed: may be partly off-screen),
; HL = frame.  Uses ng_spr_flip / ng_spr_behind.  Clobbers all but IX/IY.
ng_draw_meta:
        ld a,(hl)
        ld (ngx_w),a
        inc hl
        ld a,(hl)
        ld (ngx_h),a
        inc hl
        ld a,b
        ld (ngx_row),a
        ld a,(ng_spr_flip)
        ld (ngx_mf_flip+1),a
        or a
        ld a,$0C                ; inc c
        jr z,ngx_m_f0
        ld a,(ngx_w)            ; mirrored: start at the right end, dec c
        dec a
        add a,c
        ld c,a
        ld a,$0D                ; dec c
ngx_m_f0:
        ld (ngx_mf_step),a
        ld (ngx_m0_step),a
        ld a,c
        ld (ngx_mcol),a
ngx_m_row:
        ld a,(ngx_w)
        ld b,a
        ld a,(ngx_mcol)
        ld c,a
        ld a,(ngx_row)
        cp NG_ROWS
        jp nc,ngx_m_skip
        or a
        jp z,ngx_m_r0
        ld e,a                  ; patch the row constants of the fast path
        srl a
        add a,NG_CM/256
        ld (ngx_mf_hi+1),a
        ld a,e
        and 1
        rrca
        ld d,a
        ld a,(ng_cam_cell)
        and 63
        add a,d
        ld (ngx_mf_lo+1),a
        ld a,e
        and 7
        rrca
        rrca
        rrca
        ld (ngx_mf_slo+1),a
ngx_mf_cell:
        ld a,(hl)
        inc hl
        cp $FF
        jr z,ngx_mf_next
        ld (ngx_ink),a
        ld a,c
        cp 32
        jr nc,ngx_mf_skip8
        ld (ngx_colv),a
ngx_mf_lo:
        add a,0                 ; (patched) c0 + 128*(row & 1)
        ld e,a
ngx_mf_hi:
        ld d,0                  ; (patched) CM page of the row
        ld a,(de)
        cp NG_DYN0
        jr nc,ngx_mf_re
        or a
        jr z,ngx_mf_new
        ld a,(ng_spr_behind)
        or a
        jr nz,ngx_mf_skip8
        ld a,(de)
ngx_mf_new:
        push bc
        ld c,a
        ld a,(ngx_end)
        ld b,a
        ld a,(ngx_next)
        cp b
        jr z,ngx_mf_full
        ld (de),a
        ld b,a
        inc a
        ld (ngx_next),a
        push hl
        ld hl,(ngx_sl_wp)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld a,(ngx_colv)
ngx_mf_slo:
        add a,0                 ; (patched) (row & 7) * 32
        ld (hl),a
        inc hl
        ld (ngx_sl_wp),hl
        ld hl,(ngx_sl_cur)
        inc (hl)
        ld l,c
        ld h,NG_TATTR/256
        ld a,(hl)
        ld c,b
        pop hl
        jr ngx_mf_slot
ngx_mf_re:
        push bc
        ld c,a
        push hl
        ld l,a
        ld h,NG_TATTR/256
        ld a,(hl)
        pop hl
ngx_mf_slot:
        call ngx_mkattr
        ld e,c
        ld d,NG_TATTR/256
        ld (de),a
        ld d,NG_TG/256
        ld a,l
        ld (de),a
        inc d
        ld a,h
        ld (de),a
        inc d
ngx_mf_flip:
        ld a,0                  ; (patched)
        ld (de),a
        pop bc
ngx_mf_skip8:
        ld de,8
        add hl,de
ngx_mf_next:
ngx_mf_step:
        inc c                   ; (patched: inc c / dec c)
        djnz ngx_mf_cell
        jr ngx_m_end
ngx_mf_full:
        pop bc
        jr ngx_mf_skip8
ngx_m_skip:                     ; row off-screen: walk the data
        ld a,(hl)
        inc hl
        cp $FF
        jr z,ngx_m_s1
        ld de,8
        add hl,de
ngx_m_s1:
        djnz ngx_m_skip
        jr ngx_m_end
ngx_m_r0:                       ; row 0: through ng_spr_cell (HUD mask)
        ld a,(hl)
        inc hl
        cp $FF
        jr z,ngx_m_r0n
        push bc
        push hl
        ld b,0
        call ng_spr_cell
        pop hl
        pop bc
        ld de,8
        add hl,de
ngx_m_r0n:
ngx_m0_step:
        inc c                   ; (patched)
        djnz ngx_m_r0
ngx_m_end:
        ld a,(ngx_row)
        inc a
        ld (ngx_row),a
        ld a,(ngx_h)
        dec a
        ld (ngx_h),a
        jp nz,ngx_m_row
        ret
ngx_w:          defb 0
ngx_h:          defb 0
ngx_row:        defb 0
ngx_mcol:       defb 0
ngx_colv:       defb 0

; ============================================================================
;  6. HUD (row 0 cells excluded from the engine, drawn directly)
; ============================================================================
ng_hud_mask:    defs 32         ; 1 = column of row 0 belongs to the HUD
ng_font:        defw 0          ; font: 8 bytes per character

; HL = list of row-0 columns that belong to the HUD, $FF terminated.
; Call before ng_cls / ng_invalidate.
ng_hud_cells:
        ld a,(hl)
        cp $FF
        ret z
        ld e,a
        ld d,0
        push hl
        ld hl,ng_hud_mask
        add hl,de
        ld (hl),1
        pop hl
        inc hl
        jr ng_hud_cells

; Print character A (index into ng_font) at row 0, column C, attribute B.
ng_hud_char:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,(ng_font)
        add hl,de
        ld e,c
        ld d,$58
        ld a,b
        ld (de),a
        ld d,$40
        ld b,8
ngx_hc: ld a,(hl)
        ld (de),a
        inc hl
        inc d
        djnz ngx_hc
        ret
