"""Disassemble a range of DI2's exe (static, never run) with wide/ascii string annotation of rip-relative leas.
Usage: python disasm.py <va> <bytes>"""
import os
import sys
import capstone
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
va, n = int(sys.argv[1], 0), int(sys.argv[2], 0)
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
for ins in md.disasm(e.read(va, n), va):
    note = ""
    if "rip +" in ins.op_str and ins.mnemonic == "lea":
        tgt = ins.address + ins.size + int(ins.op_str.split("rip + ")[1].split("]")[0], 16)
        try:
            raw = e.read(tgt, 80)
            w = raw.decode("utf-16-le", "ignore").split("\0")[0]
            a = raw.split(b"\0")[0].decode("latin1")
            note = "  ; W'%s' A'%s'" % (w[:40], a[:40])
        except Exception:
            pass
    print("%x  %-6s %s%s" % (ins.address, ins.mnemonic, ins.op_str, note))
