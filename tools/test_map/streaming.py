"""List a persistent level's streaming levels: class, package, initially loaded / visible flags, transform."""
import json, sys
sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])
import level as L
lv = L.Level(sys.argv[1])
flt = sys.argv[2] if len(sys.argv) > 2 else ""
for i, e in enumerate(lv.exports):
    if "LevelStreaming" not in e.get("Type", ""):
        continue
    p = e.get("Properties") or {}
    w = (p.get("WorldAsset") or {}).get("AssetPathName", "?")
    if flt and flt not in w:
        continue
    flags = {k: p[k] for k in p if k.startswith("b") or k in ("LevelTransform", "LevelColor")}
    flags.pop("LevelColor", None)
    print(i, e["Type"], w.split(".")[0], json.dumps(flags)[:200])
