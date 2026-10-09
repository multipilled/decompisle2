"""Dump UE4.27 reflection members of the struct/class that owns a given property name (static, via tools/re/di2exe.py).
usage: python refl.py PropName [PropName ...]   (prints every owner struct found for each name)"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, struct_members  # noqa: E402

e = Exe()
seen = set()
for name in sys.argv[1:]:
    for r in e.props_named(name):
        if "error" in r:
            continue
        ms = struct_members(e, int(r["at"], 16))
        key = tuple(m["name"] for m in ms)
        if not ms or key in seen:
            continue
        seen.add(key)
        print(f"== owner of {name} (param {r['at']}), {len(ms)} members")
        for m in sorted(ms, key=lambda m: m.get("offset", 1 << 30)):
            extra = f"off {m['offset']:#x}" if "offset" in m else f"bool setbit {m.get('setbit')}"
            print(f"   {m['name']:40s} {m['kind']:12s} {extra}")
