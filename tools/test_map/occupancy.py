"""Top-down occupancy PNG around a UE point, for picking the test area.
    python tools/test_map/occupancy.py X Y FLOORZ HALF_CM out.png <level package> ...

Shapes: small meshes (< 3 m) as their world AABB; larger ones as their simple-collision elements (BodySetup AggGeom
boxes / convex hulls, projected and filled as 2D hulls), since a big mesh's AABB (a building shell, a cable run) says
nothing about the space inside it. Larger meshes without simple collision are listed and skipped.
Colours per 25 cm cell: grey = a surface topping out within +-40 cm of FLOORZ (floor), red = something reaching into
FLOORZ+15 .. FLOORZ+220 cm (clutter, brighter = more), black = neither. Image: UE +X right, UE +Y down, 5 m grid,
green cross = the point.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import level as L  # noqa: E402
import find_open as F  # noqa: E402
import build_test_map as BT  # noqa: E402

CELL = 25.0


def hull2d(pts):
    pts = sorted(set(map(tuple, np.round(pts, 1))))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def shapes(c, info):
    """[(world points (n,3) UE cm)] for the placement: AABB corners or simple-collision elements."""
    lo, hi = F.world_aabb(c["world"], info["bounds"])
    if (hi - lo).max() < 300:
        return [np.array([[a, b, z] for a in (lo[0], hi[0]) for b in (lo[1], hi[1]) for z in (lo[2], hi[2])])]
    agg = (info["body"] or {}).get("AggGeom") or {}
    out = []
    w = c["world"]
    for e in agg.get("BoxElems") or []:
        hx, hy, hz = e.get("X", 0) / 2, e.get("Y", 0) / 2, e.get("Z", 0) / 2
        pts = np.array([[sx * hx, sy * hy, sz * hz, 1] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        out.append((pts @ (BT.elem_matrix(e) @ w))[:, :3])
    for e in agg.get("ConvexElems") or []:
        pts = np.array([[v["X"], v["Y"], v["Z"], 1] for v in e.get("VertexData") or []])
        if len(pts) >= 4:
            out.append((pts @ (BT.elem_matrix(e) @ w))[:, :3])
    for e in (agg.get("SphereElems") or []) + (agg.get("SphylElems") or []):
        r = e["Radius"] + e.get("Length", 0) / 2
        pts = np.array([[sx * r, sy * r, sz * r, 1] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        out.append((pts @ (BT.elem_matrix(e) @ w))[:, :3])
    return out


def main(argv):
    x, y, fz, half = map(float, argv[:4])
    out = argv[4]
    n = int(2 * half / CELL)
    occ = Image.new("I", (n, n), 0)
    flo = Image.new("L", (n, n), 0)
    skipped = {}
    occ_arr = np.zeros((n, n), np.int32)
    for pkg in argv[5:]:
        lv = L.Level(pkg)
        for c in L.mesh_components(lv):
            if L.is_hlod(c) or c["hidden"]:
                continue
            info = BT.mesh_info(c["mesh"])
            if not info or info["bounds"] is None:
                continue
            lo, hi = F.world_aabb(c["world"], info["bounds"])
            if hi[0] < x - half or lo[0] > x + half or hi[1] < y - half or lo[1] > y + half:
                continue
            sh = shapes(c, info)
            if not sh:
                skipped[info["name"]] = skipped.get(info["name"], 0) + 1
                continue
            for pts in sh:
                zlo, zhi = pts[:, 2].min(), pts[:, 2].max()
                poly = [((px - (x - half)) / CELL, (py - (y - half)) / CELL) for px, py in hull2d(pts[:, :2])]
                if len(poly) < 3:
                    continue
                if abs(zhi - fz) <= 40:
                    ImageDraw.Draw(flo).polygon(poly, fill=255)
                elif zlo < fz + 220 and zhi > fz + 15:
                    m = Image.new("L", (n, n), 0)
                    ImageDraw.Draw(m).polygon(poly, fill=1)
                    occ_arr += np.asarray(m, np.int32)
    img = np.zeros((n, n, 3), np.uint8)
    img[np.asarray(flo) > 0] = (90, 90, 90)
    o = occ_arr > 0
    img[o] = np.stack([np.minimum(255, 120 + 40 * occ_arr[o]), np.zeros(int(o.sum())), np.zeros(int(o.sum()))], 1).astype(np.uint8)
    im = Image.fromarray(img).resize((n * 2, n * 2), Image.NEAREST)
    d = ImageDraw.Draw(im)
    step = int(500 / CELL * 2)
    for k in range(0, n * 2, step):
        d.line([(k, 0), (k, n * 2)], fill=(0, 70, 0))
        d.line([(0, k), (n * 2, k)], fill=(0, 70, 0))
    d.line([(n - 10, n), (n + 10, n)], fill=(0, 255, 0))
    d.line([(n, n - 10), (n, n + 10)], fill=(0, 255, 0))
    im.save(out)
    print("saved %s (%d px = %.0f m); large meshes without simple collision skipped: %s" % (
        out, n * 2, 2 * half / 100, sorted(skipped.items(), key=lambda kv: -kv[1])[:12]))


if __name__ == "__main__":
    main(sys.argv[1:])
