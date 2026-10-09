"""DI2 gradual damage effects (dismember / decapitate / major cut / bone break) -> game/data/gradual_damage.json.

UDamageRepercussions picks one per dismember / break from DA_ContextualGradualDamageEffectList_AI (first candidate
whose KB requirements hold; recon/RE_DISMEMBER.md §2.1) and applies its InitialEffect SplatterInfo once, then its
OverTimeEffect every update for Duration (DisplacementScale x dt / Duration).
usage: python tools/build_gradual_damage.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402
import build_splatter as S  # noqa: E402  (norm_info: texture names -> stamp layers, same as the splatter presets)


def name(ref):
    m = re.search(r"'([^']+)'", (ref or {}).get("ObjectName", ""))
    return m.group(1).split(":")[-1] if m else None


# Native defaults for fields an asset leaves unset (recon/RE_FLUIDS.md §8):
#   FDamageEffectSet ctor 0x141c63830 (StructOps 0x141c61490 Construct = memset + ctor): FluidType null,
#   FluidAmount +0x160 = 20, FluidStrength +0x164 = 2, EmissionVelocity +0x168 = 20 (cm/s);
#   UGradualDamageEffect ctor 0x141c635d0: Duration +0x318 = -1, EmmissionPeriod +0x31c = 0.5, ParticleSystem null.
SET_DEFAULTS = {"FluidType": None, "FluidAmount": 20.0, "FluidStrength": 2.0, "EmissionVelocity": 20.0}
EFFECT_DEFAULTS = {"Duration": -1.0, "EmmissionPeriod": 0.5}


def fluid(s):
    return {k: (s.get(k) if s.get(k) is not None else d) for k, d in SET_DEFAULTS.items()}


def info(i):
    return S.norm_info(i or {})


def main():
    lst = A.load("DA_ContextualGradualDamageEffectList_AI") or []
    objs = {e["Name"]: e for e in lst}
    main_obj = next(e for e in lst if e["Type"] == "ContextualGradualDamageEffectList")
    out = {"list": "DA_ContextualGradualDamageEffectList_AI", "candidates": [], "effects": {}}
    for c in main_obj["Properties"]["PriorityOrderedCandidates"]:
        eff = name(c.get("EffectData"))
        reqs = []
        for r in c.get("Requirements", []):
            o = objs.get(name(r))
            if o:
                reqs.append(o.get("Properties", {}))
        out["candidates"].append({"effect": eff, "requirements": reqs})
        if eff and eff not in out["effects"]:
            d = A.load(eff) or []
            e = next((x for x in d if x["Type"] == "GradualDamageEffect"), {})
            p = e.get("Properties", {})
            ini, ot = p.get("InitialEffect", {}), p.get("OverTimeEffect", {})
            out["effects"][eff] = {
                "initial": {"info": info(ini.get("SplatterInfo")), "modifiers": ini.get("SplatterModifiers") or {},
                            "fluid": fluid(ini)},
                "over_time": {"info": info(ot.get("SplatterInfo")), "modifiers": ot.get("SplatterModifiers") or {},
                              "fluid": fluid(ot)},
                "particle_system": name(p.get("ParticleSystem")),
                "duration": p.get("Duration", EFFECT_DEFAULTS["Duration"]),
                "emission_period": p.get("EmmissionPeriod", EFFECT_DEFAULTS["EmmissionPeriod"]),
            }
    (ROOT / "game/data/gradual_damage.json").write_text(json.dumps(out, indent=1))
    for c in out["candidates"]:
        e = out["effects"].get(c["effect"], {})
        print(c["effect"], json.dumps(c["requirements"])[:160], "| initial", e.get("initial", {}).get("info"), "| duration", e.get("duration"))


if __name__ == "__main__":
    main()
