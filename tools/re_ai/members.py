"""Print the reflected members (name, kind, offset) of the native struct/class that owns a property name.

usage: python tools/re_ai/members.py <PropertyName> [more ...]
Every reflection record named <PropertyName> is resolved to its owner's whole property list (tools/re/di2exe.py).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe, struct_members  # noqa: E402

e = Exe()
for n in sys.argv[1:]:
    for sva in e.string_vas(n):
        for p in e.pointers_to(sva):
            try:
                ms = struct_members(e, p)
            except Exception as ex:  # noqa: BLE001
                print(n, hex(p), "error", ex)
                continue
            print(f"== {n} rec {hex(p)}: {len(ms)} members")
            for m in ms:
                print(f"  {m.get('offset', '-'):>6} {m['kind']:<10} {m['name']}")
