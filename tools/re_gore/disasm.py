"""Disassemble one function (static read of the exe). usage: python tools/re_gore/disasm.py <va hex> [max insns]"""
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

e = Exe()
va = int(sys.argv[1], 16)
n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
f = e.func_of(va)
end = va + int(sys.argv[3], 16) if len(sys.argv) > 3 else (f[1] if f else va + 0x400)
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
for k, i in enumerate(md.disasm(e.read(va, end - va), va)):
    if k >= n:
        break
    print(hex(i.address), i.mnemonic, i.op_str)
