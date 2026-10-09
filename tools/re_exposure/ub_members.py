"""List shader-parameter-struct members registered in DI2's exe (static): each member registration function is
`movsxd rdi,[rdx+8]; lea rax,[rip+Name(wide)]; ...; mov dword [rsp+0x30], Offset`. Prints offset, cb register, name
for every member whose name matches the regex. Usage: ub_members.py <regex> [lo_va hi_va]"""
import os
import re
import struct
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
rx = re.compile(sys.argv[1])
n, tva, ts, raw, rs = [s for s in e.secs if s[0] == ".text"][0]
lo = int(sys.argv[2], 0) if len(sys.argv) > 2 else tva
hi = int(sys.argv[3], 0) if len(sys.argv) > 3 else tva + min(ts, rs)
code = e.read(lo, hi - lo)
i = 0
pat = bytes([0xC7, 0x44, 0x24, 0x30])
while (i := code.find(pat, i + 1)) >= 0:
    j = i - 0x16
    if code[j:j + 3] != b"\x48\x8D\x05":
        continue
    tgt = lo + j + 7 + struct.unpack_from("<i", code, j + 3)[0]
    try:
        s = e.read(tgt, 128).decode("utf-16-le", "ignore").split("\0")[0]
    except Exception:
        continue
    if s and rx.search(s):
        off = struct.unpack_from("<I", code, i + 4)[0]
        print("0x%04x cb[%d].%s  %-40s fn %x" % (off, off // 16, "xyzw"[off % 16 // 4], s, lo + j - 0x0B))
