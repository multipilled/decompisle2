"""Compile DI2 combat data into game/data/combat.json.

Sources (dumped from the user's own install with di2x json):
  - DA_AnimSet_StandardAttack_<class>: context groups (scalp/down/up/left/right) -> attack montages
  - AM_<class>_StandardAttack_*: Antic / Attack / Recovery montages with BP_DetectHits, BP_Chainable and
    BP_TriggerCameraAnimation notify times
  - AM_*_HeavyAttack_*: heavy release hit windows; kicks/dodges montage lengths
  - DA_CharacterAttributeValues_Berserker_Female, Berserker perks, block/grapple/counter configs, curves,
    DA_PlayerProgressionLevels, DA_AIAttributeValues_*, AI attribute types
Clip names are the short names used in dani_fp.glb (A_1P_ stripped, lower case).
"""
import glob
import json
import re
from pathlib import Path

J = Path(r"extracted\json\DeadIsland\Content")
OUT = Path(r"game\data\combat.json")


def load(name):
    fs = glob.glob(str(J / "**" / f"{name}.json"), recursive=True)
    return json.load(open(fs[0], encoding="utf-8")) if fs else None


def montage(name):
    d = load(name)
    if not d:
        return None
    m = next(e for e in d if e["Type"] == "AnimMontage")
    p = m["Properties"]
    seqs = [s for s in dict.fromkeys(re.findall(r"AnimSequence'([^']+)'", json.dumps(p))) if "_1P_" in s]
    out = {"length": round(p.get("SequenceLength", 0), 4), "seqs": seqs, "detect": None, "chain": [], "camera": None}
    for n in p.get("Notifies", []):
        nm, t, dur = n.get("NotifyName") or "", n.get("LinkValue", 0) or 0, n.get("Duration", 0) or 0
        if "DetectHits" in nm:
            out["detect"] = [round(t, 4), round(t + dur, 4)]
        elif nm == "BP_Chainable":
            out["chain"].append([round(t, 4), round(t + dur, 4)])
        elif nm == "BP_TriggerCameraAnimation":
            out["camera"] = round(t, 4)
    return out


def short(seq):
    return re.sub(r"^A_1P_", "", seq).lower()


def curve(name):
    d = load(name)
    for e in d or []:
        keys = e.get("Properties", {}).get("FloatCurve", {}).get("Keys", [])
        if keys:
            return [[round(k["Time"], 4), round(k["Value"], 4)] for k in keys]
    return None


def attacks(prefix_am, anim_prefix):
    """prefix_am e.g. 'AM_Medium2H_Sweeping_StandardAttack', anim_prefix e.g. 'medium2h_sweeping'."""
    out = {}
    variants = {
        "left_01": "Left_01", "left_02": "Left_02", "left_03": "Left_03",
        "right_01": "Right_01", "right_02": "Right_02", "right_03": "Right_03",
        "down_l": "Down_L", "down_r": "Down_R", "up_l": "Up_L", "up_r": "Up_R",
    }
    for key, v in variants.items():
        antic, attack, rec = montage(f"{prefix_am}_{v}_Antic"), montage(f"{prefix_am}_{v}"), montage(f"{prefix_am}_{v}_Recovery")
        if not attack:
            continue
        seq_attack = next((s for s in attack["seqs"] if s.endswith("_Attack")), attack["seqs"][0])
        base = short(seq_attack)[: -len("_attack")]
        side_from = "left" if ("left_to_right" in base or base.endswith("_l")) else "right"
        entry = {
            "antic": base + "_antic", "attack": base + "_attack", "dec": base + "_attackdec", "recovery": base + "_recovery",
            "antic_len": antic["length"] if antic else 0.5,
            "attack_len": attack["length"],
            "detect": attack["detect"] or [0.1, 0.34],
            "chain_attack": attack["chain"],
            "chain_recovery": rec["chain"] if rec else [],
            "camera": attack["camera"],
            "from": side_from,
        }
        if "left_to_right" in base or "right_to_left" in base:
            dirpart = "left_to_right" if "left_to_right" in base else "right_to_left"
            entry["impact_l"] = f"{anim_prefix}_attack_{dirpart}_impacttol"
            entry["impact_r"] = f"{anim_prefix}_attack_{dirpart}_impacttor"
        out[key] = entry
    return out


def heavy(prefix_am, anim_prefix):
    out = {}
    for v in ("Default_L", "Default_R", "Head_L", "Head_R"):
        m = montage(f"{prefix_am}_HeavyAttack_{v}")
        if m:
            out[v.lower()] = {"clip": f"{anim_prefix}_heavyattack_{v.lower()}", "length": m["length"], "detect": m["detect"] or [0.02, 0.38]}
    for v in ("L", "R"):
        m = montage(f"{prefix_am}_HeavyAttack_Lunge_{v}")
        out[f"lunge_{v.lower()}"] = {"clip": f"{anim_prefix}_heavyattack_charge_lunge_{v.lower()}", "length": m["length"] if m else 0.65}
        out[f"charge_into_{v.lower()}"] = f"{anim_prefix}_heavyattack_charge_into_{v.lower()}"
        out[f"charge_loop_{v.lower()}"] = f"{anim_prefix}_heavyattack_charge_loop_{v.lower()}"
        out[f"antic_{v.lower()}"] = f"{anim_prefix}_heavyattack_antic_{v.lower()}"
        out[f"ground_{v.lower()}"] = f"{anim_prefix}_heavyattack_ground_{v.lower()}"
    return out


def attr_values(name):
    d = load(name)
    vals = {}
    for e in d or []:
        for k, v in e.get("Properties", {}).items():
            if isinstance(v, dict) and "InitialSettings" in v:
                s = v["InitialSettings"]
                vals[k.replace("Attribute", "")] = s.get("DesiredValue", s.get("MinValue"))
    return vals


def main():
    data = {"_source": "Compiled by tools/build_combat_data.py from the user's own DI2 install (personal use)."}
    data["classes"] = {
        "bat": {
            "anim": "medium2h_sweeping", "base": "medium2h", "block": "TwoHanded", "block_from": "FromM2H", "block_to": "ToM2H",
            "attacks": attacks("AM_Medium2H_Sweeping_StandardAttack", "medium2h_sweeping"),
            "heavy": heavy("AM_Medium2H_Sweeping_Club", "medium2h_sweeping"),
            "heavy_force_curve": curve("Curve_HeavyAttack_Force_High"),
            "heavy_intensity_curve": curve("Curve_HeavyAttack_Intensity_High"),
        },
        "machete": {
            "anim": "medium1h_slicing", "base": "medium1h", "block": "OneHanded", "block_from": "FromS1H", "block_to": "ToS1H",
            "attacks": attacks("AM_Medium1H_Slicing_StandardAttack", "medium1h_slicing"),
            "heavy": heavy("AM_Medium1H_Slicing_Sword", "medium1h_slicing") or heavy("AM_Medium1H_Slicing", "medium1h_slicing"),
            "heavy_force_curve": curve("Curve_HeavyAttack_Force_Medium"),
            "heavy_intensity_curve": curve("Curve_HeavyAttack_Intensity_Medium"),
        },
    }
    # Fill machete heavy clip names even when its montages weren't found (same naming as the bat's).
    if not data["classes"]["machete"]["heavy"].get("default_l"):
        h = data["classes"]["machete"]["heavy"]
        for v in ("default_l", "default_r"):
            h[v] = {"clip": f"medium1h_slicing_heavyattack_{v}", "length": 2.8, "detect": [0.02, 0.38]}
    data["kicks"] = {k: {"montage_len": (montage(m) or {}).get("length", 0.933)} for k, m in
                     {"kick": "AM_1P_Medium2H_Kick", "low": "AM_1P_Medium2H_LowKick", "lowest": "AM_1P_Medium2H_LowestKick",
                      "shove": "AM_1P_Medium2H_Shove", "stomp": "AM_1P_Medium2H_Stomp"}.items()}
    data["dodge"] = {"movement_len": (montage("AM_Medium2H_Dodge_Forward_Movement") or {}).get("length", 0.4),
                     "recovery_len": (montage("AM_Medium2H_Dodge_Forward_Recovery") or {}).get("length", 0.533),
                     "strength_curve": curve("Curve_Dodge_StrengthOverTime_Float")}
    dani = attr_values("DA_CharacterAttributeValues_Berserker_Female")
    data["dani"] = {
        "attributes": dani,
        "perks": {
            "chain_damage": {"per_stack": 0.07, "max_stacks": 5, "duration": 3.0},
            "bloodlust_health": {"kills": 2, "health_fraction": 0.15, "cooldown": 0.2},
            "kill_streak_stamina": {"kills": 2, "stamina_fraction": 0.2, "cooldown": 0.2},
        },
        "perfect_block": {"cooldown": 1.5, "stamina_change": 1.5},
        "grapple_minigame": {"start": 0.45, "per_press": 0.2, "phase_time": 2.0, "timeout": 5.0},
        "counter_minigame": {"window": 0.5, "delay": 0.2},
        "dropkick": {"radius": 1.5, "stability_force": 40.0},
    }
    levels = load("DA_PlayerProgressionLevels")[0]["Properties"]["Levels"]
    data["progression"] = {
        "xp_total": [l.get("XPTotalValue", 0) for l in levels],
        "enemy_health_growth_per_level": 0.1,
        "enemy_damage_by_level_diff": curve("Curve_DamageModifierConfig_EnemyDamageScaling"),
        "enemy_xp": {n: attr_values(f"DA_AIAttributeValues_{n}").get("XPReward") for n in ("Walker", "Runner", "Shambler")},
        "enemy_fury": {n: attr_values(f"DA_AIAttributeValues_{n}").get("FuryReward") for n in ("Walker", "Runner", "Shambler")},
    }
    data["stability"] = {
        "base": 500.0,
        "force_to_damage": curve("Curve_ForceToStabilityDamage_Float"),
        "recharge": curve("Curve_StabilityRecharge_Float"),
        "fall_over_chance": curve("Curve_StabiltyFallOverChance_Float"),
    }
    OUT.write_text(json.dumps(data, indent=1))
    c = data["classes"]
    print("bat attacks:", list(c["bat"]["attacks"]), "machete attacks:", list(c["machete"]["attacks"]))
    print("bat left_01:", c["bat"]["attacks"].get("left_01"))
    print("bat heavy:", {k: v for k, v in c["bat"]["heavy"].items() if isinstance(v, dict)})
    print("machete heavy:", {k: v for k, v in c["machete"]["heavy"].items() if isinstance(v, dict)})
    print("dani:", data["dani"]["attributes"])
    print("xp:", data["progression"]["enemy_xp"], "fury:", data["progression"]["enemy_fury"])


if __name__ == "__main__":
    main()
