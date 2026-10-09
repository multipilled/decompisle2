"""Convert DI2 MultiPartHealth + part-bone dumps (from di2x json) into gore-core archetype JSON.

Input:  extracted\\json\\...  (local dumps of the user's own install)
Output: game\\data\\archetypes.json
"""
import json
from pathlib import Path

ROOT = Path(r"extracted\json\DeadIsland\Content")
OUT = Path(r"game\data\archetypes.json")
ASSETS = Path(r"game\assets\di2")
MONTAGES = Path(r"game\data\montages_zombie.json")   # tools/build_zombie_montages.py

# Locomotion and attacks aren't in MultiPartHealth. Families with their own DI2 body (BODIES) take their
# speeds from the root motion of the clips that body plays, as measured by tools/merge_anims.py into
# game/assets/di2/<family>/<family>.anims.json: walk = walk_slow (closing in), chase = walk, crawl = crawl.
# The rest are estimates from watching the game, and play the Walker body's clips.
BODIES = ("Walker", "Shambler", "Runner", "Thug")
LOCO = {
    "Screamer": (1.1, 2.4, 0.5), "Slobber": (0.8, 1.4, 0.4),
    "Butcher": (1.6, 4.0, 0.8), "Mutator": (1.4, 3.2, 0.6), "Whipper": (1.2, 2.6, 0.6),
    "Suicider": (0.8, 1.3, 0.4), "Reformer": (1.0, 1.8, 0.5),
}
# Attack card -> the clip game/scripts/zombie.gd plays for it.
CARD_CLIPS = {"LeftHandSwipe": "attack_swipe_l", "RightHandSwipe": "attack_swipe_r", "Grapple": "attack_grapple", "Bite": "attack_bite"}
CUT_BONES = {"head": ["neck_02"], "leg_left": ["thigh_l", "calf_l"], "leg_right": ["thigh_r", "calf_r"]}


def body_report(family):
    """(clips.json, anims.json) of a family's DI2 body, from tools/merge_anims.py."""
    d = ASSETS / family.lower()
    return json.loads((d / "clips.json").read_text()), json.loads((d / f"{family.lower()}.anims.json").read_text())


def attack_timing(family):
    """card -> (hit_time, duration) on DI2's montage timeline. The port plays each card's clip as DI2's montage for it
    (montages_zombie.json by_clip: the attack sequence after its IntoStatic lead-in segments, as DI2 composes them),
    so the hit is the start of the montage's AIDetectMeleeHits window in montage time (notify LinkValues resolved over
    the segment chain by di2_animsets.link_time) and the duration is the montage length. When DI2's regular attack
    sequence pairs the montage with a FixedWindUpMontage the body can play (montages_zombie.json windup, from
    DA_AttackDef_* WindUps[]), the wind-up Duration comes first (recon/ANIMATION.md 9). Without a FixedWindUpMontage
    but with a WindUpDefinition, AIMeleeSubAction_VariableWindUp runs the locomotion-layer wind-up for Duration
    before the attack montage (scripts/zombie_anim.gd play(); recon/ANIMATION.md 11), so Duration comes first too."""
    zm = json.loads(MONTAGES.read_text())
    body = family.lower()
    timing = {}
    for card, clip in CARD_CLIPS.items():
        mn = zm["by_clip"].get(body, {}).get(clip)
        if not mn:
            continue
        m = zm["montages"][mn]
        starts = [n[1] for n in m["notifies"] if "MeleeHits" in n[0]]
        fw, wdur, wdef = (zm.get("windup", {}).get(mn, []) + ["", 0.0, ""])[:3] if mn in zm.get("windup", {})             else ("", 0.0, "")
        if fw:
            lead = wdur if all(sg[0] for sg in zm["montages"][fw]["segments"][body]) else 0.0
        else:
            lead = wdur if wdef and wdur > 0.0 else 0.0
        if starts:
            timing[card] = (round(lead + min(starts), 3), round(lead + m["length"], 3))
    return timing


def load(rel):
    return json.load(open(ROOT / rel, encoding="utf-8"))


def cdo_props(path: Path):
    for e in json.load(open(path, encoding="utf-8")):
        if e["Name"].startswith("Default__"):
            return e.get("Properties") or {}
    return {}


def ai_attributes(name):
    """DA_AIAttributeValues_<Type>: real character health, attack damage and spacing (when DI2 has one)."""
    hits = list(ROOT.glob(f"**/DA_AIAttributeValues_{name}.json"))
    if not hits:
        return {}
    props = json.load(open(hits[0], encoding="utf-8"))[0].get("Properties", {})
    val = lambda k: (props.get(k) or {}).get("InitialSettings", {}).get("DesiredValue")

    def rng(k):
        s = (props.get(k) or {}).get("InitialSettings", {})
        return [s["MinValue"], s["MaxValue"]] if "MinValue" in s and "MaxValue" in s else None
    return {"health": val("MaxHealthAttribute"), "damage": val("BaseDamageAttribute"), "spacing": val("AttackSpacingDuration"),
            "knockdown": rng("KnockdownDuration"), "force": val("BaseForceAttribute")}


def attacks(scale, damage=12.0, spacing=1.2, timing=None):
    timing = timing or {}

    def card(name, l, r, standing=True, crawling=True, rng=1.7, dmg=1.0, hit=0.55, dur=1.3, cd=0.0, w=1.0):
        hit, dur = timing.get(name, (hit, dur))
        return dict(name=name, range=rng, damage=dmg * damage * scale, hit_time=hit, duration=dur, cooldown=cd or spacing,
                    needs_left_arm=l, needs_right_arm=r, standing=standing, crawling=crawling, weight=w)
    return [
        card("LeftHandSwipe", True, False), card("RightHandSwipe", False, True),
        card("Grapple", True, True, dmg=1.5, hit=0.8, dur=2.0, cd=3.0, w=0.5),
        card("Bite", False, False, rng=1.1, dmg=0.7, w=0.3),
    ]


def main():
    bones = {k.lower(): v["BoneNames"] for k, v in
             load("DIShared/Core/Enemies/Zombies/DT_ZombiePartBoneDefinition.json")[0]["Rows"].items()}
    base = cdo_props(ROOT / "DI2/Enemies/BPC_Base_MultiPartHealth_AI.json")
    loco, timing = dict(LOCO), {}
    for family in BODIES:
        clips, report = body_report(family)
        loco[family] = tuple(report[c]["root_speed"] for c in ("walk_slow", "walk", "crawl"))
        timing[family] = attack_timing(family)
        print(f"  {family} body: walk/chase/crawl {loco[family]} m/s, attacks (hit, duration) {timing[family]}")
    out = []
    for f in sorted(ROOT.glob("**/BPC_MultiPartHealth_*.json")):
        name = f.stem.replace("BPC_MultiPartHealth_", "")
        p = {**base, **cdo_props(f)}
        kind = next((k for k in loco if name.startswith(k)), "Walker")
        walk, chase, crawl = loco[kind]
        body = kind if kind in BODIES else "Walker"  # the body (and so the attack clips) it spawns with
        max_health = float(p.get("MaxHealth", 120.0))
        parts = []
        for d in p["PartHealthDefinitions"]:
            pid = d["BodyPartBoneDefinitionRowName"]
            s = d["DefaultSettings"]
            parts.append(dict(
                id=pid, bones=bones.get(pid.lower(), []), cut_bones=CUT_BONES.get(pid.lower(), []),
                max_health_fraction=d["MaxHealthFraction"],
                can_dismember=s["bCanBeDismembered"], dismember_chance=s["DismemberChanceWhenOnZeroHealth"],
                can_break=s["bCanBeBroken"], break_chance=s["BreakChanceWhenOnZeroHealth"],
                force_kill=s["bForceKillOwnerWhenDestroyed"] or pid.lower() == "head",
                radial_scalar=s["RadialDamageScalar"], radial_chance=s["AffectedByRadialDamageChance"],
                can_regenerate=s["bCanBeRegenerated"]))
        ai = ai_attributes(name.split("_")[0])
        out.append(dict(
            name=name, source=str(f.relative_to(ROOT)).replace("\\", "/"),
            health=float(ai.get("health") or max_health), limb_health=max_health, head_damage_multiplier=2.0,
            survive=(p.get("BodyPartExpressionRequiredToLive") or {}).get("Expression", ""),
            parts=[x for x in parts if x["bones"]],
            locomotion=dict(walk_speed=walk, chase_speed=chase, crawl_speed=crawl, turn_rate_deg=200.0),
            attacks=attacks(1.0, float(ai.get("damage") or 12.0), float(ai.get("spacing") or 1.2), timing[body]),
            sight_range=18.0, stagger_threshold=max_health * 0.2,
            knockdown_duration=ai.get("knockdown") or [3.5, 5.0], base_force=ai.get("force")))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1))
    print(f"{len(out)} archetypes -> {OUT}")
    for a in out:
        print(f"  {a['name']:28} hp={a['health']:6} parts={[x['id'] for x in a['parts']]} survive={a['survive']!r}")


if __name__ == "__main__":
    main()
