"""Survey a level's tile sublevels: component counts, extents, floor-ish meshes (for picking a test area)."""
import collections, glob, json, re, sys
pat = sys.argv[1]
for f in sorted(glob.glob(pat)):
    d = json.load(open(f, encoding="utf-8"))
    c = collections.Counter(e.get("Type") for e in d)
    meshes = collections.Counter()
    xs, ys, zs = [], [], []
    for e in d:
        if e.get("Type") not in ("StaticMeshComponent", "InstancedStaticMeshComponent", "HierarchicalInstancedStaticMeshComponent"):
            continue
        p = e.get("Properties", {})
        sm = (p.get("StaticMesh") or {}).get("ObjectPath", "?").split("/")[-1].split(".")[0]
        meshes[sm] += 1
        l = p.get("RelativeLocation")
        if l and "AttachParent" not in p:
            xs.append(l["X"]); ys.append(l["Y"]); zs.append(l["Z"])
    fl = [(m, n) for m, n in meshes.most_common() if re.search("floor|tile|ground|road|pave|concrete|plaza|platform|asphalt|sidewalk|kerb|curb|street", m, re.I)]
    name = f.split("\\")[-1]
    ext = ("X %.0f..%.0f Y %.0f..%.0f Z %.0f..%.0f" % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs))) if xs else ""
    print(name, "SMC", sum(meshes.values()), "uniq", len(meshes), "ISM", c.get("InstancedStaticMeshComponent", 0), "HISM", c.get("HierarchicalInstancedStaticMeshComponent", 0), "decals", c.get("DecalComponent", 0), ext)
    print("   floorish:", fl[:12])
