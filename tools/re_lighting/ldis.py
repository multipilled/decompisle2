"""Decompile DI2 global lighting shaders into extracted/shaders/lighting/ (fxc /dumpbin + 3Dmigoto, via
tools/shaders/decompile.py, read-only reuse) and write a feature summary per shader.
usage: python tools/re_lighting/dis.py <lib index>[:label] ...      or   --type <regex>  (all archive shaders of it)"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, r"tools\shaders")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decompile  # noqa: E402

ROOT = r"."
OUT = os.path.join(ROOT, "extracted", "shaders", "lighting")


def run(idx, label=""):
    code = open(os.path.join(ROOT, "extracted", "shaders", "Global", f"{idx:06d}.bin"), "rb").read()
    dxbc, meta = decompile.split(code)
    try:
        meta["srt"] = decompile.srt(code)
    except Exception as e:  # noqa: BLE001
        meta["srt_error"] = str(e)
    os.makedirs(OUT, exist_ok=True)
    stem = os.path.join(OUT, f"Global_{idx:06d}" + (f"_{label}" if label else ""))
    if os.path.exists(stem + ".hlsl"):
        return stem
    open(stem + ".dxbc", "wb").write(dxbc)
    json.dump(meta, open(stem + ".meta.json", "w"), indent=1)
    subprocess.run([decompile.FXC, "/nologo", "/dumpbin", "/Fc", stem + ".asm", stem + ".dxbc"], capture_output=True)
    subprocess.run([decompile.DEC, "-D", stem + ".dxbc"], capture_output=True, text=True)
    return stem


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--type":
        import list_global
        n, m, l = list_global.load()
        seen = {}
        for x in list_global.rows(args[1], n, m, l):
            seen.setdefault(x["lib_index"], []).append(x["perm"])
        for li, perms in sorted(seen.items()):
            print(run(li, f"p{min(perms)}"))
    else:
        for a in args:
            i, _, lab = a.partition(":")
            print(run(int(i), lab))
