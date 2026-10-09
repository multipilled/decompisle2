"""List the particle masters still on di2_particle_generic: emitter uses, emitter kinds, example systems (recon/PARTICLES.md 5.9)."""
import collections
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
d = json.load(open(r"game\data\particles.json"))
src = open(r"game\scripts\di2_particle_materials.gd", encoding="utf-8").read()
fam = set(re.findall(r'^\t"(\w+)": \{Kind', src, re.M))
use = collections.Counter(); ex = collections.defaultdict(set); kinds = collections.defaultdict(set)
for pn, ps in d["ps"].items():
    for e in ps["emitters"]:
        if not e: continue
        mods = {m["m"]: m for m in e["modules"]}
        k = "MESH" if "TypeDataMesh" in mods else "GPU" if "TypeDataGpu" in mods else "RIBBON" if "TypeDataRibbon" in mods else "SPRITE"
        for m in e["modules"]:
            if m["m"] == "Required" and m.get("Material"):
                mi = d["materials"].get(m["Material"]) or {}
                r = mi.get("root", "?")
                if r not in fam:
                    use[r] += 1; ex[r].add(pn); kinds[r].add(k)
for r, n in use.most_common():
    print(n, r, sorted(kinds[r]), sorted(ex[r])[:4])
