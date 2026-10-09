"""Functions with RIP-relative references to a VA that also use [reg+disp] (static read of the exe).
usage: python tools/re_gore/rip_users.py <target va hex> <disp hex>"""
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
tgt = int(sys.argv[1], 16)
disp = int(sys.argv[2], 16)
funcs = {}
for ref in e.rip_refs(tgt):
    f = e.func_of(ref)
    if f:
        funcs[f[0]] = f[1]
for b, en in sorted(funcs.items()):
    uses = [f"{hex(i.address)} {i.mnemonic} {i.op_str}" for i in md.disasm(e.read(b, en - b), b)
            if any(op.type == capstone.x86.X86_OP_MEM and op.mem.disp == disp for op in i.operands)]
    print(hex(b), hex(en), uses[:4])
