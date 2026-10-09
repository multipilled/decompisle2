"""Functions in [lo,hi) that STORE to memory at all of the given displacements (any base register except rsp/rbp).
usage: python storescan.py 0x141000000 0x142000000 0x8c 0x90 0x9c 0xa8"""
import sys
import capstone
from capstone import x86
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
lo, hi = int(sys.argv[1], 16), int(sys.argv[2], 16)
want = {int(x, 16) for x in sys.argv[3:]}
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
for b, en in e.functions:
    if b < lo or b >= hi or en - b > 0x8000:
        continue
    code = e.read(b, en - b)
    seen = set()
    for ins in md.disasm(code, b):
        if not ins.operands:
            continue
        d = ins.operands[0]
        if d.type == x86.X86_OP_MEM and d.mem.base not in (0, x86.X86_REG_RSP, x86.X86_REG_RBP, x86.X86_REG_RIP) \
                and ins.mnemonic.startswith(("mov", "movss", "movsd", "movups", "movq")) and d.mem.disp in want:
            seen.add(d.mem.disp)
    if want <= seen:
        print(f"fn {b:#x}")
