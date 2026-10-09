"""Disassemble + decompile DI2 global shaders into extracted/ghidra_dismember/shaders/ (my own output folder), reusing
tools/shaders/decompile.py's container split (read-only import). usage: python shdis.py <lib index> <label> [...pairs]"""
import json
import os
import subprocess
import sys

sys.path.insert(0, r"tools\shaders")
import decompile  # noqa: E402

OUT = r"extracted\ghidra_dismember\shaders"
os.makedirs(OUT, exist_ok=True)
a = sys.argv[1:]
for idx, label in zip(a[::2], a[1::2]):
    code = open(os.path.join(r"extracted\shaders\Global", f"{int(idx):06d}.bin"), "rb").read()
    dxbc, meta = decompile.split(code)
    stem = os.path.join(OUT, f"Global_{int(idx):06d}_{label}")
    open(stem + ".dxbc", "wb").write(dxbc)
    json.dump(meta, open(stem + ".meta.json", "w"), indent=1)
    subprocess.run([decompile.FXC, "/nologo", "/dumpbin", "/Fc", stem + ".asm", stem + ".dxbc"], capture_output=True)
    subprocess.run([decompile.DEC, "-D", stem + ".dxbc"], capture_output=True, text=True)
    print(stem, os.path.exists(stem + ".asm"), os.path.exists(stem + ".hlsl"))
