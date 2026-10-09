"""Diff vtable slots of classes against a base vtable. usage: python vtdiff.py base_vt vt [vt ...] (hex)"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
vts = [int(a, 16) for a in sys.argv[1:]]
_, TLO, TVS, _, _ = e.sec(".text")
for s in range(0, 0x600, 8):
    vals = [e.q(v + s) for v in vts]
    if not all(TLO <= x < TLO + TVS for x in vals):
        print("end at slot %#x" % s)
        break
    if len(set(vals)) > 1:
        print("slot %#5x: %s" % (s, " ".join("%#x" % x for x in vals)))
