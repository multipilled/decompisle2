"""DI2 accumulating effects (the elemental / status build-up meters) -> game/data/accumulating_effects.json.

Sources (recon/RE_ACCUMULATING.md):
  BP_StoryGameMode.AccumulatingEffectDefinitions   recipient (DefaultAI / Specials / Player) -> config asset
  DA_AccumulatingEffectConfig_*                    per effect type: AccumulatingDecayRatePerSecond, DefaultEffectDuration,
                                                   AccumulatingPauseDuration, PauseDuration, the status it applies,
                                                   Gain / Decay / EffectDuration modifiers (ModifiableValueDefinitions)
  DA_WeaponModConfig_Default / _RangedDefault / _RangedCrossbow
                                                   per weapon mod: OnHitAccumulatingEffects, the ImpactRequestModifiers'
                                                   AddAccumulatingEffects / ConvertDamageType commands and their KB
                                                   requirements and cosmetic effects
  DA_AccumulatingEffectsLevelScaling_Default -> Curve_AccumulatingEffectsLevelScaling
                                                   value x Curve(victim level - source level)
usage: python tools/build_accumulating.py
"""
import json
import re
from pathlib import Path

ROOT = Path(r".")
J = ROOT / "extracted/json/DeadIsland/Content/DI2"
OUT = ROOT / "game/data/accumulating_effects.json"


def load(rel):
    return json.load(open(J / rel, encoding="utf-8"))


def idx(ref):
    """Export index from an ObjectPath (`/Game/...Asset.N`)."""
    return int(ref["ObjectPath"].rsplit(".", 1)[1])


def short(name):
    return name.split("::")[-1]


def asset_name(ref):
    m = re.search(r"'([\w.]+)'", (ref or {}).get("ObjectName", ""))
    return m.group(1).split(".")[-1] if m else None


def modifiable_default(ref):
    """A ModifiableValueDefinition's default (DefaultValueOverride when bOverrideDefaultValue, else 1)."""
    if not ref:
        return 1.0
    path = ref["ObjectPath"].split(".")[0].replace("/Game/DI2/", "") + ".json"
    p = load(path)[0]["Properties"]
    return float(p.get("DefaultValueOverride", 1.0)) if p.get("bOverrideDefaultValue") else 1.0


def config(rel):
    d = load(rel)
    out = {}
    for e in d:
        if e["Type"] != "AccumulatingEffectDefinition":
            continue
        for it in e["Properties"]["ImplementedEffects"]:
            v = it["Value"]
            impl = d[idx(v["EffectImplementation"])] if v.get("EffectImplementation") else None
            status = asset_name(impl["Properties"].get("StatusEffectToApply")) if impl else None
            params = d[idx(impl["Properties"]["StatusEffectParamsToUse"])].get("Properties", {}) \
                if impl and impl["Properties"].get("StatusEffectParamsToUse") else {}
            out[short(it["Key"])] = {
                "decay_rate": v["AccumulatingDecayRatePerSecond"],
                "duration": v["DefaultEffectDuration"],
                "accumulating_pause": v["AccumulatingPauseDuration"],
                "pause": v["PauseDuration"],
                "gain_multiplier": modifiable_default(v.get("GainModifier")),
                "decay_multiplier": modifiable_default(v.get("DecayModifier")),
                "duration_multiplier": modifiable_default(v.get("EffectDurationModifier")),
                "status": status,
                "status_params": params,
            }
    return out


def mods(rel):
    d = load(rel)
    cfg = next(e for e in d if e["Type"] == "WeaponModConfig")["Properties"]["WeaponModConfigs"]
    out = {}
    for c in cfg:
        if "." not in c["WeaponModType"]["AssetPathName"]:   # an empty slot ('None')
            continue
        name = c["WeaponModType"]["AssetPathName"].rsplit(".", 1)[1].removesuffix("_C")
        m = re.match(r"BP_WeaponMod_(\w+)_Level_(\d)", name)
        rec = {
            "on_hit": [{"type": short(x["EffectType"]), "value": x["ValueToApply"], "apply_max": x["bApplyMaxValue"],
                        "can_extend": x["CanExtendEffectDuration"]} for x in c.get("OnHitAccumulatingEffects", [])],
            "modifiers": [],
            "facts": {f["Name"]: (f["StringValue"] if f["Type"].endswith("String") else f["IntegerValue"]
                                  if f["Type"].endswith("Integer") else f["bBooleanValue"])
                      for f in c.get("FactsSetWhenHeld", [])},
        }
        for r in c.get("ImpactRequestModifiers", []):
            o = d[idx(r)]["Properties"]
            mod = {"requires": (o.get("ImpactKBRequirements") or {}).get("Expression") or None,
                   "cosmetic_effect": asset_name(o.get("OnImpactModifiedCosmeticEffect")),
                   "add_accumulating": [], "convert_damage": []}
            for pe in o.get("PointImpactEffects", []):
                po = d[idx(pe)]
                if po["Type"] == "AddAccumulatingEffectsCommand":
                    mod["add_accumulating"] += [{"type": short(kv["Key"]), "value": kv["Value"]}
                                                for kv in po["Properties"]["EffectTypeAndValueToAdd"]]
                elif po["Type"] == "ConvertDamageTypeAndQuantityCommand":
                    for conv in po["Properties"]["DamageCategoryConversions"]:
                        mod["convert_damage"].append({
                            "from_category": conv["Key"].rsplit(".", 1)[1],
                            "to": {k.rsplit(".", 1)[1].removesuffix("_C"): v
                                   for kv in conv["Value"]["DesiredDamageTypesAsFractionOfSourceDamage"]
                                   for k, v in [(kv["Key"], kv["Value"])]}})
            rec["modifiers"].append(mod)
        out.setdefault(m.group(1).lower(), {})[m.group(2)] = rec
    return out


def curve(rel):
    keys = load(rel)[0]["Properties"]["FloatCurve"]["Keys"]
    return [[k["Time"], k["Value"]] for k in keys]


def main():
    gm = json.load(open(J / "Core/GameModes/BP_StoryGameMode.json", encoding="utf-8"))
    recipients = {}
    for e in gm:
        for kv in e.get("Properties", {}).get("AccumulatingEffectDefinitions", []) or []:
            recipients[short(kv["Key"])] = asset_name(kv["Value"])
    configs = {n: config(f"BalancingData/AccumulatingEffects/ArchetypeConfigurations/{n}.json")
               for n in sorted(set(recipients.values()))}
    data = {
        "_doc": "DI2 accumulating effects (tools/build_accumulating.py, recon/RE_ACCUMULATING.md)",
        "recipients": recipients,
        "configs": configs,
        "mods_melee": mods("BalancingData/Weapons/WeaponMods/DA_WeaponModConfig_Default.json"),
        "mods_ranged": mods("BalancingData/Weapons/WeaponMods/DA_WeaponModConfig_RangedDefault.json"),
        "mods_crossbow": mods("BalancingData/Weapons/WeaponMods/DA_WeaponModConfig_RangedCrossbow.json"),
        "level_curve": curve("BalancingData/AccumulatingEffects/Curve_AccumulatingEffectsLevelScaling.json"),
    }
    OUT.write_text(json.dumps(data, indent=1))
    print(f"{OUT}: recipients {recipients}, mods {sorted(data['mods_melee'])}")


if __name__ == "__main__":
    main()
