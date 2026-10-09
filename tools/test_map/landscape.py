"""DI2 landscape (ALandscape in a level's *_Terrain sublevel) -> render grids, layer weights and collision triangles.
Personal use; reads the user's own install (CUE4Parse JSON dumps + the cooked height / weight maps that
tools/test_map/mapx exports from the .umap as mips/<Outer>.<Name>.mips).

Facts used (UE 4.27 landscape, checked against NH_04_Terrain's data):
  * LandscapeComponent: SectionBaseX/Y (quads, landscape-local), ComponentSizeQuads 63 with one subsection, attached to
    the Landscape actor's RootComponent (NH_04: scale 50 x 50 x 100 or 50 x 50 x 50, so one quad = 50 cm).
  * HeightmapTexture: PF_B8G8R8A8, height = R * 256 + G (16 bit), local z = (height - 32768) / 128
    (LANDSCAPE_ZSCALE = 1/128), B / A = the packed normal's x / y. Texel of vertex (x, y) = HeightmapScaleBias.ZW * size
    + (x, y); NH_04's components each own a 64 x 64 heightmap (bias 0). CachedLocalBox z (-5.44..-0.26 on component 0)
    is in these local units.
  * WeightmapLayerAllocations[k] = {LayerInfo, WeightmapTextureIndex, WeightmapTextureChannel}: layer k's weight is
    channel C (0 = R, 1 = G, 2 = B, 3 = A) of WeightmapTextures[index] (B8G8R8A8: byte order B G R A), texel = vertex,
    WeightmapScaleBias likewise. The engine's visibility layer (/Engine/EditorLandscapeResources/DataLayer) marks holes
    (weight > 0.5: the quad is not drawn and has no collision; UE uses the cooked hole material).
"""
import json
import os

import numpy as np

import level as L

CHANNEL_BYTE = {0: 2, 1: 1, 2: 0, 3: 3}  # weight channel R, G, B, A -> byte offset in a B8G8R8A8 texel
HOLE_LAYER = "DataLayer"


def _mip0(build, meta, name):
    m = meta.get(name)
    if not m:
        return None
    w, h = m["mips"][0]["w"], m["mips"][0]["h"]
    raw = np.fromfile(os.path.join(build, "mips", name + ".mips"), np.uint8, w * h * 4)
    return raw.reshape(h, w, 4)


_LAYER_NAMES = {}


def layer_name(alloc):
    """The LandscapeLayerInfoObject's LayerName (NH_04: LL_Layer1_LayerInfo and LL_Layer1_LayerInfo_02 are both
    "Layer1", one per landscape actor); the material's layer k ("<k> - ..." parameters) reads layer "Layer<k>"."""
    ref = alloc.get("LayerInfo") or {}
    path = ref.get("ObjectPath", "")
    if path not in _LAYER_NAMES:
        name = L.obj_name(ref) or "?"
        pk = L.game_path_pkg(path)
        if pk:
            try:
                ex = L.package_json(pk[0])
                name = ((ex[pk[1]].get("Properties") or {}).get("LayerName")) or name
            except (FileNotFoundError, IndexError):
                pass
        _LAYER_NAMES[path] = name
    return _LAYER_NAMES[path]


def components(pkg, build, meta):
    """Yield one dict per LandscapeComponent: world grid (n, n, 3) UE cm, layer weights {layer: (n, n)}, hole mask
    (n-1, n-1) per quad, landscape-local quad coordinates (n, n, 2), the landscape actor and its material."""
    lv = L.Level(pkg)
    for i, e in enumerate(lv.exports):
        if e.get("Type") != "LandscapeComponent":
            continue
        p = e.get("Properties") or {}
        owner = lv.owner(e) or {}
        lname = owner.get("Name", "?")
        q = int(p.get("ComponentSizeQuads", 63))
        n = q + 1
        hm_ref = L.obj_name(p.get("HeightmapTexture")) and lv.export(p["HeightmapTexture"])
        if not hm_ref:
            continue
        hm = _mip0(build, meta, "%s.%s" % (lname, hm_ref["Name"]))
        if hm is None:
            print("   landscape %s %s: heightmap %s not exported" % (lname, e["Name"], hm_ref["Name"]))
            continue
        sb = p.get("HeightmapScaleBias") or {}
        ox, oy = int(round(sb.get("Z", 0.0) * hm.shape[1])), int(round(sb.get("W", 0.0) * hm.shape[0]))
        tex = hm[oy:oy + n, ox:ox + n].astype(np.float64)
        z = (tex[..., 2] * 256.0 + tex[..., 1] - 32768.0) / 128.0
        ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
        local = np.stack([xs, ys, z], -1).reshape(-1, 3)
        world = lv.world(i)
        grid = (np.c_[local, np.ones(len(local))] @ world)[:, :3].reshape(n, n, 3)
        weights, hole = {}, np.zeros((q, q), bool)
        wsb = p.get("WeightmapScaleBias") or {}
        wtex = [lv.export(r) for r in p.get("WeightmapTextures") or []]
        for a in p.get("WeightmapLayerAllocations") or []:
            ti, ch = a.get("WeightmapTextureIndex", 0), a.get("WeightmapTextureChannel", 0)
            if ti >= len(wtex) or wtex[ti] is None:
                continue
            wm = _mip0(build, meta, "%s.%s" % (lname, wtex[ti]["Name"]))
            if wm is None:
                print("   landscape %s %s: weightmap %s not exported" % (lname, e["Name"], wtex[ti]["Name"]))
                continue
            wx, wy = int(round(wsb.get("Z", 0.0) * wm.shape[1])), int(round(wsb.get("W", 0.0) * wm.shape[0]))
            w = wm[wy:wy + n, wx:wx + n, CHANNEL_BYTE[ch]].astype(np.float32) / 255.0
            nm = layer_name(a)
            if nm.startswith(HOLE_LAYER):
                # a quad is a hole when its vertices' visibility weight averages above 0.5
                hole = (w[:-1, :-1] + w[1:, :-1] + w[:-1, 1:] + w[1:, 1:]) / 4.0 > 0.5
            else:
                weights[nm] = w
        base = np.array([p.get("SectionBaseX", 0), p.get("SectionBaseY", 0)], float)
        quad_uv = (np.stack([xs, ys], -1) + base).astype(np.float32)
        yield {"landscape": lname, "component": e["Name"], "export": i, "grid": grid, "weights": weights,
               "quad_cm": float(np.linalg.norm(world[0, :3])),  # landscape scale X: cm per quad
               "hole": hole, "quad_uv": quad_uv, "mat_instances": [r.get("ObjectPath") for r in p.get("MaterialInstances") or []],
               "landscape_material": ((owner.get("Properties") or {}).get("LandscapeMaterial") or {}).get("ObjectPath")}


def triangles(n, hole):
    """Index buffer (k, 3) over an n x n vertex grid, UE winding (counter-clockwise seen from +Z in UE's left-handed
    axes = the same order the glTF meshes come in), holes left out."""
    idx = []
    for y in range(n - 1):
        for x in range(n - 1):
            if hole[y, x]:
                continue
            a, b, c, d = y * n + x, y * n + x + 1, (y + 1) * n + x, (y + 1) * n + x + 1
            idx += [(a, d, b), (a, c, d)]
    return np.array(idx, np.int32).reshape(-1, 3)


def grid_normals(grid):
    """Per-vertex normals (UE axes) from central differences of the world grid."""
    gx = np.gradient(grid, axis=1)
    gy = np.gradient(grid, axis=0)
    nrm = np.cross(gx, gy)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=-1, keepdims=True), 1e-9)
    nrm[nrm[..., 2] < 0] *= -1.0
    return nrm


if __name__ == "__main__":  # quick report: python tools/test_map/landscape.py <terrain umap> <build dir>
    import sys
    build = sys.argv[2]
    meta = {m["name"]: m for m in json.load(open(os.path.join(build, "mips", "meta.json")))}
    for c in components(sys.argv[1], build, meta):
        g = c["grid"]
        print(c["landscape"], c["component"], "z %.0f..%.0f" % (g[..., 2].min(), g[..., 2].max()),
              {k: round(float(v.mean()), 2) for k, v in c["weights"].items()}, "holes", int(c["hole"].sum()))
