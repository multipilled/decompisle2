"""Find RIP-relative references (disp32) in the exe's .text to given VAs; prints the VA of each disp32 field.
usage: python xref_rip.py <va> [<va> ...]     (static: reads the exe file only; int32 scan, ~1 s per target)"""
import sys
import numpy as np
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

e = Exe()
name, tva, tvs, traw, trs = e.sec(".text")
raw = e.m[traw:traw + trs]
for a in sys.argv[1:]:
    t = int(a, 16)
    for align in range(4):
        cnt = (len(raw) - align) // 4
        d = np.frombuffer(raw, dtype="<i4", count=cnt, offset=align).astype(np.int64)
        pos = tva + align + 4 * np.arange(cnt, dtype=np.int64)        # VA of the disp32 field
        for extra in (0, 1, 4):                                       # bytes after disp (imm8 / imm32 forms)
            for h in np.nonzero(pos + 4 + extra + d == t)[0][:20]:
                print(hex(t), "extra", extra, "disp@", hex(int(pos[h])))
