"""Convert a 6912-byte ZX screen dump (.scr) to PNG.  python tools/scr2png.py in.scr out.png [scale]"""
import sys
from PIL import Image
sys.path.insert(0, __import__('os').path.dirname(__file__))
from zxpal import zx_rgb
d = open(sys.argv[1], 'rb').read()
sc = int(sys.argv[3]) if len(sys.argv) > 3 else 2
im = Image.new('RGB', (256, 192))
for y in range(192):
    for cx in range(32):
        b = d[((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | cx]
        a = d[6144 + (y >> 3) * 32 + cx]
        ink, paper, br = zx_rgb(a & 7, a & 64), zx_rgb((a >> 3) & 7, a & 64), 0
        for x in range(8):
            im.putpixel((cx * 8 + x, y), ink if b & (0x80 >> x) else paper)
im.resize((256 * sc, 192 * sc), Image.NEAREST).save(sys.argv[2])
