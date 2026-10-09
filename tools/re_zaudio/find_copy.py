"""Functions whose code uses both displacement A and displacement B ([reg+disp32] memory operands), e.g. a field
copy between two classes. Static exe reading only.
usage: python tools/re_zaudio/find_copy.py <dispA> <dispB> [<dispC> ...]
"""
import re
import struct
import sys
from collections import defaultdict

sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

e = Exe()
_, v, vs, raw, rs = e.sec(".text")
data = e.m[raw:raw + rs]
disps = [int(x, 0) for x in sys.argv[1:]]
hit = defaultdict(set)
for d in disps:
    # opcode byte(s) then a ModRM with mod=10 (0x80-0xBF), rm != 100 (no SIB) then disp32
    pat = re.compile(rb"[\x80-\xbf]" + re.escape(struct.pack("<I", d)))
    for m in pat.finditer(data):
        modrm = data[m.start()]
        if (modrm & 7) == 4:
            continue
        f = e.func_of(v + m.start())
        if f:
            hit[f[0]].add(d)
for f, ds in sorted(hit.items()):
    if len(ds) == len(disps):
        print(hex(f), sorted(hex(x) for x in ds))
