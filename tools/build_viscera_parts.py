"""DI2 viscera + spawnable parts -> game/data/viscera_parts.json (+ part meshes in game/assets/di2/<body>/parts/).

What it collects, per body the port ships (walker / runner / shambler / thug):
  * the body's named mesh SUBSECTIONS: CharacterMaterialMasks.MaterialSectionNames / SectionID / SoftBodyNames, matched
    1:1 to the DI2 18-byte items each cooked FSkelMeshRenderSection carries (NumTriangles, BaseIndex, BaseVertexIndex,
    NumVertices, flag, 0). Every subsection gets its exact triangle range in the glb the game loads: the body glb for
    enabled sections, or parts/<SharedMesh>.glb for sections DI2 renders from SharedRenderData (the cooked body
    stores those sections disabled and empty; SK_Skeleton / SK_SkeletonBreak / SK_ZombieViscera supply them).
  * DIEngineMaterialMasks (InitiallyHidden, Dismember, SkeletonViscera, SoftBodyDeformation, ...) decoded to sections.
  * the VisceraAsset (Viscera_ZombieStandard / Viscera_Thug): groups, proxies (boxes, rupture thresholds, switchable
    variants, spawnable-part slots, shadow capsules), gibbable subsections, breakage effects, blacklist rulesets,
    soft-body modifiers, with every subsection name resolved to this body's subsection indices.
  * SpawnableParts (DA_SpawnableParts_*): eye / jaw parts, their AttachmentSpecs, sockets (SKEL_ZombieStandard),
    preset reveal splatter sets, facts, detachability, the part meshes (exported + packed here).
  * every CosmeticEffect_Viscera / CosmeticEffect_SpawnablePart / CosmeticEffect_VisceraShot instance in the extracted
    CE assets, with where the hit-effect trees (game/data/hit_effects.json) and viscera assets use them.
  * the physics assets the gibs and the falling jaw use.
  * NATIVE: class layouts, constructor defaults and the behaviour recovered by static RE of the shipping exe
    (headless Ghidra, extracted/ghidra_viscera; never run). Those values are not re-derived by this script; they are
    stated in NATIVE below with the exe addresses they came from (recon/VISCERA_PARTS.md has the write-up).

Space: DI2 data is UE component space (cm, ref pose). "*_gl" fields use the conversion the body glbs went through
(CUE4Parse glTF): position (x, y, z) cm -> (x, z, y) * 0.01 m; quaternion (x, y, z, w) -> (x, z, y, -w);
scale / extents (x, y, z) -> (x, z, y) (* 0.01 for lengths).
usage: python tools/build_viscera_parts.py        (personal use; reads the user's own extracted files)
"""
import glob
import json
import math
import re
import shutil
import struct
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools/deform"))
import di2_animsets as A  # noqa: E402
from di2mesh import Reader, find_lod_starts, parse_section  # noqa: E402
from glb import Glb  # noqa: E402

JSON = ROOT / "extracted/json"
RAW = ROOT / "extracted/raw"
MESH = ROOT / "extracted/mesh"
OUT = ROOT / "game/data/viscera_parts.json"

# folder -> skeletal mesh (see zombie.gd BODIES / tools/build_character_states.py)
BODIES = {"walker": "SK_WalkerMaleCas01", "runner": "SK_RunnerMaleCas01", "shambler": "SK_ShamMaleCas01", "thug": "SK_ThugA01"}
# Special archetypes (tools/archetype_bodies.py, recon/ARCHETYPES.md).
BODIES.update({"screamer": "SK_Screamer01", "slobber": "SK_SlobberA", "butcher": "SK_Butcher01", "suicider": "SK_SuiciderA"})
from archetype_bodies import built  # noqa: E402  P2 variant bodies (mesh only, class clips)
BODIES.update({b: Path(v["mesh"]).name for b, v in built().items()})

# ---------------------------------------------------------------------------------------------------------------
# Native behaviour recovered by static RE (DeadIsland-Win64-Shipping.exe, image base 0x140000000). Not derivable
# from asset data; each entry cites the function it was read from. recon/VISCERA_PARTS.md explains them.
NATIVE = {
    "UCosmeticEffect_Viscera": {
        "size": "0x58", "vtable": "0x1453f1c58",
        "fields": {"RawVisceraToCull": "TArray<FName> @0x38", "RawVisceraToUnHide": "TArray<FName> @0x48"},
        "defaults": {"RawVisceraToCull": [], "RawVisceraToUnHide": []},
        "apply": "0x141256350 creates a UCosmeticEffect_VisceraData instance (target actor @+0x60); 0x141259540 then "
                 "takes the actor's USkeletalMeshComponent and calls CullSubsectionByName (0x140ece1f0) for every "
                 "RawVisceraToCull name and UnhideSubsectionByName (0x140ed2dc0) for every RawVisceraToUnHide name. "
                 "One-shot: the instance finishes immediately.",
    },
    "UCosmeticEffect_VisceraShot": {
        "size": "0x40", "vtable": "0x1453f6750",
        "fields": {"Radius": "float @0x38"}, "defaults": {"Radius": 10.0},
        "apply": "0x1412563e0: target must be an ADICharacter with a VisceraComponent (actor+0x850). The hit location is "
                 "moved into the hit bone's REFERENCE pose (component bone transform inverse, then ref-pose bone "
                 "transform), then UVisceraComponent::Shot logic (0x140ecf8e0) runs for every VisceraGroup: for "
                 "groups with bIsShootable, each child proxy is tested with ProxyPointTest(Location, Scale3D * "
                 "CutMargin, point, Radius) and hits are queued in the component's proxy-state list (+0xe8).",
        "used_by_data": "no CosmeticEffect_VisceraShot instance exists in the 2545 extracted CE assets",
    },
    "UCosmeticEffect_SpawnablePart": {
        "size": "0x50", "vtable": "0x1453f1260",
        "fields": {"SpawnablePartSlots": "TArray<ESpawnablePartSlot> @0x38", "bSpawn": "bool @0x48",
                   "bDetach": "bool @0x49", "bDelete": "bool @0x4a"},
        "defaults": {"bSpawn": True, "bDetach": True, "bDelete": False},
        "apply": "0x141255ad0: target must be an ADICharacter with a UDamageRepercussionsComponent. For each slot: if "
                 "bDelete -> NetMulticastDeletePart(actor, slot); else { if bSpawn -> NetMulticastSpawnPart(actor, slot); "
                 "if bDetach -> NetMulticastDetachPart(actor, slot) } (in that order, so the default spawns AND "
                 "detaches in one go).",
    },
    "USpawnablePartResponse": {
        "what": "hit-react tree response (CT_HitReact_Organs_Head_Zombie has 15; game/data/hit_reacts.json, hit-reacts "
                "session, exports them). This, not a CE, is how ordinary head hits pop eyes and dislocate jaws.",
        "fields": {"Slots": "TArray<ESpawnablePartSlot> @0x30", "NumSlotsToActivate": "int @0x40",
                   "bSpawn": "bool @0x44", "bDetach": "bool @0x45", "bDelete": "bool @0x46"},
        "defaults": {"NumSlotsToActivate": 1, "bSpawn": False, "bDetach": False, "bDelete": False},
        "ctor": "0x141df1220",
        "apply": "0x1412b4800: victim must be an ADICharacter (and a byte at victim+0x120 must be 3, presumably the "
                 "authority net role). Copies Slots, then NumSlotsToActivate times (while slots remain): i = "
                 "min(int((rand() & 0x7fff) * 3.051851e-05 * count), count - 1); slot = Slots[i]; if bDelete -> "
                 "DeletePart else { if bSpawn -> SpawnPart; if bDetach -> DetachPart }; remove Slots[i]. Logs and "
                 "does nothing when Slots is empty or NumSlotsToActivate is 0.",
    },
    "ESpawnablePartSlot": {"LeftEye": 0, "RightEye": 1, "Jaw": 2},
    "ECutBias": {"Cull": 0, "Body": 1, "Limb": 2, "BodySentinel": 3, "LimbSentinel": 4, "BoxCentre": 5},
    "EVisceraOwnership": {"Torso": 0, "Limb": 1},
    "FSpawnablePart": {
        "size": "0x70",
        "fields": {"OriginalPartToHide": "FName @0x00", "AttachSocket": "FName @0x08", "AttachOffset": "FTransform @0x10",
                   "ClassToSpawn": "UClass* @0x40", "AttachmentSpecToSpawn": "UAttachmentSpecAsset* @0x48",
                   "PresetSplatter": "USplatterSet* @0x50", "Slot": "u8 @0x58", "bDetachable": "bool @0x59",
                   "SpawnedFact": "FName @0x5c", "DetachedFact": "FName @0x64"},
    },
    "UDamageRepercussionsComponent.parts": {
        "state": "TMap<ESpawnablePartSlot, {bool bSpawned @0, bool bDetached @1, bool bDeleted @2, weak actor @4, "
                 "weak attachment @0xc}> @0x328",
        "SpawnPart": "0x1412a4950 -> SpawnPartForMesh(owner mesh, slot) via RPC.",
        "SpawnPartForMesh": "0x1412a4790: needs the mesh's CharacterInitialStateWrapper.SpawnableParts; skips if the "
                            "slot was already spawned. Tries ClassToSpawn (0x140ed1c40, actor) then "
                            "AttachmentSpecToSpawn (0x140ed1e60). Both first hide OriginalPartToHide on the body "
                            "(CullSubsectionByName) and ABORT if that hid nothing (subsection already hidden). The "
                            "attachment path spawns the spec on the body mesh, then stamps PresetSplatter on the body "
                            "(splatter component of the owner). On success: bSpawned = true and SpawnedFact (if not "
                            "None) is set true in the owner's knowledge base.",
        "DetachPart": "0x1412a4660: only if spawned and not detached/deleted. Requires the part's bDetachable "
                      "(0x140ecd0a0 / 0x140ecd110 return false otherwise). Detaches the attachment (virtual +0x268 with "
                      "true). bDetached = true; DetachedFact set if not None.",
        "DeletePart": "0x1412a43a0: only if spawned and not detached/deleted. Destroys the part (actor Destroy / "
                      "attachment virtual +0x268 with false). bDeleted = true. The hidden original subsection is NOT "
                      "unhidden.",
        "DetachOrDeletePart": "0x1412a44b0: detach if bDetachable, else delete. Called by viscera rupture for every "
                              "slot in the ruptured proxy's SpawnablePartSlots.",
    },
    "USpawnablePartAttachment": {
        "size": "0xb0", "vtable": "0x14575f800",
        "fields": {"bAttachToDismemberedLimbs": "bool @0x90", "BoneNameForVelocity": "FName @0x94",
                   "MaxAngularVelocity": "float @0x9c"},
        "defaults": {"bAttachToDismemberedLimbs": True, "BoneNameForVelocity": "None", "MaxAngularVelocity": 270.0},
        "detach": "0x141183160: reads the parent mesh's physics linear velocity and angular velocity (rad -> deg, "
                  "x 57.295776) at BoneNameForVelocity (falls back to the attach socket name when None), sends them "
                  "to the part actor's OnDetach(ParentMesh, Velocity, AngularVelocity) event, then detaches. "
                  "MaxAngularVelocity is stored (default 270) but no read of it was found in the decompiled paths "
                  "(UNVERIFIED).",
    },
    "UVisceraGroup": {
        "fields": {"Ownership": "EVisceraOwnership @0x50", "BoneName": "FName @0x54", "bIsShootable": "bool @0x5c",
                   "CutMargin": "float @0x60", "bCanRupture": "bool @0x64", "SwitchOnDismemberment": "TArray @0x68"},
        "defaults": {"Ownership": "Torso", "BoneName": "None", "bIsShootable": False, "CutMargin": 0.75,
                     "bCanRupture": False},
        "ctor": "0x140ed66a0",
    },
    "UVisceraProxy": {
        "fields": {"Location": "FTransform @0x50 (rot 0x50, trans 0x60, scale 0x70; Scale3D = box half extents, cm)",
                   "ProxyID": "int @0x80", "VisceraSubsections": "TArray<FName> @0x88",
                   "BrokenSubsections": "TArray<FName> @0x98", "SpawnablePartSlots": "TArray<u8> @0xa8",
                   "CutBias": "ECutBias @0xb8", "bCanRupture": "bool @0xbc", "bIgnoreMaxBlend": "bool @0xbd",
                   "bHoldFinalState": "bool @0xbe", "RuptureEffects": "CE @0xc0", "RuptureThreshold": "float @0xc8",
                   "RuptureBoneId": "int @0xcc", "SwitchableThresholds": "TArray<float> @0xd0",
                   "SwitchableVariants": "TArray @0xe0", "BreakageBoneId": "int @0xf0",
                   "GibbableSectionAttachment": "@0xf8", "ShadowCapsules": "TArray<FName> @0x100",
                   "CutEvents": "@0x110", "BreakEvents": "@0x120", "RuptureEvents": "@0x130",
                   "SoftBodyMovementModifiers": "TArray (0x30 each) @0x140"},
        "defaults": {"ProxyID": -1, "CutBias": "Cull", "bCanRupture": False, "bIgnoreMaxBlend": True,
                     "bHoldFinalState": False, "RuptureThreshold": 1.0, "Scale3D": [1, 1, 1]},
        "ctor": "0x140ed6710",
    },
    "UVisceraSwitchableVariant": {
        "fields": {"RootProxyID": "int @0x50", "VisceraSubsections": "TArray<FName> @0x58",
                   "SwitchThreshold": "float @0x68", "ActivationEffects": "CE @0x70"},
        "defaults": {"RootProxyID": -1, "SwitchThreshold": 100.0},
        "ctor": "0x140ed6ab0",
    },
    "UVisceraComponent": {
        "Splatter": "UFUNCTION Splatter (exec 0x141e37490) -> 0x141256940: every FLESH splatter stamp applied to the "
                    "body is offered to the viscera. See 'rupture_from_splatter'.",
        "Shot / LimbCut / BisectionCut": "UFUNCTIONs (0x1412557e0 / 0x1412450a0 / 0x141236160). Shot = the VisceraShot "
                                         "proxy test. LimbCut and BisectionCut belong to the dismemberment path "
                                         "(dismember-re session).",
        "SpawnRandomGibs / SpawnRandomGibAttachments": "0x141256850 / 0x141256780 (MaximumGibsToSpawn): candidates = "
            "every VisceraGibbableSubSection whose owning proxy has not been gibbed; while more than Max remain, remove "
            "one at index int((rand() & 0x7fff) * 3.051851e-05 * count) (clamped to count-1). Each chosen gib: mark "
            "the proxy state gibbed, spawn its ModularAttachment on the body mesh (virtual +0x260) and detach it.",
        "proxy_state": "per proxy: float damage @0, float cap @4, float falloff @8, bool gibbed @0xc, bool final @0xe, "
                       "int variant_index @0x10",
        "ProxyPointTest": "0x1440a32e0 (as compiled; SSE lanes checked in the disassembly): l = InverseTransformPosition"
                          "(proxy.Location, p) (divides by Scale3D); dx = |l.x| ONLY (the y/z lanes are masked off); "
                          "m = min(dx, |e.x|, |e.y|, |e.z|) with e = Scale3D * CutMargin; hit = (dx - m)^2 < Radius^2.",
    },
    "rupture_from_splatter": {
        "source": "0x141256940 (stamp gate + proxy loop), 0x140ed1f80 (per-group proxy selection), 0x14124f570 "
                  "(UVisceraComponent virtual +0x408: ApplyProxyDamage), 0x141258ad0 (+0x400: SwitchVariant), "
                  "0x141243e50 (+0x3f0: HideProxy), 0x141232720 (+0x3f8: ActivateVariant)",
        "stamp_gate": "the stamp's FSplatterMeshInfo must have (SplatterType & 1) (a *Decal type), RuptureInteraction "
                      "!= NoRupture, MaximumRuptureCount > 0, and RuptureDamageMultiplier >= 1e-4 or "
                      "RuptureDamageOffset >= 1e-4.",
        "radius": "RuptureRadiusMultiplier * UVScale + RuptureDepthOffset   (as compiled: the DEPTH offset, "
                  "+0x80, is added; RuptureRadiusOffset +0x74 is not read here)",
        "depth": "RuptureDepthMultiplier * DepthScale + RuptureDepthOffset",
        "selection": "for every VisceraGroup with bCanRupture: proxies (recursive) with bCanRupture. n = stamp frame X "
                     "axis (projection direction), t / b = frame Y / Z axes, o = stamp origin (all ref-pose component "
                     "space). d = dot(n, centre) - dot(n, o); rn = sum_i |dot(S_i * axis_i, n)| (box support). Keep "
                     "if d - rn < depth AND |centre - o - n*d|^2 < (0.25 * (sum_i |dot(S_i axis_i, b)| + sum_i "
                     "|dot(S_i axis_i, t)|) + 0.5 * radius)^2.",
        "skip": "proxies whose state is gibbed or final; and, for MaxDecal stamps (SplatterType & 0x21 == 0x21), "
                "proxies with bIgnoreMaxBlend (default TRUE). Only proxies with damage < RuptureThreshold.",
        "amount": "f = 1 - min(|o - centre|^2 / UVScale^2, 1) when RuptureFalloffFactor > 1e-4 and UVScale > 1e-4 "
                  "(else f = 1; skip when f <= 1e-4). amount = (UVScale * 0.01 * f * DisplacementScale * "
                  "RuptureDamageMultiplier + RuptureDamageOffset) * f.",
        "apply": "cap = RuptureThreshold * RuptureLimitFraction. If damage >= cap: nothing. damage = min(damage + "
                 "amount, cap). If !bHoldFinalState and damage >= RuptureThreshold -> RUPTURE: emit RuptureEvents; "
                 "apply SoftBodyMovementModifiers; play RuptureEffects (CE) at the hit; for every SpawnablePartSlot "
                 "-> DamageRepercussions.DetachOrDeletePart; mark ruptured. Otherwise, with p_old / p_new = 100 * "
                 "damage / (RuptureThreshold + 1e-4): if SwitchableThresholds[k] (k = state variant index) lies in "
                 "(p_old, p_new] and SwitchableVariants[k] is set -> SwitchVariant on the proxy (or on every proxy "
                 "of its VisceraSwitchableGroup) and play the variant's ActivationEffects. Stops after "
                 "MaximumRuptureCount ruptures per stamp.",
        "SwitchVariant": "HideProxy(proxy) (cull VisceraSubsections, BrokenSubsections and every variant's "
                         "subsections, and switch off its ShadowCapsules), unhide the variant's VisceraSubsections, "
                         "ActivateVariant (soft-body modifiers + GPU influence), variant_index += 1.",
        "unverified": "the block between selection and ApplyProxyDamage (~800 lines of matrix maths in 0x141256940, "
                      "likely the VisceraStateBlacklistRuleset checks) was not decoded.",
    },
    "CullSubsectionByName": {
        "source": "0x140ece1f0 (hide) / 0x140ed2dc0 (unhide) -> 0x140ecd5a0(mesh, name, visible)",
        "rule": "with the mesh's CharacterMaterialMasks: EVERY subsection whose MaterialSectionNames entry equals the "
                "name gets its per-LOD visibility byte set (USkinnedMeshComponent 0x143646f60, all LODs); names "
                "that match nothing do nothing. Returns true if any visibility changed. Without the masks it falls "
                "back to material-slot names (ShowMaterialSection); all four bodies have masks.",
    },
}

# DI2's part actor blueprints, decoded from their Kismet bytecode (CUE4Parse with ReadScriptData; scratch dump).
PART_ACTORS = {
    "BP_Part_Jaw": {
        "components": {"SK_Jaw": "DSSkeletalMeshComponent (collision QueryAndPhysics, object ECC_GameTraceChannel5)",
                       "SoftBody": "SoftBodyComponent", "ActorGridProxy": "sphere r=5 (nav obstacle, no collision)",
                       "CharacterFader": "CharacterFaderComponent"},
        "DespawnConditionsName": "Limb",
        "BeginPlay": "bHangFromLeftSide = RandomBool(); SK_Jaw.SetSkeletalMesh(InitialMesh); register for fading; if "
                     "the KB expression {DisableImpactsOnDeath} is true at the actor location -> "
                     "SK_Jaw.SetCollisionResponseToChannel(20, Ignore).",
        "OnSpawn(ParentMesh)": "BeginAttachedState: HideSkeletonPart(ParentMesh, 'Sec_Jaw'); SoftBody data = "
                               "SoftBody_Jaw_Left if bHangFromLeftSide else SoftBody_Jaw_Right; a = 10 if "
                               "bHangFromLeftSide else -10; SK_Jaw.AddLocalTransform(T = (0, 0, -|sin(a deg) * 5|) cm, "
                               "R = Rotator(Roll a, Pitch 0, Yaw 0)).",
        "OnDetach(ParentMesh, Velocity, AngularVelocity)": "BeginDetachedState: HideSkeletonPart(ParentMesh, 'Sec_Jaw'); "
            "detach (keep world); visible; SetPhysicsAsset(PA_JawFalling); overlap events on; collision "
            "QueryAndPhysics; SetSimulatePhysics(true); SetAllPhysicsAngularVelocity(AngularVelocity deg/s, add); "
            "SetAllPhysicsLinearVelocity(Velocity, add); destroy SoftBody; SetMassOverrideInKg(all bodies, 30 kg); "
            "despawn manager: ScheduleActorDespawn(self, 'Limb', 'Jaw cleanup').",
    },
    "BP_Part_Eye": {
        "components": {"SK_Eye": "DSSkeletalMeshComponent (object ECC_GameTraceChannel5, overlap only)",
                       "SoftBody": "SoftBodyComponent (DataAsset SoftBody_Eye)", "ActorGridProxy": "sphere r=3",
                       "CharacterFader": "CharacterFaderComponent"},
        "BeginPlay": "SK_Eye.SetSkeletalMesh(InitialMesh); SoftBody.DestroySoftSimulations(); "
                     "SoftBody.CreateSoftSimulations(); register for fading; {DisableImpactsOnDeath} -> ignore "
                     "channel 20.",
        "OnSpawn(ParentMesh)": "SoftBody.SetEnableAll(true) (the eye dangles from its socket on the soft body).",
        "detach": "never: every eye part has bDetachable = false, so DetachPart fails; DetachOrDeletePart deletes it.",
    },
    "BP_SkeletalMeshSubSectionAttachment_Gib": {
        "parent": "BP_SkeletalMeshSubSectionAttachment (Mesh: DSSkeletalMeshComponent, collision object "
                  "ECC_GameTraceChannel5, ignores Pawn; DespawnConditionsName 'Debris'; ActorGridProxy sphere r=15)",
        "ForcedDeSpawnDelay": 3.5,
        "SoftBody": "SoftBodyComponent attached to Mesh, bAutoCreateOnBeginPlay false",
        "note": "the gib actor shows the body's SubSectionNamesToSpawn subsections and simulates on the gib's "
                "PhysicsAsset (one box body on a body bone); SubSectionNamesToHide are hidden on the body.",
    },
}

UE_TO_GL = "(x, y, z) cm -> (x, z, y) * 0.01 m; quat (x, y, z, w) -> (x, z, y, -w)"


# --- small helpers ------------------------------------------------------------------------------------------------

def oname(ref):
    """'Class'Pkg:Outer.Name'' -> 'Name' (last path element) for object references."""
    m = re.search(r"'([^']+)'", (ref or {}).get("ObjectName", "")) if isinstance(ref, dict) else None
    return m.group(1).split(":")[-1].split(".")[-1] if m else None


def opath(ref):
    """Reference -> export key ('Outer.Name' inside the package, or the package-level name)."""
    m = re.search(r"'([^']+)'", ref.get("ObjectName", "")) if isinstance(ref, dict) else None
    if not m:
        return None
    s = m.group(1)
    return s.split(":", 1)[1] if ":" in s else s


def ekey(e):
    o = e.get("Outer")
    if not o:
        return e["Name"]
    m = re.search(r"'([^']+)'", o.get("ObjectName", ""))
    s = m.group(1) if m else ""
    return (s.split(":", 1)[1] + "." if ":" in s else "") + e["Name"]


def enum(v):
    return str(v).split("::")[-1] if v is not None else None


def gl_pos(t):
    return [round(t.get("X", 0) * 0.01, 6), round(t.get("Z", 0) * 0.01, 6), round(t.get("Y", 0) * 0.01, 6)]


def gl_quat(q):
    return [round(q.get("X", 0), 7), round(q.get("Z", 0), 7), round(q.get("Y", 0), 7), round(-q.get("W", 1), 7)]


def gl_vec(s, k=1.0):
    return [round(s.get("X", 1) * k, 6), round(s.get("Z", 1) * k, 6), round(s.get("Y", 1) * k, 6)]


def rotator_quat(r):
    """UE4 FRotator::Quaternion (degrees)."""
    p, y, ro = (math.radians(r.get(k, 0.0)) * 0.5 for k in ("Pitch", "Yaw", "Roll"))
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return {"X": cr * sp * sy - sr * cp * cy, "Y": -cr * sp * cy - sr * cp * sy,
            "Z": cr * cp * sy - sr * sp * cy, "W": cr * cp * cy + sr * sp * sy}


def transform(t, extents=False):
    """FTransform JSON -> {ue: {...}, gl: {...}}. extents=True: Scale3D are half extents in cm (viscera boxes)."""
    t = t or {}
    tr, q, s = t.get("Translation", {}), t.get("Rotation", {}), t.get("Scale3D", {"X": 1, "Y": 1, "Z": 1})
    ue = {"t": [tr.get(k, 0.0) for k in "XYZ"], "q": [q.get(k, 0.0 if k != "W" else 1.0) for k in "XYZW"],
          "s": [s.get(k, 1.0) for k in "XYZ"]}
    gl = {"t": gl_pos(tr), "q": gl_quat(q)}
    if extents:
        gl["half_extents"] = gl_vec(s, 0.01)
    else:
        gl["s"] = gl_vec(s)
    return {"ue": ue, "gl": gl}


def bits(v, n=64):
    v = int(v)
    return [i for i in range(n) if v >> i & 1]


def json_path(name):
    p = A.index().get(name)
    return p


def load(name):
    return A.load(name)


def di2x(*args):
    """Run tools/di2x (what tools/di2x.sh does, without bash: from Python, 'bash' can resolve to WSL)."""
    import os
    env = dict(os.environ, DOTNET_ROOT=str(ROOT / "tools/dotnet10"))
    return subprocess.run([str(ROOT / "tools/di2x/bin/out/di2x.exe"), *args], cwd=ROOT, env=env, capture_output=True,
                          text=True)


def ensure_json(names):
    """Export package JSON with di2x for names not extracted yet (never overwrites existing exports)."""
    missing = [n for n in names if n and not json_path(n)]
    if not missing:
        return
    lst = ROOT / "extracted/_viscera_parts_names.txt"
    lst.write_text("\n".join(missing))
    di2x("json", f"@{lst}")
    lst.unlink()
    A.index.cache_clear()
    A.load.cache_clear()


# --- cooked mesh: sections, subsection items, triangles -------------------------------------------------------------

def cooked_lod0(raw_path):
    """LOD0 of a cooked DI2 USkeletalMesh package: sections (with DI2 items), index buffer, positions (cm)."""
    d = raw_path.read_bytes()
    r = Reader(d, find_lod_starts(d)[0])
    r.strip(); r.boolean()
    if not r.boolean():
        raise ValueError(f"{raw_path.name}: LOD0 not inlined")
    n = r.i32(); r.p += 2 * n
    secs = [parse_section(r) for _ in range(r.i32())]
    n = r.i32(); r.p += 2 * n
    r.u32()                                   # BuffersSize
    r.strip()                                 # stream strip flags
    isz = r.u8(); es, n, off = r.bulk()
    idx = np.frombuffer(d, "<u2" if isz == 2 else "<u4", count=n, offset=off).astype(np.int64)
    r.u32(); nv = r.u32(); es, n, off = r.bulk()
    pos = np.frombuffer(d, "<f4", count=3 * nv, offset=off).reshape(nv, 3)
    for s in secs:
        it = s["di2_items"]
        s["items"] = [struct.unpack_from("<IIIHHH", it, 18 * j) for j in range(len(it) // 18)]
    return secs, idx, pos


def section_tris(idx, s):
    t = idx[s["BaseIndex"]: s["BaseIndex"] + 3 * s["NumTriangles"]].reshape(-1, 3)
    if len(t) and t.max() < s["NumVertices"]:   # DI2 stores section-relative indices
        t = t + s["BaseVertexIndex"]
    return t


def tri_keys(P):
    """(n, 3, 3) float32 glTF-space triangles -> hashable keys independent of vertex order (winding)."""
    v = np.ascontiguousarray(P.astype(np.float32) + np.float32(0.0)).view(np.uint32).reshape(len(P), 3, 3)  # -0 -> +0
    order = np.lexsort((v[:, :, 2], v[:, :, 1], v[:, :, 0]), axis=1)
    s = np.take_along_axis(v, order[:, :, None], axis=1)
    return [row.tobytes() for row in s.reshape(len(P), 9)]


def glb_prims(path):
    g = Glb(path)
    out = []
    for mi, pi, mat, p in g.primitives():
        P = g.accessor(p["attributes"]["POSITION"]).astype(np.float32)
        I = g.accessor(p["indices"]).reshape(-1, 3).astype(np.int64)
        out.append({"material": mat, "tris": P[I]})
    return out


def match_section(sec, idx, pos, glb_tris, label):
    """Map each glb triangle of a primitive to its cooked triangle (CUE4Parse keeps order, drops degenerates)."""
    ct = section_tris(idx, sec)
    cp = pos[ct]                                               # cm, UE
    cgl = np.stack([cp[..., 0], cp[..., 2], cp[..., 1]], -1).astype(np.float32) * np.float32(0.01)
    ck, gk = tri_keys(cgl), tri_keys(glb_tris)
    j, out = 0, np.empty(len(gk), np.int64)
    for k, key in enumerate(gk):
        while j < len(ck) and ck[j] != key:
            j += 1
        if j == len(ck):
            raise RuntimeError(f"{label}: glb triangle {k} has no cooked match")
        out[k] = j
        j += 1
    return out, len(ct)


def subsection_ranges(sec, glb_to_cooked):
    """Per DI2 item: cooked triangle / vertex range inside the section and the glb triangle range."""
    rows = []
    t0 = sec["items"][0][1] if sec["items"] else 0
    v0 = sec["items"][0][2] if sec["items"] else 0
    for nt, bi, bvi, nv, flag, _ in sec["items"]:
        first = (bi - t0) // 3
        sel = np.nonzero((glb_to_cooked >= first) & (glb_to_cooked < first + nt))[0]
        g = [int(sel[0]), int(len(sel))] if len(sel) else [None, 0]
        if len(sel) and sel[-1] - sel[0] + 1 != len(sel):
            raise RuntimeError("subsection triangles are not contiguous in the glb")
        rows.append({"cooked_tris": [int(first), int(nt)], "cooked_verts": [int(bvi - v0), int(nv)], "item_flag": flag,
                     "glb_tris": g})
    return rows


# --- glb copies ---------------------------------------------------------------------------------------------------

def write_glb_with_materials(src, dst, rename):
    """Copy a glb, renaming materials (old -> new) in its JSON chunk."""
    b = src.read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    g = json.loads(b[20:20 + jl])
    for m in g.get("materials", []):
        m["name"] = rename.get(m.get("name"), m.get("name"))
    js = json.dumps(g, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    rest = b[20 + jl:]
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + len(rest)) + struct.pack("<II", len(js), 0x4E4F534A) + js + rest
    dst.write_bytes(out)


def mesh_glb(name, regex):
    hit = next(MESH.rglob(f"{name}.glb"), None)
    if hit is None:
        di2x("mesh", regex)
        hit = next(MESH.rglob(f"{name}.glb"), None)
    if hit is None:
        raise FileNotFoundError(name)
    return hit


def raw_package(json_file):
    rel = json_file.relative_to(JSON).with_suffix(".uasset")
    p = RAW / rel
    if not p.exists():
        di2x("raw", "^" + re.escape(rel.as_posix()) + "$")
    return p


def is_variant(glb):
    """A part glb of a P2 variant body (archetype_bodies.VARIANTS): its textures go through the shared pool."""
    from archetype_bodies import VARIANTS
    return Path(glb).resolve().relative_to((ROOT / "game/assets/di2").resolve()).parts[0] in VARIANTS


def pack(glbs):
    out = ""
    for group, flag in (([g for g in glbs if not is_variant(g)], []), ([g for g in glbs if is_variant(g)], ["--pool"])):
        if not group:
            continue
        r = subprocess.run([sys.executable, str(ROOT / "tools/pack_materials.py"), *flag, *map(str, group)], cwd=ROOT,
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(r.stderr)
        out += r.stdout
    return out


def mi_chain_textures(mi):
    """Texture parameters of a material instance resolved through its Parent chain (child values win)."""
    chain, tex, n = [], {}, mi
    while n:
        ensure_json([n])
        d = load(n)
        e = next((x for x in d or [] if x["Type"].startswith("Material")), None)
        if e is None:
            chain.append(f"{n} (not extracted)")
            break
        chain.append(n)
        p = e.get("Properties", {})
        for t in p.get("TextureParameterValues", []):
            k = (t.get("ParameterInfo") or {}).get("Name")
            if k and k not in tex and t.get("ParameterValue"):
                tex[k] = oname(t["ParameterValue"])
        n = oname(p.get("Parent"))
    return chain, tex


def fill_part_materials(glb, layer=None, layer_source=None):
    """pack_materials only sees an MI's own texture overrides (and flesh_materials.json, which covers the body
    sections). Part MIs such as MI_WalkerJaw override nothing, so fill the empty slots from the MI chain."""
    import pack_materials as PM
    man_path = glb.parent / f"{glb.stem}.materials.json"
    man = json.loads(man_path.read_text())
    placer = PM.Placer(glb, True) if is_variant(glb) else None
    for name, entry in man.items():
        chain, tex = mi_chain_textures(name)
        entry["mi_chain"] = chain
        for slot, keys in PM.SLOTS.items():
            # DI2's own parameter names resolved through the chain win over CUE4Parse's PM_* guesses.
            tname = next((tex[k] for k in keys if k in tex and not k.startswith("PM_")), None)
            src = PM.find_by_name(tname) if tname else None
            if src:
                if placer:
                    rel = placer.place(src)
                else:
                    shutil.copy2(src, glb.parent / "textures" / src.name)
                    rel = f"textures/{src.name}"
                if entry.get(slot) != rel:
                    entry.setdefault("replaced_by_mi_chain", {})[slot] = entry.get(slot)
                entry[slot] = rel
            elif slot not in entry:
                entry.setdefault("unresolved_slots", []).append(slot)
        if layer:
            entry["layer"], entry["layer_source"] = layer, layer_source
    man_path.write_text(json.dumps(man, indent=1))
    return man


# --- skeleton ------------------------------------------------------------------------------------------------------

def skeleton_bones():
    meta = json.loads(next((ROOT / "extracted/rawanim").glob("A_ZMB_Walker_*.json")).read_text())
    return [b["Name"] for b in meta["Bones"]]


def skeleton_sockets():
    out = {}
    for e in load("SKEL_ZombieStandard") or []:
        if e["Type"] != "SkeletalMeshSocket":
            continue
        p = e["Properties"]
        loc, rot = p.get("RelativeLocation", {}), p.get("RelativeRotation", {})
        q = rotator_quat(rot)
        out[p["SocketName"]] = {"bone": p["BoneName"],
                                "ue": {"t": [loc.get(k, 0.0) for k in "XYZ"],
                                       "rotator": [rot.get(k, 0.0) for k in ("Pitch", "Yaw", "Roll")],
                                       "q": [q[k] for k in "XYZW"]},
                                "gl": {"t": gl_pos(loc), "q": gl_quat(q)}}
    return out


# --- physics assets --------------------------------------------------------------------------------------------------

def physics_asset(name):
    d = load(name)
    if not d:
        return None
    pm_cache = {}
    bodies = []
    for e in d:
        if e["Type"] != "SkeletalBodySetup":
            continue
        p = e["Properties"]
        shapes = []
        for kind, elems in (p.get("AggGeom") or {}).items():
            for el in elems:
                c, r = el.get("Center", {}), el.get("Rotation", {})
                q = rotator_quat(r)
                sh = {"kind": kind.replace("Elems", "").lower(), "center_ue": [c.get(k, 0.0) for k in "XYZ"],
                      "rotator_ue": [r.get(k, 0.0) for k in ("Pitch", "Yaw", "Roll")], "center_gl": gl_pos(c),
                      "q_gl": gl_quat(q)}
                if kind == "BoxElems":
                    # FKBoxElem X/Y/Z are full lengths (UE4 creates the PhysX box with half = X / 2)
                    sh["size_ue"] = [el.get("X"), el.get("Y"), el.get("Z")]
                    sh["half_extents_gl"] = [round(el.get("X") * 0.005, 6), round(el.get("Z") * 0.005, 6),
                                             round(el.get("Y") * 0.005, 6)]
                elif kind == "SphylElems":
                    sh.update(radius_ue=el.get("Radius"), length_ue=el.get("Length"))
                elif kind == "SphereElems":
                    sh.update(radius_ue=el.get("Radius"))
                shapes.append(sh)
        pm = oname((p.get("DefaultInstance") or {}).get("PhysMaterialOverride"))
        if pm and pm not in pm_cache:
            ensure_json([pm])
            pd = next((x["Properties"] for x in load(pm) or [] if x["Type"] == "PhysicalMaterial"), {})
            pm_cache[pm] = pd
        bodies.append({"bone": p.get("BoneName"), "collision_trace": enum(p.get("CollisionTraceFlag")),
                       "phys_material": pm, "phys_material_props": pm_cache.get(pm), "shapes": shapes,
                       "instance": {k: v for k, v in (p.get("DefaultInstance") or {}).items() if k != "PhysMaterialOverride"}})
    return {"bodies": bodies}


# --- per-body subsections --------------------------------------------------------------------------------------------

def body_mesh(folder, sk):
    d = load(sk)
    sm = next(e for e in d if e["Type"] == "SkeletalMesh")
    cm = next(e["Properties"] for e in d if e["Type"] == "CharacterMaterialMasks")
    dm = next(e["Properties"]["Masks"] for e in d if e["Type"] == "DIEngineMaterialMasks")
    mats = [oname(m.get("Material")) for m in sm.get("SkeletalMaterials", [])]
    shared = {}
    for i, srd in enumerate(sm["Properties"].get("SharedRenderData", [])):
        for mp in srd["Mapping"]:
            if mp["LOD"] == 0:
                shared[mp["BaseSection"]] = {"mesh": oname(srd["Mesh"]), "shared_section": mp["SharedSection"],
                                             "tail_index": i + 1}
    secs, idx, pos = cooked_lod0(raw_package(json_path(sk)))
    names, sids, sbn = cm["MaterialSectionNames"], cm["SectionID"], cm.get("SoftBodyNames", [])
    assert len(names) == len(sids) == sum(len(s["items"]) for s in secs), f"{sk}: subsection count mismatch"
    body_glb = ROOT / f"game/assets/di2/{folder}/{folder}.glb"
    prims = glb_prims(body_glb)
    enabled = [i for i, s in enumerate(secs) if not s["bDisabled"]]
    assert len(prims) == len(enabled), f"{folder}: {len(prims)} glb primitives vs {len(enabled)} enabled sections"
    parts_dir = ROOT / f"game/assets/di2/{folder}/parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    out_secs, sub = [], 0
    shared_glbs = []
    for i, s in enumerate(secs):
        entry = {"index": i, "material": mats[s["MaterialIndex"]], "disabled_in_cook": bool(s["bDisabled"]),
                 "di2_tail": s["di2_tail"].hex()}
        if not s["bDisabled"]:
            p = enabled.index(i)
            g2c, ncooked = match_section(s, idx, pos, prims[p]["tris"], f"{folder} section {i}")
            entry.update(glb=f"res://assets/di2/{folder}/{folder}.glb", primitive=p, glb_triangles=len(g2c),
                         cooked_triangles=ncooked)
            rows = subsection_ranges(s, g2c)
        elif i in shared:
            sh = shared[i]
            entry["shared_mesh"] = sh["mesh"]
            src_json = json_path(sh["mesh"])
            ssecs, sidx, spos = cooked_lod0(raw_package(src_json))
            ss = ssecs[sh["shared_section"]]
            # The body's own items for this section are the shared section's items re-based; check they agree.
            rel = [(a[0], a[1] - s["items"][0][1], a[2] - s["items"][0][2], a[3]) for a in s["items"]]
            srel = [(a[0], a[1] - ss["items"][0][1], a[2] - ss["items"][0][2], a[3]) for a in ss["items"]]
            entry["items_match_shared_mesh"] = rel == srel
            src_glb = mesh_glb(sh["mesh"], f"/{sh['mesh']}\\.uasset")
            dst = parts_dir / f"{sh['mesh']}.glb"
            write_glb_with_materials(src_glb, dst, {n: mats[s["MaterialIndex"]] for n in
                                                    (m["material"] for m in glb_prims(src_glb))})
            shared_glbs.append(dst)
            sp = glb_prims(dst)
            g2c, ncooked = match_section(ss, sidx, spos, sp[sh["shared_section"]]["tris"], f"{sh['mesh']}")
            entry.update(glb=f"res://assets/di2/{folder}/parts/{dst.name}", primitive=sh["shared_section"],
                         glb_triangles=len(g2c), cooked_triangles=ncooked)
            rows = subsection_ranges(ss, g2c)
        else:
            rows = [{} for _ in s["items"]]
        subs = []
        for r in rows:
            assert sids[sub] == i, f"{sk}: SectionID {sids[sub]} != section {i} at subsection {sub}"
            subs.append({"index": sub, "name": names[sub], "soft_body": sbn[sub] if sub < len(sbn) else "None", **r})
            sub += 1
        entry["subsections"] = subs
        out_secs.append(entry)
    section_masks = {}
    for k, v in dm.items():
        if k == "SoftBodyMaskMap":
            continue
        b = bits(v)
        section_masks[k] = {"raw": str(v), "sections": [x for x in b if x < len(secs)]}
        if any(x >= len(secs) for x in b):
            section_masks[k]["bits_beyond_section_count"] = [x for x in b if x >= len(secs)]
    section_masks["MeatMaterialMask"] = {"raw": str(cm.get("MeatMaterialMask", 0)),
                                         "sections": [x for x in bits(cm.get("MeatMaterialMask", 0)) if x < len(secs)]}
    softbody = {x["Key"]: {"raw": str(x["Value"]), "bits": bits(x["Value"]),
                           "subsections": [i for i, n in enumerate(sbn) if n == x["Key"]]}
                for x in dm.get("SoftBodyMaskMap", [])}
    return {"mesh": sk, "glb": f"res://assets/di2/{folder}/{folder}.glb", "sections": out_secs,
            "subsection_count": len(names), "masks": section_masks, "soft_body_mask_map": softbody,
            "_names": names}, shared_glbs


def resolve(names_list, subs):
    """Subsection names -> indices on this body (all matches, as DI2's CullSubsectionByName); unresolved listed.
    FName equality is case-insensitive in UE4 (ComparisonIndex), so 'UpperarmR1' matches 'UpperArmR1'."""
    out, missing = [], []
    for n in names_list or []:
        hit = [i for i, s in enumerate(subs) if s.lower() == str(n).lower()]
        out += hit
        if not hit:
            missing.append(n)
    return {"indices": out, "unresolved": missing} if missing else {"indices": out}


# --- viscera asset -----------------------------------------------------------------------------------------------------

def viscera_asset(name, bones):
    d = load(name)
    by = {ekey(e): e for e in d}
    va = next(e for e in d if e["Type"] == "VisceraAsset")["Properties"]
    out = {"name": name, "num_proxies": va.get("NumProxies"), "skeleton": oname(va.get("Skeleton")), "groups": [],
           "proxies": [], "switchable_variants": [], "switchable_groups": [], "gibs": [], "breakage_effects": [],
           "blacklists": [], "soft_body_modifiers": [], "soft_body_gpu_influences": []}

    def parent_name(e):
        p = e.get("Properties", {}).get("Parent")
        k = opath(p) if p else None
        return by[k]["Properties"].get("Name") if k in by else None

    def group_of(e):
        k = ekey(e)
        while k in by and by[k]["Type"] != "VisceraGroup":
            p = by[k].get("Properties", {}).get("Parent")
            k = opath(p) if p else None
        return by[k]["Properties"]["Name"] if k in by else None

    def bone(i):
        return bones[i] if i is not None and 0 <= i < len(bones) else None

    for e in d:
        t, p, k = e["Type"], e.get("Properties", {}), ekey(e)
        if t == "VisceraGroup":
            out["groups"].append({
                "key": k, "name": p.get("Name"), "bone": p.get("BoneName", "None"),
                "ownership": enum(p.get("Ownership", "EVisceraOwnership::Torso")),
                "cut_margin": p.get("CutMargin", 0.75), "can_rupture": p.get("bCanRupture", False),
                "shootable": p.get("bIsShootable", False),
                "switch_on_dismemberment": p.get("SwitchOnDismemberment", []),
                "children": [opath(c) for c in p.get("Children", [])]})
        elif t == "VisceraProxy":
            loc = p.get("Location", {})
            out["proxies"].append({
                "key": k, "name": p.get("Name"), "proxy_id": p.get("ProxyID", -1), "group": group_of(e),
                "parent": parent_name(e), "box": transform(loc, extents=True),
                "subsections": p.get("VisceraSubsections", []), "broken_subsections": p.get("BrokenSubsections", []),
                "spawnable_part_slots": [enum(s) for s in p.get("SpawnablePartSlots", [])],
                "cut_bias": enum(p.get("CutBias", "ECutBias::Cull")), "can_rupture": p.get("bCanRupture", False),
                "ignore_max_blend": p.get("bIgnoreMaxBlend", True), "hold_final_state": p.get("bHoldFinalState", False),
                "rupture_effects": oname(p.get("RuptureEffects")), "rupture_threshold": p.get("RuptureThreshold", 1.0),
                "rupture_bone_id": p.get("RuptureBoneId"), "rupture_bone": bone(p.get("RuptureBoneId")),
                "breakage_bone_id": p.get("BreakageBoneId"), "breakage_bone": bone(p.get("BreakageBoneId")),
                "switchable_thresholds": p.get("SwitchableThresholds", []),
                "switchable_variants": [opath(v) for v in p.get("SwitchableVariants", [])],
                "gib": opath(p["GibbableSectionAttachment"]) if p.get("GibbableSectionAttachment") else None,
                "shadow_capsules": p.get("ShadowCapsules", []),
                "events": {k2: [opath(x) for x in p.get(k2, [])] for k2 in ("CutEvents", "BreakEvents", "RuptureEvents")
                           if p.get(k2)},
                "soft_body_movement_modifiers": p.get("SoftBodyMovementModifiers", []),
                "children": [opath(c) for c in p.get("Children", [])]})
        elif t == "VisceraSwitchableVariant":
            out["switchable_variants"].append({
                "key": k, "name": p.get("Name"), "root_proxy_id": p.get("RootProxyID", -1), "proxy": parent_name(e),
                "subsections": p.get("VisceraSubsections", []), "switch_threshold": p.get("SwitchThreshold", 100.0),
                "activation_effects": oname(p.get("ActivationEffects")),
                "children": [opath(c) for c in p.get("Children", [])]})
        elif t == "VisceraSwitchableGroup":
            out["switchable_groups"].append({"key": k, "name": p.get("Name"), "proxy_ids": p.get("ProxyIDs", []),
                                             "group": group_of(e), "children": [opath(c) for c in p.get("Children", [])]})
        elif t == "VisceraGibbableSubSection":
            att = by.get(opath(p.get("AttachmentInstance")) or "", {}).get("Properties", {})
            modules = []
            for m in att.get("Modules", []):
                me = by.get(opath(m) or "", {})
                modules.append({"type": me.get("Type"), **({"attachment_to_spawn": opath(me["Properties"]["AttachmentToSpawn"])}
                                                           if me.get("Properties", {}).get("AttachmentToSpawn") else {})})
            out["gibs"].append({
                "key": k, "name": p.get("Name"), "proxy": parent_name(e), "actor_class": oname(p.get("ActorClass")),
                "physics_asset": oname(p.get("PhysicsAsset")), "spawn_subsections": p.get("SubSectionNamesToSpawn", []),
                "hide_subsections": p.get("SubSectionNamesToHide", []), "socket": p.get("SocketName"),
                "location": transform(p.get("Location", {})), "modules": modules})
        elif t == "VisceraBreakageEffect":
            out["breakage_effects"].append({
                "key": k, "name": p.get("Name"), "proxy": parent_name(e), "effect": oname(p.get("BreakageEffect")),
                "splatter_group": p.get("SplatterGroup"), "splatter_set": oname(p.get("SplatterSet")),
                "location": transform(p.get("Location", {}))})
        elif t == "VisceraStateBlacklistRuleset":
            out["blacklists"].append({
                "key": k, "name": p.get("Name"), "group": group_of(e),
                "invalid_states": [s.get("State") for s in p.get("InvalidStates", [])],
                "proxies": [by[opath(x)]["Properties"]["Name"] for x in p.get("AssociatedProxies", []) if opath(x) in by]})
        elif t == "VisceraSoftBodyModifer":
            out["soft_body_modifiers"].append({"key": k, "name": p.get("Name"), "variant": parent_name(e),
                                               "modifier": p.get("Modifer")})
        elif t == "VisceraSoftBodyGPUInfluence":
            out["soft_body_gpu_influences"].append({
                "key": k, "name": p.get("Name"), "variant": parent_name(e), "location": transform(p.get("Location", {})),
                **{x: p.get(x) for x in ("Radius", "HalfHeight", "FadeRadius", "AddInfluenceAmount")}})
    return out


def viscera_for_body(va, names):
    """Per-body resolution of every subsection name the viscera asset uses."""
    return {
        "proxies": {p["key"]: {"subsections": resolve(p["subsections"], names),
                               "broken_subsections": resolve(p["broken_subsections"], names)} for p in va["proxies"]},
        "switchable_variants": {v["key"]: resolve(v["subsections"], names) for v in va["switchable_variants"]},
        "gibs": {g["key"]: {"spawn": resolve(g["spawn_subsections"], names), "hide": resolve(g["hide_subsections"], names)}
                 for g in va["gibs"]},
    }


# --- spawnable parts ---------------------------------------------------------------------------------------------------

def attachment_spec(name):
    d = load(name) or []
    by = {ekey(e): e for e in d}
    out = []
    for e in d:
        if e["Type"] not in ("SkeletalMeshAttachmentSpec", "StaticMeshAttachmentSpec"):
            continue
        p = e["Properties"]
        inst = by.get(opath(p.get("AttachmentInstance")) or "", {})
        out.append({"type": e["Type"], "name": p.get("Name"), "mesh": oname(p.get("Mesh")),
                    "actor_class": oname(p.get("ActorClass")), "socket": p.get("SocketName"),
                    "location": transform(p.get("Location", {})), "attachment_instance": inst.get("Type"),
                    "attachment_props": inst.get("Properties", {})})
    return out


def spawnable_parts(name, sockets, folder, names):
    d = load(name) or []
    sp = next((e["Properties"] for e in d if e["Type"] == "SpawnableParts"), {})
    parts, glbs = [], []
    for part in sp.get("Parts", []):
        spec_name = oname(part.get("AttachmentSpecToSpawn"))
        ensure_json([spec_name])
        specs = attachment_spec(spec_name) if spec_name else []
        for s in specs:
            ensure_json([s["mesh"], s["actor_class"] and s["actor_class"].removesuffix("_C")])
            mj = load(s["mesh"]) or []
            sm = next((e for e in mj if e["Type"] == "SkeletalMesh"), {})
            s["mesh_skeleton"] = oname(sm.get("Properties", {}).get("Skeleton"))
            s["mesh_physics_asset"] = oname(sm.get("Properties", {}).get("PhysicsAsset"))
            s["mesh_materials"] = [oname(m.get("Material")) for m in sm.get("SkeletalMaterials", [])]
            src = mesh_glb(s["mesh"], f"/{s['mesh']}\\.uasset")
            dst = ROOT / f"game/assets/di2/{folder}/parts/{src.name}"
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            glbs.append(dst)
            s["glb"] = f"res://assets/di2/{folder}/parts/{src.name}"
            s["attachment_defaults_native"] = NATIVE["USpawnablePartAttachment"]["defaults"]
        sock = part.get("AttachSocket")
        parts.append({
            "slot": enum(part.get("Slot")), "original_part_to_hide": part.get("OriginalPartToHide"),
            "original_part_subsections": resolve([part.get("OriginalPartToHide")], names),
            "attach_socket": sock, "socket": sockets.get(sock), "attach_offset": transform(part.get("AttachOffset", {})),
            "class_to_spawn": oname(part.get("ClassToSpawn")), "attachment_spec": spec_name, "spec": specs,
            "preset_splatter": oname(part.get("PresetSplatter")), "detachable": part.get("bDetachable", False),
            "spawned_fact": part.get("SpawnedFact", "None"), "detached_fact": part.get("DetachedFact", "None")})
    return parts, glbs


# --- cosmetic effects --------------------------------------------------------------------------------------------------

CE_TYPES = ("CosmeticEffect_Viscera", "CosmeticEffect_SpawnablePart", "CosmeticEffect_VisceraShot")


def cosmetic_effects():
    out = {}
    for f in glob.glob(str(JSON / "**/*.json"), recursive=True):
        s = open(f, encoding="utf-8").read()
        if not any(f'"Type": "{t}"' in s for t in CE_TYPES):
            continue
        d = json.loads(s)
        name = Path(f).stem
        effects, others = [], []
        for e in d:
            t, p = e["Type"], e.get("Properties", {})
            if t == "CosmeticEffect_Viscera":
                effects.append({"type": t, "cull": p.get("RawVisceraToCull", []), "unhide": p.get("RawVisceraToUnHide", [])})
            elif t == "CosmeticEffect_SpawnablePart":
                effects.append({"type": t, "slots": [enum(x) for x in p.get("SpawnablePartSlots", [])],
                                "spawn": p.get("bSpawn", True), "detach": p.get("bDetach", True),
                                "delete": p.get("bDelete", False)})
            elif t == "CosmeticEffect_VisceraShot":
                effects.append({"type": t, "radius": p.get("Radius", 10.0)})
            elif t.startswith("CosmeticEffect_"):
                ref = next((oname(v) for v in p.values() if isinstance(v, dict) and "ObjectName" in v), None)
                others.append({"type": t, "asset": ref})
        out[name] = {"path": Path(f).relative_to(JSON).as_posix(), "effects": effects, "other_effects": others}
    return out


def asset_users(ce_names):
    """Every other extracted asset that references one of these CEs (montage notifies, level sequences, weapon perks,
    paired configs ...), with the export types that hold the reference."""
    rx = re.compile(r"CosmeticEffectsDefinition'([A-Za-z0-9_]+)'")
    users = defaultdict(list)
    for f in glob.glob(str(JSON / "**/*.json"), recursive=True):
        s = open(f, encoding="utf-8").read()
        hits = set(rx.findall(s)) & ce_names
        stem = Path(f).stem
        hits.discard(stem)
        if not hits:
            continue
        for e in json.loads(s):
            es = json.dumps(e)
            for h in hits:
                if f"'{h}'" in es:
                    users[h].append({"asset": stem, "export": e.get("Name"), "type": e.get("Type")})
    return users


def hit_effect_users(ce_names):
    he = json.loads((ROOT / "game/data/hit_effects.json").read_text())
    users = defaultdict(list)
    for kind in ("trees", "modules"):
        for tname, t in he[kind].items():
            for nid, n in t["nodes"].items():
                if n["k"] == "ce" and n["ce"] in ce_names:
                    users[n["ce"]].append({"tree": tname, "node": nid})
                elif n["k"] == "multi":
                    for ce, dif in n["effects"]:
                        if ce in ce_names:
                            users[ce].append({"tree": tname, "node": nid, "direction_interpolation": dif})
    for coll, keys in he["causers"].items():
        for key, groups in keys.items():
            for g in groups:
                for w, ce in g["items"]:
                    if ce in ce_names:
                        users[ce].append({"causer_collection": coll, "key": key, "expr": g["expr"], "weight": w})
    return users


# --- main ------------------------------------------------------------------------------------------------------------

def main():
    states = json.loads((ROOT / "game/data/character_states.json").read_text())
    ensure_json(["DA_SpawnableParts_Walker", "DA_SpawnableParts_Runner", "DA_SpawnableParts_Shambler",
                 "BP_Part_Eye", "BP_Part_Jaw", "PA_JawFalling", "SoftBody_Eye", "SoftBody_Jaw_Left", "SoftBody_Jaw_Right",
                 "BP_SkeletalMeshSubSectionAttachment_Gib", "BP_SkeletalMeshSubSectionAttachment"])
    bones = skeleton_bones()
    sockets = skeleton_sockets()
    splatter = json.loads((ROOT / "game/data/splatter.json").read_text())
    known_sets = set(splatter.get("sets", {}))

    viscera, bodies, all_glbs, pas = {}, {}, [], set()
    for folder, sk in BODIES.items():
        st = states[folder]
        b, shared_glbs = body_mesh(folder, sk)
        names = b.pop("_names")
        vname = st["viscera"]
        if vname not in viscera:
            viscera[vname] = viscera_asset(vname, bones)
        parts, part_glbs = spawnable_parts(st["spawnable_parts"], sockets, folder, names)
        b.update(viscera=vname, viscera_resolved=viscera_for_body(viscera[vname], names),
                 spawnable_parts_asset=st["spawnable_parts"], spawnable_parts=parts)
        for p in parts:
            p["preset_splatter_in_splatter_json"] = p["preset_splatter"] in known_sets
        bodies[folder] = b
        all_glbs += shared_glbs + part_glbs
        print(f"{folder}: {b['subsection_count']} subsections, {len(b['sections'])} sections, viscera {vname}, "
              f"{len(parts)} parts, shared {[s.get('shared_mesh') for s in b['sections'] if s.get('shared_mesh')]}")

    for v in viscera.values():
        for g in v["gibs"]:
            pas.add(g["physics_asset"])
        for be in v["breakage_effects"]:
            be["splatter_set_in_splatter_json"] = be["splatter_set"] in known_sets
    pas.add("PA_JawFalling")
    ensure_json(sorted(pas))

    ces = cosmetic_effects()
    users = hit_effect_users(set(ces))
    others = asset_users(set(ces))
    viscera_refs = defaultdict(list)
    for vn, v in viscera.items():
        for p in v["proxies"]:
            if p["rupture_effects"]:
                viscera_refs[p["rupture_effects"]].append({"viscera": vn, "proxy": p["name"], "as": "RuptureEffects"})
        for sv in v["switchable_variants"]:
            if sv["activation_effects"]:
                viscera_refs[sv["activation_effects"]].append({"viscera": vn, "variant": sv["name"], "as": "ActivationEffects"})
        for be in v["breakage_effects"]:
            if be["effect"]:
                viscera_refs[be["effect"]].append({"viscera": vn, "breakage": be["name"], "as": "BreakageEffect"})
    for name, c in ces.items():
        c["used_by_hit_effects"] = users.get(name, [])
        c["used_by_viscera"] = viscera_refs.get(name, [])
        c["used_by_assets"] = [u for u in others.get(name, []) if u["asset"] not in viscera]
        per = {}
        for folder, b in bodies.items():
            names = [s["name"] for sec in b["sections"] for s in sec["subsections"]]
            per[folder] = [resolve(e["cull"], names) | {"unhide": resolve(e["unhide"], names)}
                           for e in c["effects"] if e["type"] == "CosmeticEffect_Viscera"]
        if any(per.values()):
            c["viscera_resolved"] = per

    # Rupture / activation / breakage CEs that are not viscera/part CEs: name + sub-effect types for reference.
    other_ces = {}
    for name in sorted(set(viscera_refs) - set(ces)):
        d = load(name) or []
        other_ces[name] = {"effects": [{"type": e["Type"], "asset": next((oname(v) for v in e.get("Properties", {}).values()
                                                                          if isinstance(v, dict) and "ObjectName" in v), None)}
                                       for e in d if e["Type"].startswith("CosmeticEffect_")],
                           "used_by_viscera": viscera_refs[name]}

    soft_bodies = {}
    for sb in ("SoftBody_Eye", "SoftBody_Jaw_Left", "SoftBody_Jaw_Right"):
        d = load(sb) or []
        dobj = next((e["Properties"] for e in d if e["Type"] == "SoftBodyDataObject"), {})
        soft_bodies[sb] = {"profiles": [{"mesh": pr.get("MeshRef", {}).get("AssetPathName"), "soft_bodies": pr.get("SoftBodies")}
                                        for pr in dobj.get("Profiles", [])],
                           "simulations": [{"name": e["Properties"].get("SimulationName"),
                                            "attached_bone": e["Properties"].get("AttachedBoneName"),
                                            "particles": len(e["Properties"].get("Particles", [])),
                                            "constraints": len(e["Properties"].get("Constraints", [])),
                                            "params": e["Properties"].get("SimulationParams")}
                                           for e in d if e["Type"] == "SoftSetupCompiledData"],
                           "note": "DI2's proprietary SoftBody plugin; data kept for reference, not decoded"}

    print(pack(all_glbs))
    for folder, b in bodies.items():
        # A part's material gets the shading layer the body uses for the section that holds the original part.
        body_mats = json.loads((ROOT / f"game/assets/di2/{folder}/{folder}.materials.json").read_text())
        for p in b["spawnable_parts"]:
            sec = next((s for s in b["sections"] for x in s["subsections"] if x["name"] == p["original_part_to_hide"]), None)
            layer = body_mats.get(sec["material"], {}).get("layer") if sec else None
            for s in p["spec"]:
                man = fill_part_materials(ROOT / "game" / s["glb"].removeprefix("res://"), layer,
                                          f"{folder}.materials.json[{sec['material']}]" if layer else None)
                s["materials"] = man
        for s in b["sections"]:
            if s.get("shared_mesh"):
                fill_part_materials(ROOT / "game" / s["glb"].removeprefix("res://"))
    out = {
        "_doc": "recon/VISCERA_PARTS.md",
        "_source": "tools/build_viscera_parts.py (DI2 assets + static RE of the shipping exe)",
        "_space": UE_TO_GL,
        "native": NATIVE,
        "part_actors": PART_ACTORS,
        "bodies": bodies,
        "viscera_assets": viscera,
        "cosmetic_effects": ces,
        "viscera_referenced_effects": other_ces,
        "physics_assets": {pa: physics_asset(pa) for pa in sorted(pas)},
        "soft_bodies": soft_bodies,
        "sockets": {k: v for k, v in sockets.items() if k.endswith("_spawn")},
        "skeleton_bones": bones,
    }
    OUT.write_text(json.dumps(out, indent=1))
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KiB): {len(ces)} viscera/part CEs, {len(viscera)} viscera assets")


if __name__ == "__main__":
    main()
