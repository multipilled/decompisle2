"""Build the DI2 special-archetype bodies (game/assets/di2/<body>/) the way runner / shambler / thug were built.

Per body:
  1. the merged SK_* mesh glb from `di2x mesh` (extracted/mesh/..., run it first under tools/with_cpu.sh),
  2. <body>/clips.json = the body's own clips (below, each from DI2's anim set / blend space data) plus every
     A_ZMB_Base_* reaction clip of walker/clips.json under the same names (the Base hit / KO / crawler clips are shared by
     every SKEL_ZombieStandard zombie, recon/RECON.md "Anim sets"), so zombie_reactions.gd works on it,
  3. tools/merge_anims.py (retargets every clip onto the mesh's rest pose) -> <body>/<body>.glb + <body>.anims.json,
  4. tools/pack_materials.py -> <body>/<body>.materials.json + textures/.
Roster and mesh choice: recon/ARCHETYPES.md (tools/list_archetypes.py). Each body uses the first mesh of its
Blueprint's DA_ModelVariation (all variants of a class share one PhysicsAsset and the class's anim sets).

Variant bodies (VARIANTS, the P2 elemental / hazard Walker / Runner meshes, coordinator decision 2026-10-09): mesh swaps
that keep their class's clips. <body>/<body>.glb is the mesh only (no clips, textures through the shared pool,
pack_materials.py --pool); at runtime game/scripts/body_variant.gd lends it the class body's clip library (walker /
runner) and applies <body>/<body>.retarget.json, the class-mesh -> variant-mesh step of UE's runtime retarget
(FAnimationRuntime::RetargetBoneTransform, as tools/merge_anims.py does offline) for the bones whose rest differs.

usage: python tools/archetype_bodies.py <body> [...]      (python only; ~seconds per body with the rawanim cache)
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(r".")
MESH = ROOT / "extracted" / "mesh" / "DeadIsland" / "Content"
ASSETS = ROOT / "game" / "assets" / "di2"

# Crawler clips: DA_AnimSetCollection_<Class>_Crawler / _Crawling_Locomotion use the Walker crawler sequences
# (A_ZMB_Walker_Crawler_* idles, BS_ZMB_Base_Crawler_Walk), as the shipped bodies do.
WALKER_CRAWL = {
    "crawl_idle": "A_ZMB_Walker_Crawler_Combat_Idle_LH_01",
    "inplace:crawl": "A_ZMB_Walker_Crawler_Walk_Med_F_01", "inplace:crawl_slow": "A_ZMB_Walker_Crawler_Walk_Slow_F_01",
    "crawl_attack_l": "A_ZMB_Walker_Crawler_Attack_LH_SwipeR_01", "crawl_attack_r": "A_ZMB_Walker_Crawler_Attack_RH_SwipeL_01",
}

BODIES = {
    # BP_Screamer_Generic -> DA_ModelVariation_Screamer_Generic -> SK_Screamer01/02/03 (PA_Screamer).
    "screamer": {
        "mesh": "DI2/Art/Characters/ZombieSpecial/Screamer/SK_Screamer01",
        "clips": {
            # DA_AnimSetCollection_Screamer_Locomotion: Combat / Calm idles.
            "idle": "A_ZMB_Screamer_Combat_Idle_01", "idle_calm": "A_ZMB_Screamer_Calm_Idle_01",
            # BS_ZMB_Screamer_Walk forward samples (Angle 0): Walk_Slow (speed 50-80), Walk_Med (200-230), Walk_Fast (350).
            "inplace:walk_slow": "A_ZMB_Screamer_Walk_Slow", "inplace:walk": "A_ZMB_Screamer_Walk_Med",
            "inplace:walk_fast": "A_ZMB_Screamer_Walk_Fast",
            # DA_AttackDef_Screamer_Swipe / _Ripper / DA_AttackSequence_Screamer_Scream sequences (Med variants).
            "attack_swipe_l": "A_ZMB_Screamer_Attack_Swipe_L_Med", "attack_swipe_r": "A_ZMB_Screamer_Attack_Swipe_R_Med",
            "attack_ripper": "A_ZMB_Screamer_Attack_Ripper_Attack_Med",
            "scream_windup": "A_ZMB_Screamer_Attack_Scream_WindUp", "scream_into": "A_ZMB_Screamer_Attack_Scream_Into_F",
            "scream_loop": "A_ZMB_Screamer_Attack_Scream_Loop", "scream_exit": "A_ZMB_Screamer_Attack_Scream_Exit",
            # The Screamer's own stun reactions (as the Thug's hit_med_* use its Stumble_Stun / Hit_Stun_Med).
            "hit_med_head": "A_ZMB_Screamer_Stumble_Stun", "hit_med_torso": "A_ZMB_Screamer_Hit_Stun_Med",
            **WALKER_CRAWL,
        },
    },
    # BP_Slobber_Generic -> DA_ModelVariation_Slobber_Generic -> SK_SlobberA (PA_Slobber).
    "slobber": {
        "mesh": "DI2/Art/Characters/ZombieSpecial/Slobber/SK_SlobberA",
        "clips": {
            # DA_AnimSetCollection_Slobber_Locomotion idles; BS_ZMB_Slobber_Walk_Fwd forward samples (Walk_F_*_01).
            "idle": "A_ZMB_Slobber_Combat_Idle_01", "idle_calm": "A_ZMB_Slobber_Calm_Idle_01",
            "inplace:walk_slow": "A_ZMB_Slobber_Walk_F_Slow_01", "inplace:walk": "A_ZMB_Slobber_Walk_F_Med_01",
            "inplace:walk_fast": "A_ZMB_Slobber_Walk_F_Fast_01",
            # DA_AttackDef_Slobber_Swipe (AM_ZMB_Slobber_Attack_Slap_LH/RH_Med), _Grapple, _Push, _BackhandedSlap;
            # DA_AnimSetCollection_Slobber_RangedAttacks (Spit / Spew / DownwardVomit).
            "attack_swipe_l": "A_ZMB_Slobber_Attack_Slap_LH_Med", "attack_swipe_r": "A_ZMB_Slobber_Attack_Slap_RH_Med",
            "attack_grapple": "A_ZMB_Slobber_Attack_Grapple_Med", "attack_push": "A_ZMB_Slobber_Attack_Push",
            "attack_spit": "A_ZMB_Slobber_Attack_Spit", "attack_spew": "A_ZMB_Slobber_Attack_Spew",
            "attack_vomit_down": "A_ZMB_Slobber_Attack_DownwardVomit",
            "hit_med_head": "A_ZMB_Slobber_Stumble_Stun", "hit_med_torso": "A_ZMB_Slobber_Hit_Stun_Med",
            **WALKER_CRAWL,
        },
    },
    # BP_Butcher_Generic -> DA_ModelVariation_Butcher_Generic -> SK_Butcher01/02/03 (PA_Butcher).
    "butcher": {
        "mesh": "DI2/Art/Characters/ZombieSpecial/Butcher/SK_Butcher01",
        "clips": {
            # DA_AnimSetCollection_Butcher_Standing_Locomotion: A_ZMB_Butcher_Combat_Idle, BS_ZMB_Butcher_Combat_Walk
            # forward samples Walk_F_Slow (100), Walk_F_Med (310), Walk_F_Fast (590-660). _Crawling_Locomotion (calm,
            # on all fours): A_ZMB_Butcher_Calm_Idle.
            "idle": "A_ZMB_Butcher_Combat_Idle", "idle_calm": "A_ZMB_Butcher_Calm_Idle",
            "inplace:walk_slow": "A_ZMB_Butcher_Combat_Walk_F_Slow", "inplace:walk": "A_ZMB_Butcher_Combat_Walk_F_Med",
            "inplace:walk_fast": "A_ZMB_Butcher_Combat_Walk_F_Fast",
            # DA_AttackDef_Butcher_Slice (AM_ZMB_Butcher_Attack_Swipe_LH/RH_Med) and _Stab (Pierce_LH/RH_Med).
            "attack_swipe_l": "A_ZMB_Butcher_Attack_Swipe_LH_Med", "attack_swipe_r": "A_ZMB_Butcher_Attack_Swipe_RH_Med",
            "attack_pierce_l": "A_ZMB_Butcher_Attack_Pierce_LH_Med", "attack_pierce_r": "A_ZMB_Butcher_Attack_Pierce_RH_Med",
            "hit_med_head": "A_ZMB_Butcher_Stumble_Stun", "hit_med_torso": "A_ZMB_Butcher_Hit_Stun_Into",
        },
    },
    # BP_Suicider_Generic -> DA_ModelVariation_Suicider_Generic -> SK_SuiciderA (PA_Suicider).
    "suicider": {
        "mesh": "DI2/Art/Characters/ZombieSpecial/Suicider/SK_SuiciderA",
        "clips": {
            # DA_AnimSetCollection_Suicider_Locomotion: A_ZMB_Suicider_Calm_Idle_01 (its only idle); BS_ZMB_Suicider_Walk
            # forward samples Calm_Walk_Slow_F_01 (45), Combat_Walk_Med_F_01 (130), Combat_Walk_Fast_F_01 (270).
            "idle": "A_ZMB_Suicider_Calm_Idle_01", "idle_calm": "A_ZMB_Suicider_Calm_Idle_01",
            "alert": "A_ZMB_Suicider_Calm2Combat_01",
            "inplace:walk_slow": "A_ZMB_Suicider_Calm_Walk_Slow_F_01", "inplace:walk": "A_ZMB_Suicider_Combat_Walk_Med_F_01",
            "inplace:walk_fast": "A_ZMB_Suicider_Combat_Walk_Fast_F_01",
            # DA_AnimSetCollection_Misc_Suicider "Suicide" (DA_AnimSet_Suicide_Suicider).
            "attack_explode": "A_ZMB_Suicider_Attack_Explosion_01",
            **WALKER_CRAWL,
        },
    },
}


# P2 variants: BP_<Class>_<Variant> -> DA_ModelVariation_<Class>_<Variant>, first VariantAssets mesh (recon/ARCHETYPES.md
# "Full variant table"). Every one is a BP_Base_Walker / BP_Base_Runner child on SKEL_ZombieStandard, so it plays its
# class's clips. "archetype" = the game/data/archetypes.json row name (zombie.gd BODIES key).
def _variant(archetype, mesh):
    cls = archetype.split("_")[0]
    return {"archetype": archetype, "class": cls, "clips_from": cls.lower(), "mesh": "DI2/Art/Characters/" + mesh}


# Body folder -> variant. Comments: the Blueprint's ModelVariation meshes (frequency); the first one is used.
VARIANTS = {
    # BP_Walker_Burning: SK_BurningWalker01 (1), SK_BurningWalker02 (1).
    "walker_burning": _variant("Walker_Burning", "ZombiePerk/BurningWalker/SK_BurningWalker01"),
    # BP_Runner_Burning: SK_BurningRunner01 (1), SK_BurningRunner02 (1).
    "runner_burning": _variant("Runner_Burning", "ZombiePerk/BurningRunner/SK_BurningRunner01"),
    # BP_Walker_Fireman: SK_BurningFiremanWalker01 (1), 02 (1). BP_Runner_Fireman: SK_BurningFiremanRunner01-03 (1).
    "walker_fireman": _variant("Walker_Fireman", "ZombiePerk/FiremanWalker/SK_BurningFiremanWalker01"),
    "runner_fireman": _variant("Runner_Fireman", "ZombiePerk/FiremanRunner/SK_BurningFiremanRunner01"),
    # BP_Walker_Shocking / BP_Runner_Shocking: SK_ShockingWalker01-03 (1) / SK_ShockingRunner01-03 (1).
    "walker_shocking": _variant("Walker_Shocking", "ZombiePerk/ShockingWalker/SK_ShockingWalker01"),
    "runner_shocking": _variant("Runner_Shocking", "ZombiePerk/ShockingRunner/SK_ShockingRunner01"),
    # BP_Walker_Caustic (parent BP_Walker_CDC) / BP_Runner_Caustic (parent BP_Runner_CDC): SK_WalkerMaleCaustic01-02 (1)
    # / SK_RunnerMaleCaustic01-02 (1).
    "walker_caustic": _variant("Walker_Caustic", "ZombieMale/Walker/SK_WalkerMaleCaustic01"),
    "runner_caustic": _variant("Runner_Caustic", "ZombieMale/Runner/SK_RunnerMaleCaustic01"),
    # BP_Walker_Spiky / BP_Runner_Spiky: SK_SpikyWalker01-03 (1) / SK_SpikyRunner01-03 (1).
    "walker_spiky": _variant("Walker_Spiky", "ZombiePerk/SpikyWalker/SK_SpikyWalker01"),
    "runner_spiky": _variant("Runner_Spiky", "ZombiePerk/SpikyRunner/SK_SpikyRunner01"),
    # BP_Walker_Vicious (parent BP_Walker_Spiky): SK_ViciousWalker01 (1), 03 (1). BP_Runner_Vicious (parent
    # BP_Runner_Spiky): SK_ViciousRunner01-03 (1).
    "walker_vicious": _variant("Walker_Vicious", "ZombiePerk/ViciousWalker/SK_ViciousWalker01"),
    "runner_vicious": _variant("Runner_Vicious", "ZombiePerk/ViciousRunner/SK_ViciousRunner01"),
    # BP_Walker_FuelTank (INCENDIARY): SK_FuelTank01 (1). BP_Walker_WaterTank: SK_WaterTank01-03 (1).
    # BP_Walker_Corrosive (CAUSTICWALKER): SK_Corrosive01 (1). (PA_ZombieBackpack; the tanks are BP_EnemyTank_Walker_*.)
    "walker_fueltank": _variant("Walker_FuelTank", "ZombiePerk/FuelTank/SK_FuelTank01"),
    "walker_watertank": _variant("Walker_WaterTank", "ZombiePerk/WaterTank/SK_WaterTank01"),
    "walker_corrosive": _variant("Walker_Corrosive", "ZombiePerk/Corrosive/SK_Corrosive01"),
    # BP_Walker_GrenadeVest (GRENADIER): SK_GrenadeVest01-05 (1). BP_Walker_InsectSwarm: SK_InsectSwarm01-02 (1).
    # BP_Walker_Radio: SK_Radio01 (1).
    "walker_grenadevest": _variant("Walker_GrenadeVest", "ZombiePerk/GrenadeVest/SK_GrenadeVest01"),
    "walker_insectswarm": _variant("Walker_InsectSwarm", "ZombiePerk/InsectSwarm/SK_InsectSwarm01"),
    "walker_radio": _variant("Walker_Radio", "ZombiePerk/Radio/SK_Radio01"),
    # BP_Walker_RiotGear_Light / _Medium / _VeryLight (parent BP_Base_Walker_RiotGear): SK_RiotGearHelmetTorso (1) /
    # SK_RiotGearNoHelmet (1) / SK_RiotGearTorsoOnly (1).
    "walker_riotgear_light": _variant("Walker_RiotGear_Light", "ZombiePerk/RiotGear/SK_RiotGearHelmetTorso"),
    "walker_riotgear_medium": _variant("Walker_RiotGear_Medium", "ZombiePerk/RiotGear/SK_RiotGearNoHelmet"),
    "walker_riotgear_verylight": _variant("Walker_RiotGear_VeryLight", "ZombiePerk/RiotGear/SK_RiotGearTorsoOnly"),
    # BP_Walker_RiotGear_Heavy sets only GenerationConfig.Rarity; its ModelVariation comes from BP_Base_Walker_RiotGear:
    # DA_ModelVariation_Walker_RiotGear_Heavy -> DA_ModelVariantAsset_RiotGearWalker01 -> SK_RiotGearWalker01.
    "walker_riotgear_heavy": _variant("Walker_RiotGear_Heavy", "ZombiePerk/RiotGear/SK_RiotGearWalker01"),
}


def built():
    """The VARIANTS whose body folder exists (archetype_bodies.py ran for them): the per-body builders loop over these."""
    return {b: v for b, v in VARIANTS.items() if (ASSETS / b / f"{b}.glb").exists()}


# SKEL_ZombieStandard's per-bone TranslationRetargetingMode, as `di2x rawanim` writes it into every clip json of that
# skeleton (all walker / runner clips carry the same list).
MODES_FROM = ROOT / "extracted" / "rawanim" / "A_ZMB_Walker_Alert2Combat_01.json"


def retarget_table(clip_glb, mesh_glb):
    """The class mesh -> variant mesh step of RetargetBoneTransform, per bone whose rest differs (glTF space).
    The class clips are already retargeted onto the class mesh's rest pose (tools/merge_anims.py), and every mode
    composes: Skeleton -> the variant rest translation; AnimationScaled -> x |variant| / |class| (the source length
    cancels); AnimationRelative -> t + (variant - class), q * inv(class q) * variant q; Animation -> unchanged."""
    sys.path.insert(0, str(ROOT / "tools"))
    import merge_anims as M
    meta = json.loads(MODES_FROM.read_text())
    modes = dict(zip((b["Name"] for b in meta["Bones"]), meta["RetargetModes"]))
    src = M.rest_pose_ue(M.read_glb(clip_glb)[0])
    dst = M.rest_pose_ue(M.read_glb(mesh_glb)[0])
    out = {}
    for name, mode in modes.items():
        if name not in src or name not in dst or mode == "Animation":
            continue
        (wt, wq), (vt, vq) = src[name], dst[name]
        if np.allclose(wt, vt, atol=1e-3) and (mode != "AnimationRelative" or abs(abs(float(np.dot(wq, vq))) - 1) < 1e-7):
            continue
        r = lambda a: [round(float(x), 6) for x in a]
        if mode == "Skeleton":
            out[name] = {"mode": mode, "t": r(M.ue_to_gltf_t(vt))}
        elif mode == "AnimationScaled":
            if np.linalg.norm(wt) > 1e-4:
                out[name] = {"mode": mode, "k": round(float(np.linalg.norm(vt) / np.linalg.norm(wt)), 6)}
        elif mode == "AnimationRelative":
            dq = M.qmul(M.qinv(wq[None]), vq[None])[0]
            out[name] = {"mode": mode, "dt": r(M.ue_to_gltf_t(vt - wt)), "dq": r(M.ue_to_gltf_q(dq))}
        else:
            raise SystemExit(f"{name}: retarget mode {mode} not handled")
    return out


def build_variant(body):
    spec = VARIANTS[body]
    src = MESH / (spec["mesh"] + ".glb")
    if not src.exists():
        sys.exit(f"{src} missing: run tools/with_cpu.sh <you> tools/di2x.sh mesh '{Path(spec['mesh']).name}\\.uasset$' first")
    out = ASSETS / body
    out.mkdir(parents=True, exist_ok=True)
    glb = out / f"{body}.glb"
    shutil.copy2(src, glb)
    clip_glb = ASSETS / spec["clips_from"] / f"{spec['clips_from']}.glb"
    table = retarget_table(clip_glb, glb)
    (out / f"{body}.retarget.json").write_text(json.dumps(
        {"clips_from": spec["clips_from"], "mesh": Path(spec["mesh"]).name, "bones": table}, indent=1))
    print(f"{body}: {Path(spec['mesh']).name}, clips from {spec['clips_from']}, {len(table)} bones retargeted")
    subprocess.run([sys.executable, str(ROOT / "tools" / "pack_materials.py"), "--pool", str(glb)], check=True)


def clips_for(body):
    walker = json.loads((ASSETS / "walker" / "clips.json").read_text())
    clips = dict(BODIES[body]["clips"])
    for k, v in walker.items():
        if isinstance(v, str) and v.startswith("A_ZMB_Base_") and k not in clips:
            clips[k] = v
    return clips


def build(body):
    spec = BODIES[body]
    src = MESH / (spec["mesh"] + ".glb")
    if not src.exists():
        sys.exit(f"{src} missing: run tools/with_cpu.sh <you> tools/di2x.sh mesh '{Path(spec['mesh']).name}\\.uasset$' first")
    out = ASSETS / body
    out.mkdir(parents=True, exist_ok=True)
    (out / "clips.json").write_text(json.dumps(clips_for(body), indent=1))
    glb = out / f"{body}.glb"
    subprocess.run([sys.executable, str(ROOT / "tools" / "merge_anims.py"), str(src), str(glb), str(out / "clips.json")], check=True)
    subprocess.run([sys.executable, str(ROOT / "tools" / "pack_materials.py"), str(glb)], check=True)


if __name__ == "__main__":
    for b in sys.argv[1:] or list(BODIES) + list(VARIANTS):
        build_variant(b) if b in VARIANTS else build(b)
