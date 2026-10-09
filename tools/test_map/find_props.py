"""Print every export (and nested path) in a JSON dump whose property names match a regex.
    python tools/test_map/find_props.py <json file> <regex>"""
import json, re, sys
rx = re.compile(sys.argv[2], re.I)


def walk(v, path, out):
    if isinstance(v, dict):
        for k, x in v.items():
            if rx.search(k):
                out.append((path + "." + k, x))
            walk(x, path + "." + k, out)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            walk(x, "%s[%d]" % (path, i), out)


for e in json.load(open(sys.argv[1], encoding="utf-8")):
    out = []
    walk(e, "", out)
    for p, x in out:
        print(e.get("Type"), e.get("Name"), p, json.dumps(x)[:300])
