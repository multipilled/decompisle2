"""For a UClass name: StaticClass registration site(s) (GetPrivateStaticClassBody callers referencing the wide class
name), so the InternalConstructor / vtable can be followed. Static exe reading only.
usage: python tools/re_zaudio/class_vtable.py <ClassName> [...]
"""
import sys

sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

e = Exe()
for name in sys.argv[1:]:
    for sva in e.string_vas(name, wide=True):
        for tg, sites in e.rip_refs_any(sva, sva + 2).items():
            for s in sites:
                print(name, hex(sva), "ref", hex(s), [hex(x) for x in (e.func_of(s) or ())])
