"""Functions that call a class's StaticClass (casts / IsA) and use [reg+disp] (static read of the exe).
usage: python tools/re_gore/class_users.py <StaticClass fn hex> <disp hex>"""
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe, calls_to

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
fn_sc = int(sys.argv[1], 16)
disp = int(sys.argv[2], 16)
funcs = {}
for site, kind in calls_to(e, fn_sc):
    f = e.func_of(site)
    if f:
        funcs[f[0]] = f[1]
for b, en in sorted(funcs.items()):
    uses = []
    for i in md.disasm(e.read(b, en - b), b):
        if any(op.type == capstone.x86.X86_OP_MEM and op.mem.disp == disp for op in i.operands):
            uses.append(f"{hex(i.address)} {i.mnemonic} {i.op_str}")
    print(hex(b), hex(en), "uses" if uses else "-", uses[:4])
