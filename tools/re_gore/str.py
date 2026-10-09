"""Read a C / wide string at VAs (static read of the exe). usage: python tools/re_gore/str.py <va hex> ..."""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe
e = Exe()
for a in sys.argv[1:]:
    va = int(a, 16)
    raw = e.read(va, 96)
    w = raw.decode("utf-16-le", "replace").split("\x00")[0]
    print(a, "c:", e.cstr(va, 80)[:80], "| w:", w[:40])
