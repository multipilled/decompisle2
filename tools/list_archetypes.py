"""List every DI2 zombie class / variant Blueprint with the skeletal meshes it can spawn with.

Chain (all from di2x json dumps of the user's install, extracted/json):
  BP_<Class>_<Variant>  (Super = BP_Base_<Class>)
    -> ProceduralCharacterPropertiesComponent.GenerationConfig.ModelVariation = DA_ModelVariation_*
    -> VariantAssets[].Model (PrimaryAssetName DA_ModelVariantAsset_*, Frequency)
    -> DA_ModelVariantAsset_*.Model.AssetPathName = SK_* (the merged skeletal mesh)
Also prints the Blueprint's UIName key, ChallengeRating, Immunities and SubArchetypeSpecificPerks.

usage: list_archetypes.py [--json out.json]     (prints a markdown table)
"""
import json
import sys
from pathlib import Path

JSON = Path(r"extracted\json\DeadIsland\Content")


def load(p):
    return json.load(open(p, encoding="utf-8"))


def by_name(stem, cache={}):
    if not cache:
        for p in JSON.rglob("DA_Model*.json"):
            cache[p.stem] = p
    return cache.get(stem)


def name_of(ref):
    return ref["ObjectName"].split("'")[1] if ref and "ObjectName" in ref else ""


def variant(bp_path):
    d = load(bp_path)
    cls = next((x for x in d if x["Type"] == "BlueprintGeneratedClass"), {})
    cdo = next((x for x in d if x["Name"].startswith("Default__")), {}).get("Properties") or {}
    ppc = next((x for x in d if x["Type"] == "ProceduralCharacterPropertiesComponent"), {}).get("Properties") or {}
    mv = name_of((ppc.get("GenerationConfig") or {}).get("ModelVariation"))
    meshes = []
    if mv and by_name(mv):
        for va in load(by_name(mv))[0]["Properties"].get("VariantAssets", []):
            an = va["Model"]["PrimaryAssetName"]
            p = by_name(an)
            sk = load(p)[0]["Properties"]["Model"]["AssetPathName"].split(".")[0] if p else "?" + an
            meshes.append((sk, va.get("Frequency", 1.0)))
    return dict(
        bp=bp_path.stem, parent=name_of(cls.get("Super")).removesuffix("_C"),
        path=str(bp_path.relative_to(JSON)).replace("\\", "/"), model_variation=mv, meshes=meshes,
        ui=(cdo.get("UINameRowHandle") or {}).get("RowName", ""), cr=cdo.get("ChallengeRating"),
        immunities=[i if isinstance(i, str) else json.dumps(i) for i in cdo.get("Immunities", [])],
        perks=[name_of(p) for p in cdo.get("SubArchetypeSpecificPerks") or []])


def main():
    rows = []
    for p in sorted(JSON.rglob("BP_*.json")):
        if "/Enemies/" not in p.as_posix() or p.stem.startswith(("BP_Base_", "BP_Action", "BP_AnimNotify", "BP_Nav")):
            continue
        try:
            v = variant(p)
        except (KeyError, IndexError, json.JSONDecodeError):
            continue
        if v["model_variation"]:
            rows.append(v)
    if "--json" in sys.argv:
        Path(sys.argv[sys.argv.index("--json") + 1]).write_text(json.dumps(rows, indent=1))
    print("| Blueprint | Parent | ModelVariation | Meshes (frequency) | CR | Perks |")
    print("|---|---|---|---|---|---|")
    for v in sorted(rows, key=lambda r: (r["parent"], r["bp"])):
        ms = ", ".join(f"{m.rsplit('/', 1)[-1]} ({f:g})" for m, f in v["meshes"])
        print(f"| {v['bp']} | {v['parent']} | {v['model_variation']} | {ms} | {v['cr']} | {', '.join(v['perks'])} |")


if __name__ == "__main__":
    main()
