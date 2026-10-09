"""Find a UE 4.27 class's constructor and vtable in DI2's exe (static analysis only; the exe is never run).

Engine classes have no RTTI, so the path is UE's own registration code:
  L"U<Class>" wide string; GetPrivateStaticClass references it + 2 (L"<Class>") and calls GetPrivateStaticClassBody
  with stack args (size 0xb0, ..., InternalConstructor<T>, InternalVTableHelperCtorCaller<T>, ...).
  InternalConstructor<T> is `if (X.Obj) jmp T::T(X)`; the constructor's own `lea rax,[vtable]; mov [rbx],rax`
  after the Super ctor call gives the vtable.
Checked on UParticleModuleVelocityCone (ctor 0x1439619c0, vtable 0x145dd63b0, Direction default (0,0,1)).

usage: python tools/particles/uclass_vtable.py <Class> [<Class> ...] [--slots N] [--ctor]
"""
import struct
import sys

sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
import capstone  # noqa: E402

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
_, TLO, TVS, _, _ = e.sec(".text")
THI = TLO + TVS
_, RLO, RVS, _, _ = e.sec(".rdata")
RHI = RLO + RVS


def disasm(va, n=0x600, stop_ret=True):
    f = e.func_of(va)
    end = f[1] if f and f[0] <= va < f[1] else va + n
    out = []
    for i in md.disasm(e.read(va, end - va), va):
        out.append(i)
        if stop_ret and i.mnemonic in ("ret", "jmp") and (not f or i.address + i.size >= end):
            break
    return out


def rip_target(i, opn=1):
    op = i.operands[opn]
    return i.address + i.size + op.mem.disp


def static_class_fn(cls):
    s = e.string_vas(cls, wide=True)
    if not s:
        return None
    for site in e.rip_refs_any(s[0] + 2, s[0] + 3).get(s[0] + 2, []):
        fn = e.func_of(site)
        if fn:
            return fn[0]
    return None


def ctor_of(cls):
    """(GetPrivateStaticClass, InternalConstructor, ctor, class size)."""
    f = static_class_fn(cls)
    if f is None:
        return None
    ins = disasm(f, stop_ret=False)
    size = None
    stack = {}
    for i in ins:
        if i.mnemonic == "mov" and i.op_str.startswith("dword ptr [rsp + 0x20]"):
            size = i.operands[1].imm
        if i.mnemonic == "lea" and "rip" in i.op_str and i.operands[0].type == capstone.x86.X86_OP_REG:
            stack[i.reg_name(i.operands[0].reg)] = rip_target(i)
        if i.mnemonic == "mov" and i.operands[0].type == capstone.x86.X86_OP_MEM and i.operands[1].type == capstone.x86.X86_OP_REG:
            r = i.reg_name(i.operands[1].reg)
            if r in stack and i.reg_name(i.operands[0].mem.base) == "r11":
                stack["[r11%+#x]" % i.operands[0].mem.disp] = stack[r]
    ic = stack.get("[r11-0x40]")
    if ic is None:
        return f, None, None, size
    ctor = None
    for i in disasm(ic, 0x20):
        if i.mnemonic == "jmp" and i.operands[0].type == capstone.x86.X86_OP_IMM:
            ctor = i.operands[0].imm
        if i.mnemonic == "call" and i.operands[0].type == capstone.x86.X86_OP_IMM:
            ctor = i.operands[0].imm
    return f, ic, ctor, size


def vtable_in_ctor(ctor):
    """Last rdata vtable stored to [this] in the ctor (most derived)."""
    vt = None
    regs = {}
    for i in disasm(ctor, 0x800):
        if i.mnemonic == "lea" and "rip" in i.op_str:
            t = rip_target(i)
            if RLO <= t < RHI:
                regs[i.reg_name(i.operands[0].reg)] = t
        if i.mnemonic == "mov" and i.operands[0].type == capstone.x86.X86_OP_MEM and i.operands[0].mem.disp == 0 \
                and i.operands[1].type == capstone.x86.X86_OP_REG:
            r = i.reg_name(i.operands[1].reg)
            if r in regs:
                t = regs[r]
                if TLO <= e.q(t) < THI:
                    vt = t
        if i.mnemonic == "ret":
            break
    return vt


def info(cls):
    f, ic, ctor, size = ctor_of(cls) or (None, None, None, None)
    vt = vtable_in_ctor(ctor) if ctor else None
    return {"class": cls, "static_class": f, "internal_ctor": ic, "ctor": ctor, "size": size, "vtable": vt}


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    nslots = 0
    for a in sys.argv[1:]:
        if a.startswith("--slots="):
            nslots = int(a.split("=")[1])
    rows = [info(c) for c in args]
    for r in rows:
        print("%-44s ctor %s size %s vtable %s" % (r["class"], hex(r["ctor"]) if r["ctor"] else None,
                                                 hex(r["size"]) if r["size"] else None,
                                                 hex(r["vtable"]) if r["vtable"] else None))
    if nslots:
        vts = [r["vtable"] for r in rows]
        for s in range(nslots):
            vals = [e.q(v + 8 * s) if v else 0 for v in vts]
            if len(set(vals)) > 1:
                print("slot %#5x: %s" % (8 * s, " ".join("%#x" % v for v in vals)))
