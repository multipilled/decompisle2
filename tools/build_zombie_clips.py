"""DI2 zombie sequences the body glbs lack -> skin-only clip glbs, one per body and set (recon/ANIMATION.md 9).

  game/assets/di2/zombie_clips/<body>_<set>.glb         the body's skin (joints + inverse binds, no meshes) and one
                                                        animation per DI2 sequence, named after it, every bone it keys,
                                                        retargeted onto the body's rest pose like tools/merge_anims.py
  game/assets/di2/zombie_clips/<body>_<set>.anims.json  per sequence: frames, rate, length, root_speed and the root
                                                        motion track (merge_anims' format: [x, y, z, yaw] per frame,
                                                        relative to frame 0); the root bone itself is held at frame 0

The body glbs belong to the bodies / combat sessions, so sequences only DI2's montages need (attack lead-ins,
reaction segments...) live here instead. scripts/zombie_anim.gd registers every clip glb of its body as "x:<sequence>"
and tools/build_zombie_montages.py resolves montage segments to those names.

Sources: extracted/rawanim/<seq>.json + .acl (`di2x rawanim`) or, for UE-codec sequences, extracted/anim/**/<seq>.psa
(`di2x anim`), exactly what merge_anims reads.

Additive sequences (AAT_LocalSpaceBase, e.g. the DA_WindUpDef WindUpStartAdditive poses) can't go through the glb:
`--additive` writes <body>_<set>.additive.json instead: per sequence {frames, rate, length, bones: {bone: [[qx, qy, qz,
qw, tx, ty, tz] per frame]}}, the cooked deltas in Godot space (bones whose delta is identity on every frame left out).
UE 4.27 FAnimationRuntime::RetargetBoneTransform for a baked additive: Skeleton mode -> zero translation delta,
AnimationScaled -> translation scaled by the target / source bone length, AnimationRelative / OrientAndScale -> kept.
Applied like FTransform::BlendFromIdentityAndAccumulate (scripts/zombie_anim.gd WindUpLayer).

usage: python tools/build_zombie_clips.py [--additive] <set> <json file {"walker": [seq, ...], "runner": [...], ...}>
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import merge_anims as M  # noqa: E402

ROOT = Path(r".")
OUT = ROOT / "game/assets/di2/zombie_clips"
IMPORT_TEMPLATE = ROOT / "game/assets/di2/zombie_facial/walker_facial.glb.import"


def clip_glb(body, seqs, set_name):
    g, binchunk = M.read_glb(ROOT / f"game/assets/di2/{body}/{body}.glb")
    target = M.rest_pose_ue(g)
    out = {"asset": g["asset"], "scene": g.get("scene", 0), "scenes": g["scenes"], "nodes": [], "skins": [],
           "accessors": [], "bufferViews": [], "buffers": [{"byteLength": 0}], "animations": []}
    ob = bytearray()
    for n in g["nodes"]:
        out["nodes"].append({k: v for k, v in n.items() if k not in ("mesh", "skin")})
    for s in g["skins"]:
        acc = g["accessors"][s["inverseBindMatrices"]]
        bv = g["bufferViews"][acc["bufferView"]]
        raw = binchunk[bv.get("byteOffset", 0) + acc.get("byteOffset", 0):][:acc["count"] * 64]
        s2 = dict(s)
        s2["inverseBindMatrices"] = M.add_accessor(out, ob, np.frombuffer(bytes(raw), dtype=np.float32).reshape(acc["count"], 16), "MAT4")
        out["skins"].append(s2)
    node_of = {n.get("name"): i for i, n in enumerate(g["nodes"])}
    report = {}
    for seq in seqs:
        meta = json.loads((M.RAW / f"{seq}.json").read_text())
        bones, ns, rate = M.load_acl(seq, meta) if (M.RAW / f"{seq}.acl").exists() else M.load_psa(seq, meta)
        bones = M.retarget(bones, meta, target)
        times = np.arange(ns, dtype=np.float32) / rate
        tin = M.add_accessor(out, ob, times, "SCALAR", minmax=True)
        anim = {"name": seq, "channels": [], "samplers": []}
        root_speed, root_track = 0.0, None
        for bone, (t, q) in bones.items():
            if bone not in node_of:
                continue
            tg, qg = M.ue_to_gltf_t(t), M.ue_to_gltf_q(q)
            qg = qg / np.linalg.norm(qg, axis=1, keepdims=True)
            for i in range(1, len(qg)):
                if np.dot(qg[i - 1], qg[i]) < 0:
                    qg[i] = -qg[i]
            if bone == "root":
                # merge_anims.main's root handling: record the motion, hold the root at frame 0.
                dist = np.linalg.norm(tg[-1, [0, 2]] - tg[0, [0, 2]])
                root_speed = float(dist / max(times[-1], 1e-3))
                rel = tg - tg[0]
                fwd_x = 1 - 2 * (qg[:, 1] ** 2 + qg[:, 2] ** 2)
                fwd_z = 2 * (qg[:, 0] * qg[:, 2] - qg[:, 1] * qg[:, 3])
                yaw = np.unwrap(np.arctan2(fwd_z, fwd_x))
                if dist > 0.02 or np.abs(rel).max() > 0.05 or abs(yaw[-1] - yaw[0]) > 0.05:
                    root_track = [[round(float(a), 4), round(float(b), 4), round(float(c), 4), round(float(y - yaw[0]), 4)]
                                  for (a, b, c), y in zip(rel, yaw)]
                tg = np.repeat(tg[:1], len(tg), axis=0)
                qg = np.repeat(qg[:1], len(qg), axis=0)
            for path, arr, typ in (("translation", tg, "VEC3"), ("rotation", qg, "VEC4")):
                o = M.add_accessor(out, ob, arr, typ)
                anim["samplers"].append({"input": tin, "output": o, "interpolation": "LINEAR"})
                anim["channels"].append({"sampler": len(anim["samplers"]) - 1, "target": {"node": node_of[bone], "path": path}})
        out["animations"].append(anim)
        report[seq] = {"frames": ns, "rate": rate, "length": float(times[-1]), "root_speed": round(root_speed, 3),
                       "tracks": len(anim["channels"]) // 2, "root": root_track}
    OUT.mkdir(parents=True, exist_ok=True)
    stem = f"{body}_{set_name}"
    M.write_glb(OUT / f"{stem}.glb", out, ob)
    (OUT / f"{stem}.anims.json").write_text(json.dumps(report, indent=1))
    imp = OUT / f"{stem}.glb.import"
    if not imp.exists():   # same scene import settings as the facial clip glbs (constant tracks kept)
        lines = [ln for ln in IMPORT_TEMPLATE.read_text().splitlines()
                 if not ln.startswith(("uid=", "path=", "dest_files="))]
        lines = [f'source_file="res://assets/di2/zombie_clips/{stem}.glb"' if ln.startswith("source_file=") else ln
                 for ln in lines]
        imp.write_text("\n".join(lines) + "\n")
    M.keep_clip_names(OUT / f"{stem}.glb")   # DI2 "_Loop" sequence names survive the import
    return report


def additive_json(body, seqs, set_name):
    """<body>_<set>.additive.json for AAT_LocalSpaceBase sequences (see the module docstring)."""
    g, _ = M.read_glb(ROOT / f"game/assets/di2/{body}/{body}.glb")
    target = M.rest_pose_ue(g)
    report = {}
    for seq in seqs:
        meta = json.loads((M.RAW / f"{seq}.json").read_text())
        assert meta.get("AdditiveAnimType") == "AAT_LocalSpaceBase", f"{seq}: {meta.get('AdditiveAnimType')}"
        bones, ns, rate = M.load_acl(seq, meta) if (M.RAW / f"{seq}.acl").exists() else M.load_psa(seq, meta)
        modes = meta.get("RetargetModes") or []
        src_pose = meta.get("RetargetPose") or meta["Bones"]
        index = {b["Name"]: i for i, b in enumerate(meta["Bones"])}
        out = {}
        for bone, (t, q) in bones.items():
            if bone not in target:
                continue
            i = index.get(bone, -1)
            mode = modes[i] if 0 <= i < len(modes) else "Animation"
            t = t.astype(np.float64)
            if mode == "Skeleton":
                t = np.zeros_like(t)
            elif mode == "AnimationScaled":
                st = np.array(src_pose[i]["T"], dtype=np.float64)
                if np.linalg.norm(st) > 1e-4:
                    t = t * (np.linalg.norm(target[bone][0]) / np.linalg.norm(st))
            tg, qg = M.ue_to_gltf_t(t), M.ue_to_gltf_q(q.astype(np.float64))
            qg = qg / np.linalg.norm(qg, axis=1, keepdims=True)
            qg = np.where(qg[:, 3:4] < 0, -qg, qg)
            if np.abs(tg).max() < 1e-5 and np.abs(qg[:, :3]).max() < 1e-5:
                continue
            out[bone] = [[round(float(v), 6) for v in (*a, *b)] for a, b in zip(qg, tg)]
        report[seq] = {"frames": ns, "rate": rate, "length": (ns - 1) / rate, "bones": out}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{body}_{set_name}.additive.json").write_text(json.dumps(report))
    return report


def main():
    add = "--additive" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--additive"]
    set_name, path = args[0], args[1]
    for body, seqs in json.loads(Path(path).read_text()).items():
        if add:
            rep = additive_json(body, sorted(set(seqs)), set_name)
            print(f"{body:9} {set_name}: {len(rep)} additive clips -> {OUT / (body + '_' + set_name)}.additive.json")
            for sq, r in rep.items():
                print(f"    {sq:55} {r['frames']:4}f  {len(r['bones']):3} bones")
            continue
        rep = clip_glb(body, sorted(set(seqs)), set_name)
        print(f"{body:9} {set_name}: {len(rep)} clips -> {OUT / (body + '_' + set_name)}.glb")
        for s, r in rep.items():
            print(f"    {s:55} {r['frames']:4}f  {r['tracks']:3} bones  root speed {r['root_speed']:.2f}")


if __name__ == "__main__":
    main()
