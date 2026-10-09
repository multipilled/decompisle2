"""Where DI2 cuts a limb: the VisceraProxy boxes of the Walker's limb groups (Viscera_ZombieStandard).

DI2 splits each long limb bone into proxy boxes (UpperArmL1-3, LowerArmL1-3, ThighL1-3, CalfL1-3) with
CutBias BoxCentre, so a cut lands at the centre of the box nearest the hit, not only at a joint. This tool
expresses each box centre as a fraction t along its limb bone (bone origin -> next limb bone), measured in
SKEL_ZombieStandard's reference pose, so it applies to any body on that skeleton.

Input:  extracted/json/.../Viscera_ZombieStandard.json, extracted/rawanim/A_ZMB_Walker_*.json (ref pose)
Output: game/data/cut_points.json   {bone: {"child": next limb bone, "cuts": [{"t", "proxy"}...]}}
"""
import json
from pathlib import Path

import numpy as np

ROOT = Path(r".")
VISCERA = ROOT / "extracted/json/DeadIsland/Content/DIShared/Art/Characters/Internal/Viscera/Male/Viscera_ZombieStandard.json"
RAWANIM = ROOT / "extracted/rawanim"
OUT = ROOT / "game/data/cut_points.json"

LIMB_GROUPS = ("LeftArm", "RightArm", "LeftLeg", "RightLeg")
SEGMENTS = [(f"{a}_{s}", f"{b}_{s}") for s in "lr" for a, b in
            (("upperarm", "lowerarm"), ("lowerarm", "hand"), ("thigh", "calf"), ("calf", "foot"))]


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz])


def quat_rotate(q, v):
    u, w = np.array(q[:3]), q[3]
    t = 2.0 * np.cross(u, v)
    return v + w * t + np.cross(u, t)


def ref_pose():
    """Component-space bone positions (UE cm) of SKEL_ZombieStandard's reference pose."""
    meta = json.loads(next(RAWANIM.glob("A_ZMB_Walker_*.json")).read_text())
    rot, pos, names = [], [], []
    for b in meta["Bones"]:
        t, r, p = np.array(b["T"]), np.array(b["R"]), b["Parent"]
        if p < 0:
            rot.append(r)
            pos.append(t)
        else:
            rot.append(quat_mul(rot[p], r))
            pos.append(pos[p] + quat_rotate(rot[p], t))
        names.append(b["Name"])
    return dict(zip(names, pos))


def main():
    bones = ref_pose()
    exports = json.loads(VISCERA.read_text(encoding="utf-8"))
    groups = {e["Name"]: e.get("Properties", {}).get("Name") for e in exports if e["Type"] == "VisceraGroup"}
    out = {a: {"child": b, "cuts": []} for a, b in SEGMENTS}
    for e in exports:
        p = e.get("Properties", {})
        if e["Type"] != "VisceraProxy" or p.get("CutBias") not in ("ECutBias::BoxCentre", "ECutBias::Limb"):
            continue
        group = next((g for k, g in groups.items() if f":{k}'" in e.get("Outer", {}).get("ObjectName", "")), None)
        if group not in LIMB_GROUPS:
            continue
        t = p["Location"]["Translation"]
        c = np.array([t["X"], t["Y"], t["Z"]])
        best = None
        for a, b in SEGMENTS:
            o, axis = bones[a], bones[b] - bones[a]
            s = float(np.dot(c - o, axis) / np.dot(axis, axis))
            dist = float(np.linalg.norm(c - (o + axis * np.clip(s, 0.0, 1.0))))
            if -0.15 <= s <= 1.15 and (best is None or dist < best[2]):
                best = (a, s, dist)
        if best is None:
            print(f"  skip {p['Name']} ({group}): not on a limb segment")
            continue
        a, s, dist = best
        out[a]["cuts"].append({"t": round(float(np.clip(s, 0.0, 1.0)), 3), "proxy": p["Name"]})
        print(f"  {p['Name']:12s} {group:9s} -> {a:12s} t={s:5.2f}  {dist:4.1f} cm off the bone line")
    for v in out.values():
        v["cuts"].sort(key=lambda c: c["t"])
    OUT.write_text(json.dumps(out, indent=1))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
