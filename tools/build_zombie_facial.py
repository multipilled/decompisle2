"""DI2 zombie facial animation -> game/data/zombie_facial.json + game/assets/di2/zombie_facial/<body>_facial.glb
(recon/ANIMATION.md section 7, read by scripts/zombie_anim.gd FaceLayer).

How DI2 animates a zombie face (all from its own data / exe; sources in recon/ANIMATION.md):
  * ABP_ZombieWalker: LayeredBoneBlend(base = body graph, blend = SubInstance ABP_ZombieWalkerFacial, branch "face"
    depth 0, weight Layer_Facial) -> the 141 bones under `face` come from the facial sub-graph.
  * ABP_ZombieWalkerFacial: state machine WAIT (ref pose) -> Idle / Combat (InternalCombatState == Combat), 0.2 s
    HermiteCubic crossfades. Each state = LayeredBoneBlend(base = AnimSetSequencePlayer(Facial.Idle_Calm /
    Facial.Idle_Combat), blend = BlendSpacePlayer(MouthMovement BS at MouthAdditiveHorizontal / Vertical), branch
    "face" depth 0 minus eye_r / eye_l (-1), weight Layer_ProceduralMouth).
  * Per family: BP_Base_<Family> AnimSetCollections -> DA_AnimSetCollection_<Family>_Facial (Idle_Calm, Idle_Combat,
    MouthMovement).
The bone masks are DI2's baked PerBoneBlendWeights of those two LayeredBoneBlend nodes.

The clips (face bones only, retargeted onto each body's rest pose like tools/merge_anims.py) go into one small glb per
body: its skin (joints + inverse binds) and no meshes, so Godot imports them as Skeleton3D bone tracks.

usage: python tools/build_zombie_facial.py      (needs extracted/rawanim/A_ZMB_Facial_* from `di2x rawanim`)
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import merge_anims as M  # noqa: E402

ROOT = Path(r".")
JB = ROOT / "extracted/json_bp/DeadIsland/Content"
JS = ROOT / "extracted/json/DeadIsland/Content"
OUT = ROOT / "game/data/zombie_facial.json"
GLB_DIR = ROOT / "game/assets/di2/zombie_facial"
SKEL = JS / "DIShared/Art/Characters/ZombieStandard/SKEL_ZombieStandard.json"
ABP_MAIN = JB / "DI2/Enemies/Zombies/Walker/ABP_ZombieWalker.json"
ABP_FACE = JB / "DI2/Enemies/Zombies/Walker/ABP_ZombieWalkerFacial.json"
COLL = JB / "DI2/Animation/AnimSetData/Zombie/Collections/Facial"
BS_DIR = JB / "DI2/Animation/Zombie/Facial/MouthDriver/AnimAssets"
# Port body -> DI2 family (scripts/zombie.gd BODIES) and the family's BP (its AnimSetCollections list the facial one).
BODIES = {"walker": "Walker", "runner": "Runner", "shambler": "Shambler", "thug": "Thug"}
BODIES.update({"screamer": "Screamer", "butcher": "Butcher", "suicider": "Suicider"})  # tools/archetype_bodies.py (Slobber: its facial idles are UE-codec, which this builder does not decode yet)
FAMILY_BP = {f: JS / f"DI2/Enemies/Zombies/{f}/BP_Base_{f}.json" for f in BODIES.values()}

# Native values read from the shipping exe (static; recon/ANIMATION.md 7.2):
LAYER_WEIGHT = {   # ULinearBlendLayerWeightProvider InternalConstructor 0x140c94c90: Desired 1.0, TransitionTime 0.33
    "desired": 1.0, "transition": 0.33}   # (PostInitProperties 0x140c91cf0: Inverse = 1 / TransitionTime)
MOUTH = {          # UBreathingAudioComponent tick 0x141173b30 / 0x1411745e0, RTPC read 0x141177340
    "rtpc": "RTPC_Zombie_Mouth_Volume", "poll": 1.0 / 30.0, "floor_db": -48.0, "scale": -0.03589682,
    "config": {"min": -1.0, "max": 1.0, "clamp": False}}   # DA_BreathingAudioMouthDamLocWalker default state


def load(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def skeleton_names():
    sk = next(e for e in load(SKEL) if e["Type"] == "Skeleton")
    return [b["Name"] for b in sk["ReferenceSkeleton"]["FinalRefBoneInfo"]]


def masked(abp, node, names):
    w = load(abp)[-1]["Properties"][node]["PerBoneBlendWeights"]
    return [names[i] for i, x in enumerate(w) if x["BlendWeight"] > 0]


def obj_name(ref):
    return ref["ObjectName"].split("'")[1] if ref and "'" in ref.get("ObjectName", "") else None


def anim_set_items(coll, key):
    """[sequence names], order of one Facial.<key> entry: AnimSet_Single -> its asset; AnimSet_DataDriven -> the
    AnimSetData group named Facial.<key> (items + selection order class)."""
    top = next(e for e in load(coll) if "CollectionName" in (e.get("Properties") or {}))
    for kv in top["Properties"]["AnimSetData"]:
        if kv["Key"] != key:
            continue
        v = kv["Value"]
        if obj_name(v.get("AnimSetClass")) == "AnimSet_Single":
            return [obj_name(v["AnimAsset"])], "Single"
        groups = next(e for e in load(asset_json(v["AnimSetData"]["ObjectPath"]))
                      if e["Type"] == "AnimSetData")["Properties"]["Groups"]
        g = next(g for g in groups if g["Name"] == f"Facial.{key}")
        return [obj_name(it["Asset"]) for it in g["Items"]], obj_name(g["Order"]).removeprefix("AnimSetSelectionOrder_")
    raise KeyError(key)


def asset_json(object_path):
    """/Game/DI2/... object path -> its dump (extracted/json_bp first, then extracted/json)."""
    rel = object_path.removeprefix("/Game/").rsplit(".", 1)[0] + ".json"
    return next(p for p in (JB / rel, JS / rel) if p.exists())


def facial_sm():
    d = load(ABP_FACE)
    cls = next(e for e in d if e["Type"] == "AnimBlueprintGeneratedClass")
    sm = cls["Properties"]["BakedStateMachines"][0]
    names = [s["StateName"] for s in sm["States"]]
    cdo = d[-1]["Properties"]
    player = cdo["AnimGraphNode_AnimSetSequencePlayer"]
    return {"initial": names[sm["InitialState"]],
            "transitions": [[names[t["PreviousState"]], names[t["NextState"]], t["CrossfadeDuration"],
                             t["BlendMode"].split("::")[1]] for t in sm["Transitions"]],
            # Idle -> Combat when InternalCombatState == 2 (ECosmeticCombatState::Combat), back when != 2 (ubergraph).
            "combat_state": 2,
            "player": {k: player[k] for k in ("bLoopAnimation", "PlayRate", "StartPosition", "ResolveRemainingTime")}}


def mouth_bs(name):
    p = next(e for e in load(BS_DIR / f"{name}.json") if e["Type"] == "BlendSpace")["Properties"]
    return {"weight_speed": p.get("TargetWeightInterpolationSpeedPerSec", 0.0),
            "axes": [[p["BlendParameters"]["Min"], p["BlendParameters"]["Max"]],
                     [p["BlendParameters[1]"]["Min"], p["BlendParameters[1]"]["Max"]]],
            "samples": [[obj_name(s["Animation"]), s["SampleValue"]["X"], s["SampleValue"]["Y"]] for s in p["SampleData"]]}


def facial_glb(body, clips, face_bones):
    """Skin-only glb (no meshes) of the body's skeleton + the face-bone channels of `clips`."""
    g, binchunk = M.read_glb(ROOT / f"game/assets/di2/{body}/{body}.glb")
    target = M.rest_pose_ue(g)
    out = {"asset": g["asset"], "scene": g.get("scene", 0), "scenes": g["scenes"], "nodes": [], "skins": [],
           "accessors": [], "bufferViews": [], "buffers": [{"byteLength": 0}], "animations": []}
    ob = bytearray()
    for n in g["nodes"]:
        out["nodes"].append({k: v for k, v in n.items() if k not in ("mesh", "skin")})
    for s in g["skins"]:
        acc = g["accessors"][s["inverseBindMatrices"]]
        bv = g["bufferViews"][acc["bufferView"]]
        raw = binchunk[bv.get("byteOffset", 0) + acc.get("byteOffset", 0):][:acc["count"] * 64]
        arr = np.frombuffer(bytes(raw), dtype=np.float32).reshape(acc["count"], 16)
        s2 = dict(s)
        s2["inverseBindMatrices"] = M.add_accessor(out, ob, arr, "MAT4")
        out["skins"].append(s2)
    node_of = {n.get("name"): i for i, n in enumerate(g["nodes"])}
    report = {}
    for seq in clips:
        meta = json.loads((M.RAW / f"{seq}.json").read_text())
        bones, ns, rate = M.load_acl(seq, meta)
        bones = M.retarget(bones, meta, target)
        times = np.arange(ns, dtype=np.float32) / rate
        tin = M.add_accessor(out, ob, times, "SCALAR", minmax=True)
        t1 = M.add_accessor(out, ob, times[:1], "SCALAR", minmax=True)
        anim = {"name": seq, "channels": [], "samplers": []}
        moving = 0
        for bone in face_bones:
            if bone not in bones or bone not in node_of:
                continue
            t, q = bones[bone]
            tg, qg = M.ue_to_gltf_t(t), M.ue_to_gltf_q(q)
            qg = qg / np.linalg.norm(qg, axis=1, keepdims=True)
            for i in range(1, len(qg)):
                if np.dot(qg[i - 1], qg[i]) < 0:
                    qg[i] = -qg[i]
            for path, arr, typ in (("translation", tg, "VEC3"), ("rotation", qg, "VEC4")):
                const = np.abs(arr - arr[:1]).max() < 1e-6
                moving += not const
                src = arr[:1] if const else arr
                o = M.add_accessor(out, ob, src, typ)
                anim["samplers"].append({"input": t1 if const else tin, "output": o, "interpolation": "LINEAR"})
                anim["channels"].append({"sampler": len(anim["samplers"]) - 1,
                                         "target": {"node": node_of[bone], "path": path}})
        out["animations"].append(anim)
        report[seq] = {"frames": ns, "rate": rate, "length": float(times[-1]), "channels": len(anim["channels"]),
                       "moving": moving}
    GLB_DIR.mkdir(parents=True, exist_ok=True)
    M.write_glb(GLB_DIR / f"{body}_facial.glb", out, ob)
    return report


def main():
    names = skeleton_names()
    face = masked(ABP_MAIN, "AnimGraphNode_LayeredBoneBlend", names)           # Layer_Facial branch "face"
    mouth = masked(ABP_FACE, "AnimGraphNode_LayeredBoneBlend", names)          # Layer_ProceduralMouth, eyes excluded
    assert set(mouth) == set(masked(ABP_FACE, "AnimGraphNode_LayeredBoneBlend_1", names))
    data = {"face_bones": face, "mouth_bones": mouth, "layer_weight": LAYER_WEIGHT, "mouth": MOUTH,
            "state_machine": facial_sm(),
            # DA_AnimLayerGroup_NPC_*: groups whose activation disables the NPCFacial layer (ProceduralMouth is in none).
            "facial_disabled_by": ["Dead", "PlayDead", "CoopAction", "GameSequence_DefaultCutscene",
                                   "StatusEffect_Frozen", "AILOD_Level1"],
            "bodies": {}, "blend_spaces": {}}
    for body, fam in BODIES.items():
        bp = load(FAMILY_BP[fam])
        coll = next(obj_name(r) for e in bp for r in (e.get("Properties") or {}).get("AnimSetCollections", [])
                    if obj_name(r) and obj_name(r).endswith("_Facial"))
        cpath = COLL / f"{coll}.json"
        idle = anim_set_items(cpath, "Idle_Calm")
        combat = anim_set_items(cpath, "Idle_Combat")
        top = next(e for e in load(cpath) if "CollectionName" in (e.get("Properties") or {}))
        bs = next(obj_name(kv["Value"]["AnimAsset"]) for kv in top["Properties"]["AnimSetData"] if kv["Key"] == "MouthMovement")
        data["blend_spaces"][bs] = mouth_bs(bs)
        clips = list(dict.fromkeys(idle[0] + combat[0] + [s[0] for s in data["blend_spaces"][bs]["samples"]]))
        rep = facial_glb(body, clips, face)
        data["bodies"][body] = {"collection": coll, "Idle": {"clips": idle[0], "order": idle[1]},
                                "Combat": {"clips": combat[0], "order": combat[1]}, "mouth_bs": bs,
                                "glb": f"res://assets/di2/zombie_facial/{body}_facial.glb", "clips": rep}
        print(f"{body:9} {coll}: Idle {idle[0]} ({idle[1]}), Combat {combat[0]} ({combat[1]}), mouth {bs}")
        for c, r in rep.items():
            print(f"    {c:42} {r['frames']:5}f  {r['moving']:3}/{r['channels']} moving channels")
    OUT.write_text(json.dumps(data, indent=1))
    print(f"face bones {len(face)}, mouth bones {len(mouth)} -> {OUT}")


if __name__ == "__main__":
    main()
