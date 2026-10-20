"""DEV: T-states per routine from the harness profile (prof.bin) and the z80asm map."""
import sys, struct, re, bisect
prof = struct.unpack('<65536Q', open(sys.argv[1], 'rb').read())
labs = []
for l in open(sys.argv[2]):
    m = re.match(r'(\w+)\s+= \$([0-9A-F]{4}) ; addr', l)
    if m: labs.append((int(m.group(2), 16), m.group(1)))
labs.sort(); ks = [a for a, _ in labs]
agg = {}
for pc, t in enumerate(prof):
    if t:
        i = bisect.bisect_right(ks, pc) - 1
        name = labs[i][1] if i >= 0 else '?'
        agg[name] = agg.get(name, 0) + t
tot = sum(agg.values())
for n, t in sorted(agg.items(), key=lambda x: -x[1])[:int(sys.argv[3]) if len(sys.argv) > 3 else 25]:
    print('%-16s %10d %5.1f%%' % (n, t, 100 * t / tot))
