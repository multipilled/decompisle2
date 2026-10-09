"""Paths that differ between two JSON files (first N).  usage: python tools/re_ai/json_diff.py <a> <b> [key] [N]"""
import json, sys
a = json.load(open(sys.argv[1], encoding='utf-8'))
b = json.load(open(sys.argv[2], encoding='utf-8'))
if len(sys.argv) > 3 and sys.argv[3]:
    a, b = a.get(sys.argv[3]), b.get(sys.argv[3])
N = int(sys.argv[4]) if len(sys.argv) > 4 else 20
out = []


def walk(x, y, p):
    if len(out) >= N:
        return
    if type(x) != type(y):
        out.append((p, str(x)[:80], str(y)[:80]))
    elif isinstance(x, dict):
        for k in sorted(set(x) | set(y)):
            walk(x.get(k, '<none>'), y.get(k, '<none>'), p + '.' + k)
    elif isinstance(x, list):
        if len(x) != len(y):
            out.append((p, 'len %d' % len(x), 'len %d' % len(y)))
        for i, (u, v) in enumerate(zip(x, y)):
            walk(u, v, '%s[%d]' % (p, i))
    elif x != y:
        out.append((p, str(x)[:80], str(y)[:80]))


walk(a, b, '')
for o in out:
    print(*o, sep='  |  ')
