"""Instructions using [reg+disp] for a field offset inside a VA range of .text, with their functions.
usage: python tools/re_gore/field_reads.py <disp hex> <lo hex> <hi hex>   (static read of the exe)"""
import struct
import sys
sys.path.insert(0, r"tools\re")
import capstone
from di2exe import Exe

disp, lo, hi = (int(a, 16) for a in sys.argv[1:4])
e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
needle = struct.pack("<i", disp)
seen = set()
pos = e.off(lo)
end = e.off(hi)
while True:
    pos = e.m.find(needle, pos, end)
    if pos < 0:
        break
    va = e.va(pos)
    for back in range(2, 8):
        start = va - back
        if start in seen:
            continue
        insn = next(md.disasm(e.read(start, 15), start), None)
        if insn and insn.address + insn.size > va and insn.size >= back + 4:
            for op in insn.operands:
                if op.type == capstone.x86.X86_OP_MEM and op.mem.disp == disp:
                    seen.add(start)
                    f = e.func_of(start)
                    print(hex(start), insn.mnemonic, insn.op_str, "func", hex(f[0]) if f else "?")
                    break
    pos += 1
