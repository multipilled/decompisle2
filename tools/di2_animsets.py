"""DI2 held-item animation data resolver (reads `di2x json` dumps of the user's own install).

A weapon's HeldItemData points at a HeldItemClassData (e.g. DA_HeldItemClassData_Medium2H_Sweeping_Club), whose
Parent chain runs ClassData -> HeldItemAnimData (style) -> HeldItemPoseData (base). Each level carries an
AnimSetCollection (OverrideAnimations / UseAnimations / PoseAnimations) mapping slot keys (StandardAttack,
HeavyAttack, Lunge, Block, Dodge, ...) to AnimSetData assets (groups with selection expressions and items that
link montages) or straight to montages / level sequences. More specific levels override less specific ones.

Library use: resolve_class(name) -> {"chain": [...], "slots": {key: Slot}} ; montage(name) -> notify windows.
CLI: python tools/di2_animsets.py [class...]   prints the resolved slots per class.
"""
import json
import re
import sys
from functools import lru_cache
from pathlib import Path

J = Path(r"extracted\json\DeadIsland\Content")
REF = re.compile(r"(AnimMontage|AnimSequence|AnimComposite|BlendSpace1D|BlendSpace|AimOffsetBlendSpace1D|AimOffsetBlendSpace|PoseAsset|CameraAnim|LevelSequence|AnimSetData|AnimSetCollection|HeldItem\w*Data|PairedActionWithHitReactConfig|AssetLinkage)'([^']+)'")


@lru_cache(maxsize=None)
def index():
    return {p.stem: p for p in J.rglob("*.json")}


@lru_cache(maxsize=None)
def load(name):
    p = index().get(name)
    return json.loads(p.read_text(encoding="utf-8")) if p else None


def leaf(ref):
    """'DA_X:AnimSet_Single_3.PairedActionWithHitReactConfig_0' -> ('DA_X', 'PairedActionWithHitReactConfig_0')."""
    pkg, _, obj = ref.partition(":")
    return pkg, obj.split(".")[-1] if obj else ""


def export(pkg, obj_name):
    for e in load(pkg) or []:
        if e.get("Name") == obj_name:
            return e
    return None


ANY = re.compile(r"(\w+)'([^']+)'")


def anyref(value):
    """First object reference of any class inside a JSON value (inline/instanced objects)."""
    m = ANY.findall(json.dumps(value))
    return m[0][1] if m else None


def refs(value):
    """All (type, name) references inside a JSON value."""
    return REF.findall(json.dumps(value))


# --- Montages -------------------------------------------------------------------------------------------

# DI2's own UAnimMontage constructor (exe 0x1434b3ee0) sets BlendIn and BlendOut to SetBlendTime(0.1) +
# SetBlendOption(HermiteCubic) (0x14348a6d0 / 0x14348a6c0), BlendOutTriggerTime -1 and auto blend-out on; cooked
# montages only store what differs from that, so absent fields mean these values (recon/ANIMATION.md).
MONTAGE_BLEND_DEFAULT = (0.1, "HermiteCubic")


def link_time(el):
    """Absolute montage time of an FAnimLinkableElement (notify start, notify EndLink, section, branching point).
    UE stores LinkValue relative to the linked montage segment: Absolute = montage seconds, Relative = seconds
    after SegmentBeginTime, Proportional = fraction of SegmentLength after SegmentBeginTime. Unlinked elements
    (no LinkedMontage) keep an absolute LinkValue. Checked on every DI2 montage: start + Duration == EndLink for
    all 4,149 notify states, and BranchingPointMarkers.TriggerTime matches the resolved notify times."""
    v = el.get("LinkValue", 0.0) or 0.0
    if not el.get("LinkedMontage") or el.get("SegmentIndex", -1) is None or el.get("SegmentIndex", -1) < 0:
        return v
    method = el.get("CachedLinkMethod") or el.get("LinkMethod") or ""
    begin = el.get("SegmentBeginTime", 0.0) or 0.0
    if method.endswith("Relative"):
        return begin + v
    if method.endswith("Proportional"):
        return begin + v * (el.get("SegmentLength", 0.0) or 0.0)
    return v


def alpha_blend(v):
    """FAlphaBlend property -> [BlendTime, BlendOption] with DI2's montage defaults filled in."""
    v = v or {}
    t = v.get("BlendTime", MONTAGE_BLEND_DEFAULT[0])
    opt = str(v.get("BlendOption", MONTAGE_BLEND_DEFAULT[1])).replace("EAlphaBlendOption::", "")
    return [round(float(t), 4), opt]


def _seg_name(seg):
    r = seg.get("AnimReference") or {}
    on = r.get("ObjectName") or ""
    return on.split("'")[1] if "'" in on else on


@lru_cache(maxsize=None)
def montage(name):
    d = load(name)
    if not d:
        return None
    m = next((e for e in d if e["Type"] == "AnimMontage"), None)
    if not m:
        return None
    p = m["Properties"]
    seqs = list(dict.fromkeys(n for t, n in refs(p.get("SlotAnimTracks", p)) if t == "AnimSequence"))
    out = {"name": name, "length": round(p.get("SequenceLength", 0) or 0, 4), "seqs": seqs, "detect": None,
           "chain": [], "camera": None, "notifies": [],
           "blend_in": alpha_blend(p.get("BlendIn")), "blend_out": alpha_blend(p.get("BlendOut")),
           "blend_out_trigger": round(float(p.get("BlendOutTriggerTime", -1.0)), 4),
           "auto_blend_out": bool(p.get("bEnableAutoBlendOut", True)),
           "sections": [[s.get("SectionName"), round(link_time(s), 4), s.get("NextSectionName")]
                        for s in p.get("CompositeSections", [])],
           "tracks": {}}
    # Slot tracks: per slot [sequence, StartPos, AnimStartTime, AnimEndTime, AnimPlayRate, LoopingCount].
    for tr in p.get("SlotAnimTracks", []):
        out["tracks"][tr.get("SlotName")] = [[_seg_name(s), round(s.get("StartPos", 0.0), 4), round(s.get("AnimStartTime", 0.0), 4),
                                              round(s.get("AnimEndTime", 0.0), 4), s.get("AnimPlayRate", 1.0), s.get("LoopingCount", 1)]
                                             for s in tr.get("AnimTrack", {}).get("AnimSegments", [])]
    for n in p.get("Notifies", []):
        nm, t, dur = n.get("NotifyName") or "", link_time(n), n.get("Duration", 0) or 0
        out["notifies"].append([nm, round(t, 4), round(dur, 4)])
        if "DetectHits" in nm:
            out.setdefault("detect_all", []).append([round(t, 4), round(t + dur, 4)])
            if out["detect"] is None:
                out["detect"] = [round(t, 4), round(t + dur, 4)]
        elif nm == "BP_Chainable":
            out["chain"].append([round(t, 4), round(t + dur, 4)])
        elif nm == "BP_TriggerCameraAnimation":
            out["camera"] = round(t, 4)
            # The notify instance: AttackDirection (ECameraAttackDirections index), Amplitude, PlayRate, Loop.
            ref = anyref(n.get("Notify")) if n.get("Notify") else None
            if ref:
                pkg, obj = leaf(ref)
                e = export(pkg, obj) or {}
                q = e.get("Properties", {})
                dirn = q.get("AttackDirection", "ECameraAttackDirections::NewEnumerator0")
                out["camera_params"] = {"AttackDirection": int(str(dirn).rsplit("NewEnumerator", 1)[-1]) if "NewEnumerator" in str(dirn) else 0,
                                        "Scale": q.get("Amplitude", 1.0), "Rate": q.get("PlayRate", 1.0), "Loop": q.get("Loop", False)}
    return out


def level_sequence_anims(name):
    """Animations a paired level sequence plays (1P, 3P and zombie sides)."""
    return [n for t, n in refs(load(name) or []) if t == "AnimSequence"]


# --- Anim sets --------------------------------------------------------------------------------------------

def animset(name):
    """AnimSetData -> list of groups {name, expr, items: [ {links: {key: asset}} | {asset: name} ]}."""
    d = load(name)
    if not d:
        return []
    main = next((e for e in d if e["Type"] == "AnimSetData"), None)
    groups = []
    for g in (main or {}).get("Properties", {}).get("Groups", []):
        items = []
        for it in g.get("Items", []):
            if it.get("Asset"):
                items.append({"asset": refs(it["Asset"])[0][1] if refs(it["Asset"]) else None, "weight": it.get("Weight", 1.0)})
            elif it.get("InstancedAsset") and anyref(it["InstancedAsset"]):
                pkg, obj = leaf(anyref(it["InstancedAsset"]))
                e = export(pkg, obj) or {}
                links = {l["Key"]: refs(l["Value"])[0][1] for l in e.get("Properties", {}).get("Links", []) if refs(l["Value"])}
                if not links:  # other inline configs: keep every animation reference
                    links = {f"ref{i}": n for i, (t, n) in enumerate(refs(e.get("Properties", {}))) if t in ("AnimMontage", "AnimSequence", "LevelSequence")}
                items.append({"links": links, "weight": it.get("Weight", 1.0)})
        groups.append({"name": g.get("Name"), "expr": (g.get("Expression") or {}).get("Expression", ""), "items": items})
    return groups


def collection(name):
    """AnimSetCollection -> {slot: {"animset": name} | {"asset": name} | {"inline": {...}}}."""
    d = load(name)
    if not d:
        return {}
    main = next((e for e in d if e["Type"] == "AnimSetCollection"), None)
    out = {}
    for s in (main or {}).get("Properties", {}).get("AnimSetData", []):
        v = s["Value"]
        if not any(anyref(v.get(k)) for k in ("AnimSetData", "AnimAsset", "InstancedAnimAsset", "AnimSet") if v.get(k)):
            continue
        if v.get("AnimSetData") and refs(v["AnimSetData"]):
            out[s["Key"]] = {"animset": refs(v["AnimSetData"])[0][1]}
        elif v.get("AnimAsset") and refs(v["AnimAsset"]):
            out[s["Key"]] = {"asset": refs(v["AnimAsset"])[0][1]}
        elif v.get("InstancedAnimAsset") and anyref(v["InstancedAnimAsset"]):
            pkg, obj = leaf(anyref(v["InstancedAnimAsset"]))
            e = export(pkg, obj) or {}
            out[s["Key"]] = {"inline": {k: refs(val)[0][1] for k, val in e.get("Properties", {}).items() if refs(val)}}
        elif v.get("AnimSet") and anyref(v["AnimSet"]):
            pkg, obj = leaf(anyref(v["AnimSet"]))
            e = export(pkg, obj) or {}
            r = refs(e.get("Properties", {}))
            if r:
                out[s["Key"]] = {"animset" if r[0][0] == "AnimSetData" else "asset": r[0][1]}
    return out


def resolve_class(class_name):
    """Walk ClassData -> AnimData -> PoseData; more specific collections win."""
    chain, slots = [], {}
    name = class_name
    while name:
        d = load(name)
        if not d:
            break
        chain.append(name)
        p = d[0].get("Properties", {})
        for key in ("OverrideAnimations", "UseAnimations", "PoseAnimations", "Animations"):
            if p.get(key):
                for slot, v in collection(refs(p[key])[0][1]).items():
                    slots.setdefault(slot, v)
        parent = refs(p.get("Parent")) if p.get("Parent") else []
        name = parent[0][1] if parent else None
    return {"chain": chain, "slots": slots}


def slot_montages(slot):
    """Every montage / level-sequence name a slot can play."""
    if "asset" in slot:
        return [slot["asset"]]
    if "inline" in slot:
        return list(slot["inline"].values())
    out = []
    for g in animset(slot["animset"]):
        for it in g["items"]:
            out += [it["asset"]] if it.get("asset") else list(it.get("links", {}).values())
    return [n for n in dict.fromkeys(out) if n]


def sequences_for(class_name):
    """All AnimSequences the class can play (montage segments + level sequence 1P tracks)."""
    seqs = []
    for slot in resolve_class(class_name)["slots"].values():
        for a in slot_montages(slot):
            if a.startswith("LS_"):
                seqs += [s for s in level_sequence_anims(a) if "_1P_" in s]
            elif a.startswith("A_"):
                seqs.append(a)
            else:
                m = montage(a)
                if m:
                    seqs += m["seqs"]
    return [s for s in dict.fromkeys(seqs) if "_1P_" in s or s.startswith("A_1P")]


if __name__ == "__main__":
    names = sys.argv[1:] or sorted(n for n in index() if n.startswith("DA_HeldItemClassData_"))
    for n in names:
        r = resolve_class(n)
        seqs = sequences_for(n)
        print(f"{n}: chain {' > '.join(r['chain'][1:])}; {len(r['slots'])} slots, {len(seqs)} 1P sequences")
        if len(names) == 1:
            for k, v in sorted(r["slots"].items()):
                print(f"   {k:34} {len(slot_montages(v)):3} assets  e.g. {slot_montages(v)[:2]}")
