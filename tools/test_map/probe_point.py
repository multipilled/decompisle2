"""What is around a UE point in a set of level packages: boxes under it (floor candidates) and boxes within a radius
in the 15..220 cm band above that floor (clutter). Mesh AABBs from the StaticMesh JSON dumps; HLOD proxies skipped.
    python tools/test_map/probe_point.py X Y Z RADIUS_CM <level package> ...
"""
import collections, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import level as L  # noqa: E402
import find_open as F  # noqa: E402

x, y, z, rad = map(float, sys.argv[1:5])
cache = {}
under, near = [], []
for pkg in sys.argv[5:]:
    lv = L.Level(pkg)
    for c in L.mesh_components(lv):
        if L.is_hlod(c):
            continue
        b = F.mesh_bounds(c["mesh"], cache)
        if b in (None, "missing"):
            continue
        lo, hi = F.world_aabb(c["world"], b)
        name = L.obj_name({"ObjectPath": c["mesh"]})
        if lo[0] <= x <= hi[0] and lo[1] <= y <= hi[1] and hi[2] <= z + 50 and hi[2] >= z - 400:
            under.append((round(hi[2]), name, c["hidden"], [round(v) for v in hi - lo]))
        if (lo[0] < x + rad and hi[0] > x - rad and lo[1] < y + rad and hi[1] > y - rad and lo[2] < z + 220 and hi[2] > z + 15
                and not c["hidden"]):
            near.append((name, [round(v) for v in lo], [round(v) for v in hi]))
print("under (top Z, mesh, hidden, size):")
for u in sorted(under, reverse=True)[:8]:
    print("  ", u)
print("clutter within %.0f cm: %d" % (rad, len(near)))
for n, k in collections.Counter(n for n, _, _ in near).most_common(25):
    print("   %3d %s" % (k, n))
