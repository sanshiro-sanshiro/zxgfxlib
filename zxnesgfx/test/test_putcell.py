"""Self-test of zxnesgfx background writes.  python test_putcell.py (needs ZASM, ZXRUN)."""
import os, subprocess, sys
H = os.path.dirname(os.path.abspath(__file__))
ZASM = os.environ.get('ZASM', 'z88dk-z80asm'); ZXRUN = os.environ.get('ZXRUN', 'zxrun')
tmp = os.path.join(H, 'out'); os.makedirs(tmp, exist_ok=True)
subprocess.run([ZASM, '-b', '-I' + os.path.dirname(H), '-o' + os.path.join(tmp, 't.bin'),
                os.path.join(H, 'test_putcell.asm')], check=True)
subprocess.run([ZXRUN, '-load', os.path.join(tmp, 't.bin') + '@8000', '-entry', '8000',
                '-frames', '50', '-out', os.path.join(tmp, 's.bin')], check=True, stdout=subprocess.DEVNULL)
d = open(os.path.join(tmp, 's.bin'), 'rb').read()
st = [d[i * 6912:(i + 1) * 6912] for i in range(3)]
PAT = [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81]
def cell(s, r, c):
    a = s[6144 + r * 32 + c]
    px = [s[((r & 0x18) << 8) | (y << 8) | ((r & 7) << 5) | c] for y in range(8)]
    return a, px
def expect(s, cells, name):
    bad = []
    for r in range(24):
        for c in range(32):
            a, px = cell(s, r, c)
            if (r, c) in cells:
                if a != 0x3A or px != PAT: bad.append((r, c, 'should be the tile'))
            elif a != 0x3F: bad.append((r, c, 'should be backdrop'))
    print('%s: %s' % (name, 'OK' if not bad else 'FAIL %s' % bad[:5]))
    return not bad
ok = expect(st[0], set(), 'A empty screen')
ok &= expect(st[1], {(10, 5), (6, 20), (6, 21), (7, 20), (7, 21)}, 'B put_cell + put_metatile (partial redraw)')
ok &= expect(st[2], {(10, 29), (10, 0)}, 'C camera 40 (mirror columns)')
sys.exit(0 if ok else 1)
