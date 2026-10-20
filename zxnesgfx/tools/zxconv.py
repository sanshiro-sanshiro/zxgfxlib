"""ZXNESGFX graphics conversion: PNG -> assembler data for zxnesgfx.asm.

Use from a project's build script:

    import sys; sys.path.insert(0, 'lib/zxnesgfx/tools')
    from zxconv import build_tileset, build_sprites, build_font, BuildError

TILESETS  (backgrounds, for ng_load_tileset)
    A PNG of 16x16 METATILE SLOTS, 16 per row: the slot at (row, col) is
    metatile id row*16 + col (NES-style ids up to $FF).  Only the ids you ask
    for are converted.  Slot $00 (top-left) must be one flat colour: it is the
    BACKDROP, and becomes code 0.
    Rules per 8x8 cell: exact ZX colours only, at most 2 colours, one BRIGHT
    (black counts as both).  With 2 colours, PAPER is chosen by paper_rule:
        'dark'      the darker colour (ZX order black < blue < ... < white)
        'backdrop'  the backdrop colour if present, else the most common one
    One-colour cells become "plain" cells (ink = paper): they get the lowest
    codes and are drawn with the attribute only.  Identical cells share a
    code.  A tileset has at most 128 codes (the rest are for sprites).
    For tile-based (non-metatile) games simply use the 2x2 cells of each slot
    as you like and ignore the metatile table, or put one tile per slot.

SPRITES  (metasprites, for ng_draw_meta)
    A PNG named <name>_<W>x<H>.png: frames of WxH pixels side by side, in
    display order, transparent background (alpha 0).  One ink colour per 8x8
    cell.  Produces spr_<name> (table of frame pointers) and spr_<name>_<k>.

FONT  (for ng_hud_char)
    A PNG strip of 8x8 characters (light pixels = ink).
"""
import os
from collections import Counter
from PIL import Image

from zxpal import rgb_to_zx


class BuildError(Exception):
    pass


def db(values, per_line=16):
    values = list(values)
    return '\n'.join('        defb ' + ','.join('$%02X' % v for v in values[i:i + per_line])
                     for i in range(0, len(values), per_line))


def read_cell(im, x0, y0, where, backdrop, paper_rule='dark'):
    """8x8 cell of a background PNG -> (8 bitmap bytes, attribute, plain?)."""
    cols = [[rgb_to_zx(im.getpixel((x0 + x, y0 + y))) for x in range(8)] for y in range(8)]
    count = Counter(c for row in cols for (c, b) in row)
    if len(count) > 2:
        raise BuildError('%s: more than 2 colours in the cell at pixel (%d,%d)' % (where, x0, y0))
    brights = {b for row in cols for (c, b) in row if c != 0}
    if len(brights) > 1:
        raise BuildError('%s: mixed BRIGHT in the cell at pixel (%d,%d)' % (where, x0, y0))
    bright = brights.pop() if brights else backdrop[1]
    if len(count) == 1:
        c = next(iter(count))
        return [0] * 8, (bright << 6) | (c << 3) | c, True
    if paper_rule == 'dark':
        paper = min(count)
    elif backdrop[0] in count:
        paper = backdrop[0]
    else:
        paper = count.most_common(1)[0][0]
    ink = [c for c in count if c != paper][0]
    data = []
    for row in cols:
        v = 0
        for (c, b) in row:
            v = (v << 1) | (1 if c != paper else 0)
        data.append(v)
    return data, (bright << 6) | (paper << 3) | ink, False


def build_tileset(label, png, ids, paper_rule='dark', max_codes=128):
    """Tileset `label` from the metatile slots `ids` of `png` -> (asm text, info)."""
    im = Image.open(png).convert('RGB')
    backdrop = rgb_to_zx(im.getpixel((0, 0)))
    sky = read_cell(im, 0, 0, png, backdrop, paper_rule)
    if not sky[2]:
        raise BuildError('%s: metatile $00 (top-left slot) must be one flat colour (the backdrop)' % png)
    cells = {(tuple(sky[0]), sky[1]): True}
    order = [(tuple(sky[0]), sky[1])]
    mt_cells = []
    for mid in sorted(set(ids) | {0}):
        ox, oy = (mid % 16) * 16, (mid // 16) * 16
        four = []
        for dx, dy in ((0, 0), (8, 0), (0, 8), (8, 8)):          # TL TR BL BR
            data, attr, plain = read_cell(im, ox + dx, oy + dy, png, backdrop, paper_rule)
            key = (tuple(data), attr)
            if key not in cells:
                cells[key] = plain
                order.append(key)
            four.append(key)
        mt_cells.append((mid, four))
    order = [order[0]] + [k for k in order[1:] if cells[k]] + [k for k in order[1:] if not cells[k]]
    nplain = sum(1 for k in order if cells[k])
    if len(order) > max_codes:
        raise BuildError('%s: %d different cells, maximum %d' % (png, len(order), max_codes))
    code = {k: i for i, k in enumerate(order)}
    mt = [(mid,) + tuple(code[k] for k in four) for mid, four in mt_cells]
    out = ['; generated from %s - do not edit' % os.path.basename(png),
           '; %d metatiles, %d cell codes, codes 0..%d are plain (attribute only)'
           % (len(mt), len(order), nplain - 1),
           '%s:' % label,
           '        defb %d       ; codes' % len(order),
           '        defb %d       ; last plain code' % (nplain - 1),
           db(b for k in order for b in k[0]),
           db(k[1] for k in order),
           '        ; metatile id, TL, TR, BL, BR']
    out += ['        defb $%02X,%d,%d,%d,%d' % m for m in mt]
    out.append('        defb $FF')
    return '\n'.join(out) + '\n', {'metatiles': len(mt), 'codes': len(order), 'plain': nplain}


def build_sprites(png):
    """Metasprite sheet <name>_<W>x<H>.png -> (asm text, info)."""
    base = os.path.splitext(os.path.basename(png))[0]
    name, size = base.rsplit('_', 1)
    w, h = (int(v) for v in size.split('x'))
    if w % 8 or h % 8:
        raise BuildError('%s: frame size must be a multiple of 8' % png)
    im = Image.open(png).convert('RGBA')
    nframes = im.width // w
    warnings = []
    out = ['; generated from %s - do not edit' % os.path.basename(png), 'spr_%s:' % name]
    out += ['        defw spr_%s_%d' % (name, f) for f in range(nframes)]
    for f in range(nframes):
        out.append('spr_%s_%d:  defb %d,%d' % (name, f, w // 8, h // 8))
        for cy in range(h // 8):
            for cx in range(w // 8):
                x0, y0 = f * w + cx * 8, cy * 8
                ink = Counter()
                rows = []
                for y in range(8):
                    v = 0
                    for x in range(8):
                        p = im.getpixel((x0 + x, y0 + y))
                        on = p[3] >= 128
                        v = (v << 1) | on
                        if on:
                            ink[rgb_to_zx(p)] += 1
                    rows.append(v)
                if not ink:
                    out.append('        defb $FF')
                    continue
                if len(ink) > 1:
                    warnings.append('%s frame %d cell (%d,%d): %d colours, using the most common'
                                    % (base, f, cx, cy, len(ink)))
                c, b = ink.most_common(1)[0][0]
                out.append('        defb $%02X' % ((b << 6) | c))
                out.append(db(rows))
    return '\n'.join(out) + '\n', {'name': name, 'frames': nframes, 'w': w, 'h': h, 'warnings': warnings}


def build_font(label, png, nchars):
    """Strip of 8x8 characters -> asm text (8 bytes per character)."""
    im = Image.open(png).convert('RGB')
    data = []
    for i in range(nchars):
        for y in range(8):
            v = 0
            for x in range(8):
                v = (v << 1) | (1 if sum(im.getpixel((i * 8 + x, y))) > 384 else 0)
            data.append(v)
    return '; generated from %s - do not edit\n%s:\n%s\n' % (os.path.basename(png), label, db(data))
