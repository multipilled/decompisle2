"""Shader list of a DI2 root material whose shader map is stored inline in its own package (no .ushaderresources key).

  python tools/particles/inline_map.py <Material> [type regex]

Needs the raw package (di2x raw "/<Material>\\.uasset$" -> extracted/raw/...) and the shadermaps.exe dump
(extracted/particles_build/materials/<Material>.json) for the CookedShaderMapIdHash. The inline map is the
UMaterial::SerializeInlineShaderMaps stream (bCooked, bValid, FMaterialShaderMapId, frozen content, ...) found by
that hash; tools/shaders/frozen.py parses it (DI2 frozen layout) and the shared code's resource hash gives the
ShaderArchive-DeadIsland indices. Same row format as tools/shaders/material_map.shader_list.
"""
import glob
import json
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "shaders"))
import frozen  # noqa: E402
import material_map  # noqa: E402

MATS = os.path.join(ROOT, "extracted", "particles_build", "materials")


def inline_maps(material):
    d = json.load(open(os.path.join(MATS, material + ".json"), encoding="utf-8"))
    raw = glob.glob(os.path.join(ROOT, "extracted", "raw", "**", material + ".uasset"), recursive=True)
    if not raw:
        raise SystemExit("no raw package: di2x raw \"/%s\\.uasset$\"" % material)
    b = open(raw[0], "rb").read()
    out = []
    for r in d.get("resources", []):
        h = bytes.fromhex(r["LoadedShaderMap"]["ShaderMapId"]["CookedShaderMapIdHash"])
        i = b.find(h)
        if i < 0:
            continue
        cooked, valid = struct.unpack_from("<II", b, i - 16)
        assert cooked == 1 and valid == 1, (material, cooked, valid)
        s = frozen.S(b, i - 8)
        out.append(frozen.shader_map(s, True))
    return out


def shader_list(material, rx="."):
    nm = material_map.names()
    lib = json.load(open(os.path.join(material_map.SH, "DeadIsland", "index.json")))
    smidx = {m["hash"]: i for i, m in enumerate(lib["shadermaps"])}
    rows = []
    for r in inline_maps(material):
        sh = lib["shadermaps"][smidx[r["resource_hash"]]]["shaders"]
        for vf, s in frozen.material_shaders(r):
            ty = nm.get(s["type"], hex(s["type"]))
            if not re.search(rx, ty):
                continue
            li = sh[s["resource_index"]]
            rows.append(dict(quality=r["quality"], vf=nm.get(vf, hex(vf)) if vf else None, type=ty, perm=s["permutation"],
                             freq=s["freq"], lib_index=li, out_hash=lib["shaders"][li]["hash"], instr=s["instructions"],
                             frozen_at=s["at"]))
    return rows


if __name__ == "__main__":
    for r in sorted(shader_list(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "."), key=lambda r: (r["vf"] or "", r["type"])):
        print(r["quality"], r["vf"], r["type"], r["freq"], r["lib_index"], r["instr"])
