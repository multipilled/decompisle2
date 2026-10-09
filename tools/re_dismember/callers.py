"""Direct call/jmp sites to each target, with containing function. usage: python callers.py 0x1409ec110 ..."""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, calls_to, root_function  # noqa: E402
e = Exe()
for a in sys.argv[1:]:
    t = int(a, 16)
    cs = calls_to(e, t)
    print(f"{t:#x}: " + ", ".join(f"{k} {s:#x} in {root_function(e, s) or 0:#x}" for s, k in cs))
