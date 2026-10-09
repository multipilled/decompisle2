"""Native function table entries (FNameNativePtrPair {name, exec}) for the given UFunction names, with neighbours.
usage: python tools/re_gore/natives.py Name [Name ...]   (static read of the exe; never runs it)"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe

e = Exe()
for n in sys.argv[1:]:
    for sva in e.string_vas(n):
        if e.cstr(sva) != n:
            continue
        for p in e.pointers_to(sva):
            fn = e.q(p + 8)
            # neighbours in the same table (contiguous pairs)
            nb = []
            for k in range(-6, 7):
                try:
                    nm = e.cstr(e.q(p + 16 * k), 80)
                    if nm.isidentifier():
                        nb.append(f"{nm}={hex(e.q(p + 16 * k + 8))}")
                except Exception:  # noqa: BLE001
                    pass
            print(n, "pair", hex(p), "exec", hex(fn), "|", " ".join(nb))
