"""List / decompile / annotate the base-pass shaders of a DI2 particle material (analysis aid for recon/PARTICLES.md).

  python tools/particles/matshaders.py <MI name> [list]           shader types per vertex factory (quality High)
  python tools/particles/matshaders.py <MI name> <VF> <type> <label>  decompile + annotate one shader

Needs extracted/particles_build/materials/<MI>.json (shadermaps.exe material dump, see tools/build_particles.py)
and the master material json under extracted/json. Output: extracted/shaders/dis + extracted/shaders/annotated.
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "shaders"))
sys.path.insert(0, HERE)
import material_map  # noqa: E402
import decompile  # noqa: E402
import annotate_p  # noqa: E402,F401  (patches the preshader decoder)
import annotate  # noqa: E402

MATS = os.path.join(ROOT, "extracted", "particles_build", "materials")


def master_json(mi):
    d = json.load(open(os.path.join(MATS, mi + ".json")))
    # walk the MI chain in extracted/json to the root Material
    idx = {os.path.basename(f)[:-5]: f for f in glob.glob(os.path.join(ROOT, "extracted", "json", "**", "*.json"), recursive=True)}
    cur = mi
    while cur in idx:
        e = next((x for x in json.load(open(idx[cur], encoding="utf-8")) if x["Type"] in ("Material", "MaterialInstanceConstant")), None)
        if e is None or e["Type"] == "Material":
            return idx[cur], d
        cur = e["Properties"]["Parent"]["ObjectName"].split("'")[1]
    return None, d


def main():
    mi = sys.argv[1]
    mj, d = master_json(mi)
    key = d.get("shader_resource_hash")
    if key:
        rows = material_map.shader_list(key)
    else:
        # root material with its shader map inline in its package (tools/particles/inline_map.py)
        import inline_map
        rows = inline_map.shader_list(os.path.basename(mj)[:-5] if mj else mi)  # the root's package holds it
    hi = [r for r in rows if r["quality"] in (1, 0)]
    if len(sys.argv) < 3 or sys.argv[2] == "list":
        print("resources:", [r.get("LoadedShaderMap", {}).get("ShaderMapId", {}).get("QualityLevel") for r in d["resources"]])
        for r in sorted(hi, key=lambda r: (r["vf"] or "", r["type"])):
            print(r["quality"], r["vf"], r["type"], r["freq"], r["lib_index"], r["instr"])
        return
    vf, typ, label = sys.argv[2], sys.argv[3], sys.argv[4]
    q = [r for r in rows if r["vf"] == vf and r["type"] == typ]
    if not q:
        raise SystemExit("no %s / %s" % (vf, typ))
    # prefer High (quality index 1), else whatever exists
    q.sort(key=lambda r: {1: 0, 2: 1, 0: 2}.get(r["quality"], 3))
    r = q[0]
    ri = [i for i, x in enumerate(d["resources"])
          if {"Low": 0, "High": 1, "Medium": 2}.get(x["LoadedShaderMap"]["ShaderMapId"]["QualityLevel"]) == r["quality"]][0]
    decompile.run("DeadIsland", r["lib_index"], label)
    print(annotate.run(os.path.join(MATS, mi + ".json"), ri, "DeadIsland", r["lib_index"], mj))


if __name__ == "__main__":
    main()
