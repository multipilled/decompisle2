"""Per-shader feature summary of the decompiled FDeferredLightPS permutations in extracted/shaders/lighting/
(written by ldis.py). Used to map permutation bits to defines. usage: python features.py [out.json]"""
import glob
import json
import os
import re
import sys

D = r"extracted\shaders\lighting"


def feats(asm, meta):
    f = {}
    f["hair_strands"] = "DISPATCH_NODECOUNT" in asm
    f["ntex"] = len(re.findall(r"dcl_resource_texture", asm))
    f["nsb"] = len(re.findall(r"dcl_resource_structured", asm))
    f["uint_tex"] = len(re.findall(r"dcl_resource_texture2d \(uint", asm))
    f["tex3d"] = len(re.findall(r"dcl_resource_texture3d", asm))
    f["switch"] = "switch" in asm
    f["barn"] = "l(0.035000)" in asm and "cb" in asm
    f["sincos"] = "sincos" in asm
    f["instr"] = len([l for l in asm.splitlines() if re.match(r"\s+[a-z_]+[ (]", l) and not l.strip().startswith("dcl")])
    ub = meta.get("uniform_buffers", {})
    dl = [k for k, v in ub.items() if v == "DeferredLightUniforms"]
    f["dl_cb"] = dl[0] if dl else None
    if dl:
        c = dl[0].replace("cb", "CB")
        c = "cb" + dl[0][2:]
        f["uses_invradius"] = f"{c}[3].w" in asm
        f["uses_falloffexp"] = f"{c}[4].w" in asm
        f["uses_dir9"] = f"{c}[9]" in asm
        f["uses_srclen"] = f"{c}[7].w" in asm
    srt = meta.get("srt", {})
    f["srt_tex"] = [(e["ub"], e["resource"]) for e in srt.get("texture", [])]
    f["srt_srv"] = [(e["ub"], e["resource"]) for e in srt.get("srv", [])]
    f["samplers"] = meta.get("packed", {}).get("samplers")
    f["srvs"] = meta.get("packed", {}).get("srvs")
    f["out_alpha_scatter"] = "0.300000, 0.590000, 0.110000" in asm
    return f


if __name__ == "__main__":
    out = {}
    for a in sorted(glob.glob(os.path.join(D, "Global_*_p*.asm"))):
        stem = a[:-4]
        m = re.search(r"Global_(\d+)_p(\d+)", stem)
        meta = json.load(open(stem + ".meta.json"))
        out[int(m.group(1))] = feats(open(a).read(), meta)
    json.dump(out, open(sys.argv[1] if len(sys.argv) > 1 else "features.json", "w"), indent=0)
    print(len(out))
