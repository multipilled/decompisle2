"""Carve the Scaleform movie out of DI2's cooked SWF_* uassets (raw IoStore export from `tools/di2x.sh raw`).

DI2's SwfMovie assets embed the GFx file verbatim: header 'GFX' (uncompressed) or 'CFX' (zlib), a version byte, then
a little-endian u32 FileLength counting the whole file from the signature. JPEXS (tools/ffdec) opens the carved .gfx.

Usage: python tools/re_ui/carve_gfx.py <raw dir or .uasset>... [--out extracted/re_ui/gfx]
Prints one line per movie: name, signature, version, length, and the external images / exports it names.
"""
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def carve(path, out_dir):
    data = open(path, "rb").read()
    for m in re.finditer(rb"(GFX|CFX)", data):
        off = m.start()
        ver = data[off + 3]
        (length,) = struct.unpack_from("<I", data, off + 4)
        if not (5 <= ver <= 40) or length < 16 or off + (length if m.group(1) == b"GFX" else 8) > len(data):
            continue
        body = data[off:off + length] if m.group(1) == b"GFX" else data[off:]
        name = os.path.splitext(os.path.basename(path))[0]
        os.makedirs(out_dir, exist_ok=True)
        dst = os.path.join(out_dir, name + ".gfx")
        open(dst, "wb").write(body)
        # External image / font references show up as plain strings (texture names, gfxfontlib, imports).
        refs = sorted(set(s.decode() for s in re.findall(rb"(?:T_|SWF_|gfxfontlib|\$)[A-Za-z0-9_\.]{3,60}", body)))
        print("%s %s v%d len=%d  refs=%s" % (name, m.group(1).decode(), ver, length, ",".join(refs[:12])))
        return dst
    print("%s: no GFX/CFX header" % path)


def main():
    args = sys.argv[1:]
    out = os.path.join(ROOT, "extracted", "re_ui", "gfx")
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        del args[i:i + 2]
    for a in args:
        if os.path.isdir(a):
            for dp, _, fs in os.walk(a):
                for f in fs:
                    if f.startswith("SWF_") and f.endswith(".uasset"):
                        carve(os.path.join(dp, f), out)
        else:
            carve(a, out)


main()
