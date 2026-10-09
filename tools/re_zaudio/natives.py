"""List UE4.27 native function tables (FNameNativePtrPair {const char* Name; FNativeFuncPtr Ptr}) that contain
any of the given function names, plus class InternalConstructor/vtable hints. Static exe reading only.
usage: python tools/re_zaudio/natives.py SetMentalState ...
"""
import struct
import sys

sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

e = Exe()
_, rv, rvs, rraw, rrs = e.sec(".rdata")
_, tv, tvs, traw, trs = e.sec(".text")


def is_text(p):
    return tv <= p < tv + tvs


def is_name(p):
    try:
        s = e.cstr(p, 80)
    except Exception:  # noqa: BLE001
        return False
    return bool(s) and s.isidentifier()


for n in sys.argv[1:]:
    for sva in e.string_vas(n):
        for ref in e.pointers_to(sva, (".rdata", ".data")):
            fp = e.q(ref + 8)
            if not is_text(fp):
                continue
            # walk the table both ways
            a = ref
            while is_name(e.q(a - 16)) and is_text(e.q(a - 8)):
                a -= 16
            print(f"== table for {n} at {hex(a)}")
            while is_name(e.q(a)) and is_text(e.q(a + 8)):
                print(f"   {e.cstr(e.q(a)):40s} {hex(e.q(a + 8))}")
                a += 16
