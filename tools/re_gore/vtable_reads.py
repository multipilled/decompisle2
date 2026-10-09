"""From an InternalConstructor, follow calls to the ctor, take the vtable it writes, and list the vtable slots whose
functions use [reg+disp]. usage: python tools/re_gore/vtable_reads.py <internal ctor hex> <disp hex> [slots]
(static read of the exe)"""
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True


def insns(va, n=400):
    f = e.func_of(va)
    end = f[1] if f else va + n
    return list(md.disasm(e.read(va, end - va), va))


def vtables_of(ctor, depth=0):
    out = []
    for i in insns(ctor):
        if i.mnemonic == "lea" and "rip" in i.op_str:
            tgt = i.address + i.size + i.operands[1].mem.disp
            if e.sec(".rdata")[1] <= tgt < e.sec(".rdata")[1] + e.sec(".rdata")[2]:
                out.append(tgt)
        if i.mnemonic in ("call", "jmp") and i.operands[0].type == capstone.x86.X86_OP_IMM and depth < 2:
            out += vtables_of(i.operands[0].imm, depth + 1)
    return out


ctor = int(sys.argv[1], 16)
disp = int(sys.argv[2], 16)
slots = int(sys.argv[3]) if len(sys.argv) > 3 else 120
for vt in dict.fromkeys(vtables_of(ctor)):
    hits = []
    for k in range(slots):
        fn = e.q(vt + 8 * k)
        t = e.sec(".text")
        if not t[1] <= fn < t[1] + t[2]:
            break
        if not e.func_of(fn):
            continue
        for i in insns(fn):
            if any(op.type == capstone.x86.X86_OP_MEM and op.mem.disp == disp for op in i.operands):
                hits.append((k, hex(fn), hex(i.address), i.mnemonic, i.op_str))
                break
    print("vtable", hex(vt), "slots", k, "hits", hits)
