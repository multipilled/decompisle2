"""Constructor-style default writes: `mov dword [reg+dispA], imm` with `mov dword [reg+dispB], imm` within 48 bytes,
over all of .text; prints both immediates as floats (static read of the exe).
usage: python tools/re_gore/ctor_floats.py <dispA hex> <dispB hex>"""
import struct
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

a, b = (int(x, 16) for x in sys.argv[1:3])
e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
name, v, vs, raw, rs = e.sec(".text")
buf = e.m[raw:raw + rs]


def imm_store(va, disp):
    for back in (2, 3):
        i = next(md.disasm(e.read(va - back, 16), va - back), None)
        if i and i.mnemonic == "mov" and len(i.operands) == 2 and i.operands[0].type == capstone.x86.X86_OP_MEM \
                and i.operands[0].mem.disp == disp and i.operands[1].type == capstone.x86.X86_OP_IMM and i.operands[0].size == 4:
            return i
    return None


needle = struct.pack("<i", a)
pos = 0
while True:
    pos = buf.find(needle, pos)
    if pos < 0:
        break
    va = v + pos
    ia = imm_store(va, a)
    if ia:
        window = e.read(ia.address, 64)
        for j in md.disasm(window, ia.address):
            if j.mnemonic == "mov" and len(j.operands) == 2 and j.operands[0].type == capstone.x86.X86_OP_MEM \
                    and j.operands[0].mem.disp == b and j.operands[1].type == capstone.x86.X86_OP_IMM and j.operands[0].size == 4:
                fa = struct.unpack("<f", struct.pack("<I", ia.operands[1].imm & 0xFFFFFFFF))[0]
                fb = struct.unpack("<f", struct.pack("<I", j.operands[1].imm & 0xFFFFFFFF))[0]
                f = e.func_of(ia.address)
                print(hex(ia.address), "func", hex(f[0]) if f else "?", "A", fa, "B", fb)
                break
    pos += 1
