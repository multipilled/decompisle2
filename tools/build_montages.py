"""DI2 1P montages -> game/data/montages.json for scripts/di2_anim.gd (recon/ANIMATION.md).

Every montage a held-item class slot can play (the "m" names in game/data/classes/*.json), with what UE's
FAnimMontageInstance needs to play it like DI2 does:
  length, blend_in / blend_out ([seconds, EAlphaBlendOption], DI2's own 0.1 s HermiteCubic default filled in),
  blend_out_trigger, auto_blend_out, sections [[name, start, next]], the Arms slot segments
  [[godot clip, StartPos, AnimStartTime, AnimEndTime, AnimPlayRate, LoopingCount]] and the notify windows with
  absolute times (tools/di2_animsets.py link_time), incl. the AnimNotifyState_ScalePlayRate windows:
  rate [[key, start, end, by_length]] (key = PlayrateDurationStringKey, by_length = bScaleByNotifyLength).

usage: python tools/build_montages.py
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402

ROOT = Path(r".")
DANI = ROOT / "game/assets/di2/dani"
OUT = ROOT / "game/data/montages.json"
SKEL = ROOT / "extracted/json/DeadIsland/Content/DSCore/Art/Characters/Skeletons/MaleStandard/SKEL_MaleStandard.json"
# Slot groups whose montages the 1P graph applies additively (ApplyMeshSpaceAdditive after the Arms slot).
ADDITIVE_GROUPS = ("AdditiveArmsLocomotionGroup", "AdditiveArmsCustomEventGroup", "AdditiveArmsCustomStateGroup")

# AnimNotifyState_ScalePlayRate blueprints (DIShared/Animation/Notifies/NotifyStates): PlayrateDurationStringKey and
# bScaleByNotifyLength (native default true, exe ctor 0x141125c50 writes +0x40 = 1; only AttackSpeed sets false).
SCALE_PLAYRATE = {"BP_AnimNotifyState_ScalePlayRateAnticipation_C": ("Anticipation", True),
                  "BP_AnimNotifyState_ScalePlayRateAttackSpeed_C": ("AttackSpeed", False),
                  "BP_AnimNotifyState_ScalePlayRateDecision_C": ("Decision", True),
                  "BP_AnimNotifyState_ScalePlayRateRepetition_C": ("Repetition", True)}


def clip_names():
    """DI2 sequence -> Godot clip name in the 1P rig (class glbs first, then dani_fp.glb)."""
    out = {}
    for f in sorted((DANI / "classes").glob("*.clips.json")):
        for g, seq in json.loads(f.read_text()).items():
            if isinstance(seq, str):
                out.setdefault(seq.removeprefix("inplace:"), g)
    for g, seq in json.loads((DANI / "clips.json").read_text()).items():
        if isinstance(seq, str):
            out.setdefault(seq.removeprefix("inplace:"), g)
    return out


def montage_names():
    names = set()

    def walk(v):
        if isinstance(v, dict):
            if isinstance(v.get("m"), str):
                names.add(v["m"])
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    for f in (ROOT / "game/data/classes").glob("*.json"):
        walk(json.loads(f.read_text()))
    return sorted(names)


def notify_class(n):
    for k in ("NotifyStateClass", "Notify"):
        v = n.get(k)
        if isinstance(v, dict) and v.get("ObjectName"):
            m = re.match(r"(\w+)'", v["ObjectName"])
            if m:
                return m.group(1)
    return ""


def slot_groups():
    """SKEL_MaleStandard SlotGroups: slot -> group (Montage_Play stops only montages of the same group)."""
    out = {}
    for e in json.loads(SKEL.read_text(encoding="utf-8")):
        if e.get("Type") == "Skeleton":
            for g in e.get("Properties", {}).get("SlotGroups", []):
                for sn in g.get("SlotNames", []):
                    out[sn] = g["GroupName"]
    return out


def main():
    names = clip_names()
    groups = slot_groups()
    out = {}
    missing = set()
    for mn in montage_names():
        m = A.montage(mn)
        if not m:
            continue
        d = A.load(mn)
        raw = next(e for e in d if e["Type"] == "AnimMontage")["Properties"]
        segs = []
        slot = "Arms" if m["tracks"].get("Arms") else next(iter(m["tracks"]), "Arms")
        for seq, start, a0, a1, rate, loops in m["tracks"].get(slot, []):
            g = names.get(seq)
            if g is None:
                missing.add(seq)
            segs.append([g or "", start, a0, a1, rate, loops])
        rate_windows = []
        for n in raw.get("Notifies", []):
            cls = notify_class(n)
            if cls in SCALE_PLAYRATE:
                t = A.link_time(n)
                key, by_len = SCALE_PLAYRATE[cls]
                rate_windows.append([key, round(t, 4), round(t + (n.get("Duration") or 0.0), 4), by_len])
        out[mn] = {"length": m["length"], "blend_in": m["blend_in"], "blend_out": m["blend_out"],
                   "blend_out_trigger": m["blend_out_trigger"], "auto_blend_out": m["auto_blend_out"],
                   "sections": m["sections"], "segments": segs, "rate": rate_windows,
                   "slot": slot, "group": groups.get(slot, "DefaultGroup"),
                   "additive": groups.get(slot, "DefaultGroup") in ADDITIVE_GROUPS,
                   "notifies": m["notifies"]}
    OUT.write_text(json.dumps(out, indent=0))
    print(f"{len(out)} montages -> {OUT}; {len(missing)} sequences without a 1P clip")
    for s in sorted(missing)[:20]:
        print("  missing", s)


if __name__ == "__main__":
    main()
