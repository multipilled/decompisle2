"""Native class -> GetPrivateStaticClass -> candidate InternalConstructors -> vtables; optionally the slot holding a
known function (static read of the exe). usage: python tools/re_gore/class_vtables.py <ClassName> [known fn hex]"""
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
T = e.sec(".text")
R = e.sec(".rdata")


def in_sec(s, va):
    return s[1] <= va < s[1] + s[2]


def insns(va):
    f = e.func_of(va)
    end = f[1] if f else va + 0x200
    return list(md.disasm(e.read(va, end - va), va))


def rip_leas(fn):
    out = []
    for i in insns(fn):
        if i.mnemonic == "lea" and len(i.operands) == 2 and i.operands[1].type == capstone.x86.X86_OP_MEM \
                and i.operands[1].mem.base == capstone.x86.X86_REG_RIP:
            out.append(i.address + i.size + i.operands[1].mem.disp)
    return out


def vtables_of(ctor, depth=0):
    out = []
    for i in insns(ctor):
        if i.mnemonic == "lea" and i.operands[1].type == capstone.x86.X86_OP_MEM and i.operands[1].mem.base == capstone.x86.X86_REG_RIP:
            t = i.address + i.size + i.operands[1].mem.disp
            if in_sec(R, t) and in_sec(T, e.q(t)):
                out.append(t)
        if i.mnemonic in ("call", "jmp") and i.operands[0].type == capstone.x86.X86_OP_IMM and depth < 1:
            out += vtables_of(i.operands[0].imm, depth + 1)
    return out


cls = sys.argv[1]
known = int(sys.argv[2], 16) if len(sys.argv) > 2 else None
for sva in e.string_vas(cls, wide=True):
    for ref in e.rip_refs(sva):
        f = e.func_of(ref)
        if not f:
            continue
        print(cls, "GetPrivateStaticClass", hex(f[0]))
        for c in rip_leas(f[0]):
            if not in_sec(T, c):
                continue
            for vt in dict.fromkeys(vtables_of(c)):
                n = 0
                while in_sec(T, e.q(vt + 8 * n)) and n < 400:
                    n += 1
                slot = next((k for k in range(n) if e.q(vt + 8 * k) == known), None) if known else None
                print("  ctor?", hex(c), "vtable", hex(vt), "slots", n, "known@", slot)
