"""DI2 held-item classes -> game/data/classes/<class>.json (one per animation class) + an index in combat.json.

Each class file mirrors DI2's resolved AnimSetCollection (see tools/di2_animsets.py): for every slot
(StandardAttack, HeavyAttack, Lunge, Knockbacks, Dodges, Select, Block*, Counter*, Shoot, Reload, ...) the
selection groups in DI2's order with their expressions, and per item the montages by role with what the game
needs from them: the 1P clips (short names as merged into dani/classes/<base>.glb), length, DetectHits window,
Chainable windows and camera-anim trigger. Level sequences (paired counters / heavy finishers / head stomp)
carry the 1P clip and the zombie's side.

usage: python tools/build_class_data.py [--classes-only]
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402

ROOT = Path(r".")
CLASSES = json.loads((ROOT / "extracted/weapon_classes.json").read_text())
OUT_DIR = ROOT / "game/data/classes"
COMBAT = ROOT / "game/data/combat.json"

ROLE = {"StandardAttackMontage": "attack", "AnticipationMontage": "antic", "StandardAttackRecoveryMontage": "recovery",
        "ReboundMontage": "rebound", "DodgeMovement": "movement", "DodgeRecovery": "recovery", "Wielder": "main",
        "Montage": "zombie", "LevelSequence": "sequence"}


def class_id(name):
    return re.sub(r"^DA_(Exp\d_|Horde_)?HeldItem_?ClassData_", "", name).lower()


def short(seq):
    return re.sub(r"^A_1P_(Base_)?", "", seq).lower()


def zombie_short(seq):
    """Walker clip names exactly as tools/select_clips.py writes them."""
    s = re.sub(r"^A_(1P|ZMB)_", "", seq)
    return s.replace("Walker_", "").replace("Base_", "").lower()


def asset_info(name, clipset):
    if not name:
        return None
    if name.startswith("LS_"):
        anims = A.level_sequence_anims(name)
        first = [short(a) for a in anims if "_1P_" in a]
        zmb = [zombie_short(a) for a in anims if a.startswith("A_ZMB_")]
        return {"ls": name, "clips": [c for c in first if c in clipset], "zombie": zmb}
    if name.startswith("A_"):
        return {"clips": [short(name)] if short(name) in clipset else [], "len": None}
    if name.startswith("BS_"):
        samples = [n for t, n in A.refs(A.load(name) or []) if t == "AnimSequence" and "_1P_" in n]
        return {"bs": name, "clips": [short(s) for s in samples if short(s) in clipset]}
    if name.startswith("AM_ZMB") or "_ZMB_" in name:
        m = A.montage(name)
        return {"m": name, "zombie": [zombie_short(s) for s in (m or {}).get("seqs", []) if "ZMB" in s], "len": (m or {}).get("length")}
    m = A.montage(name)
    if not m:
        return {"m": name, "clips": []}
    out = {"m": name, "clips": [short(s) for s in m["seqs"] if "_1P_" in s and short(s) in clipset], "len": m["length"]}
    for k in ("detect", "camera", "camera_params"):
        if m.get(k) is not None:
            out[k] = m[k]
    if m["chain"]:
        out["chain"] = m["chain"]
    # Montage events the game needs: the impact (PlayMontageNotify, e.g. a kick's hit frame), auto-aim guidance
    # and any other gameplay notify, as [name, time, duration].
    ev = [n for n in m["notifies"] if n[0] and not n[0].startswith(("BP_DetectHits", "BP_AnimNotifyState_DetectHits", "BP_Chainable"))]
    if ev:
        out["events"] = ev
    return out


def slot_data(slot, clipset):
    if "asset" in slot:
        return {"groups": [{"name": "Default", "expr": "", "items": [{"main": asset_info(slot["asset"], clipset)}]}]}
    if "inline" in slot:
        return {"groups": [{"name": "Default", "expr": "", "items": [
            {ROLE.get(k, k.lower()): asset_info(v, clipset) for k, v in slot["inline"].items()}]}]}
    groups = []
    for g in A.animset(slot["animset"]):
        items = []
        for it in g["items"]:
            if it.get("asset"):
                items.append({"main": asset_info(it["asset"], clipset)})
            elif it.get("links"):
                items.append({ROLE.get(k, re.sub(r"Montage$", "", k).lower()): asset_info(v, clipset) for k, v in it["links"].items()})
        groups.append({"name": g["name"], "expr": g["expr"], "items": items})
    return {"groups": groups}


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    index = {}
    for base, v in CLASSES.items():
        clip_file = ROOT / f"game/assets/di2/dani/classes/{base.lower()}.clips.json"
        clipset = set(json.loads(clip_file.read_text())) if clip_file.exists() else set()
        for cname in v["classes"]:
            r = A.resolve_class(cname)
            cid = class_id(cname)
            data = {"id": cid, "di2": cname, "chain": r["chain"], "base": base.lower(),
                    "glb": f"res://assets/di2/dani/classes/{base.lower()}.glb",
                    "slots": {k: slot_data(s, clipset) for k, s in sorted(r["slots"].items())}}
            (OUT_DIR / f"{cid}.json").write_text(json.dumps(data, indent=1))
            n_attacks = sum(len(g["items"]) for g in data["slots"].get("StandardAttack", {}).get("groups", []))
            index[cid] = {"file": f"res://data/classes/{cid}.json", "base": base.lower(), "di2": cname}
            print(f"{cid:42} {len(data['slots']):2} slots, {n_attacks:2} attack items")
    if "--classes-only" in sys.argv:
        # Leave combat.json / weapons.json (other sessions' files) alone; Player derives class_id itself.
        print(f"{len(index)} classes (classes only)")
        return
    combat = json.loads(COMBAT.read_text())
    combat["class_index"] = index
    COMBAT.write_text(json.dumps(combat, indent=1))
    # Point every weapon at its class id.
    wpath = ROOT / "game/data/weapons.json"
    weapons = json.loads(wpath.read_text())
    for w in weapons.values():
        if isinstance(w, dict) and w.get("class"):
            w["class_id"] = class_id(w["class"])
    wpath.write_text(json.dumps(weapons, indent=1))
    print(f"{len(index)} classes")


if __name__ == "__main__":
    main()
