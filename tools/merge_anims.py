"""Merge DI2 animation clips into a CUE4Parse-exported skeletal glb as glTF animations.

Sources per clip (from `di2x rawanim`): <name>.json (track map + USkeleton ref pose) plus either
<name>.acl (ACL 1.3, decoded by tools/acl13dec) or a CUE4Parse .psa export.

Coordinate conversion matches CUE4Parse's glTF writer:
  translation = (x, z, y) * 0.01      rotation = (x, z, y, -w)
PSA keys are mirrored by the ActorX writer (Y negated, root W negated) and get un-mirrored first.

Retargeting: when the clip json carries the skeleton's per-bone RetargetModes (newer `di2x rawanim`), the
keys are retargeted like UE does at runtime, from the pose the clip was authored on (its RetargetSource
pose, else the USkeleton ref pose) onto the glb's own rest pose. That is what lets one body play clips
authored for another, e.g. the Thug (authored on SK_ThugA) playing the shared Base hit and crawl clips.

usage: merge_anims.py <in.glb> <out.glb> <clips.json>
  clips.json: {"godot_name": "DI2_SequenceName", ...}   (prefix a name with "inplace:" to strip pelvis drift)
"""
import json
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np

RAW = Path(r"extracted\rawanim")
PSA_ROOT = Path(r"extracted\anim")
ACL13DEC = Path(r"tools\acl13dec\acl13dec.exe")


def ue_to_gltf_t(t):
    return np.stack([t[..., 0], t[..., 2], t[..., 1]], -1) * 0.01


def ue_to_gltf_q(q):
    return np.stack([q[..., 0], q[..., 2], q[..., 1], -q[..., 3]], -1)


def read_glb(path):
    b = Path(path).read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    g = json.loads(b[20:20 + jl])
    bl = struct.unpack_from("<I", b, 20 + jl)[0]
    binchunk = bytearray(b[28 + jl:28 + jl + bl])
    return g, binchunk


def write_glb(path, g, binchunk):
    while len(binchunk) % 4:
        binchunk += b"\0"
    g["buffers"][0]["byteLength"] = len(binchunk)
    js = json.dumps(g, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(binchunk)
    out = struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(binchunk), 0x004E4942) + bytes(binchunk)
    Path(path).write_bytes(out)


def add_accessor(g, binchunk, arr, typ, minmax=False):
    while len(binchunk) % 4:
        binchunk += b"\0"
    data = np.ascontiguousarray(arr, dtype=np.float32)
    off = len(binchunk)
    binchunk += data.tobytes()
    g["bufferViews"].append({"buffer": 0, "byteOffset": off, "byteLength": data.nbytes})
    acc = {"bufferView": len(g["bufferViews"]) - 1, "componentType": 5126, "count": int(data.shape[0]), "type": typ}
    if minmax:
        acc["min"] = [float(data.min())]
        acc["max"] = [float(data.max())]
    g["accessors"].append(acc)
    return len(g["accessors"]) - 1


def load_acl(name, meta):
    acl, out = RAW / f"{name}.acl", RAW / f"{name}.bin"
    if not out.exists():
        subprocess.run([str(ACL13DEC), str(acl), str(out)], check=True, capture_output=True)
    b = out.read_bytes()
    nb, ns, rate, _ = struct.unpack_from("<IIfI", b, 0)
    data = np.frombuffer(b, dtype=np.float32, offset=16).reshape(ns, nb, 10)
    tracks = meta["Tracks"]
    assert len(tracks) == nb, f"{name}: {len(tracks)} track map entries vs {nb} ACL tracks"
    bones = {}
    for ti, bone_index in enumerate(tracks):
        bones[meta["Bones"][bone_index]["Name"]] = (data[:, ti, 4:7].copy(), data[:, ti, 0:4].copy())
    return bones, ns, rate


def load_psa(name, meta):
    psa = next(PSA_ROOT.rglob(f"{name}.psa"))
    b = psa.read_bytes()
    pos, chunks = 0, {}
    while pos < len(b):
        cid = b[pos:pos + 20].split(b"\0")[0].decode()
        _, size, count = struct.unpack_from("<iii", b, pos + 20)
        chunks[cid] = (pos + 32, size, count)
        pos += 32 + size * count
    off, size, count = chunks["BONENAMES"]
    names = [b[off + i * size:off + i * size + 64].split(b"\0")[0].decode() for i in range(count)]
    off, _, _ = chunks["ANIMINFO"]
    nb, _, _, _, _, track_time, rate = struct.unpack_from("<iiiifff", b, off + 128)
    ns = int(round(track_time))
    off, size, count = chunks["ANIMKEYS"]
    keys = np.frombuffer(b, dtype=np.float32, count=count * 8, offset=off).reshape(ns, nb, 8).copy()
    t, q = keys[..., 0:3], keys[..., 3:7]
    t[..., 1] *= -1
    q[..., 1] *= -1
    q[:, 0, 3] *= -1
    # The ActorX AnimRate is NumFrames / SequenceLength, not the key rate: UE 4.27 places key k at
    # UAnimSequenceBase::GetTimeAtFrame(k) = k * SequenceLength / (NumFrames - 1), so the last key lands on
    # SequenceLength. Keying at AnimRate ended every PSA clip at (n - 1) / n of it (e.g. the 7-key, 0.2 s
    # A_ZMB_Base_Hit_Launch_* at 0.171 s). SequenceLength / NumFrames from the sequence json (`di2x rawanim`).
    seq_len = float(meta.get("SequenceLength") or 0.0)
    if ns > 1 and seq_len > 0.0:
        rate = (ns - 1) / seq_len
    return {names[i]: (t[:, i], q[:, i]) for i in range(nb)}, ns, rate


def qmul(a, b):
    """Hamilton product of (x, y, z, w) quaternions (a applied after b, as UE's FQuat a * b)."""
    ax, ay, az, aw = np.moveaxis(a, -1, 0)
    bx, by, bz, bw = np.moveaxis(b, -1, 0)
    return np.stack([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz], -1)


def qinv(q):
    return q * np.array([-1, -1, -1, 1], dtype=q.dtype)


def rest_pose_ue(g):
    """glb node rest transforms (the mesh's ref pose) back in UE space: name -> (t, q)."""
    pose = {}
    for n in g["nodes"]:
        t = np.array(n.get("translation", [0, 0, 0]), dtype=np.float64)
        q = np.array(n.get("rotation", [0, 0, 0, 1]), dtype=np.float64)
        pose[n.get("name")] = (np.array([t[0], t[2], t[1]]) * 100.0, np.array([q[0], q[2], q[1], -q[3]]))
    return pose


def retarget(bones, meta, target):
    """UE's FAnimationRuntime::RetargetBoneTransform, from the clip's source pose onto `target`."""
    modes = meta.get("RetargetModes")
    if not modes:
        return bones
    src_pose = meta.get("RetargetPose") or meta["Bones"]
    index = {b["Name"]: i for i, b in enumerate(meta["Bones"])}
    out = {}
    for name, (t, q) in bones.items():
        i = index.get(name)
        if i is None or name not in target or i >= len(modes):
            out[name] = (t, q)
            continue
        st, sq = np.array(src_pose[i]["T"], dtype=np.float64), np.array(src_pose[i]["R"], dtype=np.float64)
        tt, tq = target[name]
        t, q = t.astype(np.float64), q.astype(np.float64)
        mode = modes[i]
        if mode == "Skeleton":
            t = np.repeat(tt[None], len(t), 0)
        elif mode == "AnimationScaled":
            if np.linalg.norm(st) > 1e-4:
                t = t * (np.linalg.norm(tt) / np.linalg.norm(st))
        elif mode == "AnimationRelative":
            q = qmul(qmul(q, qinv(sq)[None]), tq[None])
            t = t + (tt - st)
        elif mode == "OrientAndScale":
            ls, lt = np.linalg.norm(st), np.linalg.norm(tt)
            if ls > 1e-4 and lt > 1e-4 and not np.allclose(st, tt):
                a, b = st / ls, tt / lt
                axis, w = np.cross(a, b), 1.0 + float(np.dot(a, b))
                rot = np.append(axis, w)
                rot /= np.linalg.norm(rot)
                v = np.concatenate([t, np.zeros((len(t), 1))], 1)
                t = qmul(qmul(np.repeat(rot[None], len(t), 0), v), qinv(rot)[None])[:, :3] * (lt / ls)
        out[name] = (t.astype(np.float32), q.astype(np.float32))
    return out


def concat(parts):
    """Joins clip phases (e.g. Antic + Attack + AttackDec + Recovery) back to back.
    Bones animated in only some phases hold their last/first value elsewhere."""
    if len(parts) == 1:
        return parts[0]
    rate = parts[0][2]
    names = set().union(*(p[0].keys() for p in parts))
    bones = {}
    for name in names:
        ts, qs = [], []
        for b, ns, _ in parts:
            if name in b:
                t, q = b[name]
            else:
                ref = next(p[0][name] for p in parts if name in p[0])
                t, q = np.repeat(ref[0][:1], ns, 0), np.repeat(ref[1][:1], ns, 0)
            ts.append(t)
            qs.append(q)
        bones[name] = (np.concatenate(ts), np.concatenate(qs))
    return bones, sum(p[1] for p in parts), rate


def keep_clip_names(glb):
    """Sets nodes/use_name_suffixes=false in <glb>.import (written minimal if missing; Godot fills the defaults).
    Godot's scene importer otherwise renames clips ending in _loop / -loop / _cycle (after trailing digits) to the bare
    name and sets LOOP_LINEAR, so DI2 names such as medium1h_throw_loop, scream_loop or paired_counter_loop lose their
    suffix and collide with the non-loop clip (medium1h_throw). Checked with Godot 4.7.2 --import on a test glb:
    default import gives bar_loop -> bar, baz-Loop -> baz; use_name_suffixes=false keeps every name. Loop modes come
    from the scripts (DI2's graphs decide looping, not the name)."""
    imp = Path(f"{glb}.import")
    if not imp.exists():
        imp.write_text('[remap]\n\nimporter="scene"\nimporter_version=1\n\n[params]\n\nnodes/use_name_suffixes=false\n')
        return
    lines = imp.read_text().splitlines()
    if "nodes/use_name_suffixes=false" in lines:
        return
    lines = [ln for ln in lines if not ln.startswith("nodes/use_name_suffixes=")]
    lines.insert(lines.index("[params]") + 1, "nodes/use_name_suffixes=false")
    imp.write_text("\n".join(lines) + "\n")


def main(src, dst, clips_path):
    g, binchunk = read_glb(src)
    node_of = {n.get("name"): i for i, n in enumerate(g["nodes"])}
    target = rest_pose_ue(g)
    g.setdefault("animations", [])
    report = {}
    for gname, seq in json.loads(Path(clips_path).read_text()).items():
        inplace = gname.startswith("inplace:")
        gname = gname.removeprefix("inplace:")
        seqs = seq if isinstance(seq, list) else [seq]
        parts = []
        try:
            for s_name in seqs:
                meta = json.loads((RAW / f"{s_name}.json").read_text())
                bones, ns, rate = load_acl(s_name, meta) if (RAW / f"{s_name}.acl").exists() else load_psa(s_name, meta)
                parts.append((retarget(bones, meta, target), ns, rate))
        except (StopIteration, FileNotFoundError, AssertionError, subprocess.CalledProcessError) as e:
            print(f"SKIP {gname}: {type(e).__name__} {e}")
            continue
        bones, ns, rate = concat(parts)
        segments = [{"sequence": s_name, "start": round(sum(p[1] for p in parts[:i]) / rate, 4), "end": round(sum(p[1] for p in parts[:i + 1]) / rate, 4)} for i, s_name in enumerate(seqs)]
        seq = "+".join(seqs)
        times = np.arange(ns, dtype=np.float32) / rate
        tin = add_accessor(g, binchunk, times, "SCALAR", minmax=True)
        anim = {"name": gname, "channels": [], "samplers": []}
        root_speed = 0.0
        root_track = None
        for bone, (t, q) in bones.items():
            if bone not in node_of:
                continue
            tg, qg = ue_to_gltf_t(t), ue_to_gltf_q(q)
            qg /= np.linalg.norm(qg, axis=1, keepdims=True)
            for i in range(1, len(qg)):  # keep consecutive quats in one hemisphere for LINEAR
                if np.dot(qg[i - 1], qg[i]) < 0:
                    qg[i] = -qg[i]
            if bone == "root":
                # Root motion: measure it, then hold the root still (the host moves the character).
                dist = np.linalg.norm(tg[-1, [0, 2]] - tg[0, [0, 2]])
                root_speed = float(dist / max(times[-1], 1e-3))
                # Keep the root-motion track (skeleton space, relative to frame 0) so hosts can move the
                # character the way DI2 does for knockdowns, stumbles, lunges and dodges.
                rel = tg - tg[0]
                fwd_x = 1 - 2 * (qg[:, 1] ** 2 + qg[:, 2] ** 2)
                fwd_z = 2 * (qg[:, 0] * qg[:, 2] - qg[:, 1] * qg[:, 3])
                yaw = np.unwrap(np.arctan2(fwd_z, fwd_x))
                if dist > 0.02 or np.abs(rel).max() > 0.05 or abs(yaw[-1] - yaw[0]) > 0.05:
                    root_track = [[round(float(a), 4), round(float(b), 4), round(float(c), 4), round(float(y - yaw[0]), 4)] for (a, b, c), y in zip(rel, yaw)]
                tg = np.repeat(tg[:1], len(tg), axis=0)
                qg = np.repeat(qg[:1], len(qg), axis=0)
            if bone == "pelvis" and inplace:
                drift = tg[-1] - tg[0]
                drift[1] = 0
                tg = tg - np.outer(times / max(times[-1], 1e-3), drift)
            for path, arr, typ in (("translation", tg, "VEC3"), ("rotation", qg, "VEC4")):
                out = add_accessor(g, binchunk, arr, typ)
                anim["samplers"].append({"input": tin, "output": out, "interpolation": "LINEAR"})
                anim["channels"].append({"sampler": len(anim["samplers"]) - 1, "target": {"node": node_of[bone], "path": path}})
        g["animations"].append(anim)
        report[gname] = {"sequence": seq, "frames": ns, "rate": rate, "length": float(times[-1]), "root_speed": round(root_speed, 3), "tracks": len(anim["channels"]) // 2, "segments": segments, "root": root_track}
        print(f"{gname:22} <- {seq:50} {ns:4}f @{rate:.0f}Hz  root speed {root_speed:.2f} m/s")
    write_glb(dst, g, binchunk)
    keep_clip_names(dst)
    Path(dst).with_suffix(".anims.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:4])
