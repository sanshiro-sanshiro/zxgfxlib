; ============================================================================
;  ZXNESGFXV - vertical scrolling tile engine for ZX Spectrum 48K ports of
;  NES games with VERTICAL SCROLLING and 2x2-cell (16x16 px) metatiles.
;
;  Assembler: z88dk z80asm.   Derived from zxnesgfx (horizontal), same model.
;
;  THE MODEL
;  ---------
;  * Everything on screen is an 8x8 CELL with a ONE BYTE code (bitmap + ZX
;    attribute) from a TILESET (tools/zxconv.py).
;  * CELLMAP is a RING of NG_RING = 24 rows x 32 columns of codes (768 bytes).
;    World cell row w lives in ring slot  w mod 24.  A metatile row is two
;    cell rows (2m, 2m+1); both land in an even/odd slot pair, never across
;    the wrap, because 24 is even.
;  * The scrolling window is NG_VIS = 22 ring rows (screen rows 2..23), starting
;    at world row ng_cam_row.  The 2 remaining ring slots are HIDDEN: that is
;    where the next metatile row is written, before it scrolls in.
;    Screen rows 0 and 1 are the fixed HUD: the engine never touches them.
;  * RULE: when the top row t is EVEN, write metatile row t/2-1 (world rows
;    t-2, t-1) with ng_put_mt_row.  Those are exactly the two hidden slots.
;  * The screen is redrawn by DIFF against SHOWN (768 bytes = one code per
;    screen cell, laid out like the screen thirds).  When the camera moved all
;    22 rows are compared; otherwise only cells touched by sprites or by
;    ng_put_cell are checked.
;  * Codes:   $00            empty (backdrop) cell: ink = paper
;             $01..PLAIN     other plain cells: ink = paper, attribute only
;             PLAIN+1..$7F   cells with a bitmap
;             $80..$BE, $C0..$FE  sprite cells (two banks, alternate ticks)
;             $FE in SHOWN = "unknown, redraw";  $FF = HUD cell
;  * Sprites are CELL ALIGNED, do not mix with the background: a sprite cell
;    shows the sprite bitmap with the PAPER (+BRIGHT) of the cell under it and
;    its own INK (xor 7 if it equals the paper).  Later sprites replace
;    earlier ones in the same cell.  ng_spr_behind=1: not drawn over non-empty
;    background.  ng_spr_flip=1: mirrored horizontally.  IY is reserved.
;
;  PER-TICK PROTOCOL
;  -----------------
;     ng_wait_tick (A = frames per tick)
;     ng_draw                    show what was prepared last tick
;     ng_spr_begin               take last tick's sprites away
;     <logic: ng_scroll_to, ng_put_mt_row, ng_put_cell, ng_put_metatile>
;     ng_draw_meta / ng_spr_cell sprites of this tick, back to front
; ============================================================================

        IFNDEF NG_CM
NG_CM       equ $C000           ; ring: 24 rows x 32 bytes = 3 pages
        ENDIF
        IFNDEF NG_SHOWN
NG_SHOWN    equ $C300           ; 768 bytes: code on each screen cell
        ENDIF
        IFNDEF NG_TATTR
NG_TATTR    equ $C600           ; 256 bytes: attribute of every code
        ENDIF
        IFNDEF NG_MT
NG_MT       equ $C700           ; metatile id -> code: 4 pages TL,TR,BL,BR
        ENDIF
        IFNDEF NG_REV
NG_REV      equ $CB00           ; bit-reversed bytes (sprite mirroring)
        ENDIF
        IFNDEF NG_TG
NG_TG       equ $CC00           ; tile bitmaps, one page per pixel row (2 KB)
        ENDIF
        IFNDEF NG_IM2TAB
NG_IM2TAB   equ $FE00
        ENDIF
        IFNDEF NG_ISRVEC
NG_ISRVEC   equ $FDFD
        ENDIF

NG_RING     equ 24              ; ring rows
NG_VIS      equ 22              ; visible scrolling rows
NG_HUD      equ 2               ; fixed HUD rows on top
NG_ROWS     equ 24              ; screen rows
NG_DYN0     equ $80
NG_DYN1     equ $C0
NG_DYN_MAX  equ 63
NG_HUDCODE  equ $FF
NG_DIRTY_MAX equ 24
NG_REC      equ 5               ; bytes per record: CM lo,hi, old, SHOWN lo,hi

; ============================================================================
;  1. FRAME COUNTER (interrupt mode 2)
; ============================================================================
ng_setup_im2:
        di
        ld hl,NG_IM2TAB
        ld (hl),$FD
        ld de,NG_IM2TAB+1
        ld bc,256
        ldir
        ld a,$C3
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
        IFDEF NG_ISR_HOOK
        push bc
        push de
        call NG_ISR_HOOK
        pop de
        pop bc
        ENDIF
        pop hl
        pop af
        ei
        reti

ng_frames:      defw 0
ngx_last_tick:  defw 0
ng_tick_used:   defb 0

; Wait until at least A frames have passed since the previous call.
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
        ret

; HL = tileset (format: tools/zxconv.py build_tileset)
ng_load_tileset:
        ld a,(hl)
        ld (ngx_lt_n),a
        inc hl
        ld a,(hl)
        inc a
        ld (ngx_dt0_cp+1),a
        ld (ngx_dt1_cp+1),a
        ld (ngx_dt2_cp+1),a
        inc hl
        ld c,0
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
        ld de,NG_TATTR
        ld b,0
        ld c,a
        ldir
        ld a,(NG_TATTR)
        ld (ng_back_attr),a
        push hl
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
ng_back_attr:   defb 0

; Clear the screen (pixels + attributes) and force a full redraw.
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
; Forget what is on screen: next ng_draw redraws every scrolling cell.
ng_invalidate:
        ld hl,NG_SHOWN
        ld de,NG_SHOWN+1
        ld bc,767
        ld (hl),$FE
        ldir
        ld hl,NG_SHOWN          ; HUD rows
        ld de,NG_SHOWN+1
        ld bc,NG_HUD*32-1
        ld (hl),NG_HUDCODE
        ldir
        ld a,1
        ld (ng_need_full),a
        ret

; ============================================================================
;  3. CAMERA AND BACKGROUND WRITES
; ============================================================================
ng_cam_row:     defb 0          ; world cell row at the top of the window
ng_top:         defb 0          ; its ring slot (= ng_cam_row mod 24)
ng_need_full:   defb 1

; A = new world cell row at the window top (0..255-NG_VIS+1).
ng_scroll_to:
        ld hl,ng_cam_row
        cp (hl)
        ret z
        ld (hl),a
ngx_st:
        cp NG_RING
        jr c,ngx_st2
        sub NG_RING
        jr ngx_st
ngx_st2:
        ld (ng_top),a
        ld a,1
        ld (ng_need_full),a
        ret

; B = screen row (NG_HUD..23)  ->  HL = ring row base, DE = SHOWN row base.
; Destroys A only besides HL, DE.  Keeps B, C.
ngx_rowaddrs:
        ld a,(ng_top)
        add a,b
        sub NG_HUD
        cp NG_RING
        jr c,ngx_ra1
        sub NG_RING
ngx_ra1:
        rrca
        rrca
        rrca
        ld l,a
        and 3
        add a,NG_CM/256
        ld h,a
        ld a,l
        and $E0
        ld l,a
        ld a,b
        rrca
        rrca
        rrca
        ld e,a
        and 3
        add a,NG_SHOWN/256
        ld d,a
        ld a,e
        and $E0
        ld e,a
        ret

; Write one metatile row: HL = 16 metatile ids, E = world metatile row (0..127).
; Writes world cell rows 2E and 2E+1.  Call only for the two hidden slots
; (see RULE above).  Clobbers all but IY.
ng_put_mt_row:
        ld a,e
        add a,a                 ; world cell row 2E (even)
ngx_pr1:
        cp NG_RING
        jr c,ngx_pr2
        sub NG_RING
        jr ngx_pr1
ngx_pr2:                        ; A = even ring slot 0..22
        rrca
        rrca
        rrca
        ld e,a
        and 3
        add a,NG_CM/256
        ld d,a
        ld a,e
        and $E0
        ld e,a                  ; DE = top row base, bit 5 clear
        ld b,h
        ld c,l                  ; BC = ids
        ld a,16
ngx_pr_l:
        ex af,af'
        ld a,(bc)
        inc bc
        ld l,a
        ld h,NG_MT/256
        ld a,(hl)               ; TL
        ld (de),a
        ld h,NG_MT/256+2
        ld a,(hl)               ; BL
        set 5,e
        ld (de),a
        res 5,e
        inc e
        ld h,NG_MT/256+1
        ld a,(hl)               ; TR
        ld (de),a
        ld h,NG_MT/256+3
        ld a,(hl)               ; BR
        set 5,e
        ld (de),a
        res 5,e
        inc e
        ex af,af'
        dec a
        jr nz,ngx_pr_l
        ret

; Change ONE background cell:  E = column (0..31), B = world cell row (0..255),
; A = code.  If visible it is redrawn at the next ng_draw.  Clobbers AF,BC,DE,HL.
ng_put_cell:
        ld c,a
        ld a,b
ngx_pc1:
        cp NG_RING
        jr c,ngx_pc2
        sub NG_RING
        jr ngx_pc1
ngx_pc2:
        rrca
        rrca
        rrca
        ld d,a
        and $E0
        or e
        ld l,a
        ld a,d
        and 3
        add a,NG_CM/256
        ld h,a
        ld (hl),c
        ld a,(ng_need_full)
        or a
        ret nz                  ; full compare coming anyway
        ld a,(ng_cam_row)
        ld d,a
        ld a,b
        sub d
        cp NG_VIS
        ret nc                  ; not in the window
        add a,NG_HUD            ; screen row
        push hl                 ; CM address
        ld d,a
        ld a,(ngx_dirty)
        cp NG_DIRTY_MAX
        jr c,ngx_pc_ok
        pop hl
        ld a,1
        ld (ng_need_full),a
        ret
ngx_pc_ok:
        ld a,d                  ; SHOWN address -> BC
        rrca
        rrca
        rrca
        ld d,a
        and $E0
        or e
        ld c,a
        ld a,d
        and 3
        add a,NG_SHOWN/256
        ld b,a
        ld hl,ngx_dirty
        ld a,(hl)
        inc (hl)
        ld e,a                  ; record = ngx_dirty+1 + count*5
        ld d,0
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        ld de,ngx_dirty+1
        add hl,de
        pop de                  ; CM address
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        inc hl                  ; old code not used for these
        ld (hl),c
        inc hl
        ld (hl),b
        ret

; One METATILE (4 cells): E = metatile column (0..15), B = world metatile row,
; A = metatile id.
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
; Draw the cell whose CELLMAP address is HL and SHOWN address is DE, screen
; third `third`.  Preserves HL, DE.  Clobbers A, BC.
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
dc_spr: push de
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

; one row of 32 cells, unrolled.  HL = ring row, DE = SHOWN row.
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

ngx_df_row0:    NGX_DIFFROW 0
        ret
ngx_df_row1:    NGX_DIFFROW 1
        ret
ngx_df_row2:    NGX_DIFFROW 2
        ret

; Put the prepared frame on the screen.  Call right after ng_wait_tick.
ng_draw:
        ld a,(ng_need_full)
        or a
        jp z,ngx_diff_part
        xor a
        ld (ng_need_full),a
        ld (ngx_dirty),a        ; (the full compare covers them)
        ld b,NG_HUD
ngx_df_l:
        push bc
        call ngx_rowaddrs
        ld a,b
        cp 8
        jr c,ngx_df_a
        cp 16
        jr c,ngx_df_b
        call ngx_df_row2
        jr ngx_df_n
ngx_df_a:
        call ngx_df_row0
        jr ngx_df_n
ngx_df_b:
        call ngx_df_row1
ngx_df_n:
        pop bc
        inc b
        ld a,b
        cp NG_ROWS
        jr nz,ngx_df_l
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
ngx_dp_list:                    ; HL = count, then NG_REC-byte records
        ld a,(hl)
        or a
        ret z
        ld b,a
        inc hl
ngx_dp_l:
        push bc
        ld c,(hl)
        inc hl
        ld b,(hl)               ; BC = CM address
        inc hl
        inc hl                  ; skip old code
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = SHOWN address
        inc hl
        push hl
        ld h,b
        ld l,c
        ld a,(de)
        cp (hl)
        call nz,ngx_draw_any
        pop hl
        pop bc
        djnz ngx_dp_l
        ret

ngx_dirty:      defs 1+NG_DIRTY_MAX*NG_REC

; ============================================================================
;  5. SPRITES
; ============================================================================
ngx_sl_a:       defs 1+NG_DYN_MAX*NG_REC
ngx_sl_b:       defs 1+NG_DYN_MAX*NG_REC
ngx_sl_cur:     defw ngx_sl_a
ngx_sl_prev:    defw ngx_sl_b
ngx_sl_wp:      defw ngx_sl_a+1
ngx_bank:       defb 0
ngx_next:       defb NG_DYN0
ngx_end:        defb NG_DYN0+NG_DYN_MAX
ng_spr_flip:    defb 0
ng_spr_behind:  defb 0

; Take the previous tick's sprites out of the ring and start a new list.
; Call once per tick, BEFORE changing the background or the camera.
ng_spr_begin:
        ld hl,(ngx_sl_cur)
        ld a,(hl)
        or a
        jr z,ngx_sb_sw
        ld b,a
        inc hl
ngx_sb_l:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)               ; old background code
        inc hl
        inc hl
        inc hl
        ld (de),a
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

; Shared tail of every sprite cell.
;   HL = ring cell, DE = SHOWN cell, BC = 8 bitmap bytes, (ngx_ink) = ink
; Clobbers all.
ngx_put_sprcell:
        ld a,(hl)
        cp NG_DYN0
        jr nc,ngx_ps_re         ; another sprite here: replace it
        ld (ngx_old),a
        or a
        jr z,ngx_ps_new
        ld a,(ng_spr_behind)
        or a
        ret nz
ngx_ps_new:
        ld a,(ngx_next)
        push hl
        ld hl,ngx_end
        cp (hl)
        pop hl
        ret z                   ; no codes left: cell dropped
        ld (ngx_code),a
        inc a
        ld (ngx_next),a
        dec a
        ld (hl),a               ; ring cell = new code
        push bc
        push de                 ; SHOWN
        push hl                 ; ring cell
        ld hl,(ngx_sl_wp)
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(ngx_old)
        ld (hl),a
        inc hl
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (ngx_sl_wp),hl
        ld hl,(ngx_sl_cur)
        inc (hl)
        pop bc
        ld a,(ngx_old)
        ld l,a
        ld h,NG_TATTR/256
        ld a,(hl)
        jr ngx_ps_slot
ngx_ps_re:
        ld (ngx_code),a
        ld l,a
        ld h,NG_TATTR/256
        ld a,(hl)
ngx_ps_slot:
        call ngx_mkattr
        ld d,a
        ld a,(ngx_code)
        ld l,a
        ld h,NG_TATTR/256
        ld (hl),d
        ld h,NG_TG/256
        ld (hl),c
        inc h
        ld (hl),b
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
ngx_old:        defb 0
ngx_code:       defb 0
ngx_col:        defb 0

; One 8x8 sprite cell.
;   B = screen row (0..23; rows < NG_HUD clipped), C = screen column (0..31)
;   HL = 8 bitmap bytes (top row first), A = ink (bits 0-2)
ng_spr_cell:
        ld (ngx_ink),a
        ld a,c
        cp 32
        ret nc
        ld a,b
        cp NG_ROWS
        ret nc
        cp NG_HUD
        ret c
        push hl
        call ngx_rowaddrs
        ld a,c
        add a,l
        ld l,a
        ld a,c
        add a,e
        ld e,a
        pop bc
        jp ngx_put_sprcell

; A metasprite frame (tools/zxconv.py build_sprites):
;     defb w, h         size in cells
;     then w*h cells, row by row: defb ink, 8 bitmap bytes   or   defb $FF
; HL = frame, B = top screen row, C = left column (signed: may be off-screen)
ng_draw_meta:
        ld a,(hl)
        ld (ngx_w),a
        inc hl
        ld a,(hl)
        ld (ngx_h),a
        inc hl
        ld (ngx_fp),hl
        ld a,b
        ld (ngx_row),a
        ld a,(ng_spr_flip)
        or a
        ld a,$3C                ; inc a
        jr z,ngx_m_f0
        ld a,(ngx_w)            ; mirrored: start at the right end, step left
        dec a
        add a,c
        ld c,a
        ld a,$3D                ; dec a
ngx_m_f0:
        ld (ngx_m_step),a
        ld a,c
        ld (ngx_mcol),a
ngx_m_row:
        ld a,(ngx_row)
        cp NG_ROWS
        jr nc,ngx_m_skip
        cp NG_HUD
        jr c,ngx_m_skip
        ld b,a
        call ngx_rowaddrs
        ld (ngx_rb),hl
        ld (ngx_sb),de
        ld a,(ngx_w)
        ld (ngx_wc),a
        ld a,(ngx_mcol)
        ld (ngx_cc),a
ngx_m_cell:
        ld hl,(ngx_fp)
        ld a,(hl)
        inc hl
        cp $FF
        jr z,ngx_m_adv          ; empty cell: no bitmap follows
        ld (ngx_ink),a
        ld (ngx_bm),hl
        ld de,8
        add hl,de
        ld (ngx_fp),hl
        ld a,(ngx_cc)
        cp 32
        jr nc,ngx_m_adv2        ; off-screen column
        ld hl,(ngx_rb)
        add a,l
        ld l,a
        ld de,(ngx_sb)
        ld a,(ngx_cc)
        add a,e
        ld e,a
        ld bc,(ngx_bm)
        call ngx_put_sprcell
        jr ngx_m_adv2
ngx_m_adv:
        ld (ngx_fp),hl
ngx_m_adv2:
        ld a,(ngx_cc)
ngx_m_step:
        inc a                   ; (patched: inc a / dec a)
        ld (ngx_cc),a
        ld hl,ngx_wc
        dec (hl)
        jr nz,ngx_m_cell
        jr ngx_m_end
ngx_m_skip:                     ; row off-screen or HUD: walk the data
        ld hl,(ngx_fp)
        ld a,(ngx_w)
        ld b,a
ngx_ms: ld a,(hl)
        inc hl
        cp $FF
        jr z,ngx_ms1
        ld de,8
        add hl,de
ngx_ms1:
        djnz ngx_ms
        ld (ngx_fp),hl
ngx_m_end:
        ld hl,ngx_row
        inc (hl)
        ld hl,ngx_h
        dec (hl)
        jp nz,ngx_m_row
        ret
ngx_w:          defb 0
ngx_h:          defb 0
ngx_row:        defb 0
ngx_mcol:       defb 0
ngx_cc:         defb 0
ngx_wc:         defb 0
ngx_fp:         defw 0
ngx_bm:         defw 0
ngx_rb:         defw 0
ngx_sb:         defw 0

; ============================================================================
;  6. HUD (rows 0 and 1, never touched by the engine; drawn directly)
; ============================================================================
ng_font:        defw 0          ; font: 8 bytes per character

; A = character (index into ng_font), B = attribute, C = column, D = row (0/1)
ng_hud_char:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        push de
        ld de,(ng_font)
        add hl,de
        pop de
        ld a,d
        rrca
        rrca
        rrca
        or c
        ld e,a
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

; HL = string of font indices ending in $FF, B = attribute, C = first column,
; D = row.  Preserves nothing.
ng_hud_str:
        ld a,(hl)
        cp $FF
        ret z
        push hl
        push bc
        push de
        call ng_hud_char
        pop de
        pop bc
        pop hl
        inc hl
        inc c
        jr ng_hud_str
