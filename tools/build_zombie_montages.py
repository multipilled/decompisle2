"""DI2 zombie montages -> game/data/montages_zombie.json for scripts/zombie_anim.gd (recon/ANIMATION.md).

  montages: every AM_ZMB_* montage (extracted/json): length, blend_in / blend_out ([seconds, EAlphaBlendOption],
            DI2's 0.1 s HermiteCubic montage default filled in), blend_out_trigger, auto_blend_out, sections, slot,
            notifies with absolute times, and per body the segments with that body's Godot clip names
            [[clip, StartPos, AnimStartTime, AnimEndTime, AnimPlayRate, LoopingCount]] ("" where the body lacks it).
  by_clip:  per body, Godot clip -> the montage DI2 plays that sequence in (single-segment, non-layered montage of
            the body's family or Base; the one named after the sequence first), so the port's clip choices play
            with DI2's montage settings.
  blend_by_clip: per body, Godot clip -> a montage that has the sequence in any segment (attacks: DI2 wraps the
            attack sequence with an IntoStatic lead-in / AnimStartTime offset), for its BlendIn / BlendOut only.
            An attack clip whose montage the body can play whole (lead-in sequences from the extra clip glbs) is
            also in by_clip, so it plays as DI2's full montage (recon/ANIMATION.md 9).
  windup:   attack montage -> [FixedWindUpMontage, Duration, WindUpDefinition] from DI2's AttackDefinitions
            (DA_AttackDef_*: WindUps[].Attacks[] pairs a Montage with its FixedWindUpMontage; WindUps[].Duration is the
            wind-up time; WindUps[].WindUp the locomotion-layer wind-up). DI2's melee action plays the wind-up montage,
            then the attack montage once Duration has passed.
  windup_defs: DA_WindUpDef_* -> {idle: WindUpIdleAdditive, start: WindUpStartAdditive, run: WindUpRun (blend space),
            idle_len: IdleAnimationLength}: the poses ABP_ZombieWalker blends in by AnimInterest_Melee.AttackWindUpAmount
            (recon/ANIMATION.md 11).
  sync_markers: DI2 sequence -> [[time, name], ...] of its AuthoredSyncMarkers.
  loco_transition: DI2 sequence -> [[time, ETransition], ...] of its AnimNotify_LocomotionTransition notifies.
  forward_foot: DI2 sequence -> [length, [[time, EFoot], ...]] of its AnimNotify_ForwardFoot notifies.
  root_motion: DI2 sequence -> root lock ("RefPose" / "AnimFirstFrame" / "Zero", "!" = bForceRootLock) for every
            dumped sequence with bEnableRootMotion (recon/ANIMATION.md 13).
  blend_profiles / loco_profiles: SKEL_ZombieStandard's BlendProfiles ({bone: BlendScale}) and the Base_Locomotion
            transitions ("Starts->Move") / Move's strafe swap ("MoveSwap") that use one (recon/ANIMATION.md 15).
  Each montage also lists its segments' DI2 sequences ("seqs"). Sequences a body glb lacks resolve to the body's
  extra clip glbs (game/assets/di2/zombie_clips/<body>_<set>.anims.json, tools/build_zombie_clips.py) as "x:<seq>".

usage: python tools/build_zombie_montages.py
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402

ROOT = Path(r".")
OUT = ROOT / "game/data/montages_zombie.json"
BODIES = ("walker", "runner", "shambler", "thug", "screamer", "slobber", "butcher", "suicider")
FAMILY = {"walker": "Walker", "runner": "Runner", "shambler": "Shambler", "thug": "Thug", "screamer": "Screamer",
          "slobber": "Slobber", "butcher": "Butcher", "suicider": "Suicider"}


def body_maps():
    out = {}
    for b in BODIES:
        f = ROOT / f"game/assets/di2/{b}/clips.json"
        m = {}
        if f.exists():
            for g, seq in json.loads(f.read_text()).items():
                if isinstance(seq, str):
                    m.setdefault(seq.removeprefix("inplace:"), []).append(g.removeprefix("inplace:"))
        out[b] = m
    return out


def windups():
    """attack montage -> [fixed wind-up montage or "", wind-up Duration] from every dumped DA_AttackDef_*. A montage
    in several definitions takes the one DI2's regular attack sequences use (DA_AttackSequence_* AttackDefinition):
    e.g. the Walker's swipes are in DA_AttackDef_Walker_Swipe (DA_AttackSequence_Walker_Swipe, no fixed wind-up) and
    in DA_AttackDef_Walker_Swipe_Horiz (fixed wind-up, used only by the CannotReachTarget sequences)."""
    users = {}
    for f in sorted((ROOT / "extracted").glob("json*/DeadIsland/Content/**/DA_AttackSequence_*.json")):
        for d in re.findall(r"AttackDefinition'(DA_AttackDef_\w+)'", f.read_text(encoding="utf-8")):
            users.setdefault(d, set()).add(f.stem)

    def rank(defn):   # 0 used by a regular sequence, 1 no dumped user, 2 only CannotReachTarget sequences
        u = users.get(defn, set())
        return 1 if not u else (2 if all("CannotReachTarget" in x for x in u) else 0)
    cands = {}
    for f in sorted((ROOT / "extracted").glob("json*/DeadIsland/Content/**/DA_AttackDef_*.json")):
        for e in json.loads(f.read_text(encoding="utf-8")):
            for w in (e.get("Properties") or {}).get("WindUps", []):
                for at in w.get("Attacks", []):
                    mn = (at.get("Montage") or {}).get("ObjectName", "")
                    if "'" not in mn:
                        continue
                    fw = (at.get("FixedWindUpMontage") or {}).get("ObjectName", "")
                    wd = (w.get("WindUp") or {}).get("ObjectName", "")
                    cands.setdefault(mn.split("'")[1], []).append(
                        (rank(f.stem), f.stem, fw.split("'")[1] if "'" in fw else "", float(w.get("Duration", 0.0)),
                         wd.split("'")[1] if "'" in wd else ""))
    return {mn: [sorted(c)[0][2], sorted(c)[0][3], sorted(c)[0][4]] for mn, c in cands.items()}


def windup_defs():
    """DA_WindUpDef_* -> its sequences (UWindUpDefinition: WindUpIdleAdditive +0x30, IdleAnimationLength +0x38,
    WindUpStartAdditive +0x40, WindUpRun +0x48 - the offsets FUN_14114e4e0 / FUN_1411291b0 read)."""
    out = {}
    for f in sorted((ROOT / "extracted").glob("json*/DeadIsland/Content/**/DA_WindUpDef_*.json")):
        p = json.loads(f.read_text(encoding="utf-8"))[0].get("Properties") or {}
        nm = lambda k: (p.get(k) or {}).get("ObjectName", "").split("'")[1] if "'" in (p.get(k) or {}).get("ObjectName", "") else ""  # noqa: E731
        out[f.stem] = {"idle": nm("WindUpIdleAdditive"), "start": nm("WindUpStartAdditive"), "run": nm("WindUpRun"),
                       "idle_len": float(p.get("IdleAnimationLength", 0.0))}
    return out


def forward_feet():
    """DI2 sequence -> [SequenceLength, [[time, foot], ...]] for every dumped zombie sequence with AnimNotify_ForwardFoot
    notifies (foot = EFoot: 0 BlendLeftFoot, 1 BlendRightFoot; notify order as cooked). time = FAnimNotifyEvent::GetTime
    (FUN_1434e9270: the link time + TriggerTimeOffset); an unlinked sequence notify's Proportional LinkValue is a
    fraction of the sequence length. The foot tracker (FUN_141111e50) and Move's start position (FUN_1411088d0) read
    these (recon/ANIMATION.md 12)."""
    out = {}
    for f in sorted((ROOT / "extracted/json/DeadIsland/Content/DI2/Animation/Zombie").rglob("A_ZMB_*.json")):
        txt = f.read_text(encoding="utf-8")
        if "AnimNotify_ForwardFoot" not in txt:
            continue
        d = json.loads(txt)
        objs = {e["Name"]: e for e in d}
        seq = next((e for e in d if e["Type"] == "AnimSequence"), None)
        if seq is None:
            continue
        p = seq["Properties"]
        length = float(p.get("SequenceLength", 0.0))
        feet = []
        for n in p.get("Notifies", []):
            o = objs.get((n.get("Notify") or {}).get("ObjectName", "").split(":")[-1].rstrip("'"))
            if not o or o["Type"] != "AnimNotify_ForwardFoot":
                continue
            v = float(n.get("LinkValue", 0.0))
            t = v * length if n.get("LinkMethod", "") == "EAnimLinkMethod::Proportional" else v
            foot = 1 if (o.get("Properties") or {}).get("FootType") == "EFoot::BlendRightFoot" else 0
            feet.append([round(t + float(n.get("TriggerTimeOffset", 0.0)), 5), foot])
        if feet:
            out[seq["Name"]] = [length, feet]
    return out


ETRANSITION = {"EndStopToMove": 0, "EndMoveToStop": 1, "EndPivot": 2, "EndTurnOnSpot": 3, "EndCycleBreak": 4,
               "EndStanceChange": 5, "PivotTurningPoint": 6}   # ETransition (exe UEnum names 0x1455feda0..)


def loco_transitions():
    """DI2 sequence -> [[time, ETransition], ...] of its AnimNotify_LocomotionTransition notifies (NotifyTransition +0x38,
    default EndStopToMove). The Start / Stop / TurnOnSpot entries (FUN_14112a190 / FUN_141129fd0 / FUN_14112a230 ->
    FUN_1411615a0 modes 0 / 1 / 3) take their Duration from the first one of their type (FUN_141162050)."""
    out = {}
    for f in sorted((ROOT / "extracted/json/DeadIsland/Content/DI2/Animation/Zombie").rglob("A_ZMB_*.json")):
        txt = f.read_text(encoding="utf-8")
        if "AnimNotify_LocomotionTransition" not in txt:
            continue
        d = json.loads(txt)
        objs = {e["Name"]: e for e in d}
        seq = next((e for e in d if e["Type"] == "AnimSequence"), None)
        if seq is None:
            continue
        p = seq["Properties"]
        length = float(p.get("SequenceLength", 0.0))
        lt = []
        for n in p.get("Notifies", []):
            o = objs.get((n.get("Notify") or {}).get("ObjectName", "").split(":")[-1].rstrip("'"))
            if not o or o["Type"] != "AnimNotify_LocomotionTransition":
                continue
            v = float(n.get("LinkValue", 0.0))
            t = v * length if n.get("LinkMethod", "") == "EAnimLinkMethod::Proportional" else v
            ty = str((o.get("Properties") or {}).get("NotifyTransition", "ETransition::EndStopToMove")).split("::")[-1]
            lt.append([round(t + float(n.get("TriggerTimeOffset", 0.0)), 5), ETRANSITION.get(ty, -1)])
        if lt:
            out[seq["Name"]] = lt
    return out


def sync_markers():
    """DI2 sequence -> [[time, marker name], ...] (AuthoredSyncMarkers, time order) for every dumped zombie sequence
    that has them: UE 4.27 marker-based sync of the Move blend space's samples (sync group "Locomotion")."""
    out = {}
    for f in sorted((ROOT / "extracted/json/DeadIsland/Content/DI2/Animation/Zombie").rglob("A_ZMB_*.json")):
        txt = f.read_text(encoding="utf-8")
        if "AuthoredSyncMarkers" not in txt:
            continue
        seq = next((e for e in json.loads(txt) if e["Type"] == "AnimSequence"), None)
        mk = (seq or {}).get("Properties", {}).get("AuthoredSyncMarkers") or []
        if mk:
            out[seq["Name"]] = sorted([round(float(m.get("Time", 0.0)), 5), str(m.get("MarkerName", ""))] for m in mk)
    return out


def root_motion():
    """DI2 sequence -> its root lock for every dumped zombie sequence with UAnimSequence.bEnableRootMotion: "RefPose"
    (the stock UE 4.27 ctor default, cooked data leaves it out), "AnimFirstFrame" or "Zero" (RootMotionRootLock), plus
    "!" when bForceRootLock. Under DINPCAnimInstance's RootMotionFromEverything these sequences give their root motion
    to the capsule and pose the root bone at the lock (UAnimSequence::ResetRootBoneForRootMotion)."""
    out = {}
    for f in sorted((ROOT / "extracted/json/DeadIsland/Content/DI2/Animation/Zombie").rglob("A_ZMB_*.json")):
        txt = f.read_text(encoding="utf-8")
        if '"bEnableRootMotion": true' not in txt:
            continue
        lock = re.search(r'"RootMotionRootLock": "ERootMotionRootLock::(\w+)"', txt)
        out[f.stem] = (lock.group(1) if lock else "RefPose") + ("!" if '"bForceRootLock": true' in txt else "")
    return out


def blend_profiles():
    """(SKEL_ZombieStandard's BlendProfiles {name: {bone: BlendScale}}, {"<From>-><To>" Base_Locomotion transition or
    "MoveSwap" (Move's BlendListByBool_3): profile name}) from the skeleton and ABP_ZombieWalker's BakedStateMachines.
    DI2 applies them per bone (state-machine transition 0x1434dba80, BlendListBase::Update 0x143099750): next pose
    weight x BlendScale, previous x 1 / BlendScale, then per-bone normalised (0x143514480)."""
    skel = json.loads((ROOT / "extracted/json/DeadIsland/Content/DIShared/Art/Characters/ZombieStandard/"
                       "SKEL_ZombieStandard.json").read_text(encoding="utf-8"))
    profiles = {e["Name"]: {x["BoneReference"]["BoneName"]: x["BlendScale"] for x in e["Properties"].get("ProfileEntries", [])}
                for e in skel if e["Type"] == "BlendProfile"}
    abp = json.loads((ROOT / "extracted/json/DeadIsland/Content/DI2/Enemies/Zombies/Walker/ABP_ZombieWalker.json")
                     .read_text(encoding="utf-8"))
    cls = next(e for e in abp if e["Type"] == "AnimBlueprintGeneratedClass")
    uses = {}
    for sm in cls["Properties"].get("BakedStateMachines", []):
        if sm["MachineName"] != "Base_Locomotion":
            continue
        names = [s["StateName"] for s in sm["States"]]
        for t in sm["Transitions"]:
            if t.get("BlendProfile"):
                uses[f"{names[t['PreviousState']]}->{names[t['NextState']]}"] = \
                    t["BlendProfile"]["ObjectName"].split(":")[-1].rstrip("'")
    swap = abp[-1]["Properties"].get("AnimGraphNode_BlendListByBool_3", {}).get("BlendProfile")
    if swap:
        uses["MoveSwap"] = swap["ObjectName"].split(":")[-1].rstrip("'")
    return profiles, uses


def extra_maps():
    """body -> {DI2 sequence: "x:<sequence>"} for the body's extra clip glbs (tools/build_zombie_clips.py)."""
    out = {b: {} for b in BODIES}
    for f in sorted((ROOT / "game/assets/di2/zombie_clips").glob("*.anims.json")):
        b = f.name.split("_", 1)[0]
        if b in out:
            for seq in json.loads(f.read_text()):
                out[b].setdefault(seq, "x:" + seq)
    return out


def main():
    maps = body_maps()
    extra = extra_maps()
    out = {"montages": {}, "by_clip": {b: {} for b in BODIES}, "blend_by_clip": {b: {} for b in BODIES},
           "windup": windups(), "windup_defs": windup_defs(), "forward_foot": forward_feet(),
           "loco_transition": loco_transitions(), "sync_markers": sync_markers(), "root_motion": root_motion()}
    out["blend_profiles"], out["loco_profiles"] = blend_profiles()
    cands = {b: {} for b in BODIES}
    loose = {b: {} for b in BODIES}
    for name in sorted(A.index()):
        if not name.startswith("AM_ZMB_"):
            continue
        m = A.montage(name)
        if not m or not m["tracks"]:
            continue
        slot, segs = next(iter(m["tracks"].items()))
        entry = {"length": m["length"], "blend_in": m["blend_in"], "blend_out": m["blend_out"],
                 "blend_out_trigger": m["blend_out_trigger"], "auto_blend_out": m["auto_blend_out"],
                 "sections": m["sections"], "slot": slot, "notifies": m["notifies"], "segments": {},
                 "seqs": [s[0] for s in segs]}
        for b in BODIES:
            entry["segments"][b] = [[(maps[b].get(s[0]) or [extra[b].get(s[0], "")])[0], s[1], s[2], s[3], s[4], s[5]]
                                    for s in segs]
        out["montages"][name] = entry
        for b in BODIES:
            if not (name.startswith("AM_ZMB_Base_") or name.startswith(f"AM_ZMB_{FAMILY[b]}_")):
                continue
            for i, sg in enumerate(segs):
                for g in maps[b].get(sg[0], []):
                    bad = ("FixedWindUp" in name) + ("Impact" in name) + ("Layered" in name)
                    loose[b].setdefault(g, []).append((bad, len(segs), len(name), name))
            if len(segs) == 1 and "Layered" not in name and slot in ("DefaultSlot", "FullBody", "Fullbody_Transform"):
                seq = segs[0][0]
                for g in maps[b].get(seq, []):
                    named = name == "AM_" + seq.removeprefix("A_") or name + "_01" == "AM_" + seq.removeprefix("A_")
                    bad = ("FixedWindUp" in name) + ("Impact" in name)
                    cands[b].setdefault(g, []).append((0 if named else 1, bad, len(name), name))
    for b in BODIES:
        for g, lst in cands[b].items():
            out["by_clip"][b][g] = sorted(lst)[0][3]
        for g, lst in loose[b].items():
            out["blend_by_clip"][b][g] = sorted(lst)[0][3]
            # Attacks: DI2 plays the attack sequence inside its montage (IntoStatic lead-in + attack). When every
            # segment resolves for this body, the clip plays as that whole montage.
            mn = out["blend_by_clip"][b][g]
            cur = out["by_clip"][b].get(g, "")
            if (g.startswith("attack_") or g.startswith("crawl_attack")) and (not cur or "FixedWindUp" in cur) and \
                    "FixedWindUp" not in mn and all(sg[0] for sg in out["montages"][mn]["segments"][b]):
                out["by_clip"][b][g] = mn   # the attack montage itself, not its wind-up partner
    OUT.write_text(json.dumps(out, indent=0))
    print(f"{len(out['montages'])} montages; clips with a montage (exact / blend-only): " + ", ".join(
        f"{b} {len(out['by_clip'][b])}/{len(out['blend_by_clip'][b])}/{sum(len(v) for v in maps[b].values())}" for b in BODIES))


if __name__ == "__main__":
    main()
