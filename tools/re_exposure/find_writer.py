"""Find code that stores to two View-uniform-buffer offsets close together (e.g. PreExposure 0x864 and
CurrentEyeAdaption 0x980): candidates for FViewInfo::SetupUniformBufferParameters. Usage: find_writer.py 0x864 0x980"""
import os
import struct
import sys
import capstone
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
a, b = (int(x, 0) for x in sys.argv[1:3])
name, tva, tsize, raw, rsize = [s for s in e.secs if s[0] == ".text"][0]
code = e.read(tva, min(tsize, rsize))
pa, pb = struct.pack("<I", a), struct.pack("<I", b)
hits_a = []
i = 0
while (i := code.find(pa, i + 1)) >= 0:
    hits_a.append(i)
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
seen = set()
for ia in hits_a:
    win = code[max(0, ia - 0x3000): ia + 0x3000]
    if pb not in win:
        continue
    # confirm both as memory displacements of stores
    for k in range(ia - 8, ia):
        for ins in md.disasm(code[k:k + 16], tva + k):
            if ins.address + ins.size > tva + ia and hex(a) in ins.op_str and "ptr [" in ins.op_str and ins.op_str.startswith(("dword", "xmm", "qword")) is not None:
                key = ins.address
                if key not in seen and ins.op_str.split(",")[0].find(hex(a)) >= 0:
                    seen.add(key)
                    print("store", hex(ins.address), ins.mnemonic, ins.op_str)
            break
