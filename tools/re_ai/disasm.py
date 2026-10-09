"""Disassemble DI2 exe bytes. usage: python tools/re_ai/disasm.py <va> [count=60]"""
import os
import sys

import capstone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe  # noqa: E402

e = Exe()
va = int(sys.argv[1], 16)
n = int(sys.argv[2]) if len(sys.argv) > 2 else 60
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
for i, ins in enumerate(md.disasm(e.read(va, n * 15), va)):
    if i >= n:
        break
    print(hex(ins.address), ins.mnemonic, ins.op_str)
