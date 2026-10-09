"""List every FSplatterMeshInfo in the extracted DI2 JSON whose SplatterType is a mesh-edit / clear type
(Dismember, DismemberWithDecal, BoneBreak, BoneBreakWithDecal, SoftInfluenceUpdate, ClearToValue, ClearSplatter,
ClearAll, None), plus every info that sets a non-default Rupture*/BoneIndex/MaterialID/DisplacementClearValue.
Prints the asset, the JSON path of the info, and the fields that differ from the native FSplatterMeshInfo defaults
(recon/RE_FLESH.md). Local data only; personal-use research.
usage: python tools/re_dismember/meshedit_data.py [extracted/json] [--all-rupture]"""
import json
import os
import sys
from collections import Counter

ROOT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else r"extracted\json"
ALL_RUPTURE = "--all-rupture" in sys.argv
MESH_EDIT = {"Dismember", "DismemberWithDecal", "BoneBreak", "BoneBreakWithDecal", "SoftInfluenceUpdate",
             "ClearToValue", "ClearSplatter", "ClearAll", "None"}
DEFAULTS = {"UVScale": 10.0, "DisplacementScale": 1.0, "FluidSplatterAmount": 1.0, "BruisingAmount": 1.0,
            "FluidDripsAmount": 1.0, "CauterisationAmount": 1.0, "DepthScale": 10.0, "DepthFadeStart": 0.35,
            "AngleWrap": 1.0, "TextureInfluence": 1.0, "ClothingDisplacementScale": 1.0, "ClothingDepthScale": 1.0,
            "DisplacementClearValue": 0.0, "BoneIndex": -1, "MaterialID": -1,
            "RuptureDamageMultiplier": 1.0, "RuptureDamageOffset": 0.0, "RuptureRadiusMultiplier": 0.25,
            "RuptureRadiusOffset": 0.0, "RuptureFalloffFactor": 1.0, "RuptureDepthMultiplier": 1.0,
            "RuptureDepthOffset": 0.0, "RuptureLimitFraction": 1.0, "InputMinimum": 0.0, "InputRange": 1.0,
            "MaximumRuptureCount": 1, "ClothingInteraction": "ESplatterClothingInteraction::Default",
            "RuptureInteraction": "ESplatterRuptureInteraction::Default", "bIgnoreRulesets": False,
            "DecorationID": 0, "bReferencePose": False, "bAbsoluteDeformation": True, "bSubtractive": False,
            "bInvertSplatter": False, "bUVSpaceSplatter": False, "SoftUpdatePrims": [],
            "InternalDisplacementDecalTexture": None}
RUPTURE_KEYS = [k for k in DEFAULTS if k.startswith("Rupture") or k == "MaximumRuptureCount"]


def short(v):
    if isinstance(v, dict) and "ObjectName" in v:
        return v["ObjectName"].split("'")[1] if "'" in v["ObjectName"] else v["ObjectName"]
    return v


def infos(node, path=""):
    """Yield (path, dict) for every dict that looks like an FSplatterMeshInfo (has SplatterType or UVScale...)."""
    if isinstance(node, dict):
        if "SplatterType" in node or ("UVScale" in node and "DisplacementDecalTexture" in node):
            yield path, node
        for k, v in node.items():
            yield from infos(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from infos(v, f"{path}[{i}]")


def main():
    types = Counter()
    for dp, _, fs in os.walk(ROOT):
        for f in fs:
            if not f.endswith(".json"):
                continue
            p = os.path.join(dp, f)
            try:
                txt = open(p, encoding="utf-8").read()
            except Exception:  # noqa: BLE001
                continue
            if "SplatterType" not in txt and "Rupture" not in txt:
                continue
            try:
                d = json.loads(txt)
            except Exception:  # noqa: BLE001
                continue
            for path, info in infos(d):
                t = str(info.get("SplatterType", "ESplatterType::Decal")).split("::")[-1]
                rupt = {k: info[k] for k in RUPTURE_KEYS if k in info and info[k] != DEFAULTS[k]}
                special = t in MESH_EDIT or any(info.get(k, DEFAULTS[k]) != DEFAULTS[k]
                                                for k in ("BoneIndex", "MaterialID", "DisplacementClearValue"))
                if not special and not (ALL_RUPTURE and rupt):
                    continue
                types[t] += 1
                diff = {k: short(v) for k, v in info.items()
                        if k != "SplatterType" and (k not in DEFAULTS or DEFAULTS[k] != v) and v is not None}
                rel = os.path.relpath(p, ROOT).replace("\\", "/")
                print(f"{t:20s} {rel} {path}")
                print("      ", json.dumps(diff))
    print(types, file=sys.stderr)


if __name__ == "__main__":
    main()
