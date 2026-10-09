"""Byte offset + bit mask of reflected native/bitfield bools: decodes the SetBitFunc (`or/mov byte ptr [rcx+off], imm`).
usage: python boolofs.py bAllowDismember [...]"""
import struct
import sys
import capstone
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
for n in sys.argv[1:]:
    for va in e.string_vas(n):
        for p in e.pointers_to(va):
            gen = e.read(p + 0x18, 1)[0]
            if gen & 0x1F != 0x0C:
                continue
            sz_outer = e.q(p + 0x28)
            fn = e.q(p + 0x30)
            code = e.read(fn, 32) if fn else b""
            ins = "; ".join(f"{i.mnemonic} {i.op_str}" for i in list(md.disasm(code, fn))[:3])
            print(f"{n}: params {p:#x} outer_size {sz_outer:#x} setbit {fn:#x}: {ins}")
