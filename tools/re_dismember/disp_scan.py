"""Find functions (by .pdata) in [lo, hi) whose instructions use a memory operand with the given displacement(s).
usage: python disp_scan.py 0x143a00000 0x143c00000 0x390 [0x398 ...]   (capstone; static, exe file only)"""
import sys
import capstone
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

e = Exe()
lo, hi = int(sys.argv[1], 16), int(sys.argv[2], 16)
disps = {int(x, 16) for x in sys.argv[3:]}
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
hits = {}
for b, en in e.functions:
    if b < lo or b >= hi:
        continue
    code = e.read(b, en - b)
    if not code:
        continue
    for ins in md.disasm(code, b):
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_MEM and op.mem.disp in disps and op.mem.base not in (0, capstone.x86.X86_REG_RIP, capstone.x86.X86_REG_RSP, capstone.x86.X86_REG_RBP):
                hits.setdefault(b, []).append(f"{ins.address:#x} {ins.mnemonic} {ins.op_str}")
for f, l in sorted(hits.items()):
    print(f"fn {f:#x}: " + " | ".join(l[:6]))
