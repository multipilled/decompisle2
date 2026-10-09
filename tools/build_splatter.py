"""DI2 FLESH splatter data -> game/data/splatter.json.

  textures   the stamp textures (DIShared/Effects/Materials/HitFX ...) packed in game/assets/di2/splatter/stamps
  defaults   FSplatterMeshInfo values for fields a preset leaves unset. Presets (UObject properties) are
             delta-serialized against the class default, so a value a preset writes explicitly is NOT the
             default; stored set stamps (array elements) write every field. Default = the most common stored
             value that no preset writes explicitly (recon/UNVERIFIED.md: inferred, not read from the exe).
  presets    every cosmetic effect that stamps splatter (CE_BluntSplatter_*, CE_SharpSplatter_*, CE_Bullet_*,
             status / explosion / dismember ...): its SplatterMeshInfo + SplatterModifiers + effect flags
  curves     the progressive-damage curves those modifiers use
  sets       every SplatterSet (stored stamps: location, orientation, info)
  prespawn   per archetype, DA_AnimSet_PreSpawnSplatter_<type> groups (expression, weighted items -> sets)

Space: stamps are stored in UE component space (cm, ref pose). They are converted like the meshes
(CUE4Parse glTF: (x, y, z) -> (x, z, y) * 0.01); the stamp frame's axes go through the same mirror.
usage: python tools/build_splatter.py
"""
import glob
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402

TEX = json.loads((ROOT / "game/assets/di2/splatter/stamps/index.json").read_text())


# FSplatterMeshInfo() in DeadIsland-Win64-Shipping.exe (recon/RE_FLESH.md, "Native defaults").
NATIVE_INFO_DEFAULTS = {
    "UVScale": 10.0, "DisplacementScale": 1.0, "FluidSplatterAmount": 1.0, "BruisingAmount": 1.0,
    "FluidDripsAmount": 1.0, "CauterisationAmount": 1.0, "DepthScale": 10.0, "DepthFadeStart": 0.35,
    "AngleWrap": 1.0, "TextureInfluence": 1.0, "ClothingDisplacementScale": 1.0, "ClothingDepthScale": 1.0,
    "DisplacementClearValue": 0.0, "BoneIndex": -1, "MaterialID": -1, "SplatterType": "Decal",
    "RuptureDamageMultiplier": 1.0, "RuptureDamageOffset": 0.0, "RuptureRadiusMultiplier": 0.25,
    "RuptureRadiusOffset": 0.0, "RuptureFalloffFactor": 1.0, "RuptureDepthMultiplier": 1.0,
    "RuptureDepthOffset": 0.0, "RuptureLimitFraction": 1.0, "InputMinimum": 0.0, "InputRange": 1.0,
    "MaximumRuptureCount": 1, "ClothingInteraction": "Default", "RuptureInteraction": "Default",
    # bool bytes 0x9C.. (ctor writes 0x100 at 0x9C: only bAbsoluteDeformation at 0x9D is set)
    "bReferencePose": False, "bAbsoluteDeformation": True, "bSubtractive": False, "bInvertSplatter": False,
    "bUVSpaceSplatter": False, "bIgnoreRulesets": False,
}
# FSplatterModifiers / UCosmeticEffect_SplatterMesh constructor defaults (same source).
NATIVE_EFFECT_DEFAULTS = {
    "MaxBlendThreshold": 1.0, "HitsToDeathMaxBlendThreshold": 0.0, "UVScaleVariation": 0.0, "AlignmentAngle": 0.0,
    "AlignmentVariation": 0.0, "DepthVariation": 0.0, "bApplyStrengthVariationToTextureInfluence": False,
    "bApplySplatterUsingFlippedRotation": True, "bAlignToWorldUp": False, "Duration": 0.0,
    "bEffectsScaleCurveWithAbsoluteTime": False, "ApplyDifferences": 1.0, "ApplyThreshold": 0.004,
}


def m(v, s=1.0):
    return [round(v["X"] * s, 5), round(v["Z"] * s, 5), round(v["Y"] * s, 5)]


def rot_axes(r):
    p, y, ro = (math.radians(r.get(k, 0.0)) for k in ("Pitch", "Yaw", "Roll"))
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    x = {"X": cp * cy, "Y": cp * sy, "Z": sp}
    yy = {"X": sr * sp * cy - cr * sy, "Y": sr * sp * sy + cr * cy, "Z": -sr * cp}
    z = {"X": -(cr * sp * cy + sr * sy), "Y": cy * sr - cr * sp * sy, "Z": cr * cp}
    return [m(x), m(yy), m(z)]


def norm_info(info):
    out = {}
    for k, v in info.items():
        if isinstance(v, dict):
            name = v.get("n") or (re.findall(r"'(\w+)'", v.get("ObjectName", "")) or [None])[0]
            if name:
                out[k] = TEX.get(name, -1)
                out[k + "_name"] = name
        elif isinstance(v, (int, float, bool, str)) and not isinstance(v, list):
            out[k] = v.split("::")[-1] if isinstance(v, str) else v
    return out


MODES = {"RCIM_Linear": "L", "RCIM_Constant": "K", "RCIM_Cubic": "C", "RCIM_None": "L"}


def curve_keys(name):
    """FRichCurve keys: [time, value, interp L|K|C, arrive tangent, leave tangent] (UE default interp: cubic)."""
    for e in A.load(name) or []:
        keys = e.get("Properties", {}).get("FloatCurve", {}).get("Keys", [])
        if keys:
            return [[round(k["Time"], 6), round(k["Value"], 6), MODES.get(k.get("InterpMode", "RCIM_Cubic"), "C"),
                     round(k.get("ArriveTangent", 0.0), 6), round(k.get("LeaveTangent", 0.0), 6)] for k in keys]
    return None


def main():
    cos = json.loads((ROOT / "game/data/cosmetics.json").read_text())
    presets, curves = {}, {}
    for name, ce in cos.items():
        stamps = []
        for e in ce["effects"]:
            if e["type"] != "SplatterMesh":
                continue
            mods = e.get("SplatterModifiers") or {}
            mod_out = {}
            for k, v in mods.items():
                if isinstance(v, dict) and v.get("@") == "CurveFloat":
                    mod_out[k] = v["n"]
                    curves.setdefault(v["n"], curve_keys(v["n"]))
                elif isinstance(v, list) and k in ("AlternateWoundTextures", "AlternateSecondaryTextures"):
                    # FSplatterModifiers: one is picked at random per hit (Wound -> DisplacementDecalTexture,
                    # Secondary -> DiffuseDecalTexture; native code at 0x141245180, recon/RE_FLESH.md).
                    names = [x.get("n") or (re.findall(r"'(\w+)'", x.get("ObjectName", "")) or [None])[0] for x in v if isinstance(x, dict)]
                    mod_out[k] = [TEX.get(n, -1) for n in names]
                    mod_out[k + "_names"] = names
                elif not isinstance(v, (dict, list)):
                    mod_out[k] = v
            flags = {k: v for k, v in e.items() if k not in ("type", "SplatterMeshInfo", "SplatterModifiers") and not isinstance(v, (dict, list))}
            # Animated splatter (Duration > 0): the strength curve over time (tick 0x141259120, recon/RE_FLESH.md).
            esc = e.get("EffecsScaleCurve")
            if isinstance(esc, dict) and esc.get("@") == "CurveFloat":
                flags["EffecsScaleCurve"] = esc["n"]
                curves.setdefault(esc["n"], curve_keys(esc["n"]))
            stamps.append({"info": norm_info(e.get("SplatterMeshInfo") or {}), "modifiers": mod_out, **flags})
        if stamps:
            presets[name] = stamps
    # Stored sets
    sets, fields = {}, {}
    for f in glob.glob(str(ROOT / "extracted/json/**/*SplatterSet*.json"), recursive=True):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for e in d:
            entries = e.get("Properties", {}).get("SplatterEntries")
            if e.get("Type") != "SplatterSet" or not entries:
                continue
            out = []
            for en in entries:
                info = en.get("SplatterMeshInfo", {})
                for k, v in info.items():
                    if isinstance(v, (int, float, str, bool)):
                        fields.setdefault(k, Counter())[v if not isinstance(v, float) else round(v, 3)] += 1
                out.append({"loc": m(en.get("Location", {"X": 0, "Y": 0, "Z": 0}), 0.01),
                            "axes": rot_axes(en.get("Orientation", {})), "info": norm_info(info)})
            sets[e["Name"]] = out
    explicit = {}
    for f in glob.glob(str(ROOT / "extracted/json/**/CE_*.json"), recursive=True):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for e in d:
            if e.get("Type") == "CosmeticEffect_SplatterMesh":
                for k, v in (e.get("Properties", {}).get("SplatterMeshInfo") or {}).items():
                    if isinstance(v, (int, float, str, bool)):
                        explicit.setdefault(k, set()).add(v if not isinstance(v, float) else round(v, 3))
    inferred = {}
    for k, c in fields.items():
        v = next((v for v, _ in c.most_common() if v not in explicit.get(k, set())), c.most_common(1)[0][0])
        inferred[k] = v.split("::")[-1] if isinstance(v, str) else v
    # The native defaults, read from the exe's FSplatterMeshInfo constructor (recon/RE_FLESH.md); the inference
    # above is only a cross-check now.
    defaults = dict(inferred)
    defaults.update(NATIVE_INFO_DEFAULTS)
    diff = {k: (inferred.get(k), v) for k, v in NATIVE_INFO_DEFAULTS.items() if inferred.get(k) != v}
    print("native vs inferred defaults that differ:", diff)
    # Pre-spawn splatter per archetype
    prespawn = {}
    for coll in sorted(n for n in A.index() if n.startswith("DA_AnimSetCollection_PreSpawnSplatter_")):
        arch = coll.removeprefix("DA_AnimSetCollection_PreSpawnSplatter_")
        groups = []
        for slot in A.collection(coll).values():
            if "animset" not in slot:
                continue
            d = A.load(slot["animset"]) or []
            objs = {e["Name"]: e for e in d}
            main = next((e for e in d if e["Type"] == "AnimSetData"), {})
            for g in main.get("Properties", {}).get("Groups", []):
                items = []
                for it in g.get("Items", []):
                    ref = A.anyref(it.get("InstancedAsset")) if it.get("InstancedAsset") else None
                    obj = objs.get(ref.split(":")[-1].split(".")[-1]) if ref else None
                    names = re.findall(r"SplatterSet'(\w+)'", json.dumps(obj.get("Properties", {}))) if obj else []
                    items.append({"weight": it.get("Weight", 1.0), "sets": names})
                groups.append({"name": g.get("Name"), "expr": (g.get("Expression") or {}).get("Expression", ""), "items": items})
        prespawn[arch] = groups
    out = {"textures": TEX, "defaults": defaults, "effect_defaults": NATIVE_EFFECT_DEFAULTS, "presets": presets, "curves": curves, "sets": sets, "prespawn": prespawn}
    (ROOT / "game/data/splatter.json").write_text(json.dumps(out, separators=(",", ":")))
    missing = sorted({s for g in sum(prespawn.values(), []) for it in g["items"] for s in it["sets"] if s not in sets})
    print(f"{len(presets)} splatter presets, {len(curves)} curves, {len(sets)} sets ({sum(len(v) for v in sets.values())} stamps), "
          f"{len(prespawn)} pre-spawn tables; missing sets: {missing[:10]}")
    print("defaults:", {k: defaults[k] for k in ("UVScale", "DisplacementScale", "DepthScale", "DepthFadeStart", "AngleWrap", "TextureInfluence", "BruisingAmount", "FluidDripsAmount", "CauterisationAmount", "FluidSplatterAmount", "RuptureInteraction", "ClothingInteraction", "SplatterType")})


if __name__ == "__main__":
    main()
