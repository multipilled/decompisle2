"""DI2 facts the hit-reaction trees read that hit_reacts.json lacks -> game/data/hit_react_extra.json.

Per weapon in game/data/weapons.json (its balancing blueprint and Super chain, extracted/json):
  weapon_class      EquippableData / MeleeArchetypeData .FactsSetWhenHeld 'WeaponClass' ("Light" / "Medium" / "Heavy"):
                    the player's KB string fact while the weapon is held; BP_Base_AIController.DetermineIfVulnerableDebug
                    evaluates the zombie's VulnerableRequirement_<WeaponClass> with it
  can_launch        ImpactConfiguration.Settings.bCanLaunch ({Hit}.CanLaunch)
  launch_settings   ImpactConfiguration.Settings.LaunchSettings (the impact-provided DA_LaunchSettings_* that
                    LaunchingImpactResponse uses when bUseImpactProvidedLaunchSettings)
Each field comes from the most derived blueprint that sets it; null = not set anywhere in the chain (native default).
The referenced DA_LaunchSettings_* assets are embedded under "launch_settings" (missing ones are listed; dump them with
`tools/di2x.sh json` into extracted/json first).

Per archetype (victims): BP_Base_AI.InitHitReactBalacingData (bytecode) writes the KB float facts
HitReactStabilityCTILarge / Medium / Small from GenericBalancingDataRow (DT_EnemyGenericData row = the archetype);
HitReactStabilityCTIXSmall is never written (reads 0).
Curves: the PhysicalizedReaction ragdoll blend-in / blend-out curves (BPC_PhysicalizedHitReact_AI).

usage: python tools/build_hit_react_extra.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402
from build_weapons import bp_chain  # noqa: E402

WEAPONS = Path(r"game\data\weapons.json")
OUT = Path(r"game\data\hit_react_extra.json")
CURVES = ["Curve_PhysicalizedReactions_RagdollBlendWeightToPhysicsBlendWeight_BlendIn_AI",
          "Curve_PhysicalizedReactions_RagdollBlendWeightToPhysicsBlendWeight_BlendOut_AI",
          "Curve_PhysicalizedReactions_RagdollBlendWeightToMotorsStrength_BlendIn_AI",
          "Curve_PhysicalizedReactions_RagdollBlendWeightToMotorsStrength_BlendOut_AI", "Curve_StabilityRecharge_Float"]


def _walk(o):
    stack = [o]
    while stack:
        x = stack.pop()
        if isinstance(x, list):
            stack.extend(x)
        elif isinstance(x, dict):
            yield x
            stack.extend(v for v in x.values() if isinstance(v, (dict, list)))


def fields(chain):
    out = {"weapon_class": None, "can_launch": None, "launch_settings": None, "held_facts": None}
    for _, _, _, d in chain:  # most derived first
        for e in d:
            for o in _walk(e.get("Properties", {})):
                if out["held_facts"] is None and isinstance(o.get("FactsSetWhenHeld"), list):
                    facts = {f["Name"]: f.get("StringValue") if f.get("Type", "").endswith("String") else
                             f.get("bBooleanValue") if f.get("Type", "").endswith("Boolean") else f.get("FloatValue")
                             for f in o["FactsSetWhenHeld"]}
                    if "WeaponClass" in facts:
                        out["held_facts"] = facts
                st = (o.get("ImpactConfiguration") or {}).get("Settings") if isinstance(o.get("ImpactConfiguration"), dict) else None
                if isinstance(st, dict):
                    if out["can_launch"] is None and "bCanLaunch" in st:
                        out["can_launch"] = bool(st["bCanLaunch"])
                    if out["launch_settings"] is None and st.get("LaunchSettings"):
                        out["launch_settings"] = (A.anyref(st["LaunchSettings"]) or "").split(".")[-1] or None
    if out["held_facts"]:
        out["weapon_class"] = out["held_facts"].get("WeaponClass")
    return out


def main():
    weapons = json.loads(WEAPONS.read_text())
    out = {"_source": "tools/build_hit_react_extra.py (personal use): DI2 weapon blueprints' held WeaponClass, "
                      "bCanLaunch and impact LaunchSettings; DT_EnemyGenericData hit-react CTI multipliers; ragdoll "
                      "blend curves.", "weapons": {}, "launch_settings": {}, "victims": {}, "curves": {}, "missing": []}
    gd = A.load("DT_EnemyGenericData")
    rows = (gd[0].get("Rows") if gd else {}) or {}
    for row, vals in rows.items():
        out["victims"][row] = {k.split("_")[0]: v for k, v in vals.items() if k.startswith("HitReactStabilityCTI")}
    for c in CURVES:
        d = A.load(c)
        if not d:
            out["missing"].append(c)
            continue
        keys = next((e.get("Properties", {}) for e in d if e.get("Type") == "CurveFloat"), {}).get("FloatCurve", {}).get("Keys", [])
        out["curves"][c] = [[k["Time"], k["Value"], k.get("InterpMode", "RCIM_Linear"), k.get("ArriveTangent", 0.0),
                             k.get("LeaveTangent", 0.0)] for k in keys]
    assets = set()
    for wid, w in weapons.items():
        if not isinstance(w, dict) or not w.get("blueprint"):
            continue
        f = fields(bp_chain(w["blueprint"]))
        out["weapons"][wid] = f
        if f["launch_settings"]:
            assets.add(f["launch_settings"])
    for a in sorted(assets):
        d = A.load(a)
        if not d:
            out["missing"].append(a)
            continue
        out["launch_settings"][a] = next((e.get("Properties", {}) for e in d if e.get("Type") == "LaunchSettings"), {})
    OUT.write_text(json.dumps(out, indent=1))
    n = len(out["weapons"])
    print(f"{n} weapons, {sum(1 for f in out['weapons'].values() if f['weapon_class'])} with WeaponClass, "
          f"{sum(1 for f in out['weapons'].values() if f['can_launch'])} can launch, {len(assets)} launch settings, "
          f"missing {out['missing']}")


if __name__ == "__main__":
    main()
