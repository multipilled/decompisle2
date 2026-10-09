"""Survey: BP_BasicTimeOfDay settings in every dumped lighting scenario."""
import glob, json, os
fs = glob.glob(r"extracted\json\DeadIsland\Content\DI2\**\*LightingScenario.json", recursive=True)
fs += glob.glob(r"extracted\json\DeadIsland\Content\DI2\**\*Lighting_Main.json", recursive=True)
for f in sorted(fs):
    for e in json.load(open(f, encoding="utf-8")):
        if "TimeOfDay" in e.get("Type", ""):
            p = e["Properties"]
            print(os.path.basename(f)[:45].ljust(45), {k: p.get(k) for k in ("Sun Intensity", "Sun Elevation", "Sun Temperature", "Sky Brightness", "Fog Density")}, (p.get("SkyTexture") or {}).get("ObjectName"))
