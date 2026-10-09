"""Survey: fluid params actors and post-process fluid colours in the dumped map JSONs (extracted/json/.../Maps)."""
import glob, json, sys
for f in sorted(glob.glob(r"extracted\json\DeadIsland\Content\DI2\**\*.json", recursive=True)):
    if "Maps" not in f:
        continue
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if not isinstance(d, list):
        continue
    for e in d:
        t = e.get("Type", "")
        p = e.get("Properties", {})
        if "Fluid" in t:
            print(f.split("Content\\")[1], t, e["Name"], json.dumps(p)[:600])
        s = p.get("Settings")
        if t == "PostProcessVolume" or (t.endswith("Component") and isinstance(s, dict) and any("Color" in k and ("Blood" in k or "Water" in k or "Fuel" in k or "Acid" in k) for k in s)):
            ks = {k: v for k, v in (s or {}).items() if any(w in k for w in ("Blood", "Water", "Fuel", "Acid"))}
            print(f.split("Content\\")[1], t, e["Name"], "fluid:", json.dumps(ks)[:800], "| other keys:", [k for k in (s or {}) if k not in ks][:40], "| props:", {k: p[k] for k in p if k in ("bUnbound", "Priority", "BlendWeight", "bEnabled", "BlendRadius")})
