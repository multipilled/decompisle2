"""List DI2 global shaders whose type name matches a regex (lib index for tools/shaders/decompile.py Global <idx>).

  python tools/particles/global_find.py <regex> [--decompile <label>]

Reads GlobalShaderCache-PCD3D_SM5.bin + ShaderArchive-Global (extracted/shaders/archive) and the type-name hashes
(extracted/shaders/name_hashes.tsv). Local data only.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "shaders"))
import frozen  # noqa: E402
import shader_archive  # noqa: E402
import decompile  # noqa: E402

ARCH = os.path.join(ROOT, "extracted", "shaders", "archive")
NAMES = os.path.join(ROOT, "extracted", "shaders", "name_hashes.tsv")


def main():
    rx = re.compile(sys.argv[1])
    label = sys.argv[sys.argv.index("--decompile") + 1] if "--decompile" in sys.argv else None
    names = {}
    for line in open(NAMES, encoding="utf-8"):
        h, n = line.rstrip("\n").split("\t")
        names[int(h, 16)] = n
    maps, _ = frozen.global_cache(open(os.path.join(ARCH, "GlobalShaderCache-PCD3D_SM5.bin"), "rb").read())
    lib = shader_archive.parse(os.path.join(ARCH, "ShaderArchive-Global-PCD3D_SM5.ushaderbytecode"))
    smh = {h: i for i, h in enumerate(lib["shadermap_hashes"])}
    for sm in maps:
        shaders, src = frozen.global_shaders(sm)
        mi = smh.get(sm.get("resource_hash"))
        if mi is None:
            continue
        ioff, nsh, _, _ = lib["shadermaps"][mi]
        sh_idx = lib["indices"][ioff:ioff + nsh]
        for s in shaders:
            tname = names.get(s["type_hash"], hex(s["type_hash"]))
            if not rx.search(tname):
                continue
            li = sh_idx[s["resource_index"]] if 0 <= s["resource_index"] < len(sh_idx) else None
            print(f"{tname} perm {s['permutation']} {s['freq']} lib {li} instr {s['instructions']} src {names.get(src, hex(src))}")
            if label and li is not None:
                stem, _ = decompile.run("Global", li, f"{label}_{tname}_p{s['permutation']}")
                print("  ->", stem)


if __name__ == "__main__":
    main()
