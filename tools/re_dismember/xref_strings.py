"""For each (wide or ascii) string, print its VA, the code sites that reference it (RIP-relative) and the functions
containing those sites (.pdata). usage: python xref_strings.py [-a] name [name ...]  (-a = ascii, default wide)"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, root_function  # noqa: E402

e = Exe()
wide = "-a" not in sys.argv
for s in [a for a in sys.argv[1:] if a != "-a"]:
    for va in e.string_vas(s, wide=wide):
        refs = e.rip_refs_any(va, va + 1).get(va, [])
        ptrs = e.pointers_to(va)
        print(f"{s!r} @ {va:#x}: {len(refs)} code refs, {len(ptrs)} data ptrs")
        for r in refs[:20]:
            f = root_function(e, r)
            print(f"    code {r:#x} in fn {f:#x}" if f else f"    code {r:#x}")
        for p in ptrs[:10]:
            print(f"    data ptr at {p:#x}")
