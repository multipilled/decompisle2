"""Fixtures for rust/gore-core/src/dismember.rs: dismember_ref.py outputs on the exported body data
(game/assets/di2/<body>/<body>.dismember.json + the body glbs) -> tools/re_dismember/fixtures/dismember_fixtures.json.

Python works in UE space (cm, row vectors) exactly as dismember_ref.py; inputs given in glTF (metres) are converted
with the exporter's conversion first, so the Rust glTF-space API and its UE-space internals can both be checked.
Floats are written with 17 significant digits (glb data: 9, i.e. the exact f32 values, which Python then uses).
Cases within float-rounding distance of a discontinuity (plane d ~ 0, safe-region box face, radial |y| ~ 1) are
skipped so f32 (Rust per-vertex code) and f64 (Python) agree on every discrete outcome.

Rerun after export_dismember_data.py:  python make_fixtures.py"""
import json
import math
import os
import random
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "deform"))
import dismember_ref as R                                   # noqa: E402
from glb import Glb                                         # noqa: E402
from export_dismember_data import load_skel, ASSETS        # noqa: E402

OUT = os.path.join(HERE, "fixtures", "dismember_fixtures.json")
SWAP = (0, 2, 1)
C_ROWS = [[100.0, 0, 0, 0], [0, 0, 100.0, 0], [0, 100.0, 0, 0], [0, 0, 0, 1.0]]   # p_gl (m) -> p_ue (cm)


def r9(x):
    return float(f"{float(x):.9g}")


def gl_dir(v):
    return [v[0], v[2], v[1]]


def gl_pos(p):
    return [p[0] * 0.01, p[2] * 0.01, p[1] * 0.01]


def ue_pos(p):
    return [p[0] * 100.0, p[2] * 100.0, p[1] * 100.0]


def cols16_to_ue_rows(c):
    """glTF column-major 16 floats (column-vector math form) -> UE rows (cm)."""
    g = [[c[col * 4 + row] for col in range(4)] for row in range(4)]          # g[row][col]
    rows = [[0.0] * 4 for _ in range(4)]
    for i in range(3):
        col = [g[0][SWAP[i]], g[1][SWAP[i]], g[2][SWAP[i]]]
        rows[i] = [col[0], col[2], col[1], 0.0]
    rows[3] = [g[0][3] * 100.0, g[2][3] * 100.0, g[1][3] * 100.0, 1.0]
    return rows


def ue_rows_to_cols16(m):
    g = [[0.0] * 4 for _ in range(4)]
    for b in range(3):
        d = gl_dir(m[SWAP[b]][:3])
        for a in range(3):
            g[a][b] = d[a]
    t = gl_pos(m[3][:3])
    for a in range(3):
        g[a][3] = t[a]
    g[3][3] = 1.0
    return [g[row][col] for col in range(4) for row in range(4)]


def flat(m):
    return [v for row in m for v in row]


def frame_to_gl(frame):
    """UE frame rows (3 directions, origin) -> glTF rows [x, y, z, origin] (lists of 3)."""
    return [gl_dir(frame[0][:3]), gl_dir(frame[1][:3]), gl_dir(frame[2][:3]), gl_pos(frame[3][:3])]


def frame_from_gl(rows):
    return [gl_dir(rows[0]) + [0.0], gl_dir(rows[1]) + [0.0], gl_dir(rows[2]) + [0.0], ue_pos(rows[3]) + [1.0]]


def load_body(body):
    d = json.load(open(os.path.join(ASSETS, body, f"{body}.dismember.json"), encoding="utf-8"))
    ref = [cols16_to_ue_rows(c) for c in d["ref_pose"]]
    topo = list(zip(d["bones"]["depth"], d["bones"]["branch"]))
    socks = {}
    for s in d["sockets"]:
        socks[s["name"]] = {"bone": s["bone"], "kind": s["kind"], "index": s["index"],
                            "loc": ue_pos(s["loc"]),
                            "quat": (s["quat"][0], s["quat"][2], s["quat"][1], -s["quat"][3]),
                            "scale": (s["scale"][0] * 100.0, s["scale"][2] * 100.0, s["scale"][1] * 100.0),
                            "branch_mask": s["branch_mask"]}
    return d, ref, topo, socks


def region(d, socks, bone, kind):
    return R.region_sockets(socks, d["bones"]["names"][bone], kind)


def ideal_frame(ref, along_cm):
    """selftest hit: decal Y (-R.Z) along the bone X axis, at `along_cm` along the bone."""
    mid = R.xform_pos((along_cm, 0, 0), ref)
    bx = R.unit_axis(ref, 1)
    yaw = math.degrees(math.atan2(bx[1], bx[0]))
    pitch = math.degrees(math.asin(max(-1, min(1, bx[2])))) - 90.0
    return R.decal_frame_from_rotator(mid, pitch, yaw, 0.0)


def random_frame(rng, ref, along_cm):
    mid = R.xform_pos((along_cm, rng.uniform(-3, 3), rng.uniform(-3, 3)), ref)
    return R.decal_frame_from_rotator(mid, rng.uniform(-90, 90), rng.uniform(-180, 180), rng.uniform(-180, 180))


def random_rigid(rng):
    q = R.quat_from_rotator(rng.uniform(-90, 90), rng.uniform(-180, 180), rng.uniform(-180, 180))
    return R.transform_matrix(q, (rng.uniform(-300, 300), rng.uniform(-300, 300), rng.uniform(-50, 50)))


def placement_record(p):
    dm_gl = R.mmul(C_ROWS, p["decal_matrix"])
    sr_gl = R.mmul(C_ROWS, p["safe_region"])
    return {"ue": {"frame": flat(p["frame"]), "decal_matrix": flat(p["decal_matrix"]),
                   "bone_matrix": flat(p["bone_matrix"]), "world_to_ref": flat(p["world_to_ref"]),
                   "safe_region": flat(p["safe_region"]), "region_branch_mask": p["region_branch_mask"],
                   "score": p["score"], "t": p["t"], "corrected": p["corrected"]},
            "gl": {"origin": gl_pos(p["frame"][3][:3]), "x": gl_dir(p["frame"][0][:3]),
                   "normal": gl_dir(p["frame"][1][:3]), "z": gl_dir(p["frame"][2][:3]),
                   "decal_matrix": flat(dm_gl), "safe_region": flat(sr_gl)}}


# ---------------------------------------------------------------------------------------------------------------
def fx_math(rng):
    out = {"quat_from_rotator": [], "transform_matrix": [], "inverse": [], "safe_normal": [], "f16": []}
    for _ in range(8):
        r = [rng.uniform(-360, 360) for _ in range(3)]
        out["quat_from_rotator"].append({"rot": r, "quat": list(R.quat_from_rotator(*r))})
    for _ in range(4):
        q = R.quat_from_rotator(*[rng.uniform(-180, 180) for _ in range(3)])
        t = [rng.uniform(-100, 100) for _ in range(3)]
        s = [rng.uniform(0.2, 30) for _ in range(3)]
        out["transform_matrix"].append({"quat": list(q), "t": t, "s": s, "m": flat(R.transform_matrix(q, t, s))})
    mats = [R.mmul(R.transform_matrix(R.quat_from_rotator(*[rng.uniform(-180, 180) for _ in range(3)]),
                                      [rng.uniform(-100, 100) for _ in range(3)],
                                      [rng.uniform(0.01, 40) for _ in range(3)]),
                   [[rng.uniform(-2, 2) for _ in range(3)] + [0.0] for _ in range(3)] + [[1.0, -2.0, 3.0, 1.0]])
            for _ in range(4)]
    mats.append([[1e-9, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [5.0, 6.0, 7.0, 1.0]])     # rows 0..2 ~ 0 -> identity
    mats.append([[1, 2, 3, 0], [2, 4, 6, 0], [0, 0, 1, 0], [0, 0, 0, 1.0]])                 # singular -> identity
    for m in mats:
        out["inverse"].append({"m": flat(m), "inv": flat(R.inverse(m))})
    for v in ([1.0, 0, 0], [0.6, 0.8, 0.0], [3, -4, 12], [1e-5, 0, 0], [0, 0, 0], [0.1, 0.2, -0.3]):
        out["safe_normal"].append({"v": v, "n": R.safe_normal(v)})
    for v in (0.0, 1.0, 0.1, 0.33333334, -0.75, 0.999, 2.5e-5, 1e-8, 65504.0, 0.50024414):
        out["f16"].append({"x": v, "f16": R.f16(v)})
    return out


def fx_topology():
    names, parents, _ = load_skel()
    t = R.bone_topology(names, parents)
    return {"names": names, "parents": parents, "depth": [x["depth"] for x in t], "branch": [x["branch"] for x in t],
            "flag": [x["flag"] for x in t], "break_bone": [x["break_bone"] for x in t]}


def fx_candidates(rng, d, ref, socks):
    """evaluate_candidate / safe_region_matrix / decal_frame_from_rotator on every walker region socket."""
    cands, srm, rot = [], [], []
    for name in sorted(socks):
        s = socks[name]
        rb = ref[s["bone"]]
        frames = [ideal_frame(rb, 10.0), random_frame(rng, rb, rng.uniform(-10, 30))]
        # decal Y along the socket's Y axis in ref space: n.x == 0 -> the 0.05 nudge path
        u = R.mmul(R.transform_matrix(s["quat"], s["loc"]), rb)
        frames.append([u[2][:3] + [0.0], u[1][:3] + [0.0], u[0][:3] + [0.0], R.xform_pos((2.0, 1.0, 0.5), u) + [1.0]])
        for f in frames:
            c = R.evaluate_candidate(f, rb, s)
            cands.append({"socket": name, "frame_ref": flat(f), "ref_bone": flat(rb),
                          "quat": list(s["quat"]), "loc": list(s["loc"]), "scale": list(s["scale"]),
                          "branch_mask": s["branch_mask"],
                          "out": {"frame": flat(c["frame"]), "safe_region": flat(c["safe_region"]),
                                  "branch_mask": c["branch_mask"], "score": c["score"], "t": c["t"],
                                  "corrected": c["corrected"]}})
        ws = R.mmul(R.transform_matrix(s["quat"], s["loc"], s["scale"]), rb)
        for cv in (False, True):
            srm.append({"m": flat(ws), "use_cvars": cv, "out": flat(R.safe_region_matrix(ws, cv))})
    for _ in range(6):
        loc = [rng.uniform(-100, 100) for _ in range(3)]
        p, y, r = rng.uniform(-90, 90), rng.uniform(-180, 180), rng.uniform(-180, 180)
        rot.append({"loc": loc, "rot": [p, y, r], "frame": flat(R.decal_frame_from_rotator(loc, p, y, r))})
    return cands, srm, rot


def fx_place(rng, body, d, ref, socks):
    out = []
    names = d["bones"]["names"]
    region_bones = sorted({(s["bone"], s["kind"]) for s in socks.values()})
    for bone, kind in region_bones:
        rb = ref[bone]
        sk = R.region_sockets(socks, names[bone], kind)
        along = 12.0 if names[bone].startswith(("upperarm", "lowerarm", "thigh", "calf")) else 0.0
        hits = [("ideal", ideal_frame(rb, along), None), ("random", random_frame(rng, rb, along), None)]
        w = random_rigid(rng)
        f = random_frame(rng, rb, along)
        hits.append(("posed", R.mmul(f, w), R.mmul(rb, w)))
        for tag, frame, now in hits:
            rec ={"body": body, "bone": bone, "bone_name": names[bone], "kind": kind, "hit": tag,
                   "frame_gl": frame_to_gl(frame), "bone_now_gl": ue_rows_to_cols16(now) if now is not None else None}
            # the Rust API takes the frame in glTF: Python recomputes from the round-tripped frame for exact parity
            frame_rt = frame_from_gl(rec["frame_gl"])
            now_rt = cols16_to_ue_rows(rec["bone_now_gl"]) if now is not None else rb
            p = R.place_dismember(frame_rt, now_rt, rb, sk, reference_pose=now is None)
            rec["expected"] = placement_record(p)
            rec["target"] = target_for(d, bone, kind, p)
            out.append(rec)
    return out


def target_for(d, bone, kind, p):
    b = d["bones"]
    return [bone, b["depth"][bone], b["branch"][bone] | p["region_branch_mask"],
            b["break_bone"][bone] if kind == "break" else 0]


# ---------------------------------------------------------------------------------------------------------------
_glb_cache = {}


def section_data(body):
    if body in _glb_cache:
        return _glb_cache[body]
    g = Glb(os.path.join(ASSETS, body, f"{body}.glb"))
    out = []
    for mi, pi, mat, prim in g.primitives():
        a = prim["attributes"]
        pos = [[r9(v) for v in row] for row in g.accessor(a["POSITION"]).astype(np.float64)]
        jt = g.accessor(a["JOINTS_0"]).astype(np.int64).tolist()
        wt = [[r9(v) for v in row] for row in g.accessor(a["WEIGHTS_0"]).astype(np.float64)]
        idx = g.accessor(prim["indices"]).reshape(-1).astype(np.int64).tolist()
        out.append((pos, jt, wt, idx))
    _glb_cache[body] = out
    return out


def plane_d(p, dm):
    return R._plane_d(p, dm)


def sr_margin(p, sr):
    q = R.xform_pos(p, sr)
    return min(abs(abs(v) - 1.0) for v in q)


def fx_classify(rng, body, d, ref, topo, socks, scen):
    """scen: (bone_name, kind, hit-kind, seed)."""
    names = d["bones"]["names"]
    secs = section_data(body)
    out = []
    for bone_name, along, randomise in scen:
        bone = names.index(bone_name)
        rb = ref[bone]
        frame = random_frame(rng, rb, along) if randomise else ideal_frame(rb, along)
        frame_gl = frame_to_gl(frame)
        frame = frame_from_gl(frame_gl)
        p = R.place_dismember(frame, rb, rb, R.region_sockets(socks, bone_name, "safe"), reference_pose=True)
        target = target_for(d, bone, "safe", p)
        dm, sr = p["decal_matrix"], p["safe_region"]
        buckets = {0: [], 1: [], 2: [], 3: []}
        binary_tris = []
        for si, sec in enumerate(d["sections"]):
            if not sec["dismember"]:
                continue
            pos, jt, wt, idx = secs[si]
            binary = sec["binary_dismember"]
            pue = [ue_pos(v) for v in pos]
            dist = [plane_d(v, dm) for v in pue]
            for t in range(len(idx) // 3):
                i3 = idx[3 * t: 3 * t + 3]
                if any(abs(dist[i]) < 0.01 for i in i3):
                    continue
                if target[2] != 0 and not binary and any(sr_margin(pue[i], sr) < 1e-4 for i in i3):
                    continue
                verts = [(pue[i], jt[i], wt[i]) for i in i3]
                code = R.classify_code(verts, dm, sr, target, topo, binary)
                rec = {"section": si, "binary": binary, "pos_gl": [pos[i] for i in i3],
                       "bones": [jt[i] for i in i3], "weights": [wt[i] for i in i3], "code": code}
                near = min(abs(x) for x in (dist[i] for i in i3)) < 25.0
                (binary_tris if binary else buckets[code]).append((near, rec))
        tris = []
        for code, lst in list(buckets.items()) + [("binary", binary_tris)]:
            rng.shuffle(lst)
            lst.sort(key=lambda x: not x[0])       # near the cut first
            tris += [r for _, r in lst[:45 if code != "binary" else 30]]
        out.append({"body": body, "bone": bone, "bone_name": bone_name, "kind": "safe", "frame_gl": frame_gl,
                    "target": target, "decal_matrix": flat(dm), "safe_region": flat(sr),
                    "counts": {str(k): len(v) for k, v in buckets.items()} | {"binary": len(binary_tris)},
                    "triangles": tris})
    return out


def fx_break(rng, body, d, ref, topo, socks, scen):
    names = d["bones"]["names"]
    secs = section_data(body)
    out = []
    for bone_name, along in scen:
        bone = names.index(bone_name)
        rb = ref[bone]
        frame_gl = frame_to_gl(random_frame(rng, rb, along))
        frame = frame_from_gl(frame_gl)
        p = R.place_dismember(frame, rb, rb, R.region_sockets(socks, bone_name, "break"), reference_pose=True)
        target = target_for(d, bone, "break", p)
        dm = p["decal_matrix"]
        changed, same = [], []
        for si, sec in enumerate(d["sections"]):
            if not (sec["dismember"] or sec["skeleton_viscera"]) or target[3] not in sec["bones"]:
                continue
            pos, jt, wt, idx = secs[si]
            binary = sec["binary_dismember"]
            for vi in sorted(set(idx)):
                pue = ue_pos(pos[vi])
                dd = plane_d(pue, dm)
                if abs(dd) < 0.01:
                    continue
                r = R.break_vertex(pue, jt[vi], wt[vi], dm, target, topo, binary)
                rec = {"section": si, "binary": binary, "pos_gl": pos[vi], "bones": jt[vi], "weights": wt[vi],
                       "out": None if r is None else {"bones": r[0], "weights": r[1]}}
                (changed if r is not None else same).append((abs(dd) < 25.0, rec))
        res = []
        for lst, n in ((changed, 120), (same, 60)):
            rng.shuffle(lst)
            lst.sort(key=lambda x: not x[0])
            res += [r for _, r in lst[:n]]
        out.append({"body": body, "bone": bone, "bone_name": bone_name, "kind": "break", "frame_gl": frame_gl,
                    "target": target, "decal_matrix": flat(dm), "counts": {"changed": len(changed), "same": len(same)},
                    "vertices": res})
    return out


# analytic stand-ins for the stamp textures (identical in the Rust tests)
def tex_dif(u, v):
    return [u, v, u * v, 1.0 - u * v]


def tex_disp(u, v):
    return [0.25 + 0.5 * u * v, u * u, v * v, 1.0]


def tex_disp_r(u, v):
    return 0.25 + 0.5 * u * v


ELEMENTS = {
    "add": {"ScaleVec": [1.0, 1.0, 1.0, 1.0], "WoundScale": [1.0, 0.8, 0.6, 0.0], "FXScale": [0.5, 0.4, 1.0, 1.0],
            "RangeParams": [0.0, 1.0], "DeformParams": [0.0, 1.0]},
    "absolute": {"ScaleVec": [1.0, 0.7, 1.0, 1.0], "WoundScale": [1.2, 1.0, 1.0, 1.0], "FXScale": [1.0, 1.0, 1.0, 1.0],
                 "RangeParams": [0.3, 0.2], "DeformParams": [1.0, 1.0]},
    "subtract": {"ScaleVec": [1.0, 1.0, 1.0, 1.0], "WoundScale": [1.0, 1.0, 1.0, 0.0], "FXScale": [1.0, 1.0, 1.0, 1.0],
                 "RangeParams": [0.0, 1.0], "DeformParams": [0.0, -1.0]},
    "min": {"ScaleVec": [1.0, 0.9, -1.0, 1.0], "WoundScale": [-1.0, -0.5, -0.5, 0.0], "FXScale": [-1.0, -1.0, 1.0, 1.0],
            "RangeParams": [0.0, 1.0], "DeformParams": [0.0, 1.0]},
    "min_inv": {"ScaleVec": [1.0, 0.9, -1.0, 1.0], "WoundScale": [1.0, 1.0, 1.0, 0.0], "FXScale": [1.0, 1.0, 1.0, 1.0],
                "RangeParams": [0.0, 1.0], "DeformParams": [0.0, -1.0]},
    "max": {"ScaleVec": [1.0, 1.1, 1.0, -1.0], "WoundScale": [1.0, 0.5, 0.25, 0.0], "FXScale": [0.5, 0.5, 1.0, 1.0],
            "RangeParams": [0.45, 0.5], "DeformParams": [0.0, 1.0]},
}


def fx_radial(rng, body, d, ref, socks, bone_name, uv_scale):
    names = d["bones"]["names"]
    bone = names.index(bone_name)
    rb = ref[bone]
    frame_gl = frame_to_gl(ideal_frame(rb, 12.0))
    p = R.place_dismember(frame_from_gl(frame_gl), rb, rb, R.region_sockets(socks, bone_name, "safe"),
                          reference_pose=True)
    rdm = R.radial_decal_matrix(p["frame"], uv_scale)
    sr = p["safe_region"]
    secs = section_data(body)
    pts = []
    for si, sec in enumerate(d["sections"]):
        if not sec["deformation"]:
            continue
        pos = secs[si][0]
        for v in pos:
            pue = ue_pos(v)
            y = R._plane_d(pue, rdm)
            if abs(y) < 1.5:
                pts.append(v)
    rng.shuffle(pts)
    pts.sort(key=lambda v: R.radial_coords(ue_pos(v), rdm, sr)[0] == 0.0)     # inside the stamp first
    pts = pts[:110] + pts[-60:]
    cases = []
    for v in pts:
        pue = ue_pos(v)
        if abs(abs(R._plane_d(pue, rdm)) - 1.0) < 1e-4:
            continue
        s = R.xform_pos(pue, sr)
        if math.hypot(s[1], s[2]) < 1e-3:
            continue
        w, uv = R.radial_coords(pue, rdm, sr)
        dlen = r9(rng.uniform(0.0, 8.0))
        depth = r9(rng.uniform(0.0, 1.0))
        rec = {"pos_gl": v, "w": w, "uv": list(uv), "deform_len": dlen, "depth": depth, "texel": {}, "vertex_depth": {}}
        for name, e in ELEMENTS.items():
            t = R.radial_texel(pue, rdm, sr, e, dlen, tex_dif, tex_disp)
            rec["texel"][name] = None if t is None else [t[0], t[1]]
            rec["vertex_depth"][name] = R.radial_vertex_depth(pue, rdm, sr, e, depth, tex_disp_r)
        cases.append(rec)
    return {"body": body, "bone": bone, "bone_name": bone_name, "uv_scale": uv_scale, "frame_gl": frame_gl,
            "cut_frame": flat(p["frame"]), "radial_decal_matrix": flat(rdm), "safe_region": flat(sr),
            "radial_decal_matrix_gl": flat(R.mmul(C_ROWS, rdm)), "elements": ELEMENTS, "points": cases}


def fx_clears(rng):
    out = []
    for t in (0, 1, 2, 3, 8, 16, 17, 33, 64, 80):
        for proxy in (False, True):
            for cv in (0.0, 0.37, 1.0):
                disp = [r9(rng.uniform(0, 1)) for _ in range(4)]
                dif = [r9(rng.uniform(0, 1)) for _ in range(4)]
                a, b = R.clear_rt_texel(t, proxy, cv, disp, dif)
                out.append({"t": t, "proxy": proxy, "clear_value": cv, "disp": disp, "dif": dif,
                            "kind": R.clear_kind(t), "out_disp": a, "out_dif": b,
                            "vertex_depth": R.clear_vertex_depth(cv)})
    return out


def main():
    rng = random.Random(20261008)
    fx = {"generator": "tools/re_dismember/make_fixtures.py", "math": fx_math(rng), "topology_skel": fx_topology()}
    d, ref, topo, socks = load_body("walker")
    fx["evaluate_candidate"], fx["safe_region_matrix"], fx["decal_frame_from_rotator"] = fx_candidates(rng, d, ref, socks)
    fx["place"] = []
    fx["classify"] = []
    fx["break"] = []
    for body in ("walker", "runner", "shambler", "thug"):
        d, ref, topo, socks = load_body(body)
        fx["place"] += fx_place(rng, body, d, ref, socks)
        if body == "walker":
            fx["classify"] += fx_classify(rng, body, d, ref, topo, socks,
                                          [("upperarm_l", 12.0, False), ("spine_04", 0.0, False), ("head", 0.0, True),
                                           ("neck_01", 0.0, True), ("thigh_r", 12.0, True)])
            fx["break"] += fx_break(rng, body, d, ref, topo, socks, [("upperarm_l", 17.0), ("calf_l", -20.0)])
            fx["radial"] = fx_radial(rng, body, d, ref, socks, "upperarm_l", 45.0)
        if body == "thug":
            fx["classify"] += fx_classify(rng, body, d, ref, topo, socks, [("spine_03", 0.0, True)])
            fx["break"] += fx_break(rng, body, d, ref, topo, socks, [("thigh_l", -30.0)])
    fx["clears"] = fx_clears(rng)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    s = json.dumps(fx, separators=(",", ":"), default=float)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"wrote {OUT} ({len(s) // 1024} KB)")
    print("place cases", len(fx["place"]), "candidates", len(fx["evaluate_candidate"]))
    for c in fx["classify"]:
        print(f"classify {c['body']} {c['bone_name']}: all {c['counts']} kept {len(c['triangles'])}")
    for c in fx["break"]:
        print(f"break {c['body']} {c['bone_name']}: {c['counts']} kept {len(c['vertices'])}")
    print("radial points", len(fx["radial"]["points"]), "nonzero w",
          sum(1 for p in fx["radial"]["points"] if p["w"] > 0))


if __name__ == "__main__":
    main()
