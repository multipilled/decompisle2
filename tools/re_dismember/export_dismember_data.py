"""Load-time dismember data per body -> game/assets/di2/<body>/<body>.dismember.json (read by gore-core dismember.rs).

Sources (local data only):
  - the body's glb (game/assets/di2/<body>/<body>.glb): skin joints (order = JOINTS_0 indices), joint hierarchy,
    inverseBindMatrices (the mesh's ref pose, CachedComposedRefPoseMatrices), primitives (= LOD0 sections);
  - the mesh JSON (extracted/json/.../SK_*.json): region sockets (<bone>_safe_region[_N], <bone>_break_region[_N]),
    UDIEngineMaterialMasks, LOD0 section -> material slot.

Everything is written in glTF bind-pose space, metres, with the UE -> glTF conversion used by the other exporters:
  position (x, y, z) cm  -> (x, z, y) * 0.01
  quaternion (x, y, z, w) -> (x, z, y, -w)
  socket scale (sx, sy, sz) cm (region half-extents along socket X, Y, Z) -> (sx, sz, sy) * 0.01
  (the y/z swap is a reflection: the socket's glTF local Y is its UE local Z.)
Matrices are 16 floats, column-major (glTF / glam `Mat4::from_cols_array` order), column-vector convention.

Self-checks (printed): glb joint names / parents vs SKEL_ZombieStandard, glb bind pose vs the SKEL ref pose,
the quaternion and matrix conversions, glb primitive vertex counts vs the LOD0 sections.

usage: python export_dismember_data.py [body ...]       (default: walker runner shambler thug)"""
import json
import math
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "deform"))
import dismember_ref as R          # noqa: E402
from glb import Glb                # noqa: E402  (tools/deform/glb.py, read-only)
from masks_dump import BODIES, MASKS, ROOT   # noqa: E402

ASSETS = r"game\assets\di2"
SKEL = r"extracted\json\DeadIsland\Content\DIShared\Art\Characters\ZombieStandard\SKEL_ZombieStandard.json"
SWAP = (0, 2, 1)
SECTION_MASKS = {"dismember": "DismemberMask", "binary_dismember": "BinaryDismemberMask",
                 "skeleton_viscera": "SkeletonVisceraMask", "hide": "HideMask",
                 "initially_hidden": "InitiallyHiddenMask", "write_splatter": "WriteSplatterMask",
                 "clothing_proxy": "ClothingProxyMask", "deformation": "DeformationMask",
                 "soft_body_deformation": "SoftBodyDeformationMask", "clothing": "ClothingMask",
                 "trim": "TrimMask", "trim_hq": "TrimHQMask"}


# ---------------------------------------------------------------------------------------------------------------
# UE <-> glTF
# ---------------------------------------------------------------------------------------------------------------
def gl_pos(p):
    return [p[0] * 0.01, p[2] * 0.01, p[1] * 0.01]


def gl_dir(v):
    return [v[0], v[2], v[1]]


def gl_quat(q):
    return [q[0], q[2], q[1], -q[3]]


def gl_scale(s):
    return [s[0] * 0.01, s[2] * 0.01, s[1] * 0.01]


def ue_rows_to_gl(m):
    """UE FMatrix rows (row vectors, cm) -> glTF column-vector 4x4 (numpy, metres)."""
    g = np.eye(4)
    for b in range(3):
        g[:3, b] = gl_dir(m[SWAP[b]][:3])
    g[:3, 3] = gl_pos(m[3][:3])
    return g


def gl_to_ue_rows(g):
    rows = [[0.0] * 4 for _ in range(4)]
    for i in range(3):
        col = g[:3, SWAP[i]]
        rows[i] = [float(col[0]), float(col[2]), float(col[1]), 0.0]
    t = g[:3, 3]
    rows[3] = [float(t[0]) * 100.0, float(t[2]) * 100.0, float(t[1]) * 100.0, 1.0]
    return rows


def cols16(g):
    """numpy 4x4 (column-vector math form) -> 16 floats column-major."""
    return [float(v) for v in np.asarray(g).T.reshape(-1)]


# ---------------------------------------------------------------------------------------------------------------
def load_skel():
    sk = json.load(open(SKEL, encoding="utf-8"))
    rs = [o for o in sk if o["Type"] == "Skeleton"][0]["ReferenceSkeleton"]
    names = [b["Name"] for b in rs["FinalRefBoneInfo"]]
    parents = [b["ParentIndex"] for b in rs["FinalRefBoneInfo"]]
    local = []
    for p in rs["FinalRefBonePose"]:
        r, t, s = p["Rotation"], p["Translation"], p["Scale3D"]
        local.append(R.transform_matrix((r["X"], r["Y"], r["Z"], r["W"]), (t["X"], t["Y"], t["Z"]),
                                        (s["X"], s["Y"], s["Z"])))
    comp = [None] * len(local)
    for i in range(len(local)):
        comp[i] = local[i] if parents[i] < 0 else R.mmul(local[i], comp[parents[i]])
    return names, parents, comp


def conversion_selfcheck():
    """quat (x,z,y,-w) and the matrix swap agree with each other on random rotations."""
    rng = np.random.default_rng(1)
    worst = 0.0
    for _ in range(64):
        p, y, r = rng.uniform(-180, 180, 3)
        q = R.quat_from_rotator(p, y, r)
        t = rng.uniform(-50, 50, 3)
        m_ue = R.transform_matrix(q, t)
        g = ue_rows_to_gl(m_ue)
        x, yy, z, w = gl_quat(q)
        # glTF quaternion -> rotation matrix (column-vector convention)
        rot = np.array([[1 - 2 * (yy * yy + z * z), 2 * (x * yy - z * w), 2 * (x * z + yy * w)],
                        [2 * (x * yy + z * w), 1 - 2 * (x * x + z * z), 2 * (yy * z - x * w)],
                        [2 * (x * z - yy * w), 2 * (yy * z + x * w), 1 - 2 * (x * x + yy * yy)]])
        worst = max(worst, float(np.abs(rot - g[:3, :3]).max()))
        back = gl_to_ue_rows(g)
        worst = max(worst, max(abs(back[i][j] - m_ue[i][j]) for i in range(4) for j in range(4)) / 100.0)
    assert worst < 1e-9, worst
    return worst


def export(body):
    mesh_path = ROOT + BODIES[body]
    glb_path = os.path.join(ASSETS, body, f"{body}.glb")
    out_path = os.path.join(ASSETS, body, f"{body}.dismember.json")
    g = Glb(glb_path)
    j = g.json
    skin = j["skins"][0]
    joints = skin["joints"]
    nodes = j["nodes"]
    names = [nodes[i]["name"] for i in joints]
    node_parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            node_parent[c] = i
    jidx = {n: k for k, n in enumerate(joints)}
    parents = [jidx.get(node_parent.get(n, -1), -1) for n in joints]
    assert all(p < k for k, p in enumerate(parents)), "glb joint order is not parent-first"

    # ref pose = inverse(inverseBindMatrices), glTF column-vector form
    ibm = g.accessor(skin["inverseBindMatrices"]).astype(np.float64)
    bind = [np.linalg.inv(ibm[k].reshape(4, 4).T) for k in range(len(joints))]
    ref_ue = [gl_to_ue_rows(b) for b in bind]

    # --- checks against the UE skeleton asset (SKEL_ZombieStandard: the shared skeleton)
    sk_names, sk_parents, sk_comp = load_skel()
    sk_idx = {n: i for i, n in enumerate(sk_names)}
    missing = [n for n in names if n not in sk_idx]
    order = [sk_idx[n] for n in names if n in sk_idx]
    par_bad = [n for k, n in enumerate(names) if n in sk_idx and parents[k] >= 0
               and sk_parents[sk_idx[n]] != sk_idx.get(names[parents[k]], -2)]
    rot_dev, pos_dev, worst_bone = 0.0, 0.0, None
    for k, n in enumerate(names):
        if n not in sk_idx:
            continue
        a, b = ref_ue[k], sk_comp[sk_idx[n]]
        rd = max(abs(a[r][c] - b[r][c]) for r in range(3) for c in range(3))
        pd = max(abs(a[3][c] - b[3][c]) for c in range(3))
        if pd > pos_dev:
            worst_bone = n
        rot_dev, pos_dev = max(rot_dev, rd), max(pos_dev, pd)
    region_bones = sorted({re.match(r"^(.*)_(?:safe|break)_region", o["Properties"]["SocketName"]).group(1)
                           for o in json.load(open(mesh_path, encoding="utf-8"))
                           if o["Type"] == "SkeletalMeshSocket"
                           and re.match(r"^(.*)_(?:safe|break)_region", o["Properties"].get("SocketName", ""))})
    reg_dev = 0.0
    for n in region_bones:
        k, b = names.index(n), sk_comp[sk_idx[n]]
        reg_dev = max([reg_dev] + [abs(ref_ue[k][r][c] - b[r][c]) for r in range(4) for c in range(3)])
    print(f"== {body}: {len(names)} joints; not in SKEL {missing}; SKEL order preserved "
          f"{order == sorted(order)}; parent mismatches {par_bad}")
    print(f"   glb bind vs SKEL ref pose: max |rot| dev {rot_dev:.2e}, max |pos| dev {pos_dev:.3f} cm ({worst_bone}); "
          f"region bones' max dev {reg_dev:.2e} ({len(region_bones)} bones)")

    topo = R.bone_topology(names, parents)

    # --- mesh JSON: sockets, masks, sections
    d = json.load(open(mesh_path, encoding="utf-8"))
    sk = [o for o in d if o["Type"] == "SkeletalMesh"][0]
    mats = [((m.get("Material") or {}).get("ObjectName") or "None").split("'")[1] if m.get("Material") else "None"
            for m in sk["SkeletalMaterials"]]
    mm = [o for o in d if o["Type"] == "DIEngineMaterialMasks"]
    masks = mm[0]["Properties"]["Masks"] if mm else {}
    mask_val = {k: int(masks.get(k, 0)) for k in MASKS}

    sockets = []
    for o in d:
        if o["Type"] != "SkeletalMeshSocket":
            continue
        p = o["Properties"]
        m = re.match(r"^(.*)_(safe|break)_region(?:_(\d+))?$", p.get("SocketName", ""))
        if not m:
            continue
        assert m.group(1) == p["BoneName"], (p["SocketName"], p["BoneName"])
        loc, rot, sc = p.get("RelativeLocation", {}), p.get("RelativeRotation", {}), p.get("RelativeScale", {})
        loc = (loc.get("X", 0.0), loc.get("Y", 0.0), loc.get("Z", 0.0))
        rot = (rot.get("Pitch", 0.0), rot.get("Yaw", 0.0), rot.get("Roll", 0.0))
        sc = (sc.get("X", 1.0), sc.get("Y", 1.0), sc.get("Z", 1.0))
        q = R.quat_from_rotator(*rot)
        sockets.append({"name": p["SocketName"], "bone": jidx_name(names, p["BoneName"]), "bone_name": p["BoneName"],
                        "kind": m.group(2), "index": int(m.group(3) or 0),
                        "loc": gl_pos(loc), "quat": gl_quat(q), "scale": gl_scale(sc),
                        "branch_mask": int(p.get("BoneBranchMask", 0)),
                        "ue": {"loc": list(loc), "rot": list(rot), "quat": list(q), "scale": list(sc)}})
    sockets.sort(key=lambda s: (s["bone"], s["kind"], s["index"]))

    # socket world-matrix check: glTF bind . socket(T, R, S) == conversion of the UE (socket . ref bone)
    sdev = 0.0
    for s in sockets:
        ue = s["ue"]
        m_ue = R.mmul(R.transform_matrix(ue["quat"], ue["loc"], ue["scale"]), ref_ue[s["bone"]])
        x, y, z, w = s["quat"]
        rot = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        t = np.eye(4)
        t[:3, :3] = rot @ np.diag(np.array(s["scale"]) * 100.0)   # scale back to cm so the axes compare 1:1
        t[:3, 3] = s["loc"]
        sdev = max(sdev, float(np.abs(bind[s["bone"]] @ t - ue_rows_to_gl(m_ue)).max()))
    print(f"   {len(sockets)} region sockets; socket matrix conversion max dev {sdev:.2e}")
    assert sdev < 1e-4, sdev

    # LOD0 sections <-> glb primitives
    secs = sk["LODModels"][0]["Sections"]
    prims = g.primitives()
    assert len(prims) == len(secs), (len(prims), len(secs))
    sections = []
    unsorted = 0
    count_mismatch = []
    for k, (mi, pi, mat, prim) in enumerate(prims):
        sec = secs[k]
        slot = int(sec["MaterialIndex"])
        nv = j["accessors"][prim["attributes"]["POSITION"]]["count"]
        if nv != sec["NumVertices"]:
            count_mismatch.append((k, int(nv), int(sec["NumVertices"])))
        assert mats[slot] == mat, (body, k, mats[slot], mat)
        jt = g.accessor(prim["attributes"]["JOINTS_0"]).astype(np.int64)
        wt = g.accessor(prim["attributes"]["WEIGHTS_0"]).astype(np.float64)
        bones = sorted({int(b) for b in jt[wt > 0.0]})
        unsorted += int(np.sum(np.any(np.diff(wt, axis=1) > 1e-6, axis=1)))
        rec = {"primitive": k, "mesh": mi, "mesh_primitive": pi, "section": k, "material_slot": slot,
               "material": mat, "vertices": int(nv), "triangles": int(sec["NumTriangles"]), "bones": bones}
        for key, mname in SECTION_MASKS.items():
            rec[key] = bool(mask_val.get(mname, 0) >> slot & 1)
        sections.append(rec)
    print(f"   {len(sections)} sections; vertices with WEIGHTS_0 not in descending order: {unsorted}; "
          f"glb vs LOD0 vertex-count mismatches (primitive, glb, LOD0) {count_mismatch}")

    out = {
        "version": 1,
        "body": body,
        "source": {"glb": os.path.relpath(glb_path, r".").replace("\\", "/"),
                   "mesh": os.path.relpath(mesh_path, r".").replace("\\", "/"),
                   "doc": "recon/RE_DISMEMBER.md", "reference": "tools/re_dismember/dismember_ref.py"},
        "convention": "glTF bind pose, metres. UE->glTF: pos (x,z,y)*0.01, quat (x,z,y,-w), socket scale "
                      "(sx,sz,sy)*0.01. Matrices: 16 floats column-major, column vectors. Bone indices = glb skin "
                      "joint indices (JOINTS_0 values).",
        "bones": {"names": names, "parents": parents,
                  "depth": [t["depth"] for t in topo], "branch": [t["branch"] for t in topo],
                  "flag": [t["flag"] for t in topo], "break_bone": [t["break_bone"] for t in topo]},
        "ref_pose": [cols16(b) for b in bind],
        "sockets": sockets,
        "masks": {k: {"hex": f"0x{v:016x}", "bits": [b for b in range(64) if v >> b & 1]} for k, v in mask_val.items()},
        "material_slots": mats,
        "sections": sections,
        "checks": {"skel_order_preserved": order == sorted(order), "joints_not_in_skel": missing,
                   "parent_mismatches": par_bad, "bind_vs_skel_max_rot_dev": rot_dev,
                   "bind_vs_skel_max_pos_dev_cm": pos_dev, "socket_conversion_max_dev": sdev,
                   "region_bones_vs_skel_max_dev": reg_dev,
                   "weights_not_descending": unsorted, "vertex_count_mismatches": count_mismatch},
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print(f"   wrote {out_path}")


def jidx_name(names, n):
    return names.index(n)


def main():
    print(f"conversion self-check: max dev {conversion_selfcheck():.1e}")
    for body in (sys.argv[1:] or ["walker", "runner", "shambler", "thug"]):
        export(body)


if __name__ == "__main__":
    main()
