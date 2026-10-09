"""Reflected members of the struct/class owning a property name, plus its super chain if found by name list.
usage: python tools/re_gore/class_members.py PropName [PropName ...]   (static read of the exe)"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, struct_members

e = Exe()
for n in sys.argv[1:]:
    for r in e.props_named(n):
        if "offset" not in r and "setbit" not in r:
            continue
        ms = struct_members(e, int(r["at"], 16))
        print("==", n, r["at"], [(m.get("name"), hex(m["offset"]) if "offset" in m else "bool") for m in ms])
