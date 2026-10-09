"""DI2 hit-effect decision trees -> game/data/hit_effects.json.

DI2 picks what a hit does cosmetically (FLESH splatter, blood, particles, sounds, shakes) by walking a
HitEffectTree: the weapon's MeleeArchetypeData/ranged module ImpactConfiguration names an attacker, a victim
and an environment tree (melee base classes: BP_Base_<Club|Axe|Knife...> -> CT_HitEffect_<Blunt|Sharp>_*;
guns: CT_HitEffect_Ranged_*); a character's HitEffectsComponent has its own victim tree for enemy hits
(BP_Base_Walker -> CT_HitEffect_Zombie_Victim). Trees branch on DI2 expressions ({Hit}.X, {Victim}.X,
{Attacker}.X, #Alias) and on modular trees (CT_WeaponModType, CT_IsLarge, CT_AttackType, CT_RangedWeapon...)
whose result labels pick a link.

Node kinds written here:
  bool    expr, t (true node), f (false node)
  str     expr, links {value: node}, default
  module  module (a modular tree name), links {label: node}
  result  label                                     (modular trees only)
  multi   effects [[ce, direction_interpolation]], next
  ce      ce
  causer  names (keys looked up in the damage causer's ObjectSet anim set collections)
  grid    material-grid effect (bullets): row, row_fact, prefer_kb, registry, next
usage: python tools/build_hit_effects.py
"""
import glob
import json
import os
import re
from pathlib import Path

ROOT = Path(r".")
SRC = [ROOT / "extracted/json/DeadIsland/Content/DI2/Core/HitEffects",
       ROOT / "extracted/json/DeadIsland/Content/DI2/Core/ModularTrees",
       ROOT / "extracted/json/DeadIsland/Content/DI2/Enemies/Zombies",
       ROOT / "extracted/json/DeadIsland/Content/DI2/Effects/HitEffects",
       ROOT / "extracted/json/DeadIsland/Content/DI2/Expansion02/Effects/CosmeticEffects"]


def ref(o):
    """Node id from an object reference (`Class'Tree:Node'`)."""
    if not o:
        return None
    m = re.search(r"'[^:']*:(\w+)'", o.get("ObjectName", ""))
    return m.group(1) if m else None


def asset(o):
    if not o:
        return None
    m = re.search(r"'(\w+)'", o.get("ObjectName", ""))
    return m.group(1) if m else None


def node(e):
    t, p = e["Type"], e.get("Properties", {})
    expr = (p.get("Expression") or {}).get("Expression", "")
    if t == "ConditionalTreeNode_BooleanExpression":
        return {"k": "bool", "expr": expr, "t": ref(p.get("TrueNode")), "f": ref(p.get("FalseNode"))}
    if t == "ConditionalTreeNode_StringExpression":
        return {"k": "str", "expr": expr, "links": {l["Value"]: ref(l.get("Node")) for l in p.get("Links", [])},
                "default": ref(p.get("DefaultNode"))}
    if t == "ConditionalTreeNode_Module":
        return {"k": "module", "module": asset(p.get("ModuleToUse")),
                "links": {l["Value"]: ref(l.get("Node")) for l in p.get("Links", [])}}
    if t == "ConditionalTreeNode_ModularResult":
        return {"k": "result", "label": p.get("ResultLabel", "")}
    if t == "ConditionalTreeNode_MultiHitEffectCosmeticEffect":
        return {"k": "multi", "effects": [[asset(x.get("Definition")), x.get("DirectionInterpolationFactor", 0.0)]
                                          for x in p.get("Effects", []) if x.get("Definition")],
                "next": ref(p.get("NextNode"))}
    if t in ("ConditionalTreeNode_CosmeticEffect", "ConditionalTreeNode_HitEffectCosmeticEffect"):
        return {"k": "ce", "ce": asset(p.get("Definition"))}
    if t == "ConditionalTreeNode_CosmeticEffectDamageCauser":
        return {"k": "causer", "names": p.get("CosmeticEffectNames", [])}
    if t == "ConditionalTreeNode_MaterialGridCosmeticEffect":
        return {"k": "grid", "row": (p.get("MaterialGridRow") or {}).get("RowName") if isinstance(p.get("MaterialGridRow"), dict) else p.get("MaterialGridRow"),
                "row_fact": (p.get("MaterialGridRowFactName") or {}).get("NameStorage"),
                "prefer_kb": p.get("bPreferMaterialGridRowNameFromImpactKnowledgebase", False),
                "registry": asset(p.get("OverrideEffectsRegistry")), "next": ref(p.get("NextNode"))}
    return {"k": "unknown", "type": t, "props": p}


def causer_sets():
    """Damage-causer cosmetic collections (DA_AnimSetCollection_Attacker_* / _Counter_* ...): key ->
    groups [{expr, items: [[weight, CE]]}] (AnimSet_Single = one unconditional item)."""
    out = {}
    for f in glob.glob(str(ROOT / "extracted/json/**/DA_AnimSetCollection_*.json"), recursive=True):
        d = json.load(open(f, encoding="utf-8"))
        objs = {e["Name"]: e for e in d}
        coll = next((e for e in d if e["Type"] == "AnimSetCollection"), None)
        if not coll:
            continue
        keys = {}
        for kv in coll.get("Properties", {}).get("AnimSetData", []):
            aset = (kv.get("Value") or {}).get("AnimSet")
            o = objs.get(ref(aset) or "") if aset else None
            if not o:
                continue
            p = o.get("Properties", {})
            if o["Type"] == "AnimSet_Single":
                ce = asset(p.get("Asset"))
                if ce and ce.startswith("CE_"):
                    keys[kv["Key"]] = [{"expr": "", "items": [[1.0, ce]]}]
            elif o["Type"] == "AnimSet_DataDriven":
                name = asset(p.get("Data"))
                src = glob.glob(str(ROOT / f"extracted/json/**/{name}.json"), recursive=True) if name else []
                if not src:
                    continue
                for e in json.load(open(src[0], encoding="utf-8")):
                    if e["Type"] != "AnimSetData":
                        continue
                    groups = [{"expr": (g.get("Expression") or {}).get("Expression", ""),
                               "items": [[it.get("Weight", 1.0), asset(it.get("Asset"))] for it in g.get("Items", [])
                                         if asset(it.get("Asset") or {}) and asset(it.get("Asset")).startswith("CE_")]}
                              for g in e.get("Properties", {}).get("Groups", [])]
                    groups = [g for g in groups if g["items"]]
                    if groups:
                        keys[kv["Key"]] = groups
        if keys:
            out[Path(f).stem] = keys
    return out


def main():
    trees, modules, unknown = {}, {}, set()
    for d in SRC:
        for f in glob.glob(str(d / "**/*.json"), recursive=True):
            name = Path(f).stem
            if not name.startswith("CT_"):
                continue
            data = json.load(open(f, encoding="utf-8"))
            nodes, start, outs, kind = {}, None, None, None
            for e in data:
                if e["Type"] in ("HitEffectTree", "ModularConditionalTree"):
                    kind = e["Type"]
                    start = ref(e.get("Properties", {}).get("StartNode"))
                    outs = e.get("Properties", {}).get("OutputStrings")
                elif e["Type"].startswith("ConditionalTreeNode_"):
                    n = node(e)
                    if n["k"] == "unknown" and False:
                        unknown.add(n["type"])
                    nodes[e["Name"]] = n
            if kind is None:
                continue
            unknown |= {n["type"] for n in nodes.values() if n["k"] == "unknown"}
            entry = {"start": start, "nodes": nodes}
            if outs:
                entry["outputs"] = outs
            (modules if kind == "ModularConditionalTree" else trees)[name] = entry
    out = {"trees": trees, "modules": modules, "causers": causer_sets()}
    (ROOT / "game/data/hit_effects.json").write_text(json.dumps(out, separators=(",", ":")))
    ces = sorted({x[0] for t in trees.values() for n in t["nodes"].values() if n["k"] == "multi" for x in n["effects"]} |
                 {n["ce"] for t in trees.values() for n in t["nodes"].values() if n["k"] == "ce"})
    print(f"{len(trees)} hit-effect trees, {len(modules)} modular trees, {len(ces)} cosmetic effects referenced; unknown node types: {sorted(unknown)}")


if __name__ == "__main__":
    main()
