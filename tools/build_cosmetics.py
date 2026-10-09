"""DI2 cosmetic effects (CE_* CosmeticEffectsDefinition assets) -> game/data/cosmetics.json.

DI2 routes camera animations, sounds, particles, decals, blood splatter meshes, viscera and force feedback for
every gameplay event through these definitions. Each definition lists instanced effect objects; references to
other assets are reduced to their names (AnimSequence, AkAudioEvent, ParticleSystem, material, mesh, nested
CosmeticEffectsDefinition) so the runtime (game/scripts/cosmetics.gd) can resolve them.

usage: python tools/build_cosmetics.py
"""
import glob
import json
import re
from pathlib import Path

ROOT = Path(r".")
REF = re.compile(r"^(\w+)'([^']+)'$")


def reduce(v):
    if isinstance(v, dict):
        if "ObjectName" in v and len(v) <= 2:
            m = REF.match(v["ObjectName"])
            if m:
                name = m.group(2).split(":")[-1].split(".")[-1]
                return {"@": m.group(1), "n": name}
            return v["ObjectName"]
        if "AssetPathName" in v:
            return {"@": "soft", "n": v["AssetPathName"].split(".")[-1]} if v["AssetPathName"] != "None" else None
        if set(v) >= {"Namespace", "Key", "SourceString"}:
            return v.get("LocalizedString") or v.get("SourceString")
        return {k: reduce(x) for k, x in v.items()}
    if isinstance(v, list):
        return [reduce(x) for x in v]
    return v


def main():
    out = {}
    for f in sorted(glob.glob(str(ROOT / "extracted/json/**/CE_*.json"), recursive=True)):
        d = json.load(open(f, encoding="utf-8"))
        objs = {e["Name"]: e for e in d}
        main_def = next((e for e in d if e["Type"] == "CosmeticEffectsDefinition"), None)
        if not main_def:
            continue
        p = main_def.get("Properties", {})
        effects = []
        for ref in [r for r in p.get("Instanced", []) if r]:
            m = REF.match(ref.get("ObjectName", ""))
            name = m.group(2).split(":")[-1].split(".")[-1] if m else ""
            e = objs.get(name)
            if not e:
                continue
            props = reduce(e.get("Properties", {}))
            # Inline sub-objects (param remaps, spawn methods) referenced by name inside this package.
            for k, v in list(props.items()):
                if isinstance(v, dict) and v.get("n") in objs and v.get("@") not in ("CosmeticEffectsDefinition",):
                    sub = objs[v["n"]]
                    props[k] = {"_type": sub["Type"], **reduce(sub.get("Properties", {}))}
                elif isinstance(v, list):
                    props[k] = [({"_type": objs[x["n"]]["Type"], **reduce(objs[x["n"]].get("Properties", {}))}
                                 if isinstance(x, dict) and x.get("n") in objs and x.get("@") not in ("CosmeticEffectsDefinition",) else x) for x in v]
            effects.append({"type": e["Type"].removeprefix("CosmeticEffect_"), **props})
        out[main_def["Name"]] = {"effects": effects, **{k: reduce(v) for k, v in p.items() if k != "Instanced"}}
    (ROOT / "game/data/cosmetics.json").write_text(json.dumps(out, separators=(",", ":")))
    from collections import Counter
    c = Counter(e["type"] for v in out.values() for e in v["effects"])
    print(f"{len(out)} cosmetic effects -> game/data/cosmetics.json ({(ROOT / 'game/data/cosmetics.json').stat().st_size // 1024} KB)")
    print(c.most_common(12))


if __name__ == "__main__":
    main()
