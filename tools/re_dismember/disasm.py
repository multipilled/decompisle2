"""Disassemble [start, start+len) of the exe with capstone. usage: python dis.py 0x141256940 0x200 [grep-regex]"""
import re
import sys
import capstone
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
a, n = int(sys.argv[1], 16), int(sys.argv[2], 16)
rx = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
for i in md.disasm(e.read(a, n), a):
    s = f"{i.address:#x}: {i.mnemonic} {i.op_str}"
    if not rx or rx.search(s):
        print(s)
