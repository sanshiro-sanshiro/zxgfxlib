"""ZX Spectrum palette helpers and NES -> ZX colour mapping (shared by the tools)."""

# ZX colours 0..7 (black, blue, red, magenta, green, cyan, yellow, white)
_BASE = [(0, 0, 0), (0, 0, 1), (1, 0, 0), (1, 0, 1), (0, 1, 0), (0, 1, 1), (1, 1, 0), (1, 1, 1)]


def zx_rgb(colour, bright):
    v = 0xFF if bright else 0xD7
    r, g, b = _BASE[colour & 7]
    return (r * v, g * v, b * v)


# every distinct RGB a ZX can show -> (colour, bright).  Black is (0, 0).
ZX_FROM_RGB = {}
for _c in range(8):
    for _b in (0, 1):
        ZX_FROM_RGB.setdefault(zx_rgb(_c, _b), (_c, _b))


def rgb_to_zx(rgb):
    """Exact or nearest ZX colour for an RGB triple -> (colour, bright)."""
    rgb = tuple(rgb[:3])
    if rgb in ZX_FROM_RGB:
        return ZX_FROM_RGB[rgb]
    best = min(ZX_FROM_RGB, key=lambda k: sum((a - b) ** 2 for a, b in zip(k, rgb)))
    return ZX_FROM_RGB[best]


# Hand-picked NES colour -> ZX colour (colour, bright).  Edit freely: it only
# matters for the one-off extraction from the ROM; afterwards the PNGs rule.
NES_TO_ZX = {
    0x0F: (0, 0), 0x0D: (0, 0), 0x1D: (0, 0), 0x3F: (0, 0), 0x2F: (0, 0), 0x1F: (0, 0),
    0x22: (5, 1),             # sky
    0x0C: (1, 0),             # underground / castle backdrop
    0x29: (4, 1), 0x2A: (4, 1), 0x3A: (4, 1), 0x1A: (4, 0), 0x19: (4, 0), 0x09: (4, 0), 0x0A: (4, 0),
    0x36: (6, 1), 0x37: (6, 1), 0x38: (6, 1), 0x28: (6, 1), 0x27: (6, 0), 0x18: (6, 0),
    0x17: (2, 0), 0x16: (2, 1), 0x06: (2, 0), 0x07: (2, 0),
    0x30: (7, 1), 0x20: (7, 1), 0x10: (7, 0), 0x00: (7, 0), 0x3D: (7, 0), 0x2D: (7, 0),
    0x21: (5, 1), 0x31: (5, 1), 0x3C: (5, 1), 0x2C: (5, 1), 0x1C: (5, 0), 0x0B: (5, 0), 0x2B: (5, 1),
    0x11: (1, 1), 0x12: (1, 1), 0x01: (1, 0), 0x02: (1, 0), 0x32: (1, 1),
    0x15: (3, 1), 0x25: (3, 1), 0x24: (3, 1), 0x14: (3, 1), 0x34: (3, 1), 0x35: (3, 1),
}


def nes_to_zx(index):
    return NES_TO_ZX.get(index & 0x3F, (7, 0))
