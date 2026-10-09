"""Landscape inputs for tools/build_test_map.py (heavy: mounts the paks; run through tools/with_cpu.sh):
  1. mapx exports every Texture2D cooked into the terrain level (height / weight maps) to <build>/terrain/mips;
  2. the landscape materials' MI chains are resolved (shadermaps) and printed: master, texture / scalar / vector params.

    python tools/test_map/landscape_prep.py <map name>
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import build_test_map as T  # noqa: E402
import level as L  # noqa: E402


def main(name):
    cfg = T.MAPS[name]
    build = os.path.join(T.ROOT, "extracted", "test_map", name)
    tdir = os.path.join(build, "terrain")
    os.makedirs(tdir, exist_ok=True)
    ml, tl = os.path.join(tdir, "meshes.txt"), os.path.join(tdir, "textures.txt")
    open(ml, "w").write("")
    open(tl, "w").write("\n".join(cfg["terrain"]))
    log = T.run([T.MAPX, T.ROOT, ml, tl, tdir])
    print("\n".join(l for l in log.splitlines() if l.startswith("FAIL"))[:2000])
    meta = json.load(open(os.path.join(tdir, "mips", "meta.json")))
    print("terrain textures exported: %d" % len(meta))
    mats = set()
    for pkg in cfg["terrain"]:
        for e in L.Level(pkg).exports:
            if e.get("Type") == "Landscape":
                m = ((e.get("Properties") or {}).get("LandscapeMaterial") or {}).get("ObjectPath")
                if m:
                    mats.add(m)
    resolved, masters = T.resolve_materials(mats, build)
    for p, e in resolved.items():
        print(json.dumps({"path": p, "chain": e["chain"], "master": e["master"], "render": e["render"],
                          "texture_values": e["texture_values"], "switches": e["switches"], "scalars": e["scalars"],
                          "vectors": e["vectors"]}, indent=1)[:6000])


if __name__ == "__main__":
    main(sys.argv[1])
