"""Export DI2's per-vertex deform vectors for our body glbs.

For each body (walker, runner, shambler, thug):
  * parse LOD0 of the cooked SK_* package (tools/deform/di2mesh.py) including DI2's deform half4 stream;
  * map every vertex of game/assets/di2/<body>/<body>.glb (CUE4Parse glTF export, LOD0, morphs off) back to the
    cooked vertex it came from, triangle by triangle, and verify positions / normals / UV0;
  * write <body>.deform.bin: per glb primitive in file order, float32 (x, y, z) per glb vertex, already in glTF space
    (UE (x, y, z) cm -> glTF (x, z, y) * 0.01, the same swap CUE4Parse applies to positions);
  * write <body>.deform.json: primitive / material names, counts, initial depth (deform.w), stats, verification.

CUE4Parse's glTF writer (CUE4Parse-Conversion/Writers/Gltf/Gltf.cs) feeds each enabled section's triangles to
SharpGLTF in index order; SharpGLTF dedups equal vertices and drops degenerate triangles. So glb triangle k of a
primitive is the k-th surviving cooked triangle of that section, and that is how vertices are matched here.

usage: python tools/deform/export_deform.py [body ...]   (personal-use; reads the user's own extracted files)
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from di2mesh import find_lod_starts, parse_deform, parse_lod  # noqa: E402
from glb import Glb  # noqa: E402

ROOT = "."
BODIES = {
    "walker": "DeadIsland/Content/DI2/Art/Characters/ZombieMale/Walker/SK_WalkerMaleCas01",
    "runner": "DeadIsland/Content/DI2/Art/Characters/ZombieMale/Runner/SK_RunnerMaleCas01",
    "shambler": "DeadIsland/Content/DI2/Art/Characters/ZombieMale/Shambler/SK_ShamMaleCas01",
    "thug": "DeadIsland/Content/DI2/Art/Characters/ZombieSpecial/Thug/SK_ThugA01",
    "screamer": "DeadIsland/Content/DI2/Art/Characters/ZombieSpecial/Screamer/SK_Screamer01",  # tools/archetype_bodies.py
    "slobber": "DeadIsland/Content/DI2/Art/Characters/ZombieSpecial/Slobber/SK_SlobberA",
    "butcher": "DeadIsland/Content/DI2/Art/Characters/ZombieSpecial/Butcher/SK_Butcher01",
    "suicider": "DeadIsland/Content/DI2/Art/Characters/ZombieSpecial/Suicider/SK_SuiciderA",
}
# P2 variant bodies (mesh only, class clips): tools/archetype_bodies.py VARIANTS.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from archetype_bodies import VARIANTS  # noqa: E402
BODIES.update({b: "DeadIsland/Content/" + v["mesh"] for b, v in VARIANTS.items()})


def ue_to_gltf(v):
    """UE (x, y, z) cm -> glTF (x, z, y) m, float32 like CUE4Parse (FVector * 0.01f, then SwapYZ)."""
    v = np.asarray(v, np.float32) * np.float32(0.01)
    return v[..., [0, 2, 1]]


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n == 0, 1, n)


def closest_point_on_triangles(p, a, b, c):
    """Distance from each point p (P,3) to the nearest of triangles (a,b,c) (T,3 each). Ericson, vectorised."""
    best = np.full(len(p), np.inf)
    for s in range(0, len(p), 256):
        q = p[s:s + 256, None, :]
        ab, ac, ap = b - a, c - a, q - a
        d1, d2 = (ab * ap).sum(-1), (ac * ap).sum(-1)
        bp = q - b
        d3, d4 = (ab * bp).sum(-1), (ac * bp).sum(-1)
        cp = q - c
        d5, d6 = (ab * cp).sum(-1), (ac * cp).sum(-1)
        va = d3 * d6 - d5 * d4
        vb = d5 * d2 - d1 * d6
        vc = d1 * d4 - d3 * d2
        denom = va + vb + vc
        denom = np.where(np.abs(denom) < 1e-20, 1e-20, denom)
        v = vb / denom
        w = vc / denom
        res = a + ab * v[..., None] + ac * w[..., None]                       # interior
        # edges and vertices
        cond_ab = (vc <= 0) & (d1 >= 0) & (d3 <= 0)
        t = d1 / np.where(d1 - d3 == 0, 1, d1 - d3)
        res = np.where(cond_ab[..., None], a + ab * t[..., None], res)
        cond_ac = (vb <= 0) & (d2 >= 0) & (d6 <= 0)
        t = d2 / np.where(d2 - d6 == 0, 1, d2 - d6)
        res = np.where(cond_ac[..., None], a + ac * t[..., None], res)
        cond_bc = (va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0)
        t = (d4 - d3) / np.where((d4 - d3) + (d5 - d6) == 0, 1, (d4 - d3) + (d5 - d6))
        res = np.where(cond_bc[..., None], b + (c - b) * t[..., None], res)
        res = np.where(((d1 <= 0) & (d2 <= 0))[..., None], a, res)
        res = np.where(((d3 >= 0) & (d4 <= d3))[..., None], b, res)
        res = np.where(((d6 >= 0) & (d5 <= d6))[..., None], c, res)
        dist = np.linalg.norm(q - res, axis=-1)
        best[s:s + 256] = dist.min(axis=1)
    return best


def pct(x, qs=(0, 5, 50, 95, 100)):
    x = np.asarray(x, np.float64)
    return {f"p{q}": round(float(np.percentile(x, q)), 4) for q in qs} if len(x) else None


def section_tris(lod, s):
    I = lod["indices"]
    t = I[s["BaseIndex"]: s["BaseIndex"] + 3 * s["NumTriangles"]].reshape(-1, 3)
    if t.max() < s["NumVertices"]:          # DI2 stores section-relative indices (CUE4Parse ConvertIndices)
        t = t + s["BaseVertexIndex"]
    return t


def material_names(body):
    j = json.load(open(f"{ROOT}/extracted/json/{BODIES[body]}.json"))
    sk = next(e for e in j if e.get("Type") == "SkeletalMesh")
    out = []
    for m in sk["SkeletalMaterials"]:
        mat = m.get("Material")
        name = mat.get("ObjectName") if isinstance(mat, dict) else mat
        out.append(name.split("'")[1] if name and "'" in name else name)
    masks = next((e for e in j if e.get("Type") == "DIEngineMaterialMasks"), None)
    return out, (masks or {}).get("Properties", {}).get("Masks", {})


def export(body):
    raw = f"{ROOT}/extracted/raw/{BODIES[body]}.uasset"
    d = open(raw, "rb").read()
    starts = find_lod_starts(d)
    lod, _ = parse_lod(d, starts[0])
    deform, hdr, end = parse_deform(d, lod["deform_header"], lod["NumVertices"])
    assert len(starts) == 1 or end == starts[1], "deform block must end where LOD1 starts"
    deform = deform.astype(np.float32)
    mats, masks = material_names(body)

    P = lod["positions"]
    N_ue = unit(lod["tangent_z"][:, :3])
    UV0 = lod["uvs"][:, 0]

    g = Glb(f"{ROOT}/game/assets/di2/{body}/{body}.glb")
    prims = g.primitives()
    enabled = [(i, s) for i, s in enumerate(lod["sections"]) if not s["bDisabled"]]
    assert len(prims) == len(enabled), (len(prims), len(enabled))

    out_xyz = []
    prim_info = []
    worst = {"position_m": 0.0, "normal": 0.0, "uv0": 0.0}
    merged_conflicts = 0
    vert_maps = []
    for (mi, pi, mat, p), (si, s) in zip(prims, enabled):
        assert mat == mats[s["MaterialIndex"]], (mat, mats[s["MaterialIndex"]])
        gpos = g.accessor(p["attributes"]["POSITION"])
        gnrm = g.accessor(p["attributes"]["NORMAL"])
        guv = g.accessor(p["attributes"]["TEXCOORD_0"])
        gidx = g.accessor(p["indices"]).reshape(-1, 3).astype(np.int64)
        ut = section_tris(lod, s)
        upos = ue_to_gltf(P)
        # Align glb triangles with cooked triangles: SharpGLTF skips degenerate triangles, nothing else.
        gmap = np.full(len(gpos), -1, np.int64)
        k = 0
        skipped_degenerate = 0
        for t in ut:
            if k < len(gidx) and np.array_equal(upos[t], gpos[gidx[k]]):
                for c in range(3):
                    gv, uv = gidx[k][c], t[c]
                    if gmap[gv] < 0:
                        gmap[gv] = uv
                    elif gmap[gv] != uv and not np.array_equal(deform[gmap[gv]], deform[uv]):
                        merged_conflicts += 1
                k += 1
            else:
                assert len(set(t.tolist())) < 3 or len({tuple(x) for x in upos[t].tolist()}) < 3, \
                    f"{body} prim {pi}: non-degenerate cooked triangle has no glb counterpart"
                skipped_degenerate += 1
        assert k == len(gidx), f"{body} prim {pi}: matched {k} of {len(gidx)} glb triangles"
        assert (gmap >= 0).all()
        dpos = np.abs(upos[gmap] - gpos).max()
        dnrm = np.abs(unit(N_ue[gmap][:, [0, 2, 1]]) - gnrm).max()
        duv = np.abs(UV0[gmap] - guv).max()
        worst["position_m"] = max(worst["position_m"], float(dpos))
        worst["normal"] = max(worst["normal"], float(dnrm))
        worst["uv0"] = max(worst["uv0"], float(duv))

        D = deform[gmap]
        xyz_gltf = ue_to_gltf(D[:, :3])            # cm -> m, axis swap: same transform as POSITION
        out_xyz.append(xyz_gltf.astype("<f4"))
        vert_maps.append(gmap)
        L = np.linalg.norm(D[:, :3], axis=1)
        nz = L > 0
        cosn = (unit(D[nz, :3]) * N_ue[gmap][nz]).sum(1)
        w = D[:, 3]
        prim_info.append({
            "primitive": pi, "material": mat, "vertex_count": int(len(gpos)),
            "float_offset": int(sum(len(x) for x in out_xyz[:-1]) * 3),
            "ue_section": si, "ue_material_index": s["MaterialIndex"],
            "ue_base_vertex": s["BaseVertexIndex"], "ue_num_vertices": s["NumVertices"],
            "ue_num_triangles": s["NumTriangles"], "degenerate_triangles_dropped_by_gltf": skipped_degenerate,
            # cooked Deform.w: the depth this primitive starts at (shells start at 1 = drawn at P + Deform.xyz)
            "initial_depth": float(np.bincount((w * 1000).astype(np.int64)).argmax() / 1000),
            "initial_depth_values": {str(float(u)): int((w == u).sum()) for u in np.unique(w)},
            "initial_depth_exceptions": ({"glb_vertices": np.nonzero(w != np.median(w))[0].tolist(),
                                          "depth": float(w[w != np.median(w)][0])}
                                         if not np.all(w == w[0]) else None),
            "zero_vectors": int((~nz).sum()),
            "length_cm": pct(L[nz]) if nz.any() else None,
            "cos_to_normal": pct(cosn) if nz.any() else None,
            "frac_against_normal": round(float((cosn < 0).mean()), 4) if nz.any() else None,
        })

    # --- relation to the interior shell -------------------------------------------------------------------------
    # Shell sections: cooked depth (w) mostly 1. Their vertices are copies of outer (skin) vertices: same position,
    # same deform vector. Twins are found by exact equality of position and deform xyz.
    sec = lod["sections"]
    cloth_slots = {i for i in range(len(mats)) if (int(masks.get("ClothingMask", 0)) >> i) & 1}

    def vr(s):
        return np.arange(s["BaseVertexIndex"], s["BaseVertexIndex"] + s["NumVertices"])

    def live(t):
        return t[(t[:, 0] != t[:, 1]) & (t[:, 1] != t[:, 2]) & (t[:, 0] != t[:, 2])]

    def canon(tri):
        return tuple(np.roll(tri, -int(np.argmin(tri))).tolist())

    enabled_ids = [i for i, s in enumerate(sec) if not s["bDisabled"]]
    shell_ids = [i for i in enabled_ids if deform[vr(sec[i]), 3].mean() > 0.5]
    outer_ids = [i for i in enabled_ids if i not in shell_ids
                 and np.linalg.norm(deform[vr(sec[i]), :3], axis=1).max() > 0]
    sec_of = np.full(len(P), -1)
    for i in enabled_ids:
        sec_of[vr(sec[i])] = i
    key = lambda v: P[v].tobytes() + deform[v, :3].tobytes()  # noqa: E731
    outer_by_key = {}
    for i in outer_ids:
        for v in vr(sec[i]):
            outer_by_key.setdefault(key(v), []).append(v)
    outer_tris = {canon(t) for i in outer_ids for t in section_tris(lod, sec[i]).tolist()}
    has_shell = np.zeros(len(P), bool)          # outer vertex whose tip is a vertex of a live shell triangle
    has_twin = np.zeros(len(P), bool)
    shells, shell_tri_list = [], []
    for si in shell_ids:
        s = sec[si]
        r = vr(s)
        twin = np.array([outer_by_key.get(key(v), [-1])[0] for v in r])
        st = section_tris(lod, s)
        lt = live(st)
        shell_tri_list.append(lt)
        used = np.zeros(len(r), bool)
        used[(lt - s["BaseVertexIndex"]).ravel()] = True
        for j, v in enumerate(r):
            for c in outer_by_key.get(key(v), []):
                has_twin[c] = True
                has_shell[c] |= used[j]
        # Winding check. Seam duplicates share position and vector, so try every twin candidate per corner.
        cands = [outer_by_key.get(key(v), []) for v in r]
        rev = same = 0
        for a, b, c in (lt - s["BaseVertexIndex"]).tolist():
            combos = [(x, y, z) for x in cands[a] for y in cands[b] for z in cands[c]]
            rev += any(canon(np.array([x, z, y])) in outer_tris for x, y, z in combos)
            same += any(canon(np.array([x, y, z])) in outer_tris for x, y, z in combos)
        tw = twin >= 0
        rendered = P[r] + deform[r, :3] * deform[r, 3:4]
        tip = P[twin[tw]] + deform[twin[tw], :3]
        w = deform[r, 3]
        shells.append({
            "shell_section": si, "shell_material": mats[s["MaterialIndex"]], "vertices": int(len(r)),
            "depth_values": {str(float(u)): int((w == u).sum()) for u in np.unique(w)},
            "vertices_with_outer_twin": int(tw.sum()),
            "twin_sections": {mats[sec[k]["MaterialIndex"]]: int((sec_of[twin[tw]] == k).sum())
                              for k in sorted(set(sec_of[twin[tw]].tolist()))},
            "triangles_total": int(len(st)), "triangles_live": int(len(lt)),
            "triangles_index_degenerate": int(len(st) - len(lt)),
            "live_triangles_matching_outer_triangle_reversed": int(rev),
            "live_triangles_matching_outer_triangle_same_winding": int(same),
            "max_abs_diff_outer_tip_vs_rendered_shell_vertex_cm":
                float(np.abs(tip - rendered[tw]).max()) if tw.any() else None,
        })

    shell_tris = None
    if shell_tri_list:
        t = np.concatenate(shell_tri_list)
        V = P + deform[:, :3] * deform[:, 3:4]
        shell_tris = (V[t[:, 0]], V[t[:, 1]], V[t[:, 2]])
    skin_ids = [i for i in outer_ids if sec[i]["MaterialIndex"] not in cloth_slots]
    st = live(np.concatenate([section_tris(lod, sec[i]) for i in skin_ids]))
    skin_tris = (P[st[:, 0]], P[st[:, 1]], P[st[:, 2]])
    tip_stats = []
    for info in prim_info:
        si = info["ue_section"]
        if si not in outer_ids:
            continue
        r = vr(sec[si])
        r = r[np.linalg.norm(deform[r, :3], axis=1) > 0]
        L = np.linalg.norm(deform[r, :3], axis=1)
        tip = P[r] + deform[r, :3]
        e = {"primitive": info["primitive"], "material": info["material"], "vertices": int(len(r)),
             "cloth": sec[si]["MaterialIndex"] in cloth_slots,
             "frac_with_shell_twin_vertex": round(float(has_twin[r].mean()), 4),
             "frac_tip_is_live_shell_vertex": round(float(has_shell[r].mean()), 4)}
        if shell_tris is not None:
            dist = closest_point_on_triangles(tip, *shell_tris)
            e["tip_to_live_shell_surface_cm"] = pct(dist)
            e["vertex_to_live_shell_over_length_where_tip_on_shell"] = pct(
                closest_point_on_triangles(P[r][has_shell[r]], *shell_tris) / L[has_shell[r]])                 if has_shell[r].any() else None
        if e["cloth"]:
            e["cloth_vertex_to_skin_surface_cm"] = pct(closest_point_on_triangles(P[r], *skin_tris))
            e["cloth_tip_to_skin_surface_cm"] = pct(closest_point_on_triangles(tip, *skin_tris))
        tip_stats.append(e)

    # --- write ----------------------------------------------------------------------------------------------------
    allxyz = np.concatenate(out_xyz).astype("<f4")
    dst = f"{ROOT}/game/assets/di2/{body}/{body}.deform"
    allxyz.tofile(dst + ".bin")
    meta = {
        "body": body,
        "source": f"extracted/raw/{BODIES[body]}.uasset (LOD0, inlined render data)",
        "glb": f"game/assets/di2/{body}/{body}.glb",
        "format": "float32 little-endian (x, y, z) per glb vertex, primitives in glb order, no header. "
                  "glTF space: UE Deform.xyz (cm, bind pose) -> (x, z, y) * 0.01, the transform CUE4Parse applies to "
                  "POSITION. DI2 VS: P_bind = Position + Deform.xyz * depth (before skinning).",
        "floats": int(allxyz.size), "vertices": int(allxyz.size // 3),
        "ue_lod0": {"num_vertices": lod["NumVertices"], "num_sections": len(sec),
                    "deform_block_offset": lod["deform_header"], "deform_data_offset": hdr["data_offset"],
                    "header": {k: hdr[k] for k in ("unknown", "stride", "num_vertices", "elem_size", "count",
                                                   "trailing_bool")}},
        "masks_by_material_slot": {k: [i for i in range(len(mats)) if (int(v) >> i) & 1]
                                   for k, v in masks.items() if isinstance(v, int)},
        "verification": {"max_abs_position_diff_m": worst["position_m"], "max_abs_normal_diff": worst["normal"],
                         "max_abs_uv0_diff": worst["uv0"], "merged_vertices_with_different_deform": merged_conflicts},
        "primitives": prim_info,
        "interior_shells": shells,
        "tips_vs_shell": tip_stats,
        "material_slots": mats,
    }
    json.dump(meta, open(dst + ".json", "w"), indent=1,
              default=lambda o: o.item() if isinstance(o, np.generic) else str(o))
    return meta


if __name__ == "__main__":
    for b in (sys.argv[1:] or list(BODIES)):
        m = export(b)
        v = m["verification"]
        print(f"{b}: {m['vertices']} verts in {len(m['primitives'])} prims; max |dpos| {v['max_abs_position_diff_m']:.3g} m, "
              f"|dn| {v['max_abs_normal_diff']:.3g}, |duv| {v['max_abs_uv0_diff']:.3g}, merged conflicts {v['merged_vertices_with_different_deform']}")
