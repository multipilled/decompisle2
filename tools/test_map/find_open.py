"""Find open, flat floor areas in DI2 level packages, for picking the recreation's test area.

    python tools/test_map/find_open.py [--dump] <level package> [<level package> ...]

Each placed static mesh's world AABB (StaticMesh RenderData.Bounds through the component transform) is rasterised
top-down on a 50 cm grid. A cell is "open at height t" when some box tops out at t there (the floor) and no box
reaches into (t + 15 cm, t + 220 cm). Per height (20 cm buckets) the largest open rectangle is reported, with the
floor meshes under it. AABBs of rotated props are conservative, so open space is under- rather than over-estimated.
--dump writes extracted/test_map/mesh_names.txt (the unique meshes still missing a JSON dump) for `di2x json @file`.
"""
import collections
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import level as L  # noqa: E402

CELL = 50.0
CLEAR_LO, CLEAR_HI = 15.0, 220.0


def mesh_bounds(object_path, cache):
    if object_path in cache:
        return cache[object_path]
    pkg = object_path.split(".")[0].replace("/Game/", "DeadIsland/Content/") + ".uasset"
    b = None
    try:
        for e in L.package_json(pkg):
            if e.get("Type") == "StaticMesh":
                rb = (e.get("RenderData") or {}).get("Bounds") or (e.get("Properties") or {}).get("ExtendedBounds")
                if rb:
                    b = (L.vec(rb["Origin"]), L.vec(rb["BoxExtent"]))
                break
    except FileNotFoundError:
        b = "missing"
    cache[object_path] = b
    return b


def world_aabb(world, b):
    o, ext = b
    corners = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]) * ext + o
    w = np.c_[corners, np.ones(8)] @ world
    return w[:, :3].min(0), w[:, :3].max(0)


def max_rect(grid):
    """Largest all-True axis-aligned rectangle: (area, row0, col0, rows, cols)."""
    h = np.zeros(grid.shape[1], int)
    best = (0, 0, 0, 0, 0)
    for r in range(grid.shape[0]):
        h = np.where(grid[r], h + 1, 0)
        stack = []
        for c in range(len(h) + 1):
            cur = h[c] if c < len(h) else 0
            start = c
            while stack and stack[-1][1] >= cur:
                s, hh = stack.pop()
                if hh * (c - s) > best[0]:
                    best = (hh * (c - s), r - hh + 1, s, hh, c - s)
                start = s
            stack.append((start, cur))
    return best


def main(args):
    dump = "--dump" in args
    pkgs = [a for a in args if not a.startswith("--")]
    boxes, cache, missing = [], {}, set()
    for pkg in pkgs:
        lv = L.Level(pkg)
        for c in L.mesh_components(lv):
            if c["hidden"] and not c["collision"]:
                continue
            if L.is_hlod(c):
                continue
            b = mesh_bounds(c["mesh"], cache)
            if b == "missing":
                missing.add(L.obj_name({"ObjectPath": c["mesh"]}))
                continue
            if b is None:
                continue
            lo, hi = world_aabb(c["world"], b)
            boxes.append((lo, hi, L.obj_name({"ObjectPath": c["mesh"]}), c["hidden"]))
    if dump:
        out = os.path.join(L.ROOT, "extracted", "test_map", "mesh_names.txt")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, "w").write("\n".join(sorted(missing)))
        print("%d meshes without a JSON dump -> %s" % (len(missing), out))
        return
    if missing:
        print("warning: %d meshes without a JSON dump (run with --dump)" % len(missing))
    lo = np.min([b[0] for b in boxes], 0)
    hi = np.max([b[1] for b in boxes], 0)
    nx, ny = int((hi[0] - lo[0]) // CELL) + 1, int((hi[1] - lo[1]) // CELL) + 1
    print("%d boxes, extent X %.0f..%.0f Y %.0f..%.0f Z %.0f..%.0f, grid %dx%d" % (len(boxes), lo[0], hi[0], lo[1], hi[1], lo[2], hi[2], nx, ny))
    cells = collections.defaultdict(list)
    for bi, (blo, bhi, name, hid) in enumerate(boxes):
        x0, x1 = int((blo[0] - lo[0]) // CELL), int((bhi[0] - lo[0]) // CELL)
        y0, y1 = int((blo[1] - lo[1]) // CELL), int((bhi[1] - lo[1]) // CELL)
        if (x1 - x0 + 1) * (y1 - y0 + 1) > 400000:
            continue
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                cells[(x, y)].append(bi)
    # open[(bucket)] = set of cells open at that floor height; floor mesh per cell
    open_at = collections.defaultdict(dict)
    for key, ids in cells.items():
        for bi in ids:
            t = boxes[bi][1][2]
            if boxes[bi][3]:
                continue  # hidden blockers are not floors
            blocked = any(j != bi and boxes[j][0][2] < t + CLEAR_HI and boxes[j][1][2] > t + CLEAR_LO for j in ids)
            if not blocked:
                open_at[int(t // 20)][key] = boxes[bi][2]
    results = []
    for bucket, cellmap in open_at.items():
        if len(cellmap) < 200:
            continue
        g = np.zeros((nx, ny), bool)
        for (x, y) in cellmap:
            g[x, y] = True
        area, r0, c0, rows, cols = max_rect(g)
        floors = collections.Counter(cellmap.get((x, y)) for x in range(r0, r0 + rows) for y in range(c0, c0 + cols))
        results.append((area, bucket * 20, lo[0] + r0 * CELL, lo[1] + c0 * CELL, rows * CELL, cols * CELL, floors.most_common(4)))
    for r in sorted(results, reverse=True)[:12]:
        area, z, x, y, sx, sy, fl = r
        print("open %5.0f m2 at Z %6.0f: X %.0f..%.0f Y %.0f..%.0f (%.1f x %.1f m)  centre (%.0f, %.0f)  floor %s" % (
            area * CELL * CELL / 1e4, z, x, x + sx, y, y + sy, sx / 100, sy / 100, x + sx / 2, y + sy / 2, fl))


if __name__ == "__main__":
    main(sys.argv[1:])
