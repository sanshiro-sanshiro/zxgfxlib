"""DEV: summarise the markers logged by the zxrun harness."""
import sys, statistics as st
ev = [l.split() for l in open(sys.argv[1]) if l.startswith('M ')]
ticks, cur = [], None
for _, m, t in ev:
    m, t = int(m), int(t)
    if m == 1:
        if cur: ticks.append(cur)
        cur = {1: t}
    elif cur is not None:
        cur[m] = t
F = 69888
rows = []
for a, b in zip(ticks, ticks[1:]):
    if 4 not in a: continue
    rows.append(dict(full=6 in a, diff=a[2]-a[1], logic=a[3]-a[2], spr=a[4]-a[3],
                     busy=a[4]-a[1], frames=round((b[1]-a[1])/F)))
rows = rows[1:]  # skip the very first full screen draw
def show(name, sel):
    if not sel: return
    for k in ('diff', 'logic', 'spr', 'busy'):
        v = sorted(r[k] for r in sel); n = len(v)
        print('  %-5s %-6s media %6.0f  p50 %6d  p95 %6d  max %6d' % (name, k, st.mean(v), v[n//2], v[int(n*.95)], v[-1]))
    fr = [r['frames'] for r in sel]
    print('  %-5s ticks %d, frames/tick: %s' % (name, len(sel), {k: fr.count(k) for k in sorted(set(fr))}))
show('full', [r for r in rows if r['full']])
show('part', [r for r in rows if not r['full']])
