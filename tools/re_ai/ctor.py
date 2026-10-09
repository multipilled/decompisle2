"""Native defaults of UE classes in DI2's exe: class-name string -> GetPrivateStaticClass -> InternalConstructor ->
the ctor's immediate stores (recon/ZOMBIE_AI.md; technique: Knowledge unreal4-native-class-re-without-rtti).

usage: python tools/re_ai/ctor.py <wide class-name string VA (the "U..." text)> [...]
Prints the InternalConstructor, the ctor it jumps / calls into, and every `mov [reg+off], imm` / movss-from-constant
store in the ctor body (first 400 instructions), floats decoded.
"""
import os
import struct
import sys

import capstone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe, root_function  # noqa: E402

e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True


def ins_at(va, n):
    return list(md.disasm(e.read(va, n * 15), va))[:n]


def rip_target(ins):
    for op in ins.operands:
        if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
            return ins.address + ins.size + op.mem.disp
    return None


def static_class_ctor(name_va):
    for site in e.rip_refs(name_va + 2):          # TEXT("UName") + 1
        f = root_function(e, site)
        stores = {}
        for ins in ins_at(f, 80):
            if ins.mnemonic == "lea" and ins.op_str.startswith("rax"):
                last = rip_target(ins)
            if ins.mnemonic == "mov" and "r11 - 0x40" in ins.op_str and ins.op_str.endswith("rax"):
                stores["ctor"] = last
            if ins.mnemonic == "mov" and "r11 - 0x28" in ins.op_str and ins.op_str.endswith("rax"):
                stores["super"] = last
            if ins.mnemonic == "call":
                break
        return f, stores
    return None, {}


def dump_ctor(va, depth=0):
    body = ins_at(va, 400)
    xmm = {}
    for ins in body:
        t = rip_target(ins)
        if ins.mnemonic == "movss" and t and ins.op_str.startswith("xmm"):
            xmm[ins.op_str.split(",")[0]] = struct.unpack("<f", e.read(t, 4))[0]
        if ins.mnemonic in ("mov", "movss") and ins.op_str.startswith(("dword ptr [r", "byte ptr [r", "qword ptr [r", "word ptr [r")):
            src = ins.op_str.split(", ")[-1]
            val = src
            if src.startswith("0x") or src.isdigit():
                iv = int(src, 16) if src.startswith("0x") else int(src)
                val = f"{src}" + (f" (f={struct.unpack('<f', struct.pack('<I', iv & 0xffffffff))[0]:g})" if iv > 0xffff else "")
            elif src in xmm:
                val = f"{src}={xmm[src]:g}"
            print(f"  {'  ' * depth}{hex(ins.address)} {ins.mnemonic} {ins.op_str.split(', ')[0]} <- {val}")
        if ins.mnemonic == "call" and depth == 0:
            print(f"  {hex(ins.address)} call {ins.op_str}" + (f"  (xmm1={xmm.get('xmm1')})" if "xmm1" in xmm else ""))
        if ins.mnemonic == "ret":
            break


for a in sys.argv[1:]:
    f, st = static_class_ctor(int(a, 16))
    print(f"== {a}: StaticClass fn {hex(f) if f else None} {({k: hex(v) for k, v in st.items() if v})}")
    if st.get("ctor"):
        # InternalConstructor: `if (*rcx) { super ctor; write vtable; field defaults }` (or a jmp to the real ctor)
        dump_ctor(st["ctor"])
