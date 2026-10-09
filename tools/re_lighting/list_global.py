"""List DI2 global shaders (GlobalShaderCache-PCD3D_SM5.bin) whose type name matches a regex, with the archive index in
ShaderArchive-Global, permutation id and source file. Reuses tools/shaders/{frozen,shader_archive}.py read-only.
usage: python tools/re_lighting/list_global.py <type-regex> [--json out.json]"""
import json
import re
import sys

sys.path.insert(0, r"tools\shaders")
import frozen  # noqa: E402
import shader_archive  # noqa: E402

ARCH = r"extracted\shaders\archive"
NAMES = r"extracted\shaders\name_hashes.tsv"


def load():
    names = {}
    for line in open(NAMES, encoding="utf-8", errors="replace"):
        h, n = line.rstrip("\n").split("\t", 1)
        names[int(h, 16)] = n
    cache = open(ARCH + r"\GlobalShaderCache-PCD3D_SM5.bin", "rb").read()
    maps, _ = frozen.global_cache(cache)
    lib = shader_archive.parse(ARCH + r"\ShaderArchive-Global-PCD3D_SM5.ushaderbytecode")
    return names, maps, lib


def rows(rx, names, maps, lib):
    smh = {h: i for i, h in enumerate(lib["shadermap_hashes"])}
    out = []
    for smi, sm in enumerate(maps):
        shaders, src = frozen.global_shaders(sm)
        mi = smh.get(sm.get("resource_hash"))
        if mi is None:
            continue
        ioff, nsh, _, _ = lib["shadermaps"][mi]
        sh_idx = lib["indices"][ioff:ioff + nsh]
        for s in shaders:
            tname = names.get(s["type_hash"], hex(s["type_hash"]))
            if not re.search(rx, tname):
                continue
            li = sh_idx[s["resource_index"]] if 0 <= s["resource_index"] < len(sh_idx) else None
            out.append(dict(type=tname, perm=s["permutation"], freq=s["freq"], lib_index=li,
                            instr=s["instructions"], src=names.get(src, hex(src)), map=smi, frozen_at=s["at"]))
    return out


if __name__ == "__main__":
    n, m, l = load()
    r = rows(sys.argv[1], n, m, l)
    for x in sorted(r, key=lambda x: (x["type"], x["perm"])):
        print(f'{x["type"]:45s} p{x["perm"]:<7d} {x["freq"]} lib {x["lib_index"]:<5} instr {x["instr"]:<5} {x["src"]}')
    if "--json" in sys.argv:
        json.dump(r, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)
