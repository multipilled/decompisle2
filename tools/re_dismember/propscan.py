"""Scan reflected property arrays for an owner that has properties at all the given offsets (static).
usage: python propscan.py 0x9c 0x90 0xa8"""
import re
import struct
import sys
import numpy as np
sys.path.insert(0, r"tools\re")
from di2exe import Exe, struct_members  # noqa: E402
e = Exe()
want = [int(x, 16) for x in sys.argv[1:]]
name, v, vs, raw, rs = e.sec(".rdata")
buf = np.frombuffer(e.m, dtype=np.uint8, count=rs // 8 * 8, offset=raw).view(np.uint64)
# FPropertyParamsBaseWithOffset: name ptr @0, offset i32 @0x24. Candidates: records whose i32 at +0x24 == want[0]
hits = set()
for i in range(0, len(buf) - 5):
    off = int(buf[i + 4] >> 32) & 0xFFFFFFFF
    if off != want[0]:
        continue
    nptr = int(buf[i])
    if not (0x144000000 <= nptr < 0x147000000):
        continue
    try:
        nm = e.cstr(nptr, 64)
    except Exception:
        continue
    if not nm or not re.fullmatch(r"[A-Za-z_]\w*", nm):
        continue
    at = v + i * 8
    ms = struct_members(e, at)
    offs = {m.get("offset") for m in ms}
    if all(w in offs for w in want):
        key = tuple(sorted((m["name"], m.get("offset", -1)) for m in ms))
        if key in hits:
            continue
        hits.add(key)
        print("== owner via", nm, hex(at))
        for m in sorted(ms, key=lambda m: m.get("offset", 1 << 30)):
            print(f"   {m['name']:36s} {m['kind']:10s} {m.get('offset', '')}")
