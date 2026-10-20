"""Make a .tap with a BASIC loader:  10 CLEAR start-1: LOAD ""CODE: RANDOMIZE USR entry

    python tools/mktap.py bin/frogzx.tap frogzx 8000 bin/frogzx_data.bin@6000 bin/frogzx_code.bin@8000

The binaries (one per assembler SECTION) are merged into one memory image that
starts at the lowest address; gaps are filled with zeros.  The image is also
written next to the .tap as .img (for the test harness).
"""
import struct
import sys


def number(n):
    """ASCII digits + hidden 5-byte small-integer form, as the ROM stores them."""
    return str(n).encode() + bytes([0x0E, 0, 0, n & 0xFF, n >> 8, 0])


def block(flag, data):
    body = bytes([flag]) + data
    x = 0
    for b in body:
        x ^= b
    body += bytes([x])
    return struct.pack('<H', len(body)) + body


def header(kind, name, length, p1, p2):
    name = name.encode()[:10].ljust(10)
    return block(0x00, bytes([kind]) + name + struct.pack('<HHH', length, p1, p2))


def main():
    out, name, entry = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
    parts = []
    for spec in sys.argv[4:]:
        f, at = spec.rsplit('@', 1)
        parts.append((int(at, 16), open(f, 'rb').read()))
    start = min(a for a, _ in parts)
    end = max(a + len(d) for a, d in parts)
    img = bytearray(end - start)
    for a, d in sorted(parts):
        if any(img[a - start:a - start + len(d)]):
            raise SystemExit('sections overlap at $%04X' % a)
        img[a - start:a - start + len(d)] = d
    if end > 0xC000:
        raise SystemExit('image ends at $%04X: overlaps the engine tables at $C000' % end)
    CLEAR, LOAD, CODE, RANDOMIZE, USR = 0xFD, 0xEF, 0xAF, 0xF9, 0xC0
    line = (bytes([CLEAR]) + number(start - 1) + b':' + bytes([LOAD]) + b'""' + bytes([CODE]) +
            b':' + bytes([RANDOMIZE, USR]) + number(entry) + b'\r')
    prog = struct.pack('>H', 10) + struct.pack('<H', len(line)) + line
    tap = header(0, name, len(prog), 10, len(prog)) + block(0xFF, prog)
    tap += header(3, name, len(img), start, 32768) + block(0xFF, bytes(img))
    open(out, 'wb').write(tap)
    open(out.rsplit('.', 1)[0] + '.img', 'wb').write(img)
    for a, d in sorted(parts):
        print('  $%04X-$%04X  %5d bytes' % (a, a + len(d) - 1, len(d)))
    print('%s: image $%04X-$%04X, entry $%04X' % (out, start, end - 1, entry))


if __name__ == '__main__':
    main()
