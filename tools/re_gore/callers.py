"""Direct callers of functions (static read of the exe). usage: python tools/re_gore/callers.py <fn hex> [...]"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, calls_to

e = Exe()
for a in sys.argv[1:]:
    t = int(a, 16)
    for site, kind in calls_to(e, t):
        f = e.func_of(site)
        print(a, kind, hex(site), "in", hex(f[0]) if f else "?")
