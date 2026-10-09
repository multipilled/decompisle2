"""DI2 anim-graph data -> game/data/anim_graphs.json for scripts/di2_anim.gd (recon/ANIMATION.md).

  state_machines: every BakedStateMachine of ABP_PlayerCharacter_1P (Dani) and ABP_ZombieWalker (the zombie
                  bodies' AnimClass in BP_Base_Walker): states and transitions [from, to, CrossfadeDuration,
                  EAlphaBlendOption, LogicType].
  blend_spaces:   the 1P blend spaces the held-item classes use (UpperBody*BlendSpace, ArmSway*) and the zombie
                  locomotion blend spaces: axes, InterpolationParam, TargetWeightInterpolationSpeedPerSec,
                  samples [[godot clip | DI2 sequence, x, y, RateScale]].
  movement:       DIAICharacterMovementComponent CharMoveComp of BP_Base_Walker (MaxAcceleration, braking,
                  RotationRate).

usage: python tools/build_anim_graphs.py
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402

ROOT = Path(r".")
J = ROOT / "extracted/json/DeadIsland/Content"
OUT = ROOT / "game/data/anim_graphs.json"
ABPS = {"player_1p": J / "DI2/Core/Player/ABP_PlayerCharacter_1P.json",
        "zombie_walker": J / "DI2/Enemies/Zombies/Walker/ABP_ZombieWalker.json"}


def opt(v):
    return str(v).replace("EAlphaBlendOption::", "")


def state_machines(path):
    d = json.loads(path.read_text(encoding="utf-8"))
    cls = next(e for e in d if e["Type"] == "AnimBlueprintGeneratedClass")
    out = {}
    for sm in cls["Properties"].get("BakedStateMachines", []):
        names = [s["StateName"] for s in sm["States"]]
        out[sm["MachineName"]] = {"states": names, "initial": names[sm.get("InitialState", 0)] if names else "",
                                  "transitions": [[names[t["PreviousState"]], names[t["NextState"]], round(t["CrossfadeDuration"], 4),
                                                   opt(t["BlendMode"]), t["LogicType"].split("::")[-1]] for t in sm["Transitions"]]}
    return out


def clip_names():
    out = {}
    dani = ROOT / "game/assets/di2/dani"
    for f in sorted((dani / "classes").glob("*.clips.json")) + [dani / "clips.json"]:
        for g, seq in json.loads(f.read_text()).items():
            if isinstance(seq, str):
                out.setdefault(seq.removeprefix("inplace:"), g)
    return out


def zombie_clip_names():
    """DI2 sequence -> Godot clip per zombie body (game/assets/di2/<body>/clips.json)."""
    out = {}
    for body in ("walker", "runner", "shambler", "thug"):
        f = ROOT / f"game/assets/di2/{body}/clips.json"
        if not f.exists():
            continue
        m = {}
        for g, seq in json.loads(f.read_text()).items():
            if isinstance(seq, str):
                m.setdefault(seq.removeprefix("inplace:"), g)
        # Sequences the body glb lacks, from its skin-only clip glbs (tools/build_zombie_clips.py): "x:<sequence>".
        for xf in sorted((ROOT / "game/assets/di2/zombie_clips").glob(f"{body}_*.anims.json")):
            for seq in json.loads(xf.read_text()):
                m.setdefault(seq, "x:" + seq)
        out[body] = m
    return out


def blend_space(name, names):
    d = A.load(name)
    if not d:
        return None
    e = next((x for x in d if "BlendSpace" in x["Type"]), None)
    if not e:
        return None
    p = e["Properties"]
    axes = [p.get("BlendParameters", {}), p.get("BlendParameters[1]", {})]
    samples = []
    for s in p.get("SampleData", []):
        on = (s.get("Animation") or {}).get("ObjectName", "")
        seq = on.split("'")[1] if "'" in on else on
        v = s.get("SampleValue", {})
        samples.append([names.get(seq, seq) if isinstance(names, dict) else seq, v.get("X", 0.0), v.get("Y", 0.0), s.get("RateScale", 1.0)])
    # UE's precomputed GridSamples (2D: element X * (GridNumY + 1) + Y holds up to 3 [sample index, weight]), which
    # UBlendSpace::GetSamplesFromBlendInput interpolates bilinearly (recon/ANIMATION.md 10).
    grid = [[[g.get(f"Indices{k}", 0), g.get(f"Weights{k}", 0.0)] for k in ("", "[1]", "[2]")] for g in p.get("GridSamples", [])]
    return {"type": e["Type"], "axes": [{"name": a.get("DisplayName", ""), "min": a.get("Min", 0.0), "max": a.get("Max", 100.0),
                                          "grid": a.get("GridNum", 4)} for a in axes if a],
            "interp": (p.get("InterpolationParam") or {}).get("InterpolationType", "BSIT_Average"),
            "weight_speed": p.get("TargetWeightInterpolationSpeedPerSec", 0.0),
            "markers_sample": p.get("SampleIndexWithMarkers", -1), "samples": samples, "grid": grid}


def main():
    out = {"state_machines": {k: state_machines(v) for k, v in ABPS.items()}, "blend_spaces": {}, "movement": {}}
    names = clip_names()
    # 1P blend spaces referenced by the held-item classes.
    for f in (ROOT / "game/data/classes").glob("*.json"):
        for slot in json.loads(f.read_text())["slots"].values():
            for g in slot["groups"]:
                for it in g["items"]:
                    for role in it.values():
                        if isinstance(role, dict) and role.get("bs") and role["bs"] not in out["blend_spaces"]:
                            bs = blend_space(role["bs"], names)
                            if bs:
                                out["blend_spaces"][role["bs"]] = bs
    # Zombie locomotion blend spaces (per body: Godot clip names where that body has the sequence).
    zn = zombie_clip_names()
    for f in sorted((J / "DI2/Animation/Zombie").rglob("BS_ZMB_*.json")):
        bs = blend_space(f.stem, None)
        if bs and any(k in f.stem for k in ("Walk", "Run", "TurnonSpot", "TurnOnSpot", "Start", "Stop", "Pivot")):
            bs["clips"] = {body: [m.get(s[0], "") for s in bs["samples"]] for body, m in zn.items()}
            out["blend_spaces"][f.stem] = bs
    bp = json.loads((J / "DI2/Enemies/Zombies/Walker/BP_Base_Walker.json").read_text(encoding="utf-8"))
    mv = next((e for e in bp if e["Type"] == "DIAICharacterMovementComponent"), {})
    out["movement"]["BP_Base_Walker"] = mv.get("Properties", {})
    OUT.write_text(json.dumps(out, indent=1))
    print(f"{OUT}: {sum(len(v) for v in out['state_machines'].values())} state machines, {len(out['blend_spaces'])} blend spaces")


if __name__ == "__main__":
    main()
