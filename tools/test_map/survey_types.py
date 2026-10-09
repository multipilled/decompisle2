"""Counts export types across all dumped map JSONs whose type or property names mention a pattern."""
import collections, glob, json, re, sys
rx = re.compile(sys.argv[1], re.I)
types, props = collections.Counter(), collections.Counter()
where = {}
for f in glob.glob(r"extracted\json\DeadIsland\Content\DI2\**\Maps\**\*.json", recursive=True):
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(d, list):
        continue
    for e in d:
        t = e.get("Type", "")
        if rx.search(t):
            types[t] += 1; where.setdefault(t, f)
        for k in (e.get("Properties") or {}):
            if rx.search(k):
                props[(t, k)] += 1; where.setdefault((t, k), f)
print(types.most_common(40))
for k, n in props.most_common(60):
    print(n, k, where[k].split("Content\\")[1])
