"""Inventory of a DI2 level's streaming sublevels: component counts per type and per tile (recon/TEST_MAP.md
"NH_04 inventory"). Reads the CUE4Parse JSON dumps in extracted/json (tools/di2x.sh json first).

    python tools/test_map/inventory.py [--md] <package> ...      (DeadIsland/Content/.../X.umap)

Categories (export Type based):
  smc         StaticMeshComponent with a StaticMesh property (HLOD proxies counted apart as hlod)
  smc_tmpl    StaticMeshComponent without one: the mesh comes from the Blueprint class template (Template ref)
  spline      SplineMeshComponent;  ism / hism / foliage: components (+ instances)
  physics     mesh components whose BodyInstance sets bSimulatePhysics (DI2 simulates them)
  landscape   LandscapeComponent, LandscapeHeightfieldCollisionComponent, GrassMeshComponent
  decal       DecalComponent;  light: Point / Spot / Rect / Directional / SkyLight components
  refl        reflection captures;  volume: Brush-based actors (*Volume, BlockingVolume apart as blocking)
  particles   ParticleSystemComponent;  skel  SkeletalMeshComponent;  bp  Blueprint actors (Type ends in _C)
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import level as L  # noqa: E402

LIGHTS = ("PointLightComponent", "SpotLightComponent", "RectLightComponent", "DirectionalLightComponent",
          "SkyLightComponent")


def inventory(pkg):
    lv = L.Level(pkg)
    c = collections.Counter()
    bp = collections.Counter()
    xs, ys = [], []
    for i, e in enumerate(lv.exports):
        t = e.get("Type", "")
        p = e.get("Properties") or {}
        if t in ("StaticMeshComponent", "SplineMeshComponent") or t.endswith("InstancedStaticMeshComponent"):
            mesh = (p.get("StaticMesh") or {}).get("ObjectPath", "")
            key = {"StaticMeshComponent": "smc", "SplineMeshComponent": "spline",
                   "InstancedStaticMeshComponent": "ism", "HierarchicalInstancedStaticMeshComponent": "hism",
                   "FoliageInstancedStaticMeshComponent": "foliage"}.get(t, "ism")
            if key == "smc" and not mesh:
                key = "smc_tmpl"
            elif "_HLOD" in mesh.rsplit("/", 1)[-1]:
                key = "hlod"
            c[key] += 1
            inst = e.get("PerInstanceSMData") or p.get("PerInstanceSMData")
            if inst:
                c[key + "_inst"] += len(inst)
            if (p.get("BodyInstance") or {}).get("bSimulatePhysics"):
                c["physics"] += 1
            if key in ("smc", "spline", "ism", "hism", "foliage"):
                w = lv.world(i)[3]
                if w[0] or w[1]:  # skip unplaced templates at the origin
                    xs.append(w[0]); ys.append(w[1])
        elif t in ("LandscapeComponent", "LandscapeHeightfieldCollisionComponent", "GrassMeshComponent"):
            c[{"LandscapeComponent": "land", "LandscapeHeightfieldCollisionComponent": "land_col",
               "GrassMeshComponent": "grass"}[t]] += 1
        elif t == "DecalComponent":
            c["decal"] += 1
        elif t in LIGHTS:
            c["light"] += 1
        elif t.endswith("ReflectionCaptureComponent"):
            c["refl"] += 1
        elif t == "ParticleSystemComponent":
            c["particles"] += 1
        elif t == "SkeletalMeshComponent":
            c["skel"] += 1
        elif t == "BlockingVolume":
            c["blocking"] += 1
        elif t.endswith("Volume"):
            c["volume"] += 1
        if t.endswith("_C") and "Component" not in t and not t.startswith(("BPC_", "NH_", "Horde_")):
            c["bp"] += 1
            bp[t] += 1
    ext = ("X %.0f..%.0f Y %.0f..%.0f" % (min(xs) / 100, max(xs) / 100, min(ys) / 100, max(ys) / 100)) if xs else ""
    return lv.name, c, bp, ext


COLS = ["smc", "smc_tmpl", "hlod", "spline", "ism", "hism", "foliage", "foliage_inst", "physics", "land", "land_col",
        "grass", "decal", "light", "refl", "blocking", "volume", "particles", "skel", "bp"]


def main(argv):
    md = "--md" in argv
    pkgs = [a for a in argv if not a.startswith("--")]
    tot = collections.Counter()
    rows = [inventory(pkg) for pkg in pkgs]
    for _n, c, _b, _e in rows:
        tot.update(c)
    cols = [k for k in COLS if tot.get(k)]  # empty columns (e.g. ISM / HISM in NH_04) are left out
    if md:
        print("| Level | " + " | ".join(cols) + " | extent (UE, m) | top Blueprint classes |")
        print("|---" * (len(cols) + 3) + "|")
    for name, c, bp, ext in rows:
        top = ", ".join("%s %d" % (k[:-2], n) for k, n in bp.most_common(3))
        if md:
            print("| %s | " % name + " | ".join(str(c.get(k, 0) or "") for k in cols) + " | %s | %s |" % (ext, top))
        else:
            print(name, {k: c[k] for k in cols if c.get(k)}, ext, top)
    if md:
        print("| **total** | " + " | ".join(str(tot.get(k, 0) or "") for k in cols) + " | | |")
    else:
        print("total", {k: tot[k] for k in cols})


if __name__ == "__main__":
    main(sys.argv[1:])
