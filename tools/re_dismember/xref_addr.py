"""RIP-relative code references (lea/mov/cmp) to each VA, with the containing function. usage: python xref_addr.py 0x146b70a80 ..."""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, root_function  # noqa: E402
e = Exe()
for a in sys.argv[1:]:
    va = int(a, 16)
    refs = e.rip_refs_any(va, va + 1).get(va, [])
    fns = sorted({root_function(e, r) or 0 for r in refs})
    print(f"{va:#x}: {len(refs)} refs in {len(fns)} fns: " + " ".join(f"{f:#x}" for f in fns))
