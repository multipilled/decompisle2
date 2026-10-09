"""Name of the reflected struct/class whose property array holds a property record (static read of the exe).
usage: python tools/re_gore/struct_name.py <property record va hex>"""
import re
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe

e = Exe()
rec = int(sys.argv[1], 16)


def ok(p):
    try:
        n = e.cstr(e.q(e.q(p)), 80)
        return bool(n) and re.fullmatch(r"[A-Za-z_]\w*", n) is not None
    except Exception:  # noqa: BLE001
        return False


for arr in e.pointers_to(rec):
    a = arr
    while ok(a - 8):
        a -= 8
    print("array start", hex(a))
    for ref in e.pointers_to(a):
        # FStructParams / FClassParams: look at nearby pointers for a C-string name
        for k in range(-6, 7):
            try:
                s = e.cstr(e.q(ref + 8 * k), 80)
                if s and re.fullmatch(r"[A-Za-z_]\w*", s):
                    print("  params", hex(ref), "k", k, s)
            except Exception:  # noqa: BLE001
                pass
