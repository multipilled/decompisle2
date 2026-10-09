"""Print decompiled functions by address from Ghidra DecompileAt outputs (default: extracted/ghidra/splatter_all.c and
extracted/ghidra_dismember/*.c). usage: python fn.py 0x140a05050 [more addrs] [--files f1.c,f2.c]"""
import glob
import re
import sys

files = [r"extracted\ghidra\splatter_all.c"] + sorted(glob.glob(r"extracted\ghidra_dismember\*.c"))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
for a in sys.argv[1:]:
    if a.startswith("--files="):
        files = a.split("=", 1)[1].split(",")
want = {int(a, 16) for a in args}
found = set()
for f in files:
    txt = open(f, encoding="utf-8", errors="replace").read()
    parts = re.split(r"(?m)^(?=// ===== )", txt)
    for p in parts:
        m = re.match(r"// ===== \S+ @ ([0-9a-f]+)", p)
        if m and int(m.group(1), 16) in want and int(m.group(1), 16) not in found:
            found.add(int(m.group(1), 16))
            print(p)
for w in sorted(want - found):
    print(f"// {w:#x}: not decompiled yet")
