"""Build a DI2 level section as the recreation's test environment (personal use: reads the user's own install,
writes only local files; game/assets/di2 and extracted/ are never shared).

    tools/with_cpu.sh <who> python tools/build_test_map.py <map>        (mounts the paks: CPU slot)

Inputs: the level packages listed in MAPS (dumped to extracted/json with tools/di2x.sh json), their static meshes,
material chains and textures (read here with tools/test_map/mapx and tools/shaders/shadermaps).
Outputs (game/assets/di2/maps/<map>/, .gdignore'd, read raw by game/scripts/di2_map.gd):
  map.json    meshes, materials, instance groups, collision, lights, the level's settings actors;
  map.bin     the arrays, Godot-encoded (var_to_bytes layout) so di2_map.gd decodes them with bytes_to_var;
  textures/   cooked DI2 textures as DDS: shipped BC format and mips, mips above TEX_CAP dropped.
Intermediates: extracted/test_map/<map>/ (glb exports, mip dumps, material chain dumps).
Write-up (choice of level, what is exact, what is approximate): recon/TEST_MAP.md.

Placement: the map is moved so MAPS[map]["origin"] (UE cm, an open floor point found with tools/test_map/find_open.py)
is the Godot origin, then turned by MAPS[map]["yaw"] degrees about it so the open area's long side runs along Godot Z
(the tests put Dani at +Z 6 m and the zombies at -Z 2..6 m). Everything whose world box reaches into the cull box
(origin +- "extent" cm, Z "z_range") is kept.
"""
import json
import math
import os
import struct
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "test_map"))
sys.path.insert(0, os.path.join(HERE, "shaders"))
sys.path.insert(0, os.path.join(HERE, "deform"))
sys.path.insert(0, HERE)
import level as L  # noqa: E402
import hull as H  # noqa: E402
from glb import Glb  # noqa: E402
import build_flesh_materials as B  # noqa: E402  (read-only reuse: material chains, MI overrides, render settings)
import build_dani_materials as D  # noqa: E402  (read-only reuse: DDS writer)
import post as P  # noqa: E402  (DI2 post-process: effective settings, eye adaptation, LUT)

MAPX = os.path.join(HERE, "test_map", "mapx", "bin", "out", "mapx.exe")
DI2X = os.path.join(HERE, "di2x", "bin", "out", "di2x.exe")
ENV = dict(os.environ, DOTNET_ROOT=os.path.join(ROOT, "tools", "dotnet10"), MSYS_NO_PATHCONV="1")
TEX_CAP = 512  # px; 1024 gave 1.6 GB for the NH_04 street
D.DDS_FMT.setdefault("PF_BC6H", (None, 95, 16, True))

HORDE = "DeadIsland/Content/DI2/Horde/Maps/"
MAPS = {
    # Horde map NH_04 (a Bel-Air street block built for horde fights), around its T03 road: asphalt road, sidewalks,
    # kerbs, mansion walls and street props, lit by the shared Horde_Lighting_Main time of day (midday sun).
    # "seed" is where the open-floor search starts; "origin" (when set) pins the spawn origin instead.
    "nh04_street": {
        "levels": [HORDE + "NH_04/SubLevels/NH_04_T%02d_Fixed.umap" % i for i in (1, 2, 3, 4, 5, 7)] + [HORDE + "NH_04/NH_04_Main.umap"],
        "lighting": [HORDE + "Horde_Lighting_Main.umap"] + [HORDE + "NH_04/SubLevels/NH_04_T%02d_Lighting.umap" % i for i in (1, 2, 3, 4, 5, 7)],
        "seed": [6135.0, -68176.0, 811.0],
        # more search seeds: the centres / tops of NH_04's road meshes (SM_LSC_NH_04_RoadA_T02_01 / _04, T03_01,
        # T04_01); the best clear rectangle over all seeds wins (tools/build_test_map.py search_seeds)
        "seeds": [[6135.0, -68176.0, 811.0], [2236.0, -60801.0, 816.0], [2491.0, -64733.0, 817.0],
                  [11638.0, -69361.0, 808.0], [-211.0, -70922.0, 819.0]],
        "extent": [4000.0, 4000.0],   # spawn search window (cm, half sizes)
        "keep": [2500.0, 2500.0],     # geometry kept around the chosen spawn origin
        "z_range": [-800.0, 2500.0],
    },
}
# The whole Horde NH_04 level (recon/TEST_MAP.md "NH_04 inventory"): every streamed tile DI2 loads for the map
# (Horde_Persistent_Main's LevelStreamingDynamic list), at nh04_street's spawn origin and yaw so the tests' fixed
# positions land on the same floor. "whole": no cull box, no spawn search; groups / collision split into "cell" m cells
# (Godot culls per MultiMesh / body). "fluid_z": the fluid map's height range (DI2Fluids) stays the street's.
NH04_SUB = HORDE + "NH_04/SubLevels/NH_04_"
MAPS["nh04"] = {
    "levels": [HORDE + "NH_04/NH_04_Main.umap", HORDE + "NH_04/NH_04_Vista.umap"]
              + [NH04_SUB + "T%02d_Fixed.umap" % i for i in (1, 2, 3, 4, 5, 7)]
              + [NH04_SUB + "T%02d_Lighting.umap" % i for i in (1, 2, 3, 4, 7)]  # lamp fixture meshes
              + [NH04_SUB + "Vegetation.umap"],  # InstancedFoliageActor: FoliageInstancedStaticMeshComponents
    "lighting": MAPS["nh04_street"]["lighting"],
    "origin": [-311.0, -70472.0, 809.4999387264252], "yaw": 90.0,  # = nh04_street's search result (map.json)
    "seed": [-311.0, -70472.0, 809.4999387264252],
    "extent": [200000.0, 200000.0], "keep": [200000.0, 200000.0], "z_range": [-100000.0, 100000.0],
    "fluid_z": MAPS["nh04_street"]["z_range"],
    "terrain": [NH04_SUB + "Terrain.umap"],
    "whole": True, "cell": 32.0, "hlod": True,
}

# Material parameter names per slot, across DI2's environment masters (first hit wins; the build prints any master
# whose base maps it could not find, so new names get added here rather than guessed).
SLOT_PARAMS = {
    "albedo": ["Diffuse Colour Map", "Diffuse Color Map", "Base Colour Map", "Base Color Map", "BaseColor", "Diffuse",
               "Base Diffuse",  # M_Interior_Horde's base layer
               "DiffuseTexture"],  # M_StaticMeshBaseFlatten / M_VehicleBaseFlatten (merged-mesh proxies)
    "normal": ["Normal Map", "Normal", "Base Normal", "NormalTexture"],
    "mro": ["Packed MRO Map (see tooltip)", "Packed MRO Map (see tooltip!)", "Packed MRO Map", "MRO", "Base MRA"],
}
# Masters the port doesn't draw (their surfaces are left out rather than drawn wrong): mesh decals (M_Decal_*,
# M_DecalPOM_*: "01 - Diffuse Colour Map" + "02 - Packed ARA Map", composited onto the surface below; the ARA channel
# use is not decoded), translucent cobweb cards. Listed in recon/TEST_MAP.md.
SKIP_MASTERS = ("M_Decal_", "M_DecalPOM_", "M_Cobwebs")

_CANON = {}
# Build report (written as build_report.json next to map.json): everything the build could not draw, with the reason.
REPORT = {"mesh_no_json": {}, "mesh_no_glb": {}, "material_unresolved": {}, "material_skipped": {}, "texture_missing": {},
          "material_approximated": {}}


def note(kind, key, reason):
    REPORT[kind].setdefault(key, reason)


def canon(pkg):
    """Package path with the case the paks store (DI2 data references paths case-insensitively, e.g. .../FoodStuffs/...
    for .../Foodstuffs/..., while CUE4Parse's file lookup is case-sensitive). extracted/files.txt = di2x list."""
    if not _CANON:
        with open(os.path.join(ROOT, "extracted", "files.txt"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                _CANON[line.lower()] = line
    return _CANON.get(pkg.lower(), pkg)


# --- Godot var encoding (core/io/marshalls.cpp encode_variant) ---------------------------------------------------
VT_ARRAY, VT_INT32, VT_FLOAT32, VT_VEC2, VT_VEC3, VT_COLOR = 28, 30, 32, 35, 36, 37


def var_packed(vtype, arr):
    a = np.ascontiguousarray(arr, dtype=np.int32 if vtype == VT_INT32 else np.float32)
    per = {VT_INT32: 1, VT_FLOAT32: 1, VT_VEC2: 2, VT_VEC3: 3, VT_COLOR: 4}[vtype]
    return struct.pack("<II", vtype, a.size // per) + a.tobytes()


def var_array(items):
    return struct.pack("<II", VT_ARRAY, len(items)) + b"".join(items)


class Blob:
    def __init__(self):
        self.parts, self.size = [], 0

    def add(self, b):
        off = self.size
        self.parts.append(b)
        self.size += len(b)
        return [off, len(b)]


# --- level -> placements -------------------------------------------------------------------------------------------

def gather(cfg):
    o = np.array(cfg.get("origin") or cfg["seed"], float)
    ext = np.array(cfg["extent"], float)
    zr = cfg["z_range"]
    out, bounds_cache = [], {}
    for pkg in cfg["levels"]:
        lv = L.Level(pkg)
        for c in L.mesh_components(lv):
            if L.is_hlod(c):
                if not (cfg.get("hlod") and c.get("hlod_draw")):
                    continue
                c["collision"] = False  # proxies are render-only (their LODActor has no collision)
            b = mesh_bounds(c["mesh"], bounds_cache)
            if b is None:
                note("mesh_no_json", c["mesh"], "no StaticMesh JSON dump / no bounds (%s)" % c["level"])
                continue
            lo, hi = world_aabb(c["world"], b)
            if (hi[0] < o[0] - ext[0] or lo[0] > o[0] + ext[0] or hi[1] < o[1] - ext[1] or lo[1] > o[1] + ext[1]
                    or hi[2] < o[2] + zr[0] or lo[2] > o[2] + zr[1]):
                continue
            out.append(c)
    return out


def mesh_bounds(object_path, cache):
    if object_path not in cache:
        info = mesh_info(object_path)
        cache[object_path] = info["bounds"] if info else None
    return cache[object_path]


def world_aabb(world, b):
    o, e = b
    corners = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]) * e + o
    w = np.c_[corners, np.ones(8)] @ world
    return w[:, :3].min(0), w[:, :3].max(0)


_MESH_INFO = {}


def mesh_info(object_path):
    """StaticMesh JSON: bounds, material slots [(slot name, material path)], BodySetup collision."""
    if object_path in _MESH_INFO:
        return _MESH_INFO[object_path]
    pkg = B.game_to_pkg(object_path)
    try:
        exports = L.package_json(pkg)
    except FileNotFoundError:
        _MESH_INFO[object_path] = None
        return None
    pk = L.game_path_pkg(object_path)
    sm = exports[pk[1]] if pk and pk[1] < len(exports) and exports[pk[1]].get("Type") == "StaticMesh" else None
    sm = sm or next((e for e in exports if e.get("Type") == "StaticMesh"), None)
    if sm is None:
        _MESH_INFO[object_path] = None
        return None
    p = sm.get("Properties") or {}
    rb = (sm.get("RenderData") or {}).get("Bounds") or p.get("ExtendedBounds")
    slots = [(s.get("MaterialSlotName") or s.get("ImportedMaterialSlotName"), (s.get("MaterialInterface") or {}).get("ObjectPath"))
             for s in p.get("StaticMaterials") or []]
    bs = None
    bsi = L.ref_index(sm.get("BodySetup"))
    if bsi is not None and 0 <= bsi < len(exports):
        bs = exports[bsi].get("Properties") or {}
    info = {"pkg": pkg, "name": sm["Name"], "bounds": (L.vec(rb["Origin"]), L.vec(rb["BoxExtent"])) if rb else None,
            "slots": slots, "body": bs}
    _MESH_INFO[object_path] = info
    return info


def glb_path(build, info):
    """The exported glb of a mesh: mapx (CUE4Parse) writes <package dir>/<mesh name>.glb, which is <package>.glb for the
    usual one-mesh package and one file per cluster mesh in an HLOD_Root package."""
    return os.path.join(build, "mesh", os.path.dirname(canon(info["pkg"])), info["name"] + ".glb")


# --- transforms ----------------------------------------------------------------------------------------------------

def map_xform(cfg):
    """(R, o): Godot-space rotation about the origin for the map yaw, and the UE origin."""
    a = math.radians(cfg.get("yaw", 0.0))
    r = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    return r, np.array(cfg["origin"], float)


def godot_xform(world, cfg):
    r, o = map_xform(cfg)
    basis, origin = L.to_godot(world, o)
    return r @ basis, r @ origin


def godot_point(p_ue, cfg):
    r, o = map_xform(cfg)
    return r @ L.point_to_godot(p_ue, o)


# --- collision -------------------------------------------------------------------------------------------------------

def elem_matrix(e, rot_key="Rotation"):
    """UE row-vector 4x4 of an AggGeom element (Center + Rotation rotator, or a Transform)."""
    if "Transform" in e:
        t = e["Transform"]
        return L.make_xform(L.vec(t.get("Translation")), L.quat_matrix(t["Rotation"]), L.vec(t.get("Scale3D"), (1, 1, 1)))
    return L.make_xform(L.vec(e.get("Center")), L.rotator_matrix(e.get(rot_key) or {}), (1, 1, 1))


def to_world_points(pts_local, m, cfg):
    w = np.c_[pts_local, np.ones(len(pts_local))] @ m
    r, o = map_xform(cfg)
    return (r @ (L.P @ ((w[:, :3] - o) * 0.01).T)).T


def collision_for(c, info, glb_tris, cfg, out):
    """Append this placement's collision (Godot world space) to out = {"trimesh": [...], "convex": [...], ...}."""
    body = info["body"] or {}
    agg = body.get("AggGeom") or {}
    flag = body.get("CollisionTraceFlag", "CTF_UseDefault")
    simple = sum(len(agg.get(k) or []) for k in ("BoxElems", "ConvexElems", "SphereElems", "SphylElems"))
    if flag == "CTF_UseComplexAsSimple" or simple == 0:
        if glb_tris is not None and len(glb_tris):
            out["trimesh"].append(to_world_points(glb_tris.reshape(-1, 3), c["world"], cfg))
            out["counts"]["trimesh"] += 1
        return
    w = c["world"]
    for e in agg.get("BoxElems") or []:
        hx, hy, hz = e.get("X", 0) / 2, e.get("Y", 0) / 2, e.get("Z", 0) / 2
        corners = np.array([[sx * hx, sy * hy, sz * hz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        add_hull(out, to_world_points(corners, elem_matrix(e) @ w, cfg))
        out["counts"]["box"] += 1
    for e in agg.get("ConvexElems") or []:
        pts = np.array([[v["X"], v["Y"], v["Z"]] for v in e.get("VertexData") or []])
        if len(pts) >= 4:
            add_hull(out, to_world_points(pts, elem_matrix(e) @ w, cfg))
            out["counts"]["convex"] += 1
    for e in agg.get("SphereElems") or []:
        m = elem_matrix(e) @ w
        ctr = to_world_points(np.zeros((1, 3)), m, cfg)[0]
        s = np.linalg.norm(m[:3, :3], axis=1)
        if s.max() - s.min() < 1e-3 * s.max():
            out["spheres"].append([*ctr, e["Radius"] * s[0] * 0.01])
        else:
            add_hull(out, to_world_points(_sphere_pts(e["Radius"]), m, cfg))
        out["counts"]["sphere"] += 1
    for e in agg.get("SphylElems") or []:
        m = elem_matrix(e) @ w
        s = np.linalg.norm(m[:3, :3], axis=1)
        if s.max() - s.min() < 1e-3 * s.max():
            basis, origin = godot_xform(m, cfg)
            basis = basis / s[0]
            # Godot capsules run along local Y; the swapped UE sphyl axis (local Z) is Godot local Y.
            out["capsules"].append([*basis[:, 0], *basis[:, 1], *basis[:, 2], *origin,
                                    e["Radius"] * s[0] * 0.01, (e["Length"] + 2 * e["Radius"]) * s[0] * 0.01])
        else:
            add_hull(out, to_world_points(_capsule_pts(e["Radius"], e["Length"]), m, cfg))
        out["counts"]["capsule"] += 1


MIN_HULL_M = 0.02  # Jolt's hull builder fails on near-flat point sets (tolerance 1 mm); port parameter, not DI2's


def add_hull(out, pts):
    """Append a convex hull (Godot metres). Points are de-duplicated to 0.1 mm; a hull thinner than MIN_HULL_M along
    its smallest principal axis (flat UE boxes / convex elements, e.g. 0 cm thick blockers) is pushed out to
    MIN_HULL_M about its mid-plane so Jolt can build it (counted in counts["thin_hull"])."""
    pts = np.unique(np.round(pts, 4), axis=0)
    if len(pts) < 4:
        return
    c = pts.mean(0)
    _u, _s, vt = np.linalg.svd(pts - c, full_matrices=False)
    ax = vt[-1]
    d = (pts - c) @ ax
    if d.max() - d.min() < MIN_HULL_M:
        mid = (d.max() + d.min()) / 2  # both faces of the slab: every point projected to mid +- MIN_HULL_M / 2
        pts = np.concatenate([pts + np.outer(mid + MIN_HULL_M / 2 - d, ax), pts + np.outer(mid - MIN_HULL_M / 2 - d, ax)])
        pts = np.unique(np.round(pts, 4), axis=0)
        out["counts"]["thin_hull"] = out["counts"].get("thin_hull", 0) + 1
    if len(pts) > 64:
        # large hulls (some DI2 ConvexElems of 300..700 points still failed in Jolt after clean-up): their hull's
        # triangles as concave collision instead (a static surface collides the same; port parameter)
        hf = H.hull_points(pts, 0.002, with_faces=True)
        if hf is not None:
            out["trimesh"].append(hf[1].reshape(-1, 3)[:, [0, 2, 1]].reshape(-1, 3))  # main swaps the winding back
            out["counts"]["hull_as_mesh"] = out["counts"].get("hull_as_mesh", 0) + 1
            return
    if len(pts) > 8:
        hp = H.hull_points(pts, 0.002)  # drop points within 2 mm of the hull (tools/test_map/hull.py)
        if hp is not None:
            pts = hp
    out["convex"].append(pts)


def _sphere_pts(r, n=8):
    pts = []
    for i in range(n + 1):
        th = math.pi * i / n
        for j in range(2 * n):
            ph = math.pi * j / n
            pts.append([r * math.sin(th) * math.cos(ph), r * math.sin(th) * math.sin(ph), r * math.cos(th)])
    return np.array(pts)


def _capsule_pts(r, length, n=8):
    s = _sphere_pts(r, n)
    return np.concatenate([s + [0, 0, length / 2], s - [0, 0, length / 2]])


# --- materials ---------------------------------------------------------------------------------------------------------

def material_chains(leaf_paths, build):
    """{leaf object path: [material json, ...] leaf first}, like build_flesh_materials.chains_for, but safe for level
    content: environment MIs reuse export names across folders (e.g. two MI_PlasterInteriorA_01_Teal_TileUV), and
    shadermaps.exe writes <export name>.json, so each batch (unique names, <= 60 packages: the regex rides on the
    command line, Windows' 32k limit) gets its own folder; index.json maps package -> dump file and caches across runs."""
    root = os.path.join(build, "materials")
    os.makedirs(root, exist_ok=True)
    idx_path = os.path.join(root, "index.json")
    index = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    cache = {}

    def load(pkg):
        if pkg not in cache:
            cache[pkg] = json.load(open(index[pkg]))
            assert cache[pkg]["path"].lower() == pkg.lower(), (pkg, index[pkg])  # UE paths are case-insensitive
        return cache[pkg]

    todo = {B.game_to_pkg(p) for p in leaf_paths}
    while todo:
        need = sorted(p for p in todo if p not in index)
        while need:
            batch, names, rest = [], set(), []
            for p in need:
                n = os.path.basename(p)[:-7]
                (rest if n in names or len(batch) >= 60 else batch).append(p)
                names.add(n)
            out = os.path.join(root, "b%04d" % len([d for d in os.listdir(root) if d.startswith("b")]))
            os.makedirs(out, exist_ok=True)
            B.MATS = out
            B.dump_materials(set(batch))
            for p in batch:
                index[p] = os.path.join(out, os.path.basename(p)[:-7] + ".json")
            json.dump(index, open(idx_path, "w"))
            need = rest
        nxt = set()
        for pkg in todo:
            par = (load(pkg)["properties"].get("Properties", {}).get("Parent") or {}).get("ObjectPath")
            if par:
                nxt.add(B.game_to_pkg(par))
        todo = {p for p in nxt if p not in cache}
    out = {}
    for p in leaf_paths:
        chain, pkg = [], B.game_to_pkg(p)
        while pkg:
            m = load(pkg)
            chain.append(m)
            par = (m["properties"].get("Properties", {}).get("Parent") or {}).get("ObjectPath")
            pkg = B.game_to_pkg(par) if par else None
        out[p] = chain
    return out


def resolve_materials(paths, build):
    """{material object path: resolved entry} through the MI chain (tools/shaders/build_flesh_materials.py helpers)."""
    B.BUILD = build
    chains = material_chains(sorted(paths), build)
    out, masters = {}, {}
    for p, chain in chains.items():
        master = chain[-1]
        mprops = master["properties"].get("Properties", {})
        ref = [(t or {}).get("ObjectPath") for t in (mprops.get("CachedExpressionData") or {}).get("ReferencedTextures", [])]
        owner, sm = B.effective_map(chain)
        ov = B.mi_overrides(chain)
        used_tex, used_vec = {}, {}
        if sm:
            ues = sm["Content"]["MaterialCompilationOutput"]["UniformExpressionSet"]
            for x in ues["UniformTextureParameters"][0]:
                if x["ParameterName"]:
                    used_tex[x["ParameterName"]] = ref[x["TextureIndex"]] if x["TextureIndex"] < len(ref) else None
            for x in ues["UniformVectorParameters"]:
                d = x["DefaultValue"]
                used_vec[x["ParameterName"]] = [d["R"], d["G"], d["B"], d["A"]]
        tex = {n: v for n, v in used_tex.items()}
        for n, (v, _src) in ov["textures"].items():
            if n in used_tex or not used_tex:
                tex[n] = v
        entry = {"name": B.short(p), "path": p, "chain": [m["export"] for m in chain], "master": master["export"],
                 "render": {k: v["value"] for k, v in B.render_settings(chain).items()},
                 "textures": {}, "texture_params": sorted(tex), "texture_values": tex, "switches": {k: v[0] for k, v in ov["switches"].items()},
                 "scalars": {k: v[0] for k, v in ov["scalars"].items()}, "vectors": {**used_vec, **{k: v[0] for k, v in ov["vectors"].items()}}}
        for slot, names in SLOT_PARAMS.items():
            for n in names:
                if tex.get(n):
                    entry["textures"][slot] = tex[n]
                    break
        masters.setdefault(entry["master"], set()).update(tex)
        out[p] = entry
    return out, masters


# --- spawn origin: open, flat floor from the real triangles ---------------------------------------------------------
CELL, SPACING, BAND = 25.0, 12.0, (15.0, 220.0)


def surface_samples(tris):
    """Points every <= SPACING cm over each triangle (barycentric grid) -> (points (n,3), triangle |normal.z| per point)."""
    e1, e2 = tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]
    nrm = np.cross(e1, e2)
    ln = np.linalg.norm(nrm, axis=1)
    keep = ln > 1e-6
    tris, e1, e2, nz = tris[keep], e1[keep], e2[keep], np.abs(nrm[keep, 2]) / ln[keep]
    longest = np.maximum(np.maximum(np.linalg.norm(e1, axis=1), np.linalg.norm(e2, axis=1)), np.linalg.norm(e2 - e1, axis=1))
    k = np.maximum(1, np.ceil(longest / SPACING)).astype(int)
    pts, flat = [], []
    for kk in np.unique(k):
        sel = k == kk
        ij = np.array([(i, j) for i in range(kk + 1) for j in range(kk + 1 - i)], float) / kk
        p = tris[sel, 0][:, None, :] + ij[None, :, 0:1] * e1[sel][:, None, :] + ij[None, :, 1:2] * e2[sel][:, None, :]
        pts.append(p.reshape(-1, 3))
        flat.append(np.repeat(nz[sel], len(ij)))
    return np.concatenate(pts), np.concatenate(flat)


# Clear floor the tests need (m, long x short): Dani at Godot +Z 6, the zombie ring (radius 5 around -Z 4) and the
# flesh suite's cameras within +-4.5 m of X. Tried in order; the first size that fits anywhere in the window wins.
# A wide-enough area ranks before a long narrow one: the cameras sit at X +-3.6 m, the spawn ring at +-5 m.
# (12 x 7.5 m covers the flesh suite's own footprint: cameras / zombies within X +-3.6 m, Z -5.5 .. +6 m.)
SPAWN_NEED = [(16.0, 9.0), (14.0, 8.0), (12.0, 9.0), (12.0, 7.5), (16.0, 6.5), (12.0, 6.0)]


SPAWN_MARGIN = [8.0, 5.0, 3.0]  # m of loaded floor required around the rectangle, tried in order


def eroded(mask, r):
    """True where every cell within +-r cells is True (box erosion via an integral image)."""
    if r <= 0:
        return mask.copy()
    ii = np.pad(mask.astype(np.int32), ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    n0, n1 = mask.shape
    out = np.zeros_like(mask)
    i0, i1 = np.arange(n0) - r, np.arange(n0) + r + 1
    j0, j1 = np.arange(n1) - r, np.arange(n1) + r + 1
    ok_i = (i0 >= 0) & (i1 <= n0)
    ok_j = (j0 >= 0) & (j1 <= n1)
    I0, I1 = np.clip(i0, 0, n0), np.clip(i1, 0, n0)
    J0, J1 = np.clip(j0, 0, n1), np.clip(j1, 0, n1)
    box = ii[I1][:, J1] - ii[I0][:, J1] - ii[I1][:, J0] + ii[I0][:, J0]
    out = (box == (2 * r + 1) ** 2) & ok_i[:, None] & ok_j[None, :]
    return out


def max_rect_min(grid, min_rows, min_cols):
    """Largest all-True rectangle with at least min_rows x min_cols cells: (area, row0, col0, rows, cols), area 0 if none.
    Histogram method; every maximal rectangle is visited, so the constrained maximum is exact."""
    h = np.zeros(grid.shape[1], int)
    best = (0, 0, 0, 0, 0)
    for r in range(grid.shape[0]):
        h = np.where(grid[r], h + 1, 0)
        stack = []
        for c in range(len(h) + 1):
            cur = h[c] if c < len(h) else 0
            start = c
            while stack and stack[-1][1] >= cur:
                s0, hh = stack.pop()
                w = c - s0
                if hh >= min_rows and w >= min_cols and hh * w > best[0]:
                    best = (hh * w, r - hh + 1, s0, hh, w)
                start = s0
            stack.append((start, cur))
    return best


def find_spawn(places, glb_tris, cfg):
    """Largest clear flat floor rectangle near the seed: floor = highest near-horizontal surface (|n.z| > 0.7) within
    +-300 cm of the seed height per cell; a cell is clear when nothing lies BAND above its floor and its floor is within
    20 cm of the seed area's dominant floor height. Returns (origin UE cm, yaw deg, (len_y, len_x) m, report)."""
    seed = np.array(cfg["seed"], float)
    half = min(cfg["extent"]) - 300.0
    n = int(2 * half / CELL)
    x0, y0 = seed[0] - half, seed[1] - half
    chunks = []
    for c in places:
        t = glb_tris.get(c["mesh"])
        if t is None or (c["hidden"] and not c["collision"]):
            continue
        w = (np.c_[t[:, [0, 2, 1]], np.ones(len(t))] @ c["world"])[:, :3].reshape(-1, 3, 3)
        lo, hi = w.min(1), w.max(1)
        sel = (hi[:, 0] > x0) & (lo[:, 0] < x0 + 2 * half) & (hi[:, 1] > y0) & (lo[:, 1] < y0 + 2 * half) & \
              (hi[:, 2] > seed[2] - 300) & (lo[:, 2] < seed[2] + 300 + BAND[1])
        if sel.any():
            chunks.append(w[sel])
    pts, flat = surface_samples(np.concatenate(chunks))
    ci = ((pts[:, 0] - x0) // CELL).astype(int)
    cj = ((pts[:, 1] - y0) // CELL).astype(int)
    inside = (ci >= 0) & (ci < n) & (cj >= 0) & (cj < n)
    pts, flat, ci, cj = pts[inside], flat[inside], ci[inside], cj[inside]
    floor = np.full((n, n), -1e9)
    fl = (flat > 0.7) & (pts[:, 2] < seed[2] + 300) & (pts[:, 2] > seed[2] - 300)
    np.maximum.at(floor, (ci[fl], cj[fl]), pts[fl, 2])
    has_floor = floor > -1e8
    rel = pts[:, 2] - floor[ci, cj]
    blocked = np.zeros((n, n), bool)
    b = has_floor[ci, cj] & (rel > BAND[0]) & (rel < BAND[1])
    blocked[ci[b], cj[b]] = True
    # Per floor height (40 cm buckets over the whole window: a road's camber and kerbs stay in one bucket), the largest
    # clear rectangle; the biggest one wins. The spawn floor height is that rectangle's median floor.
    hz = np.round(floor[has_floor] / 40) * 40
    vals, cnt = np.unique(hz, return_counts=True)
    best = None
    for margin in SPAWN_MARGIN:
        # floor all around (DI2 geometry the build loads): the tests' cameras must not look past the map's edge
        support = eroded(has_floor, int(margin * 100 / CELL))
        for zb in vals[np.argsort(-cnt)][:8]:
            okb = has_floor & ~blocked & (np.abs(floor - zb) <= 40) & support
            for rank, need in enumerate(SPAWN_NEED):
                for mr, mc in ((need[1], need[0]), (need[0], need[1])):   # long side along UE Y (yaw 0) or UE X (yaw 90)
                    area, r0, c0_, rows, cols = max_rect_min(okb, int(mr * 100 / CELL), int(mc * 100 / CELL))
                    if area and (best is None or (rank, -area) < (best[7], -best[0])):
                        best = (area, r0, c0_, rows, cols, float(zb), okb, rank, margin)
        if best is not None:
            break
    if best is None:
        raise RuntimeError("no clear floor rectangle of %s m in the search window" % (SPAWN_NEED[-1],))
    area, r0, c0_, rows, cols, zb, ok, _rank, margin = best
    zref = float(np.median(floor[r0:r0 + rows, c0_:c0_ + cols]))
    cx = x0 + (r0 + rows / 2) * CELL
    cy = y0 + (c0_ + cols / 2) * CELL
    len_x, len_y = rows * CELL / 100, cols * CELL / 100
    yaw = 0.0 if len_y >= len_x else 90.0
    report = {"seed": seed.tolist(), "floor_z": zref, "rect_ue": [float(x0 + r0 * CELL), float(y0 + c0_ * CELL),
              float(x0 + (r0 + rows) * CELL), float(y0 + (c0_ + cols) * CELL)],
              "size_m": [float(len_x), float(len_y)], "floor_margin_m": margin, "clear_cells": int(ok.sum()), "samples": int(len(pts))}
    return [float(cx), float(cy), zref], yaw, report, (floor, blocked, ok, x0, y0)


def load_tris(places, build):
    """{mesh object path: LOD0 triangles (n*3, 3) in UE cm, glTF axes} for the placements, exporting missing glbs."""
    todo = sorted({canon(mesh_info(c["mesh"])["pkg"]) for c in places if not os.path.exists(glb_path(build, mesh_info(c["mesh"])))})
    if todo:
        ml, tl = os.path.join(build, "search_meshes.txt"), os.path.join(build, "search_textures.txt")
        open(ml, "w").write("\n".join(todo))
        open(tl, "w").write("")
        meta_path = os.path.join(build, "mips", "meta.json")
        keep = open(meta_path).read() if os.path.exists(meta_path) else None
        print("search: exporting %d meshes" % len(todo))
        run([MAPX, ROOT, ml, tl, build])
        if keep is not None:  # mapx rewrites meta.json; no textures were dumped here
            open(meta_path, "w").write(keep)
    out = {}
    for c in places:
        if c["mesh"] in out:
            continue
        glb = glb_path(build, mesh_info(c["mesh"]))
        out[c["mesh"]] = None
        if os.path.exists(glb):
            g = Glb(glb)
            tris = [g.accessor(p["attributes"]["POSITION"])[g.accessor(p["indices"]).reshape(-1)] for _a, _b, _m, p in g.primitives()]
            out[c["mesh"]] = np.concatenate(tris) * 100.0 if tris else None
    return out


def search_seeds(cfg, build):
    """Run find_spawn around every cfg["seeds"] point; pin cfg origin / yaw / seed to the best (largest SPAWN_NEED
    size that fits, then area)."""
    best = None
    for seed in cfg["seeds"]:
        c2 = dict(cfg, seed=seed, origin=None)
        places = gather(c2)
        try:
            spawn, yaw, report, grids = find_spawn(places, load_tris(places, build), c2)
        except RuntimeError as err:
            print("seed %s: %s" % (seed, err))
            continue
        need = (SPAWN_MARGIN.index(report["floor_margin_m"]),
                next((i for i, n in enumerate(SPAWN_NEED) if min(report["size_m"]) >= n[1] and max(report["size_m"]) >= n[0]), 99))
        area = report["size_m"][0] * report["size_m"][1]
        print("seed %s: %s m at %s, yaw %.0f, floor margin %.0f m" % (seed, report["size_m"], [round(v) for v in spawn], yaw,
                                                                    report["floor_margin_m"]))
        if best is None or (need, -area) < (best[0], -best[1]):
            best = (need, area, seed, spawn, yaw, report, grids)
    _need, _area, seed, spawn, yaw, report, grids = best
    cfg["seed"], cfg["origin"], cfg["yaw"] = seed, spawn, yaw
    save_spawn_png(grids, report["rect_ue"], os.path.join(build, "spawn_area.png"))
    cfg["_search_report"] = report
    print("best spawn: seed %s, %s m, origin %s, yaw %.0f" % (seed, report["size_m"], spawn, yaw))


def save_spawn_png(grids, rect, path):
    from PIL import Image, ImageDraw
    floor, blocked, ok, x0, y0 = grids
    n = floor.shape[0]
    img = np.zeros((n, n, 3), np.uint8)
    img[floor > -1e8] = (70, 70, 70)
    img[ok] = (40, 120, 40)
    img[blocked] = (200, 30, 30)
    im = Image.fromarray(img.transpose(1, 0, 2)).resize((n * 2, n * 2), Image.NEAREST)
    d = ImageDraw.Draw(im)
    d.rectangle([(rect[0] - x0) / CELL * 2, (rect[1] - y0) / CELL * 2, (rect[2] - x0) / CELL * 2, (rect[3] - y0) / CELL * 2], outline=(255, 255, 0))
    im.save(path)


# --- level settings ------------------------------------------------------------------------------------------------
# Pre-exposure (UE's View.PreExposure): the scene buffer holds luminance * P; DI2's eye adaptation and tonemap run on
# it at runtime (game/scripts/di2_post.gd, tools/test_map/post.py) and divide P out again, so P only sets the HDR
# buffer's range. P = DI2's exposure at the AutoExposureMaxBrightness clamp without compensation: 0.18 / (1.2 * 2^EV100)
# (EV100 luminance 1.2 * 2^EV: r.EyeAdaptation.LensAttenuation 0.65, ExtendDefaultLuminanceRange=True; middle grey
# 0.18 from DI2's eye-adaptation shader). Godot's lights are unitless with Lambert's 1/pi folded in, so a UE
# illuminance E (lux) becomes energy E * P / pi and a sky radiance L (cd/m2 scale) becomes L * P.
LIGHT_TYPES = {"DirectionalLightComponent": "directional", "PointLightComponent": "point", "SpotLightComponent": "spot",
               "RectLightComponent": "rect", "SkyLightComponent": "sky"}


def plain(v):
    """JSON-safe copy of a property value without object references' noise."""
    if isinstance(v, dict) and "ObjectPath" in v:
        return v["ObjectPath"]
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    if isinstance(v, list):
        return [plain(x) for x in v]
    return v


def level_settings(cfg):
    """Everything the lighting / settings packages place: time of day, lights, fog, post-process volumes, fluid params."""
    out = {"time_of_day": [], "lights": [], "fog": [], "post_process": [], "fluid_params": [], "world_settings": []}
    o = np.array(cfg.get("origin") or cfg["seed"], float)
    ext = np.array(cfg["extent"], float)
    for pkg in dict.fromkeys(cfg.get("lighting", []) + cfg["levels"]):  # a tile may be in both lists
        lv = L.Level(pkg)
        for i, e in enumerate(lv.exports):
            t = e.get("Type", "")
            p = e.get("Properties") or {}
            if "TimeOfDay" in t:
                keep = {k: plain(v) for k, v in p.items() if not isinstance(v, dict) or "ObjectPath" not in v or "Sky" in k}
                keep.pop("BlueprintCreatedComponents", None)
                out["time_of_day"].append({"level": lv.name, "actor": e["Name"], "class": t, "properties": keep})
                # The actor's PostProcessComponent keeps its class template's settings (the level instance stores none):
                # /Game/DSCore/Lighting/BP_BasicTimeOfDay NODE_AddPostProcessComponent-3, unbound, priority 0.
                bp = "DeadIsland/Content/DSCore/Lighting/%s.uasset" % t.removesuffix("_C")
                try:
                    for te in L.package_json(bp):
                        if te.get("Type") == "PostProcessComponent" and (te.get("Properties") or {}).get("Settings"):
                            tp = te["Properties"]
                            out["post_process"].append({"level": lv.name, "actor": e["Name"] + " (" + te["Name"] + ", class template)",
                                                        "priority": tp.get("Priority", 0.0), "unbound": tp.get("bUnbound", True),
                                                        "enabled": tp.get("bEnabled", True), "blend_radius": None,
                                                        "blend_weight": tp.get("BlendWeight", 1.0), "settings": plain(tp["Settings"])})
                except FileNotFoundError:
                    print("   time of day class %s: no JSON dump (%s)" % (t, bp))
            elif t in LIGHT_TYPES:
                w = lv.world(i)
                pos = w[3, :3]
                if LIGHT_TYPES[t] in ("point", "spot", "rect") and (np.abs(pos[:2] - o[:2]) > ext[:2] + 2000).any():
                    continue
                out["lights"].append({"level": lv.name, "component": e["Name"], "owner": (lv.owner(e) or {}).get("Name"),
                                      "kind": LIGHT_TYPES[t], "world_rows": w[:3, :3].tolist(), "location": pos.tolist(),
                                      "properties": {k: plain(v) for k, v in p.items() if k not in ("AttachParent", "LightGuid", "UCSModifiedProperties")}})
            elif t == "ExponentialHeightFogComponent":
                out["fog"].append({"level": lv.name, "component": e["Name"], "properties": {k: plain(v) for k, v in p.items() if k != "AttachParent"}})
            elif t in ("PostProcessVolume", "PostProcessComponent") and p.get("Settings"):
                out["post_process"].append({"level": lv.name, "actor": e["Name"], "priority": p.get("Priority", 0.0),
                                            "unbound": p.get("bUnbound", False), "enabled": p.get("bEnabled", True),
                                            "blend_radius": p.get("BlendRadius"), "blend_weight": p.get("BlendWeight", 1.0),
                                            "settings": plain(p["Settings"])})
            elif "FluidParams" in t:
                out["fluid_params"].append({"level": lv.name, "actor": e["Name"], "class": t, "properties": plain(p)})
            elif t == "DIWorldSettings" and lv.name in [os.path.splitext(os.path.basename(x))[0] for x in cfg.get("lighting", [])]:
                out["world_settings"].append({"level": lv.name, "properties": {k: plain(v) for k, v in p.items() if not isinstance(v, list)}})
    return out


def sun_and_sky(settings, cfg):
    """Godot lights + environment from the time-of-day actor (see the exposure note above)."""
    pp = [v for v in settings["post_process"] if v["unbound"] and v["enabled"]]
    pp.sort(key=lambda v: v["priority"])
    ev = None
    for v in pp:  # higher priority last, so it wins
        s = v["settings"]
        if "AutoExposureMaxBrightness" in s:
            ev = s["AutoExposureMaxBrightness"]
    exposure = 0.18 / (P.LUMINANCE_MAX * 2.0 ** ev) if ev is not None else None
    lights, env = [], {"ev100": ev, "pre_exposure": exposure}
    r, _o = map_xform(cfg)
    for l in settings["lights"]:
        if l["kind"] != "directional":
            continue
        fwd = np.array(l["world_rows"][0])
        d = r @ L.dir_to_godot(fwd / np.linalg.norm(fwd))
        z = -d
        up = np.array([0.0, 1.0, 0.0]) if abs(z[1]) < 0.99 else np.array([1.0, 0.0, 0.0])
        x = np.cross(up, z); x /= np.linalg.norm(x)
        y = np.cross(z, x)
        lux = l["properties"].get("Intensity", 10.0)  # UDirectionalLightComponent default 10 lux
        tpl = P.component_template(l["owner"], l["component"]) if l.get("owner") else {}
        temp = l["properties"].get("Temperature", tpl.get("Temperature"))
        color = P.temperature_color(temp) if temp and tpl.get("bUseTemperature") else [1.0, 1.0, 1.0]
        lights.append({"kind": "directional", "name": "Sun_" + l["component"], "lux": lux, "temperature": temp,
                       "energy": lux * exposure / math.pi if exposure else 1.0, "color": color, "shadow": True,
                       "xform": [*x, *y, *z, 0.0, 0.0, 0.0], **P.sun_shadows(tpl)})
    tod = settings["time_of_day"][0]["properties"] if settings["time_of_day"] else {}
    if settings["time_of_day"]:
        env["fog"] = P.height_fog(settings["time_of_day"][0], cfg)
    if tod.get("SkyTexture"):
        env["sky_texture"] = tod["SkyTexture"]
        env["sky_brightness"] = tod.get("Sky Brightness")
        env["sky_energy"] = tod.get("Sky Brightness", 1.0) * exposure if exposure else 1.0
    return lights, env


# --- HLOD proxies -----------------------------------------------------------------------------------------------------
HLOD_TEX_NAME = {}  # texture object path inside an HLOD package -> its export name (the mips file mapx writes)
HLOD_SLOTS = {"albedo": "DiffuseTexture", "normal": "NormalTexture", "mro": "PackedTexture"}


def hlod_materials(paths):
    """Resolved entries (resolve_materials' shape) for the flattened MIs cooked into <Level>_<n>_HLOD packages: each is a
    MaterialInstanceConstant of /Game/DIShared/Core/Materials/LOD/M_HLODBaseFlatten whose DiffuseTexture /
    NormalTexture / PackedTexture are textures of the same package (T_HLOD_<cluster>_D / _N / _MRO: PackedTexture is
    read as DI2's usual MRO packing, after its _MRO name; the master's shader is not decompiled, UNVERIFIED #111)."""
    out = {}
    for path in sorted(paths):
        pk = L.game_path_pkg(path)
        try:
            ex = L.package_json(pk[0])
        except (FileNotFoundError, TypeError):
            continue
        e = ex[pk[1]]
        p = e.get("Properties") or {}
        tex = {}
        for t in p.get("TextureParameterValues") or []:
            ref = t.get("ParameterValue") or {}
            tp = ref.get("ObjectPath")
            ti = L.ref_index(ref)
            if tp and ti is not None and ti < len(ex):
                HLOD_TEX_NAME[tp] = ex[ti]["Name"]
                tex[t["ParameterInfo"]["Name"]] = tp
        bpo = p.get("BasePropertyOverrides") or {}
        master = B.short((p.get("Parent") or {}).get("ObjectPath", "M_HLODBaseFlatten"))
        out[path] = {"name": e["Name"], "path": path, "chain": [e["Name"], master], "master": master,
                     "render": {"BlendMode": bpo.get("BlendMode", "BLEND_Opaque"), "TwoSided": bpo.get("TwoSided", False),
                                "OpacityMaskClipValue": bpo.get("OpacityMaskClipValue", 0.3333)},
                     "textures": {sl: tex[n] for sl, n in HLOD_SLOTS.items() if tex.get(n)}, "texture_params": sorted(tex),
                     "texture_values": tex, "switches": {},
                     "scalars": {x["ParameterInfo"]["Name"]: x.get("ParameterValue") for x in p.get("ScalarParameterValues") or []},
                     "vectors": {}}
    return out


# --- landscape -------------------------------------------------------------------------------------------------------
LAND_LAYER_PARAMS = {"albedo": "Diffuse Colour Map", "normal": "Normal Map", "mro": "Packed MRO Map (see tooltip)",
                     "height": "Heightmap"}  # M_LandscapeLite's per-layer texture parameters ("<k> - <name>", k = 1..5)


def master_defaults(master_json):
    """{name: value} of a master's parameter defaults: CachedExpressionData.Parameters, whose ParameterInfos list the
    scalars, then the vectors, then the textures (Counts: 27 / 10 / 31 in M_LandscapeLite)."""
    pr = master_json["properties"]["Properties"]["CachedExpressionData"]["Parameters"]
    names = [x["Name"] for x in pr["Data"]["ParameterInfos"]]
    sv, vv, tv = pr.get("ScalarValues", []), pr.get("VectorValues", []), pr.get("TextureValues", [])
    out = {}
    for i, n in enumerate(names):
        if i < len(sv):
            out[n] = sv[i]
        elif i < len(sv) + len(vv):
            v = vv[i - len(sv)]
            out[n] = [v["R"], v["G"], v["B"], v["A"]]
        elif i - len(sv) - len(vv) < len(tv):
            out[n] = (tv[i - len(sv) - len(vv)] or {}).get("ObjectPath")
    return out


def landscape_materials(cfg, build):
    """{landscape material path: record} for cfg["terrain"]'s Landscape actors: per layer k = 1..5 the texture paths
    and the scalars / vectors the master reads, MI overrides over the master defaults (tools/shaders helpers)."""
    mats = set()
    for pkg in cfg.get("terrain", []):
        for e in L.Level(pkg).exports:
            if e.get("Type") == "Landscape":
                m = ((e.get("Properties") or {}).get("LandscapeMaterial") or {}).get("ObjectPath")
                if m:
                    mats.add(m)
    chains = material_chains(sorted(mats), build)
    out = {}
    for p, chain in chains.items():
        vals = master_defaults(chain[-1])
        ov = B.mi_overrides(chain)
        for kind in ("textures", "scalars", "vectors"):
            for n, (v, _src) in ov[kind].items():
                vals[n] = v
        layers = []
        for k in range(1, 6):
            lay = {s: vals.get("%d - %s" % (k, n)) for s, n in LAND_LAYER_PARAMS.items()}
            for n in ("Diffuse Colour Tint", "Height Blend Influence", "Roughness Adjustment", "Displacement Amount",
                      "Subsurface Colour", "Surface Translucency Adjustment", "Subsurface Material Density"):
                lay[n] = vals.get("%d - %s" % (k, n))
            layers.append(lay)
        out[p] = {"master": chain[-1]["export"], "chain": [m["export"] for m in chain], "layers": layers,
                  "tiling_cm": vals.get("Texture Tiling (in cm)"), "macro_tiling_cm": vals.get("Macro Texture Tiling (in cm)"),
                  "switches": {k: v[0] for k, v in ov["switches"].items()}}
    return out


def landscape_build(cfg, build, blob, meshes, groups, col, materials, land_mats, dds):
    """Append the landscape components of cfg["terrain"] as meshes + identity groups + collision triangles.
    Needs tools/test_map/landscape_prep.py's export of the cooked height / weight maps (<build>/terrain/mips)."""
    import landscape as LS
    tdir = os.path.join(build, "terrain")
    meta_path = os.path.join(tdir, "mips", "meta.json")
    if not os.path.exists(meta_path):
        print("landscape: no terrain export (run tools/test_map/landscape_prep.py %s); skipped" % cfg.get("name", ""))
        return [], {"skipped": "no terrain export"}
    meta = {m["name"]: m for m in json.load(open(meta_path))}
    comps = [c for pkg in cfg["terrain"] for c in LS.components(pkg, tdir, meta)]
    layers = sorted({k for c in comps for k in c["weights"]})
    if len(layers) > 5:
        print("landscape: %d layers, only 5 fit COLOR + UV2.x: %s" % (len(layers), layers))
    mat_ids = {}
    r, _o = map_xform(cfg)
    tris_total = 0
    for c in comps:
        lm = c["landscape_material"]
        if lm not in mat_ids:
            mat_ids[lm] = len(materials)
            rec = land_mats.get(lm) or {}
            mlayers = [dict({k: v for k, v in lay.items() if k not in LAND_LAYER_PARAMS},
                           textures={sl: dds(lay[sl]) for sl in LAND_LAYER_PARAMS if lay.get(sl) and dds(lay[sl])})
                      for lay in rec.get("layers", [])]
            materials.append({"name": B.short(lm) if lm else "landscape", "shader": "landscape", "master": rec.get("master", "?"),
                              "path": lm, "layers": mlayers, "tiling_cm": rec.get("tiling_cm"),
                              "macro_tiling_cm": rec.get("macro_tiling_cm"), "switches": rec.get("switches", {})})
        g = c["grid"]
        n = g.shape[0]
        pos = (r @ (L.P @ ((g.reshape(-1, 3) - _o) * 0.01).T)).T.astype(np.float32)  # = godot_point, vectorised
        nrm = (r @ (L.P @ LS.grid_normals(g).reshape(-1, 3).T)).T.astype(np.float32)
        tu = (r @ (L.P @ np.gradient(g, axis=1).reshape(-1, 3).T)).T  # along +quad x (UV u)
        tv = (r @ (L.P @ np.gradient(g, axis=0).reshape(-1, 3).T)).T  # along +quad y (UV v)
        tu /= np.maximum(np.linalg.norm(tu, axis=1, keepdims=True), 1e-9)
        w = np.sign(np.einsum("ij,ij->i", np.cross(nrm, tu), tv))  # Godot: binormal = cross(normal, tangent) * w
        tan = np.c_[tu, np.where(w == 0, 1.0, w)].astype(np.float32)
        idx = LS.triangles(n, c["hole"])
        if not len(idx):
            continue
        t0 = pos[idx[0]]
        if np.cross(t0[1] - t0[0], t0[2] - t0[0])[1] > 0:  # Godot front faces are clockwise: up-facing needs y < 0
            idx = idx[:, [0, 2, 1]]
        wts = np.zeros((n * n, 5), np.float32)
        for k, nm in enumerate(layers[:5]):
            if nm in c["weights"]:
                wts[:, k] = c["weights"][nm].reshape(-1)
        arrays = {"vertex": blob.add(var_packed(VT_VEC3, pos)), "normal": blob.add(var_packed(VT_VEC3, nrm)),
                  "tangent": blob.add(var_packed(VT_FLOAT32, tan)), "index": blob.add(var_packed(VT_INT32, idx.reshape(-1))),
                  # DI2 maps the layers by absolute world XY (cm) / "Texture Tiling (in cm)" (PS 26989: r4.xy)
                  "uv": blob.add(var_packed(VT_VEC2, g[..., :2].reshape(-1, 2))),
                  "uv2": blob.add(var_packed(VT_VEC2, np.c_[wts[:, 4], np.zeros(n * n)])),
                  "color": blob.add(var_packed(VT_COLOR, wts[:, :4]))}
        mi = len(meshes)
        meshes.append({"name": "%s_%s" % (c["landscape"], c["component"]), "surfaces": [{"slot": 0, "slot_name": "landscape", "arrays": arrays}]})
        cell = tuple(np.floor(pos.mean(0)[[0, 2]] / cfg["cell"]).astype(int).tolist()) if cfg.get("cell") else None
        groups[(mi, (mat_ids[c["landscape_material"]],), True, ("cell", cell, None))] = [np.c_[np.eye(3), np.zeros(3)].reshape(-1)]
        col["trimesh"].append(pos[idx.reshape(-1)].astype(float))
        col["trimesh_cell"].append(cell)
        col["counts"]["landscape"] = col["counts"].get("landscape", 0) + 1
        tris_total += len(idx)
    print("landscape: %d components, %d triangles, layers %s, materials %s" % (len(comps), tris_total, layers, list(mat_ids)))
    return layers[:5], {"components": len(comps), "triangles": tris_total}


# --- main ----------------------------------------------------------------------------------------------------------

def run(cmd, **kw):
    r = subprocess.run(cmd, env=ENV, capture_output=True, text=True, **kw)
    if r.returncode:
        raise RuntimeError("%s failed:\n%s\n%s" % (cmd[0], r.stdout[-3000:], r.stderr[-3000:]))
    return r.stdout


def ensure_mesh_json(object_paths):
    missing = sorted({os.path.basename(B.game_to_pkg(p))[:-7] for p in object_paths
                      if not os.path.exists(os.path.join(L.JSON_ROOT, B.game_to_pkg(p)[:-7] + ".json"))})
    if missing:
        lst = os.path.join(ROOT, "extracted", "test_map", "mesh_json_missing.txt")
        open(lst, "w").write("\n".join(missing))
        print("dumping %d mesh JSONs" % len(missing))
        run([DI2X, "json", "@" + lst])
        _MESH_INFO.clear()


def main(name):
    cfg = MAPS[name]
    build = os.path.join(ROOT, "extracted", "test_map", name)
    out_dir = os.path.join(ROOT, "game", "assets", "di2", "maps", name)
    os.makedirs(os.path.join(out_dir, "textures"), exist_ok=True)
    open(os.path.join(out_dir, ".gdignore"), "w").close()

    # 1. placements in the cull box
    comps = []
    for pkg in cfg["levels"]:
        comps += [c["mesh"] for c in L.mesh_components(L.Level(pkg))]
    ensure_mesh_json(set(comps))
    if not cfg.get("origin") and cfg.get("seeds"):
        search_seeds(cfg, build)
    places = gather(cfg)
    print("%d placements in the cull box" % len(places))

    # 2. materials per placement slot
    def slot_materials(c, info):
        mats = []
        for i, (_slot, mp) in enumerate(info["slots"]):
            ov = c["overrides"][i] if i < len(c["overrides"]) else None
            mats.append(ov or mp)
        return mats

    all_mats = set()
    for c in places:
        info = mesh_info(c["mesh"])
        all_mats.update(m for m in slot_materials(c, info) if m)
    hlod_mats = {m for m in all_mats if m.split(".")[0].endswith("_HLOD")}  # flattened HLOD proxy MIs (hlod_materials)
    resolved, masters = resolve_materials(all_mats - hlod_mats, build)
    resolved.update(hlod_materials(hlod_mats))
    for m, params in sorted(masters.items()):
        hit = {s for s, names in SLOT_PARAMS.items() if any(n in params for n in names)}
        print("master %-40s base maps %-22s params %s" % (m, ",".join(sorted(hit)) or "-", sorted(params)[:12]))

    # 3. level settings, then export meshes + texture mips
    settings = level_settings(cfg)
    lights, env = sun_and_sky(settings, dict(cfg, origin=cfg.get("origin") or cfg["seed"], yaw=0.0))
    print("settings: %d time-of-day, %d lights, %d fog, %d post-process, %d fluid params; env %s" % (
        len(settings["time_of_day"]), len(settings["lights"]), len(settings["fog"]), len(settings["post_process"]),
        len(settings["fluid_params"]), env))
    _eff, post = P.block(settings)
    lut_tex = post["effective"].get("ColorGradingLUT")
    mesh_pkgs = sorted({canon(mesh_info(c["mesh"])["pkg"]) for c in places})
    land_mats = landscape_materials(cfg, build) if cfg.get("terrain") else {}
    land_tex = {lay[sl] for r in land_mats.values() for lay in r["layers"] for sl in LAND_LAYER_PARAMS if lay.get(sl)}
    tex_paths = sorted({t for e in resolved.values() for t in e["textures"].values() if t} | ({env["sky_texture"]} if env.get("sky_texture") else set())
                       | ({lut_tex} if lut_tex else set()) | land_tex)
    tex_pkgs = sorted({canon(B.game_to_pkg(t)) for t in tex_paths})
    ml, tl = os.path.join(build, "meshes.txt"), os.path.join(build, "textures.txt")
    # cache: only what an earlier build of this map hasn't exported yet
    meta_path = os.path.join(build, "mips", "meta.json")
    prev_meta = json.load(open(meta_path)) if os.path.exists(meta_path) else []
    have_tex = {m["path"] for m in prev_meta}
    todo_mesh = sorted({canon(mesh_info(c["mesh"])["pkg"]) for c in places if not os.path.exists(glb_path(build, mesh_info(c["mesh"])))})
    todo_tex = [p for p in tex_pkgs if p not in have_tex]
    open(ml, "w").write("\n".join(todo_mesh))
    open(tl, "w").write("\n".join(todo_tex))
    print("mapx: %d meshes, %d textures (%d / %d cached)" % (len(todo_mesh), len(todo_tex),
                                                           len(mesh_pkgs) - len(todo_mesh), len(tex_pkgs) - len(todo_tex)))
    if todo_mesh or todo_tex:
        log = run([MAPX, ROOT, ml, tl, build])
        fails = [l for l in log.splitlines() if l.startswith("FAIL")]
        if fails:
            print("\n".join(fails[:20]))
        new_meta = json.load(open(meta_path)) if os.path.exists(meta_path) else []
        names = {m["name"] for m in new_meta}
        json.dump(new_meta + [m for m in prev_meta if m["name"] not in names], open(meta_path, "w"))

    # 4. textures -> DDS, written on first use (only what the kept geometry's materials reference)
    meta = {m["name"]: m for m in json.load(open(os.path.join(build, "mips", "meta.json")))}
    meta_ci = {k.lower(): v for k, v in meta.items()}
    tex_dir = os.path.join(out_dir, "textures")
    for f in os.listdir(tex_dir):
        os.remove(os.path.join(tex_dir, f))
    tex_files = {}

    def dds(t):
        if t in tex_files:
            return tex_files[t]
        n = HLOD_TEX_NAME.get(t) or B.short(t)
        m = meta.get(n) or meta_ci.get(n.lower())  # data may reference a texture in another case than the pak
        tex_files[t] = None
        if not m or m["pixel_format"] not in D.DDS_FMT or not m["mips"]:
            print("   texture %s: %s" % (n, "not dumped" if not m else "format %s" % m["pixel_format"]))
            note("texture_missing", t, "not exported by mapx" if not m else "pixel format %s" % m["pixel_format"])
            return None
        k = 0
        while k < len(m["mips"]) - 1 and max(m["mips"][k]["w"], m["mips"][k]["h"]) > TEX_CAP:
            k += 1
        raw = open(os.path.join(build, "mips", n + ".mips"), "rb").read()
        off = sum(x["bytes"] for x in m["mips"][:k])
        D.write_dds(os.path.join(tex_dir, n + ".dds"), m["pixel_format"], m["mips"][k:], raw[off:])
        tex_files[t] = "textures/%s.dds" % n
        return tex_files[t]
    if env.get("sky_texture") and dds(env["sky_texture"]):
        env["sky_file"] = tex_files[env["sky_texture"]]
    # DI2's post chain (tools/test_map/post.py): grading LUT texture, the LUT blender's constants, its GLSL port
    lut_size = 16
    if lut_tex and dds(lut_tex):
        lm = meta[B.short(lut_tex)]
        post["lut_file"], post["lut_srgb"] = tex_files[lut_tex], bool(lm["srgb"])
        lut_size = lm["mips"][0]["h"]
    post["lut_cb0"] = P.lut_cb0(_eff, lut_size)
    post["lut_shader"] = "post_lut.glsl"
    open(os.path.join(out_dir, "post_lut.glsl"), "w").write(P.lut_glsl())
    env["post"] = post

    # 5. meshes (LOD0 glb) -> arrays in memory; triangles for the spawn search
    prims, glb_tris = {}, {}
    for c in places:
        if c["mesh"] in prims:
            continue
        info = mesh_info(c["mesh"])
        glb = glb_path(build, info)
        prims[c["mesh"]] = None
        if not os.path.exists(glb):
            print("   mesh %s: no glb" % info["name"])
            note("mesh_no_glb", c["mesh"], "mapx exported no glb")
            continue
        g = Glb(glb)
        out, tris = [], []
        slot_names = [s for s, _ in info["slots"]]
        for _mi, _pi, mat, prim in g.primitives():
            a = prim["attributes"]
            pos = g.accessor(a["POSITION"])
            idx = g.accessor(prim["indices"]).reshape(-1, 3).astype(np.int32)
            tris.append(pos[idx.reshape(-1)])
            out.append({"slot": slot_names.index(mat) if mat in slot_names else len(out), "slot_name": mat, "pos": pos,
                        "nrm": g.accessor(a["NORMAL"]), "idx": idx,
                        "tan": g.accessor(a["TANGENT"]) if "TANGENT" in a else None,
                        "uv": g.accessor(a["TEXCOORD_0"]) if "TEXCOORD_0" in a else None})
        prims[c["mesh"]] = out
        glb_tris[c["mesh"]] = np.concatenate(tris) * 100.0 if tris else None  # back to UE cm, glTF axes

    # 5b. spawn origin + yaw (pinned by cfg["origin"], else the largest clear floor rectangle near the seed)
    if cfg.get("_search_report"):
        report = cfg["_search_report"]
    elif cfg.get("whole"):
        report = {"pinned": "origin / yaw pinned in MAPS (nh04_street's spawn search result)"}
    else:
        spawn, yaw, report, grids = find_spawn(places, glb_tris, cfg)
        save_spawn_png(grids, report["rect_ue"], os.path.join(build, "spawn_area.png"))
    print("open floor near the seed: %s" % report)
    if not cfg.get("origin"):
        cfg["origin"], cfg["yaw"] = spawn, yaw
    print("spawn origin UE %s, yaw %.0f" % (cfg["origin"], cfg.get("yaw", 0.0)))
    lights, _env = sun_and_sky(settings, cfg)

    # 5c. keep what reaches into origin +- "keep" (the search window is wider), then write the kept meshes
    places = gather(dict(cfg, extent=cfg.get("keep", cfg["extent"])))
    blob = Blob()
    mesh_index, meshes = {}, []
    for c in places:
        if c["mesh"] in mesh_index:
            continue
        pr = prims.get(c["mesh"])
        if not pr:
            mesh_index[c["mesh"]] = -1
            continue
        surfaces = []
        for x in pr:
            # glTF: counter-clockwise front faces; Godot: clockwise (its glTF importer swaps the same way).
            arrays = {"vertex": blob.add(var_packed(VT_VEC3, x["pos"])), "normal": blob.add(var_packed(VT_VEC3, x["nrm"])),
                      "index": blob.add(var_packed(VT_INT32, x["idx"][:, [0, 2, 1]].reshape(-1)))}
            if x["tan"] is not None:
                arrays["tangent"] = blob.add(var_packed(VT_FLOAT32, x["tan"]))
            if x["uv"] is not None:
                arrays["uv"] = blob.add(var_packed(VT_VEC2, x["uv"]))
            surfaces.append({"slot": x["slot"], "slot_name": x["slot_name"], "arrays": arrays})
        mesh_index[c["mesh"]] = len(meshes)
        meshes.append({"name": mesh_info(c["mesh"])["name"], "surfaces": surfaces})
    print("%d placements kept around the spawn" % len(places))
    # areas (one per level package) for the whole-map test's fixed cameras and bot waypoints: the 5..95 % box of the
    # level's placement origins in Godot space (game/scripts/autotest_map_walk.gd)
    by_level = {}
    for c in places:
        if not c["hidden"]:
            by_level.setdefault(c["level"], []).append(godot_xform(c["world"], cfg)[1])
    areas = []
    for lvl, pts in sorted(by_level.items()):
        pts = np.array(pts)
        lo, hi = np.percentile(pts, 5, axis=0), np.percentile(pts, 95, axis=0)
        areas.append({"name": lvl, "center": ((lo + hi) / 2).tolist(), "size": (hi - lo).tolist(), "count": len(pts)})

    # 6. materials table
    mat_index, materials = {}, []

    def material_id(path):
        if not path or path not in resolved:
            note("material_unresolved", str(path), "no material in the slot" if not path else "MI chain not resolved")
            return -1
        if path not in mat_index:
            e = resolved[path]
            rs = e["render"]
            blend = str(rs.get("BlendMode", "BLEND_Opaque"))
            shader = "glass" if blend in ("BLEND_Translucent", "BLEND_Additive", "BLEND_Modulate") else \
                "two_sided" if rs.get("TwoSided") else "opaque"
            if e["master"].startswith(SKIP_MASTERS):
                shader = "none"
                note("material_skipped", path, "master %s not drawn (SKIP_MASTERS: mesh decal / cobweb)" % e["master"])
            md = {"name": e["name"], "master": e["master"], "shader": shader, "blend": blend,
                  "masked": blend == "BLEND_Masked", "clip": rs.get("OpacityMaskClipValue", 0.3333),
                  "textures": {s: dds(t) for s, t in e["textures"].items() if shader != "none" and dds(t)},
                  "vectors": e["vectors"], "switches": e["switches"]}
            if shader != "none" and "albedo" not in md["textures"]:
                note("material_approximated", e["master"], "no base colour map among SLOT_PARAMS (master params %s): drawn "
                     "with the default grey and its other base maps" % sorted(e["texture_params"])[:6])
            mat_index[path] = len(materials)
            materials.append(md)
        return mat_index[path]

    # 7. instance groups + collision
    groups, hlod_proxies = {}, {}
    col = {"trimesh": [], "trimesh_cell": [], "convex": [], "spheres": [], "capsules": [],
           "counts": {"trimesh": 0, "box": 0, "convex": 0, "sphere": 0, "capsule": 0}}
    for c in places:
        info = mesh_info(c["mesh"])
        mi = mesh_index.get(c["mesh"], -1)
        if mi >= 0 and not c["hidden"]:
            slot_mats = slot_materials(c, info)
            mats = [material_id(slot_mats[s["slot"]]) if s["slot"] < len(slot_mats) else -1 for s in meshes[mi]["surfaces"]]
            basis, origin = godot_xform(c["world"], cfg)
            # whole maps: one group per cell (cfg["cell"] m, Godot X / Z), so Godot frustum-culls each MultiMesh
            cell = tuple(np.floor(origin[[0, 2]] / cfg["cell"]).astype(int).tolist()) if cfg.get("cell") else None
            # DI2's HLOD (cfg["hlod"]): a proxy is its own group, shown beyond its LODActor's LODDrawDistance; the
            # components it replaces are grouped per proxy and hidden while it shows (Godot visibility_parent)
            if cfg.get("hlod") and c.get("hlod_draw"):
                cluster = ("proxy", c["level"], c["export"])
                hlod_proxies[(c["level"], c["export"])] = (c["hlod_draw"], c.get("lod_parent"))
            elif cfg.get("hlod") and c.get("lod_parent") is not None:
                cluster = ("child", c["level"], c["lod_parent"])
            else:
                cluster = ("cell", cell, c.get("cull_end"))
            key = (mi, tuple(mats), bool(c["cast_shadow"]), cluster)
            groups.setdefault(key, []).append(np.c_[basis, origin].reshape(-1))
        if c["collision"]:
            # glTF axes -> UE axes for the render-mesh triangles (swap back y/z)
            t = glb_tris.get(c["mesh"])
            n_tri = len(col["trimesh"])
            collision_for(c, info, t[:, [0, 2, 1]] if t is not None else None, cfg, col)
            if len(col["trimesh"]) > n_tri:
                o = godot_xform(c["world"], cfg)[1]
                tc = tuple(np.floor(o[[0, 2]] / cfg["cell"]).astype(int).tolist()) if cfg.get("cell") else None
                col["trimesh_cell"] += [tc] * (len(col["trimesh"]) - n_tri)
    # 7b. landscape (cfg["terrain"]): one mesh per LandscapeComponent, vertices already in Godot space (identity
    # instance), layer weights in COLOR (layers 0..3) and UV2.x (layer 4), landscape-local quad coordinates in UV;
    # the heightfield's triangles join the cell collision (tools/test_map/landscape.py)
    land_layers, land_report = [], {}
    if cfg.get("terrain"):
        land_layers, land_report = landscape_build(cfg, build, blob, meshes, groups, col, materials, land_mats, dds)
    group_list = [{"mesh": k[0], "materials": list(k[1]), "shadow": k[2],
                   "xforms": blob.add(var_packed(VT_FLOAT32, np.array(v)))} for k, v in groups.items()]
    # visibility: HLOD proxy ranges / parents (metres), foliage cull distances
    proxy_group = {(k[3][1], k[3][2]): gi for gi, k in enumerate(groups) if k[3] and k[3][0] == "proxy"}
    hlod_stats = {"proxies": len(proxy_group), "child_groups": 0, "orphans": 0}
    for gi, k in enumerate(groups):
        cl = k[3]
        if not cl:
            continue
        if cl[0] == "proxy":
            draw, parent = hlod_proxies[(cl[1], cl[2])]
            group_list[gi]["vis_begin"] = draw / 100.0
            if parent is not None and (cl[1], parent) in proxy_group:
                group_list[gi]["vis_parent"] = proxy_group[(cl[1], parent)]
        elif cl[0] == "child":
            if (cl[1], cl[2]) in proxy_group:
                group_list[gi]["vis_parent"] = proxy_group[(cl[1], cl[2])]
                hlod_stats["child_groups"] += 1
            else:
                hlod_stats["orphans"] += 1
        elif cl[0] == "cell" and cl[2]:
            group_list[gi]["vis_end"] = cl[2] / 100.0
    print("hlod: %s" % hlod_stats)
    collision = {"counts": col["counts"], "spheres": col["spheres"], "capsules": col["capsules"]}
    if col["trimesh"] and cfg.get("cell"):
        # whole maps: one concave shape per cell (an array of face arrays; di2_map.gd takes either form)
        cells = {}
        for t, k in zip(col["trimesh"], col["trimesh_cell"]):
            cells.setdefault(k, []).append(t)
        collision["trimesh"] = blob.add(var_array([var_packed(VT_VEC3, np.concatenate(v).reshape(-1, 3, 3)[:, [0, 2, 1]].reshape(-1, 3))
                                                   for v in cells.values()]))
    elif col["trimesh"]:
        tri = np.concatenate(col["trimesh"])
        tri = tri.reshape(-1, 3, 3)[:, [0, 2, 1]].reshape(-1, 3)  # winding as for the render mesh
        collision["trimesh"] = blob.add(var_packed(VT_VEC3, tri))
    if col["convex"]:
        collision["convex"] = blob.add(var_array([var_packed(VT_VEC3, h) for h in col["convex"]]))

    data = {"version": 1, "name": name, "origin_ue": cfg["origin"], "yaw": cfg.get("yaw", 0.0), "levels": cfg["levels"],
            "spawn_search": report,
            # DI2Fluids' top-down fluid map (game/scripts/di2_fluids.gd map_area / map_heights): centred on the spawn
            # origin at the gore session's 51.2 m (2048 texels at 2.5 cm); heights = this map's cull range around the
            # spawn floor (MAPS[...]["z_range"]), so every surface the build keeps maps into the r channel.
            "fluid_area": {"rect": [-25.6, -25.6, 51.2, 51.2], "heights": [z / 100.0 for z in cfg.get("fluid_z", cfg["z_range"])]},
            "blob": "map.bin", "meshes": meshes, "materials": materials, "groups": group_list, "collision": collision,
            "lights": lights, "environment": env, "decals": [], "level_settings": settings, "areas": areas,
            "landscape": {"layers": land_layers, **land_report}}
    with open(os.path.join(out_dir, "map.bin"), "wb") as f:
        for p in blob.parts:
            f.write(p)
    json.dump(data, open(os.path.join(out_dir, "map.json"), "w"), indent=0)
    json.dump(REPORT, open(os.path.join(out_dir, "build_report.json"), "w"), indent=1)
    print("build report: " + ", ".join("%s %d" % (k, len(v)) for k, v in REPORT.items()))
    print("%s: %d meshes, %d materials, %d groups, %d instances, %d textures, blob %.1f MB, collision %s" % (
        name, len(meshes), len(materials), len(group_list), sum(len(v) for v in groups.values()), len(tex_files),
        blob.size / 1e6, col["counts"]))


if __name__ == "__main__":
    main(sys.argv[1])
