"""DI2 explosions -> game/data/explosions.json (recon/RE_EXPLOSIONS.md).

Reads every DA_ExplosionArchetype_* (base game + Expansion; Horde mode skipped) from extracted/json and writes what
the port's explosion action (game/scripts/di2_explosion.gd) needs, with the native defaults the archetype's C++
constructor sets (UExplosionActionArchetype ctor 0x141c029d0) for anything the asset leaves out. Curves referenced
anywhere are written as FRichCurve keys [time, value, interp L|K|C, arrive, leave] (the Flesh.curve format).
Balancing assets (ExplosionBalancing_PlayerBasedRules) keep TimeRangeScale / ValueScale (ctor 0x141c06460: 1, 1).
Personal-use research data; nothing here is published.
usage: python tools/build_explosions.py
"""
import json
import sys
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402
from build_splatter import curve_keys  # noqa: E402

# UExplosionActionArchetype native defaults (ctor 0x141c029d0).
DEFAULTS = {
    "OuterRadius": 100.0, "StaticOcclusion": 1.0, "DynamicOcclusion": 0.9, "DynamicOcclusionTurbulence": 0.5,
    "BlastSpeed": 5000.0, "BlastImpulse": 20000.0, "BodyPartDamageEffectivenessMultiplier": 1.0,
    "StabilityDamageForce": 150.0, "bCanLaunch": False,
}
# FImpactData defaults as the ctor writes them at archetype +0x1cc..0x1d4 (bSpawnLimbsOnDismember = 1,
# BisectionChance = 1.0, the rest 0).
IMPACT_DEFAULTS = {"bCanCauseBreak": False, "bCanCauseDismember": False, "bSpawnLimbsOnDismember": True,
                   "bCanCut": False, "bCanCauseBisection": False, "BisectionChance": 1.0}


def name_of(ref):
    """'CurveFloat'Curve_X'' / {'ObjectName': ...} -> 'Curve_X' (None for null)."""
    if not ref:
        return None
    s = ref.get("ObjectName", "") if isinstance(ref, dict) else str(ref)
    return s.split("'")[1] if "'" in s else s


def class_key(path):
    """'/Game/DI2/Enemies/Zombies/Walker/BP_Base_Walker.BP_Base_Walker_C' -> 'BP_Base_Walker_C'."""
    return path.rsplit(".", 1)[-1]


def overrides(lst):
    return {class_key(o["Key"]): name_of(o["Value"]) for o in (lst or [])}


def fact(f):
    t = f["Type"].split("::")[-1]
    v = {"Boolean": f.get("bBooleanValue"), "Integer": f.get("IntegerValue"), "Float": f.get("FloatValue"),
         "String": f.get("StringValue")}.get(t, f.get("bBooleanValue"))
    return [f["Name"], v]


def main():
    curves, balancing, out = {}, {}, {}

    def use_curve(n):
        if n and n not in curves:
            curves[n] = curve_keys(n)
        return n

    def use_balancing(n):
        if n and n not in balancing:
            p = {}
            for e in A.load(n) or []:
                p.update(e.get("Properties", {}))
            balancing[n] = {"TimeRangeScale": p.get("TimeRangeScale", 1.0), "ValueScale": p.get("ValueScale", 1.0)}
        return n

    files = sorted(ROOT.glob("extracted/json/DeadIsland/Content/DI2/**/DA_ExplosionArchetype_*.json"))
    for f in files:
        if "/Horde/" in f.as_posix():
            continue
        p = {}
        for e in json.loads(f.read_text(encoding="utf-8")):
            if e.get("Type") == "ExplosionActionArchetype":
                p.update(e.get("Properties", {}))
        if not p:
            continue
        a = {k: p.get(k, v) for k, v in DEFAULTS.items()}
        a["source"] = f.relative_to(ROOT / "extracted/json").as_posix()
        a["ImpactData"] = {**IMPACT_DEFAULTS, **p.get("ImpactData", {})}
        settings = (p.get("ImpactConfiguration") or {}).get("Settings", {})
        a["VictimEffectTree"] = name_of(settings.get("VictimEffectTree"))
        a["bCanLaunch"] = settings.get("bCanLaunch", False)
        a["LaunchSettings"] = name_of(settings.get("LaunchSettings"))
        a["DistanceScaleCurve"] = use_curve(name_of(p.get("DistanceScaleCurve")))
        a["DistanceScaleCurveClassOverrides"] = {k: use_curve(v) for k, v in overrides(p.get("DistanceScaleCurveClassOverrides")).items()}
        a["DistanceBalancingData"] = use_balancing(name_of(p.get("DistanceBalancingData")))
        for k in ["AngleScaleCurve", "StaticOcclusionStabilityScaleCurve", "StaticOcclusionDamageScaleCurve",
                  "StaticOcclusionImpactScaleCurve", "DynamicOcclusionImpactScaleCurve", "StabilityDistanceScaleCurve"]:
            a[k] = use_curve(name_of(p.get(k)))
        a["StabilityDistanceScaleCurveClassOverrides"] = {k: use_curve(v) for k, v in overrides(p.get("StabilityDistanceScaleCurveClassOverrides")).items()}
        a["StabilityDistanceBalancingData"] = use_balancing(name_of(p.get("StabilityDistanceBalancingData")))
        a["ImpactKB"] = [fact(x) for x in p.get("ImpactKB", [])]
        a["CosmeticEffects"] = name_of(p.get("CosmeticEffects"))
        a["StatusEffects"] = [name_of(s.get("StatusEffectType") or s.get("StatusEffect")) for s in p.get("StatusEffects", [])]
        defs = []
        for d in p.get("DamageDefinitions", []):
            dd = d.get("DSDamageData", {})
            defs.append({
                "Damage": d.get("Damage", 0.0),
                "DamageType": name_of(d.get("DamageTypeClass")),
                "Force": dd.get("Force", 0.0),
                "ImpactData": {**IMPACT_DEFAULTS, **dd.get("ImpactData", {})},
                "DismembermentChanceOnKill": dd.get("DismembermentChanceOnKill", 0.0),
                "CustomDamageFacts": [fact(x) for x in dd.get("CustomDamageFacts", [])],
                "bOnlyApplyToCharacters": d.get("bOnlyApplyToCharacters", False),
                "DistanceScaleCurve": use_curve(name_of(d.get("DistanceScaleCurve"))),
                "DistanceBalancingData": use_balancing(name_of(d.get("DistanceBalancingData"))),
                "DistanceScaleCurveClassOverrides": {k: use_curve(v) for k, v in overrides(d.get("DistanceScaleCurveClassOverrides")).items()},
                # FAccumulatingEffectApplicationParams: EffectType, bApplyMaxValue, ValueToApply, CanExtendEffectDuration
                # (recon/RE_ACCUMULATING.md); scaled by the level curve when bUseScalingOnAccumulatingEffects.
                "AccumulatingEffectsToApply": [{"type": str(x.get("EffectType", "")).split("::")[-1],
                                                "value": x.get("ValueToApply", 0.0),
                                                "apply_max": x.get("bApplyMaxValue", False),
                                                "can_extend": x.get("CanExtendEffectDuration", False)}
                                               for x in d.get("AccumulatingEffectsToApply", [])],
                "bUseScalingOnAccumulatingEffects": d.get("bUseScalingOnAccumulatingEffects", False),
            })
        a["DamageDefinitions"] = defs
        out[f.stem.replace("DA_ExplosionArchetype_", "")] = a
    launch = {}
    for n in sorted({a["LaunchSettings"] for a in out.values() if a["LaunchSettings"]}):
        p = {}
        for e in A.load(n) or []:
            p.update(e.get("Properties", {}))
        launch[n] = p
    dest = ROOT / "game/data/explosions.json"
    dest.write_text(json.dumps({"archetypes": out, "curves": curves, "balancing": balancing, "launch": launch},
                               indent=1), encoding="utf-8")
    print(f"{len(out)} explosion archetypes, {len(curves)} curves, {len(balancing)} balancing -> {dest}")
    missing = [n for n, k in curves.items() if not k]
    if missing:
        print("curves without keys (not exported?):", missing)


if __name__ == "__main__":
    main()
