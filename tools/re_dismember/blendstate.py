"""Reconstruct the FBlendStateInitializerRHI a TStaticBlendState creator builds on its frame (tiny emulator: imm
stores, reg loads/stores and movups copies relative to rbp/rsp), then decode the bytes passed in r8.
usage: python blendstate.py 0x140a08e80 [...]   (static; exe file only)
UE4.27: FRenderTarget[8] {ColorBlendOp, ColorSrcBlend, ColorDestBlend, AlphaBlendOp, AlphaSrcBlend,
AlphaDestBlend, ColorWriteMask}, then bUseIndependentRenderTargetBlendStates, bUseAlphaToCoverage."""
import sys
import capstone
from capstone import x86
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

OPS = ["Add", "Sub", "Min", "Max", "RevSub"]
BF = ["Zero", "One", "SrcColor", "InvSrcColor", "SrcAlpha", "InvSrcAlpha", "DstAlpha", "InvDstAlpha", "DstColor",
      "InvDstColor", "Const", "InvConst"]
e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
FRAME = (x86.X86_REG_RBP, x86.X86_REG_RSP)
for a in sys.argv[1:]:
    fn = int(a, 16)
    mem, regs, xmm = {}, {}, {}
    arg = None
    for ins in md.disasm(e.read(fn, 0x400), fn):
        if ins.mnemonic in ("ret", "call") and arg is not None and ins.mnemonic == "call":
            break
        ops = ins.operands
        if ins.mnemonic == "lea" and ops[0].reg == x86.X86_REG_R8 and ops[1].mem.base in FRAME:
            arg = (ops[1].mem.base, ops[1].mem.disp)
        if ins.mnemonic in ("mov", "movzx") and len(ops) == 2:
            d, s = ops
            if d.type == x86.X86_OP_MEM and d.mem.base in FRAME:
                if s.type == x86.X86_OP_IMM:
                    val = s.imm
                elif s.type == x86.X86_OP_REG and s.reg in regs:
                    val = regs[s.reg]
                else:
                    continue
                for k in range(d.size):
                    mem[(d.mem.base, d.mem.disp + k)] = (val >> (8 * k)) & 0xFF
            elif d.type == x86.X86_OP_REG and s.type == x86.X86_OP_MEM and s.mem.base in FRAME:
                v = 0
                for k in range(s.size):
                    v |= mem.get((s.mem.base, s.mem.disp + k), 0) << (8 * k)
                regs[d.reg] = v
                # sub-registers alias (eax/ax/al -> rax family) are handled by capstone reg ids per size; good enough
                for alias in {x86.X86_REG_EAX: (x86.X86_REG_AX, x86.X86_REG_AL)}.get(d.reg, ()):
                    regs[alias] = v
        if ins.mnemonic == "movups" and len(ops) == 2:
            d, s = ops
            if d.type == x86.X86_OP_REG and s.type == x86.X86_OP_MEM and s.mem.base in FRAME:
                xmm[d.reg] = [mem.get((s.mem.base, s.mem.disp + k)) for k in range(16)]
            elif d.type == x86.X86_OP_MEM and s.type == x86.X86_OP_REG and s.reg in xmm and d.mem.base in FRAME:
                for k, bv in enumerate(xmm[s.reg]):
                    if bv is not None:
                        mem[(d.mem.base, d.mem.disp + k)] = bv
    if arg is None:
        print(a, "no r8 arg"); continue
    b = [mem.get((arg[0], arg[1] + k)) for k in range(58)]
    print(f"{a}: FBlendStateInitializerRHI")
    for rt in range(8):
        r = b[rt * 7: rt * 7 + 7]
        if None in r:
            print(f"  RT{rt}: incomplete {r}"); continue
        print(f"  RT{rt}: color {OPS[r[0]]}({BF[r[1]]}, {BF[r[2]]})  alpha {OPS[r[3]]}({BF[r[4]]}, {BF[r[5]]})  writemask {r[6]:#x}")
    print(f"  independent={b[56]} alphaToCoverage={b[57]}")
