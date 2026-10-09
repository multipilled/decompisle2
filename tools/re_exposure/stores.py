"""List stores to [reg + disp32] for given displacements in DI2's exe .text, with the containing function (pdata).
Usage: stores.py 0x864 0x980 -> functions that store to all given displacements."""
import os
import sys
import struct
import capstone
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
n, tva, ts, raw, rs = [s for s in e.secs if s[0] == ".text"][0]
code = e.read(tva, min(ts, rs))
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
funcs = {}
disps = [int(x, 0) for x in sys.argv[1:]]
for d in disps:
    pat = struct.pack("<I", d)
    i = 0
    while (i := code.find(pat, i + 1)) >= 0:
        for k in range(3, 7):
            hit = None
            for ins in md.disasm(code[i - k:i + 8], tva + i - k):
                if ins.address + ins.size in (tva + i + 4, tva + i + 5, tva + i + 8) and ins.op_str.split(",")[0].endswith(hex(d) + "]") \
                        and "rsp" not in ins.op_str:
                    hit = ins
                break
            if hit:
                f = e.func_of(hit.address)
                if f:
                    funcs.setdefault(f, {}).setdefault(d, []).append("%x %s %s" % (hit.address, hit.mnemonic, hit.op_str))
                break
for f, m in funcs.items():
    if len(m) == len(disps):
        print("func %x-%x" % f)
        for d in disps:
            for s in m[d][:4]:
                print("   ", s)
