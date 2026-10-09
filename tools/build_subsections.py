"""DI2 mesh subsections per glb vertex -> game/assets/di2/<body>/<body>.subsections.json.

DI2 hides and reveals viscera, skull pieces and bones by named subsections of a render section (recon/VISCERA_PARTS.md
§2). game/data/viscera_parts.json gives each subsection's glb triangle range (`glb_tris`, in the glb's own index
order). Godot's importer reorders vertices and triangles, so this writes, per glb primitive, the subsection of every
glb vertex (glb vertex order). GoreBody then remaps it by bit-exact position, as it does the deform stream.

Per body: {"<glb res path>": [{"primitive", "section", "material", "names": [...], "vertex_sub": [...],
"initially_hidden"}]}. Unnamed single-subsection sections are left out (nothing to cull by name).
usage: python tools/build_subsections.py
"""
import json
import struct
from pathlib import Path

ROOT = Path(r".")


def glb_indices(path):
    b = path.read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    js = json.loads(b[20:20 + jl])
    bo = 20 + jl + 8
    out = []
    for p in js["meshes"][0]["primitives"]:
        a = js["accessors"][p["indices"]]
        v = js["bufferViews"][a["bufferView"]]
        o = bo + v.get("byteOffset", 0) + a.get("byteOffset", 0)
        fmt = {5121: "B", 5123: "H", 5125: "I"}[a["componentType"]]
        size = struct.calcsize(fmt)
        idx = struct.unpack_from(f"<{a['count']}{fmt}", b, o) if v.get("byteStride", size) == size else None
        nverts = js["accessors"][p["attributes"]["POSITION"]]["count"]
        out.append((list(idx), nverts))
    return out


def main():
    vp = json.loads((ROOT / "game/data/viscera_parts.json").read_text(encoding="utf-8"))
    for body, b in vp["bodies"].items():
        hidden = set(b["masks"]["InitiallyHiddenMask"]["sections"])
        out = {}
        cache = {}
        for s in b["sections"]:
            subs = s["subsections"]
            glb = s["glb"]
            if len(subs) < 2 and s["index"] not in hidden and all(x["name"] in ("None", "") for x in subs):
                continue
            path = ROOT / "game" / glb.removeprefix("res://")
            if glb not in cache:
                cache[glb] = glb_indices(path)
            idx, nverts = cache[glb][s["primitive"]]
            vsub = [-1] * nverts
            for k, sub in enumerate(subs):
                first, count = sub["glb_tris"]
                for t in range(first, first + count):
                    for c in range(3):
                        vsub[idx[t * 3 + c]] = k
            missing = sum(1 for x in vsub if x < 0)
            out.setdefault(glb, []).append({
                "primitive": s["primitive"], "section": s["index"], "material": s["material"],
                "names": [x["name"] for x in subs], "vertex_sub": [max(0, x) for x in vsub],
                "initially_hidden": s["index"] in hidden,
            })
            print(f"{body:9} section {s['index']:2} {s['material']:32} {len(subs):3} subsections, {nverts} vertices"
                  f"{', hidden at spawn' if s['index'] in hidden else ''}{f', {missing} unassigned' if missing else ''}")
        (ROOT / f"game/assets/di2/{body}/{body}.subsections.json").write_text(json.dumps(out))


if __name__ == "__main__":
    main()
