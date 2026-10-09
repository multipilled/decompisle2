"""DI2 hit particle effects (Cascade ParticleSystems played by zombie hit cosmetic effects) -> game/data/particles.json.

What it reads (all static, the game is never run):
  game/data/cosmetics.json, hit_effects.json, viscera_parts.json, explosions.json, vfx_roots.json (weapon / world-impact
                                                                   roots) which CEs a hit / explosion / weapon plays, and what each CE spawns
  extracted/json/**/PS_*.json                                      the ParticleSystem exports (di2x json; --fetch dumps missing)
  extracted/json/**/<material>.json                                MIC / Material chains of every emitter's material
  extracted/particles_build/materials/*.json                       shader-map dumps (shadermaps.exe) for the hashes
DI2 only uses Cascade for these effects (no Niagara asset is referenced by any CE in the hit closure).

What it writes:
  game/data/particles.json
    ce        CE -> [{ps, attach, rot, ...}] particle links (+ FluidParticle entries, nested CEs, the hit-tree
              DirectionInterpolationFactor values the CE is used with)
    ps        ParticleSystem -> LOD distances + emitters; each emitter has a module table and per-LOD module lists
              (indices into the table), with DI2's cooked values. Distributions keep DI2's baked lookup tables
              exactly (UE 4.27 FDistributionLookupTable) or, where the cook left a UDistribution object, that object.
    materials MIC -> flattened parameters (scalar / vector / texture / static switch) over its parent chain
    textures  texture -> exported file + format; meshes: mesh -> exported file
  game/assets/di2/particles/   (.gdignore'd, loaded raw by game/scripts/di2_particles.gd)
    tex/<T>.dds        cooked mips byte for byte (BC1/3/4/5/7, B8G8R8A8, G8); sRGB is recorded in the json
    tex/<T>.vatpos     VAT positions: PF_A2B10G10R10 unpacked to float16 RGBA (exact for 10-bit unorm), header w,h
    tex/<T>.vatnrm     VAT normals:   PF_V8U8 (signed) unpacked to float16 RG, header w,h
    mesh/<M>.pmesh     static mesh LOD0: "DI2M", u32 verts, u32 indices, u32 flags (1 = tangents), then float32
                       positions (UE cm), normals, tangents xyzw, UV0, UV1, colours rgba, u32 indices (UE winding)

usage: python tools/build_particles.py [--fetch] [--no-assets]
   (wrap it: tools/with_cpu.sh particles python tools/build_particles.py)
Doc: recon/PARTICLES.md (format, the DI2 source of every value, approximations, UNVERIFIED items).
Personal-use research; nothing from here is published.
"""
import glob
import json
import os
import re
import shutil
import struct
import subprocess
import sys

import numpy as np

ROOT = r"."
J = os.path.join(ROOT, "extracted", "json")
BUILD = os.path.join(ROOT, "extracted", "particles_build")
OUT_JSON = os.path.join(ROOT, "game", "data", "particles.json")
ASSETS = os.path.join(ROOT, "game", "assets", "di2", "particles")
DI2X = os.path.join(ROOT, "tools", "di2x", "bin", "out", "di2x.exe")
DOTNET = os.path.join(ROOT, "tools", "dotnet10", "dotnet.exe")
SHADERMAPS = os.path.join(ROOT, "tools", "shaders", "shadermaps", "bin", "out", "shadermaps.exe")
ENV = dict(os.environ, DOTNET_ROOT=os.path.join(ROOT, "tools", "dotnet10"), MSYS_NO_PATHCONV="1")
REF = re.compile(r"^(\w+)'([^']+)'$")

# ----------------------------------------------------------------------------------------------------------------
# Class defaults of the module properties the runtime reads. Cooked packages only store properties that differ
# from the class default object, so a property missing from a dump has this value. Checked in DI2's exe
# constructors (tools/particles/uclass_vtable.py + Ghidra, extracted/ghidra_particles/modules1.c) for Required
# (EmitterDuration 1, EmitterLoops 0, SubImages 1x1, AlphaThreshold 0.1, MaxDrawCount 500, NormalsSphereCenter
# (0,0,100), NormalsCylinderDirection (0,0,1), ScreenAlignment PSA_Square) and VelocityCone (Direction (0,0,1));
# the rest are the UE 4.27 constructor values (engine source), UNVERIFIED in the exe (recon/PARTICLES.md 6).
# Distributions created by InitializeDefaults are always serialized in DI2's data.
# ----------------------------------------------------------------------------------------------------------------
DEFAULTS = {
    "Required": dict(ScreenAlignment="PSA_Square", bUseLocalSpace=False, bKillOnDeactivate=False,
                     bKillOnCompleted=False, SortMode="PSORTMODE_None", bUseLegacyEmitterTime=True,
                     bRemoveHMDRoll=False, EmitterDuration=1.0, EmitterDurationLow=0.0,
                     bEmitterDurationUseRange=False, bDurationRecalcEachLoop=False, EmitterLoops=0,
                     EmitterDelay=0.0, EmitterDelayLow=0.0, bEmitterDelayUseRange=False, bDelayFirstLoopOnly=False,
                     InterpolationMethod="PSUVIM_None", SubImages_Horizontal=1, SubImages_Vertical=1, bScaleUV=False,
                     RandomImageTime=1.0, RandomImageChanges=0, bOverrideSystemMacroUV=False,
                     bUseMaxDrawCount=True, MaxDrawCount=500, AlphaThreshold=0.1,
                     UVFlippingMode="EParticleUVFlipMode::None",
                     EmitterNormalsMode="ENM_CameraFacing", NormalsSphereCenter=[0.0, 0.0, 100.0],
                     NormalsCylinderDirection=[0.0, 0.0, 1.0], bOrbitModuleAffectsVelocityAlignment=False,
                     MinFacingCameraBlendDistance=0.0, MaxFacingCameraBlendDistance=0.0,
                     OpacitySourceMode="OSM_Alpha", EmitterOrigin=[0.0, 0.0, 0.0], EmitterRotation=[0.0, 0.0, 0.0],
                     bEnabled=True),
    "Spawn": dict(ParticleBurstMethod="EPBM_Instant", bProcessSpawnRate=True, bProcessBurstList=True,
                  bApplyGlobalSpawnRateScale=True, BurstList=[]),
    "SpawnPerUnit": dict(UnitScalar=50.0, MovementTolerance=0.1, MaxFrameDistance=0.0, bIgnoreSpawnRateWhenMoving=False,
                         bIgnoreMovementAlongX=False, bIgnoreMovementAlongY=False, bIgnoreMovementAlongZ=False,
                         bProcessSpawnRate=True, bProcessBurstList=True),
    "Color": dict(bClampAlpha=True),
    "ColorOverLife": dict(bClampAlpha=True),
    "ColorScaleOverLife": dict(bEmitterTime=False),
    "VelocityCone": dict(Direction=[0.0, 0.0, 1.0], bInWorldSpace=False, bApplyOwnerScale=False),
    "Velocity": dict(bInWorldSpace=False, bApplyOwnerScale=False),
    "VelocityInheritParent": dict(bInWorldSpace=False),
    "VelocityOverLifetime": dict(Absolute=False, bInWorldSpace=False, bApplyOwnerScale=False),
    "Acceleration": dict(bApplyOwnerScale=False, bAlwaysInWorldSpace=False),
    "AccelerationConstant": dict(Acceleration=[0.0, 0.0, 0.0], bAlwaysInWorldSpace=False),
    "AccelerationDrag": dict(bAlwaysInWorldSpace=False),
    "Location": dict(DistributeOverNPoints=0.0, DistributeThreshold=0.0),
    "LocationPrimitiveSphere": dict(Positive_X=True, Positive_Y=True, Positive_Z=True, Negative_X=True,
                                    Negative_Y=True, Negative_Z=True, SurfaceOnly=False, Velocity=False),
    "LocationPrimitiveCylinder": dict(Positive_X=True, Positive_Y=True, Positive_Z=True, Negative_X=True,
                                      Negative_Y=True, Negative_Z=True, SurfaceOnly=False, Velocity=False,
                                      RadialVelocity=True, HeightAxis="PMLPC_HEIGHTAXIS_Z"),
    "LocationEmitter": dict(SelectionMethod="ELESM_Random", InheritSourceVelocity=False, InheritSourceVelocityScale=1.0,
                            bInheritSourceRotation=False, InheritSourceRotationScale=1.0),
    "MeshRotation": dict(bInheritParent=False),
    "SubUV": dict(bUseRealTime=False),
    "SizeMultiplyLife": dict(MultiplyX=True, MultiplyY=True, MultiplyZ=True),
    "SizeScale": dict(EnableX=True, EnableY=True, EnableZ=True),
    "SizeScaleBySpeed": dict(SpeedScale=[1.0, 1.0], MaxScale=[1.0, 1.0]),
    "OrientationAxisLock": dict(LockAxisFlags="EPAL_NONE"),
    "CameraOffset": dict(bSpawnTimeOnly=False, UpdateMethod="EPCOUM_DirectSet"),
    "Collision": dict(CollisionCompletionOption="EPCC_Kill", bApplyPhysics=False, bIgnoreTriggerVolumes=False,
                      DirScalar=3.5, bPawnsDoNotDecrementCount=True, bOnlyVerticalNormalsDecrementCount=False,
                      VerticalFudgeFactor=0.1, bDropDetail=True, bCollideOnlyIfVisible=True,
                      bIgnoreSourceActor=True, MaxCollisionDistance=1000.0, CollisionTypes=[]),
    "EventReceiverSpawn": dict(bUseParticleTime=False, bUsePSysLocation=False, bInheritVelocity=False,
                               bBanPhysicalMaterials=False, PhysicalMaterials=[]),
    "ParameterDynamic": dict(bUsesVelocity=False),
    "TypeDataMesh": dict(CastShadows=False, DoCollisions=False, MeshAlignment="PSMA_MeshFaceCameraWithRoll",
                         bOverrideMaterial=False, AxisLockOption="EPAL_NONE", bCameraFacing=False,
                         CameraFacingUpAxisOption="CameraFacing_NoneUP", CameraFacingOption="XAxisFacing_NoUp",
                         bApplyParticleRotationAsSpin=False, bFaceCameraDirectionRatherThanPosition=False,
                         bCollisionsConsiderPartilceSize=True, bUseStaticMeshLODs=True, LODSizeScale=1.0),
    "PivotOffset": dict(PivotOffset=[0.0, 0.0]),
    "Orbit": dict(ChainMode="EOChainMode_Add"),
}
DYN_PARAM_DEFAULT = dict(ParamName="None", bUseEmitterTime=False, bSpawnTimeOnly=False, ValueMethod="EDPV_UserSet",
                         bScaleVelocityByParamValue=False)
EVENT_DEFAULT = dict(Type="EPET_Spawn", Frequency=0, ParticleFrequency=0, FirstTimeOnly=False, LastTimeOnly=False,
                     UseReflectedImpactVector=False, bUseOrbitOffset=False, CustomName="None")


# --- small helpers ----------------------------------------------------------------------------------------------

def index_json():
    out = {}
    for f in glob.glob(os.path.join(J, "**", "*.json"), recursive=True):
        out.setdefault(os.path.basename(f)[:-5], f)
    return out


def refname(o):
    """'Class'Pkg:Obj'' / 'Class'Name'' -> name."""
    if not isinstance(o, dict) or "ObjectName" not in o:
        return None
    m = REF.match(o["ObjectName"])
    return m.group(2).split(":")[-1].split(".")[-1] if m else o["ObjectName"]


def vec(v, keys="XYZ"):
    if isinstance(v, dict):
        return [float(v.get(k, 0.0)) for k in keys]
    return v


def rot(v):
    """FRotator -> [Pitch, Yaw, Roll] degrees."""
    return [float(v.get("Pitch", 0.0)), float(v.get("Yaw", 0.0)), float(v.get("Roll", 0.0))] if v else None


class Package:
    """One di2x json export list; object references resolve by the export index in ObjectPath ('<pkg>.<index>')."""

    def __init__(self, path):
        self.d = json.load(open(path, encoding="utf-8"))

    def obj(self, ref):
        if not isinstance(ref, dict) or "ObjectPath" not in ref:
            return None
        i = int(ref["ObjectPath"].rsplit(".", 1)[1])
        return self.d[i] if 0 <= i < len(self.d) else None

    def first(self, typ):
        return next((e for e in self.d if e["Type"] == typ), None)


# --- distributions ------------------------------------------------------------------------------------------------

def curve_points(c):
    pts = []
    for p in (c or {}).get("Points", []):
        o, a, l = p.get("OutVal", 0.0), p.get("ArriveTangent", 0.0), p.get("LeaveTangent", 0.0)
        if isinstance(o, dict):
            o, a, l = vec(o), vec(a), vec(l)
        pts.append([float(p.get("InVal", 0.0)), o, a, l, p.get("InterpMode", "CIM_Linear")])
    return pts


def dist_object(o):
    """A cooked UDistribution* subobject (kept by the cook when it couldn't be baked) -> compact dict."""
    t, p = o["Type"], o.get("Properties", {})
    lock = p.get("LockedAxes", "EDVLF_None") if p.get("bLockAxes", False) else "EDVLF_None"
    if t == "DistributionFloatConstant":
        return {"d": "FC", "c": float(p.get("Constant", 0.0))}
    if t == "DistributionFloatUniform":
        return {"d": "FU", "min": float(p.get("Min", 0.0)), "max": float(p.get("Max", 0.0))}
    if t == "DistributionFloatConstantCurve":
        return {"d": "FCC", "pts": curve_points(p.get("ConstantCurve"))}
    if t == "DistributionVectorConstant":
        return {"d": "VC", "c": vec(p.get("Constant", {})), "lock": lock}
    if t == "DistributionVectorUniform":
        return {"d": "VU", "min": vec(p.get("Min", {})), "max": vec(p.get("Max", {})), "lock": lock,
                "mirror": [p.get("MirrorFlags", ["EDVMF_Different"] * 3)]}
    if t == "DistributionVectorConstantCurve":
        return {"d": "VCC", "pts": curve_points(p.get("ConstantCurve")), "lock": lock}
    if t in ("DistributionFloatParticleParameter", "DistributionVectorParticleParameter"):
        isv = t.startswith("DistributionVector")
        g = (lambda k, d: vec(p.get(k, {"X": d, "Y": d, "Z": d}))) if isv else (lambda k, d: float(p.get(k, d)))
        mode = p.get("ParamModes", ["DPM_Normal"] * 3) if isv else p.get("ParamMode", "DPM_Normal")
        return {"d": "VP" if isv else "FP", "name": p.get("ParameterName", "None"), "mode": mode,
                "in": [g("MinInput", 0.0), g("MaxInput", 1.0)], "out": [g("MinOutput", 0.0), g("MaxOutput", 1.0)],
                "c": g("Constant", 0.0)}
    return {"d": "UNSUPPORTED:" + t, "props": p}


def dist(pkg, v):
    """FRawDistributionFloat/Vector -> {"op","lock","n","s","ss","ts","tb","v"} (baked lookup table, used by UE at
    runtime when present) or the UDistribution object, or None (= 0)."""
    if not isinstance(v, dict):
        return None
    t = v.get("Table")
    if t and t.get("Values") and int(t.get("Op", 0)) != 0:
        return {"op": int(t["Op"]), "lock": int(t.get("LockFlag", 0)), "n": int(t.get("EntryCount", 1)),
                "s": int(t.get("EntryStride", 1)), "ss": int(t.get("SubEntryStride", 0)),
                "ts": float(t.get("TimeScale", 0.0)), "tb": float(t.get("TimeBias", 0.0)),
                "v": [float(x) for x in t["Values"]]}
    o = pkg.obj(v.get("Distribution")) if v.get("Distribution") else None
    return dist_object(o) if o else None


def is_dist(v):
    return isinstance(v, dict) and ("Table" in v or "Distribution" in v)


# --- modules ------------------------------------------------------------------------------------------------------

def norm_value(pkg, k, v):
    if is_dist(v):
        return dist(pkg, v)
    if isinstance(v, dict) and set(v) >= {"Pitch", "Yaw", "Roll"}:
        return rot(v)
    if isinstance(v, dict) and set(v) <= {"X", "Y", "Z"} and v:
        return vec(v, "XYZ"[:len(v)] if set(v) != {"X", "Y"} else "XY")
    if isinstance(v, dict) and set(v) == {"X", "Y"}:
        return vec(v, "XY")
    if isinstance(v, dict) and "ObjectName" in v:
        return refname(v)
    if isinstance(v, list):
        return [norm_value(pkg, k, x) for x in v]
    if isinstance(v, dict):
        return {kk: norm_value(pkg, kk, vv) for kk, vv in v.items()}
    return v


def module(pkg, m):
    typ = m["Type"].removeprefix("ParticleModule")
    p = m.get("Properties", {})
    out = {"m": typ}
    out.update(DEFAULTS.get(typ, {}))
    for k, v in p.items():
        if k in ("LODValidity",):
            continue
        out[k] = norm_value(pkg, k, v)
    if typ == "ParameterDynamic":
        out["DynamicParams"] = [{**DYN_PARAM_DEFAULT, **x} for x in out.get("DynamicParams", [])]
    if typ == "EventGenerator":
        out["Events"] = [{**EVENT_DEFAULT, **x} for x in out.get("Events", [])]
    out.setdefault("bEnabled", True)
    return out


def particle_system(path):
    pkg = Package(path)
    ps = pkg.first("ParticleSystem")
    pp = ps["Properties"]
    sysout = {"lod_distances": pp.get("LODDistances", [0.0]), "lod_method": pp.get("LODMethod", "PARTICLESYSTEMLODMETHOD_Automatic"),
              "warmup": pp.get("WarmupTime", 0.0), "warmup_tick": pp.get("WarmupTickRate", 0.0),
              "delay": pp.get("Delay", 0.0), "delay_low": pp.get("DelayLow", 0.0), "delay_range": pp.get("bUseDelayRange", False),
              "fixed_bounds": [vec(pp["FixedRelativeBoundingBox"]["Min"]), vec(pp["FixedRelativeBoundingBox"]["Max"])]
              if pp.get("bUseFixedRelativeBoundingBox") else None,
              "emitters": []}
    for er in pp.get("Emitters", []):
        em = pkg.obj(er)
        if em is None:
            sysout["emitters"].append(None)
            continue
        ep = em.get("Properties", {})
        table, keyidx = [], {}

        def mref(r):
            o = pkg.obj(r)
            if o is None:
                return None
            k = r["ObjectPath"]
            if k not in keyidx:
                keyidx[k] = len(table)
                table.append(module(pkg, o))
            return keyidx[k]

        lods = []
        for lr in ep.get("LODLevels", []):
            lod = pkg.obj(lr)
            lp = lod.get("Properties", {})
            lods.append({"level": lp.get("Level", 0), "enabled": lp.get("bEnabled", True),
                         "required": mref(lp.get("RequiredModule")), "spawn": mref(lp.get("SpawnModule")),
                         "type": mref(lp.get("TypeDataModule")) if lp.get("TypeDataModule") else None,
                         "events": mref(lp.get("EventGenerator")) if lp.get("EventGenerator") else None,
                         "modules": [mref(r) for r in lp.get("Modules", []) if r],
                         "peak": lp.get("PeakActiveParticles", 0)})
        sysout["emitters"].append({
            "name": ep.get("EmitterName", "None"), "class": em["Type"],
            "render": ep.get("EmitterRenderMode", "ERM_Normal"),
            "legacy_spawn": ep.get("bUseLegacySpawningBehavior", False),
            "significance": ep.get("SignificanceLevel", "EParticleSignificanceLevel::Critical"),
            "detail_mask": ep.get("DetailModeBitmask", 7),
            "disabled_lods_keep_alive": ep.get("bDisabledLODsKeepEmitterAlive", False),
            "modules": table, "lods": lods})
    return sysout


# --- cosmetic effects -----------------------------------------------------------------------------------------

def ce_closure(cos, he, vp, ex=None):
    roots = set(re.findall(r'"(CE_[A-Za-z0-9_]+)"', json.dumps(he)))
    # explosion archetypes' CosmeticEffects (game/data/explosions.json, DI2Explosion)
    roots |= set(re.findall(r'"(CE_[A-Za-z0-9_]+)"', json.dumps(ex or {})))
    roots |= set(vp.get("cosmetic_effects", {})) | set(vp.get("viscera_referenced_effects", {}))
    seen, todo = set(), list(roots)
    while todo:
        c = todo.pop()
        if c in seen or c not in cos:
            continue
        seen.add(c)
        todo += re.findall(r'"n": "(CE_[A-Za-z0-9_]+)"', json.dumps(cos[c]))
    return seen


def ce_links(cos, he, names):
    factors = {}
    for t in he["trees"].values():
        for n in t["nodes"].values():
            if n["k"] == "multi":
                for ce, f in n["effects"]:
                    factors.setdefault(ce, set()).add(f)
            elif n["k"] == "ce":
                factors.setdefault(n["ce"], set()).add(None)
    out = {}
    for c in sorted(names):
        d = cos[c]
        ps, fluid, nested, other = [], [], [], []
        for e in d.get("effects", []):
            t = e["type"]
            if t == "ParticleSystem" and e.get("ParticleSystem"):
                ps.append({"ps": e["ParticleSystem"]["n"],
                           "force_not_attached": bool(e.get("bForceNotAttached", False)),
                           "rot": rot(e.get("RotationOffset")),
                           "attachment": (e.get("AttachmentInstance") or {}).get("_type"),
                           "desaturation": e.get("DesaturationResponse"),
                           "custom_depth": bool(e.get("bRenderCustomDepth", False)),
                           "stencil": e.get("CustomDepthStencilWriteMask"),
                           "affect_lifetime": e.get("bShouldAffectLifetime", True),
                           "destroy_persistent": bool(e.get("bShouldDestroyPersistentParticlesOnDestroy", False)),
                           "force_visible": bool(e.get("bForceVisible", False)),
                           "remap": e.get("ParameterRemappings")})
            elif t == "FluidParticle":
                fluid.append({"type": (e.get("FluidType") or {}).get("n"), "speed": e.get("Speed"),
                              "amount": e.get("Amount"), "spawn": e.get("ProjectileSpawnMethod")})
            elif t == "Emitter":
                other.append(e)
            for n in re.findall(r'"n": "(CE_[A-Za-z0-9_]+)"', json.dumps(e)):
                nested.append(n)
        for f in d.get("Files", []) or []:
            if isinstance(f, dict) and str(f.get("n", "")).startswith("CE_"):
                nested.append(f["n"])
        if ps or fluid or nested:
            fs = sorted(x for x in factors.get(c, set()) if x is not None)
            out[c] = {"ps": ps, "fluid": fluid, "nested": sorted(set(nested)), "factors": fs,
                      "params": d.get("ParameterRemappings"), "budget": d.get("BudgetOverrideSettings")}
    return out


def gradual_effects(idx):
    """DA_ContextualGradualDamageEffectList_AI (BP_Base_Walker's list, recon/RE_DISMEMBER.md 2.1): priority-ordered
    {requirement, UGradualDamageEffect}; each effect's ParticleSystem / Duration / EmmissionPeriod. Absent properties
    take DI2's native defaults: UGradualDamageEffect ctor 0x141c635d0 (Duration -1, EmmissionPeriod 0.5) and
    FDamageEffectSet ctor 0x141c63830 (FluidAmount 20, FluidStrength 2, EmissionVelocity 20 cm/s), as traced by the
    gore session (tools/build_gradual_damage.py -> game/data/gradual_damage.json, which zombie.gd plays)."""
    name = "DA_ContextualGradualDamageEffectList_AI"
    if name not in idx:
        return {}
    pkg = Package(idx[name])
    lst = pkg.first("ContextualGradualDamageEffectList")
    out = []
    for c in lst["Properties"].get("PriorityOrderedCandidates", []):
        eff = refname(c.get("EffectData"))
        reqs = [((pkg.obj(r) or {}).get("Properties") or {}).get("OwnerKBExpression") for r in c.get("Requirements", [])]
        e = {}
        if eff in idx:
            ge = Package(idx[eff]).first("GradualDamageEffect")
            p = ge.get("Properties", {}) if ge else {}
            ot = p.get("OverTimeEffect") or {}
            e = {"ps": refname(p.get("ParticleSystem")), "duration": p.get("Duration", -1.0),
                 "emission_period": p.get("EmmissionPeriod", 0.5), "custom_depth": p.get("bRenderCustomDepth", False),
                 "desaturation": p.get("DesaturationResponse"),
                 "over_time_fluid": {"type": refname(ot.get("FluidType")), "amount": ot.get("FluidAmount", 20.0),
                                     "strength": ot.get("FluidStrength", 2.0), "velocity": ot.get("EmissionVelocity", 20.0)}}
        out.append({"effect": eff, "requirements": reqs, **e})
    return {"list": name, "candidates": out}


# --- materials ------------------------------------------------------------------------------------------------

def material_chain(idx, name):
    chain, cur = [], name
    while cur and cur in idx:
        e = next((x for x in json.load(open(idx[cur], encoding="utf-8"))
                  if x["Type"] in ("Material", "MaterialInstanceConstant")), None)
        if e is None:
            break
        chain.append((cur, e))
        cur = refname(e["Properties"].get("Parent"))
    return chain


def flatten_material(idx, name):
    chain = material_chain(idx, name)
    if not chain:
        return None
    sc, vc, tx, sw = {}, {}, {}, {}
    base = {}
    root_name, root = chain[-1]
    rp = root["Properties"]
    # Root material defaults (CachedExpressionData.Parameters: scalars, vectors, textures in that order).
    P = (rp.get("CachedExpressionData") or {}).get("Parameters") or {}
    infos = P.get("ParameterInfos") or []
    n_s = P.get("Counts", 0)
    n_v = P.get("Counts[1]", 0)
    n_t = P.get("Counts[2]", 0)
    svals, vvals, tvals = P.get("ScalarValues", []), P.get("VectorValues", []), P.get("TextureValues", [])
    for i in range(n_s):
        sc[infos[i]["Name"]] = svals[i] if i < len(svals) else None
    for i in range(n_v):
        v = vvals[i] if i < len(vvals) else {}
        vc[infos[n_s + i]["Name"]] = [v.get("R", 0.0), v.get("G", 0.0), v.get("B", 0.0), v.get("A", 0.0)]
    for i in range(n_t):
        tx[infos[n_s + n_v + i]["Name"]] = refname(tvals[i]) if i < len(tvals) else None
    for k in ("BlendMode", "ShadingModel", "TwoSided", "OpacityMaskClipValue", "bUsedWithMeshParticles",
              "TranslucencyLightingMode", "bDisableDepthTest", "bUseTranslucencyVertexFog", "bComputeFogPerPixel",
              "bScreenSpaceReflections", "bEnableResponsiveAA", "TranslucencyPass", "bTangentSpaceNormal",
              "DitheredLODTransition", "bUseEmissiveForDynamicAreaLighting", "bOutputTranslucentVelocity"):
        if k in rp:
            base[k] = rp[k]
    # Instances, parent first, so the leaf wins.
    for n, e in reversed(chain[:-1]):
        p = e["Properties"]
        for x in p.get("ScalarParameterValues", []):
            sc[x["ParameterInfo"]["Name"]] = x.get("ParameterValue")
        for x in p.get("VectorParameterValues", []):
            v = x.get("ParameterValue", {})
            vc[x["ParameterInfo"]["Name"]] = [v.get("R", 0.0), v.get("G", 0.0), v.get("B", 0.0), v.get("A", 0.0)]
        for x in p.get("TextureParameterValues", []):
            tx[x["ParameterInfo"]["Name"]] = refname(x.get("ParameterValue"))
        for x in (p.get("StaticParameters") or {}).get("StaticSwitchParameters", []):
            if x.get("bOverride", True):
                sw[x["ParameterInfo"]["Name"]] = x.get("Value", False)
        for k, v in (p.get("BasePropertyOverrides") or {}).items():
            base[k] = v
    refs = [refname(t) if t else None for t in ((rp.get("CachedExpressionData") or {}).get("ReferencedTextures") or [])]
    # The compiled shader map's uniform parameters carry the defaults this permutation was built with (the root
    # material's cached parameter list is stripped for some roots). Instance overrides win.
    sm_key, ues = None, None
    for n, _ in chain:
        p = os.path.join(BUILD, "materials", n + ".json")
        if os.path.exists(p):
            d = json.load(open(p, encoding="utf-8"))
            if d.get("resources"):
                sm_key = d.get("shader_resource_hash") or ("inline:" + n)
                ues = d["resources"][0]["LoadedShaderMap"]["Content"]["MaterialCompilationOutput"]["UniformExpressionSet"]
                break
    if ues:
        for x in ues.get("UniformScalarParameters", []):
            if x.get("ParameterName") and x["ParameterName"] not in sc:
                sc[x["ParameterName"]] = x.get("DefaultValue")
        for x in ues.get("UniformVectorParameters", []):
            if x.get("ParameterName") and x["ParameterName"] not in vc:
                v = x.get("DefaultValue") or {}
                vc[x["ParameterName"]] = [v.get("R", 0.0), v.get("G", 0.0), v.get("B", 0.0), v.get("A", 0.0)]
        for x in (ues.get("UniformTextureParameters") or [[]])[0]:
            nm = x.get("ParameterName")
            ti = x.get("TextureIndex", -1)
            if nm and nm not in tx and 0 <= ti < len(refs):
                tx[nm] = refs[ti]
    return {"root": root_name, "chain": [n for n, _ in chain], "base": base, "scalars": sc, "vectors": vc,
            "textures": tx, "switches": sw, "shader_map": sm_key, "referenced_textures": refs}


# --- texture / mesh export ------------------------------------------------------------------------------------

MIPDUMP_CS = r'''// Generated by tools/build_particles.py: dump every cooked mip of the listed texture packages (2D / volume), untouched.
using CUE4Parse.Compression; using CUE4Parse.Encryption.Aes; using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports.Texture; using CUE4Parse.UE4.Objects.Core.Misc; using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;
const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
var root = args[0]; var outDir = args[2]; Directory.CreateDirectory(outDir);
var toolDir = Path.Combine(root, "tools", "di2x", "bin", "out");
OodleHelper.Initialize(Path.Combine(toolDir, OodleHelper.OodleFileName));
ZlibHelper.Initialize(Path.Combine(toolDir, ZlibHelper.DllName));
var provider = new DefaultFileProvider(Paks, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_DeadIsland2));
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(File.ReadAllText(Path.Combine(root, "recon", "aes_key.txt")).Trim()));
provider.PostMount();
var meta = new List<object>();
foreach (var path in File.ReadAllLines(args[1]).Where(l => l.Trim().Length > 0))
{
    try
    {
        foreach (var e in provider.LoadPackage(path.Trim()).GetExports())
        {
            if (e is not UTexture t || t.PlatformData == null) continue;
            var pd = t.PlatformData; var first = t.GetFirstMipIndex();
            var t2 = e as UTexture2D;
            var mips = new List<object>();
            using var fs = File.Create(Path.Combine(outDir, e.Name + ".mips"));
            for (var i = first; i < pd.Mips.Length; i++)
            {
                var data = pd.Mips[i].BulkData?.Data;
                if (data == null) break;
                fs.Write(data, 0, data.Length);
                mips.Add(new { w = pd.Mips[i].SizeX, h = pd.Mips[i].SizeY, d = pd.Mips[i].SizeZ, bytes = data.Length });
            }
            meta.Add(new {
                name = e.Name, path = path.Trim(), cls = e.ExportType, pixel_format = t.Format.ToString(), srgb = t.SRGB,
                address = t2 != null ? new[] { t2.GetTextureAddressX().ToString(), t2.GetTextureAddressY().ToString() } : new[] { "TA_Wrap", "TA_Wrap" },
                filter = t.Filter.ToString(), lod_group = t.LODGroup.ToString(), compression = t.CompressionSettings.ToString(),
                packed = pd.PackedData, first_mip = first, total_mips = pd.Mips.Length, mips,
            });
            Console.WriteLine($"ok   {e.Name} {t.Format} mips {mips.Count}/{pd.Mips.Length - first}");
        }
    }
    catch (Exception ex) { Console.WriteLine($"FAIL {path}: {ex.Message}"); }
}
File.WriteAllText(Path.Combine(outDir, "meta.json"), JsonConvert.SerializeObject(meta, Formatting.Indented));
'''
# Same package references as the texture dumpers of tools/shaders/build_flesh_materials.py / build_dani_materials.py.
MIPDUMP_PROJ = '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings><Nullable>disable</Nullable></PropertyGroup>
  <ItemGroup><PackageReference Include="CUE4Parse" Version="1.2.2.202610" />
    <PackageReference Include="CUE4Parse-Conversion" Version="1.2.2.202610" /></ItemGroup>
</Project>
'''

# EPixelFormat -> (DDS FourCC or None, DXGI format, bytes per 4x4 block (bc) or per pixel, block compressed)
DDS_FMT = {"PF_DXT1": ("DXT1", 71, 8, True), "PF_DXT5": ("DXT5", 77, 16, True), "PF_BC4": (None, 80, 8, True),
           "PF_BC5": (None, 83, 16, True), "PF_BC7": (None, 98, 16, True), "PF_B8G8R8A8": (None, 87, 4, False),
           "PF_G8": (None, 61, 1, False), "PF_FloatRGBA": (None, 10, 8, False)}


def mip_bytes(fmt, w, h):
    _, _, bpb, bc = DDS_FMT[fmt]
    return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * bpb if bc else w * h * bpb


def write_dds(dst, fmt, mips, data):
    """DDS (legacy FourCC for DXT1/DXT5, DX10 header otherwise) holding the cooked mips byte for byte."""
    fourcc, dxgi, bpb, bc = DDS_FMT[fmt]
    w, h = mips[0]["w"], mips[0]["h"]
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | (0x80000 if bc else 0x8)
    pitch = mip_bytes(fmt, w, h) if bc else w * bpb
    pf = struct.pack("<II4sIIIII", 32, 0x4, (fourcc or "DX10").encode(), 0, 0, 0, 0, 0)
    caps = 0x1000 | 0x8 | 0x400000
    hdr = b"DDS " + struct.pack("<IIIIIII", 124, flags, h, w, pitch, 0, len(mips)) + b"\0" * 44 + pf + \
        struct.pack("<IIIII", caps, 0, 0, 0, 0)
    if not fourcc:
        hdr += struct.pack("<IIIII", dxgi, 3, 0, 1, 0)
    total = sum(m["bytes"] for m in mips)
    for m in mips:
        assert m["bytes"] == mip_bytes(fmt, m["w"], m["h"]), (dst, m, fmt)
    open(dst, "wb").write(hdr + data[:total])


def run(cmd, **kw):
    r = subprocess.run(cmd, env=ENV, capture_output=True, text=True, **kw)
    if r.returncode:
        raise RuntimeError(" ".join(cmd[:3]) + "\n" + r.stdout[-3000:] + r.stderr[-3000:])
    return r.stdout


def dump_mips(pkgs):
    proj = os.path.join(BUILD, "mipdump")
    exe = os.path.join(proj, "bin", "out", "mipdump.exe")
    os.makedirs(proj, exist_ok=True)
    src_changed = not os.path.exists(os.path.join(proj, "Program.cs")) or open(os.path.join(proj, "Program.cs")).read() != MIPDUMP_CS
    if src_changed or not os.path.exists(exe):
        open(os.path.join(proj, "Program.cs"), "w").write(MIPDUMP_CS)
        open(os.path.join(proj, "mipdump.csproj"), "w").write(MIPDUMP_PROJ)
        run([DOTNET, "build", "-c", "Release", "-o", os.path.join(proj, "bin", "out"), proj])
    lst = os.path.join(BUILD, "mip_textures.txt")
    open(lst, "w").write("\n".join(sorted(pkgs)))
    raw = os.path.join(BUILD, "mips")
    out = run([exe, ROOT, lst, raw])
    fails = [l for l in out.splitlines() if l.startswith("FAIL")]
    if fails:
        raise RuntimeError("\n".join(fails))
    return raw, {m["name"]: m for m in json.load(open(os.path.join(raw, "meta.json")))}


def dump_shadermaps(names):
    """shadermaps.exe material dumps (tools/shaders/shadermaps) of the named Material / MIC packages ->
    extracted/particles_build/materials/<name>.json. The regex is built here (exact names, no shell)."""
    rx = "/(" + "|".join(re.escape(n) for n in names) + r")\.uasset$"
    res = os.path.join(ROOT, "extracted", "shaders", "archive", "ShaderArchive-DeadIsland-PCD3D_SM5.ushaderresources")
    names_tsv = os.path.join(ROOT, "extracted", "shaders", "name_hashes.tsv")
    out = run([SHADERMAPS, "material", res, names_tsv, os.path.join(BUILD, "materials"), rx])
    ok = sum(1 for l in out.splitlines() if l.startswith("ok"))
    print("shader-map dumps: %d of %d" % (ok, len(names)))


def half_header(w, h, c):
    return b"DI2V" + struct.pack("<III", w, h, c)


def export_textures(idx, names):
    """Cooked texture mips -> game/assets/di2/particles/tex. Returns {name: info}."""
    pkgs = {}
    listed = {}
    fl = os.path.join(ROOT, "extracted", "files.txt")
    if os.path.exists(fl):
        for line in open(fl, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line.endswith(".uasset"):
                listed.setdefault(os.path.basename(line)[:-7], line)
    for n in names:
        if n in idx:
            p = idx[n].replace(os.sep, "/")
            pkgs[n] = p[len(J.replace(os.sep, "/")) + 1:-5] + ".uasset"
        elif n in listed:
            pkgs[n] = listed[n]
    if not pkgs:
        return {}
    raw, meta = dump_mips(set(pkgs.values()))
    os.makedirs(os.path.join(ASSETS, "tex"), exist_ok=True)
    out = {}
    for n in sorted(pkgs):
        m = meta.get(n)
        if not m or not m["mips"]:
            out[n] = {"missing": True}
            continue
        data = open(os.path.join(raw, n + ".mips"), "rb").read()
        fmt, w, h = m["pixel_format"], m["mips"][0]["w"], m["mips"][0]["h"]
        d = m["mips"][0].get("d", 1) or 1
        info = {"format": fmt, "w": w, "h": h, "srgb": m["srgb"], "address": m["address"], "filter": m["filter"],
                "lod_group": m["lod_group"], "compression": m["compression"], "mips": len(m["mips"]),
                "cooked_first_mip": m["first_mip"], "packed": m["packed"], "class": m.get("cls")}
        if d > 1:
            # Volume texture: mip 0 slices ("DI2T", channel tag, w, h, d, texels); PF_B8G8R8A8 swizzled to RGBA8.
            info["d"] = d
            if fmt not in ("PF_B8G8R8A8", "PF_G8"):
                info["unsupported"] = True
                out[n] = info
                continue
            fn = "tex/%s.vol" % n
            n0 = m["mips"][0]["bytes"]
            px = np.frombuffer(data[:n0], np.uint8)
            if fmt == "PF_B8G8R8A8":
                px = px.reshape(-1, 4)[:, [2, 1, 0, 3]]
            tag = b"RGBA" if fmt == "PF_B8G8R8A8" else b"L8__"
            open(os.path.join(ASSETS, fn), "wb").write(b"DI2T" + struct.pack("<4sIII", tag, w, h, d) + px.tobytes())
            info["file"] = fn
            out[n] = info
            continue
        if fmt == "PF_A2B10G10R10":
            # R = bits 0-9, G = 10-19, B = 20-29, A = 30-31 (DXGI R10G10B10A2_UNORM). Checked on PT_VertexAnim_Fluid_03_Pos:
            # every frame decodes inside [Bounding Min, Bounding Max] and the last frame reaches both exactly.
            px = np.frombuffer(data[:w * h * 4], "<u4").reshape(h, w)
            f = np.stack([px & 1023, (px >> 10) & 1023, (px >> 20) & 1023], -1).astype(np.float32) / 1023.0
            a = ((px >> 30) & 3).astype(np.float32)[..., None] / 3.0
            arr = np.concatenate([f, a], -1).astype(np.float16)
            fn = "tex/%s.vatpos" % n
            open(os.path.join(ASSETS, fn), "wb").write(half_header(w, h, 4) + arr.tobytes())
        elif fmt == "PF_V8U8":
            # Signed 8-bit pairs (DXGI R8G8_SNORM: -128 and -127 both map to -1).
            px = np.frombuffer(data[:w * h * 2], np.int8).reshape(h, w, 2).astype(np.float32)
            arr = np.maximum(px / 127.0, -1.0).astype(np.float16)
            fn = "tex/%s.vatnrm" % n
            open(os.path.join(ASSETS, fn), "wb").write(half_header(w, h, 2) + arr.tobytes())
        elif fmt in DDS_FMT:
            fn = "tex/%s.dds" % n
            mips = m["mips"]
            full = max(w, h).bit_length()
            if len(mips) not in (1, full):
                # Godot's DDS loader needs a complete chain; a partial cooked chain (only the UI-group
                # Good64x64TilingNoiseHighFreq, sampled at screen pixel / 64) keeps its top mip.
                mips = mips[:1]
                info["mips_written"] = 1
            write_dds(os.path.join(ASSETS, fn), fmt, mips, data)
        else:
            info["unsupported"] = True
            out[n] = info
            continue
        info["file"] = fn
        out[n] = info
    return out


def load_glb(path):
    b = open(path, "rb").read()
    n = struct.unpack_from("<I", b, 12)[0]
    g = json.loads(b[20:20 + n])
    binc = b[20 + n + 8:]

    def acc(i):
        a = g["accessors"][i]
        bv = g["bufferViews"][a["bufferView"]]
        comp = {5126: "f4", 5123: "u2", 5125: "u4", 5121: "u1"}[a["componentType"]]
        k = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        es = k * int(comp[1])
        st = bv.get("byteStride", 0) or es
        raw = np.frombuffer(binc, np.uint8, count=st * (a["count"] - 1) + es, offset=off)
        rows = np.lib.stride_tricks.as_strided(raw, shape=(a["count"], es), strides=(st, 1))
        return np.ascontiguousarray(rows).view("<" + comp).reshape(a["count"], k)
    return g, acc


def export_vector_fields(names, idx, fetch):
    """UVectorFieldStatic assets (GPU emitters' LocalVectorField) -> game/assets/di2/particles/vf/<VF>.vf:
    "DI2F", u32 SizeX, SizeY, SizeZ, f32 bounds min xyz, max xyz, intensity, then float32 xyz per voxel (x fastest).
    The voxels are the asset's SourceData bulk payload (FFloat16Color per voxel, inline in the package: the bulk
    header {u32 flags, u32 count, u32 size, i64 offset} with count = size = voxels * 8 precedes it)."""
    out = {}
    raw_root = os.path.join(ROOT, "extracted", "raw")
    missing_json = [n for n in names if n not in idx]
    missing_raw = [n for n in names if not glob.glob(os.path.join(raw_root, "**", n + ".uasset"), recursive=True)]
    if fetch and missing_json:
        lst = os.path.join(BUILD, "fetch_vf.txt")
        open(lst, "w").write("\n".join(missing_json) + "\n")
        run([DI2X, "json", "@" + lst])
        idx = index_json()
    if fetch and missing_raw:
        run([DI2X, "raw", "/(" + "|".join(re.escape(n) for n in missing_raw) + r")\.uasset$"])
    os.makedirs(os.path.join(ASSETS, "vf"), exist_ok=True)
    for n in sorted(names):
        if n not in idx:
            out[n] = {"missing": True}
            continue
        e = next((x for x in json.load(open(idx[n], encoding="utf-8")) if x["Type"] == "VectorFieldStatic"), None)
        raws = glob.glob(os.path.join(raw_root, "**", n + ".uasset"), recursive=True)
        if e is None or not raws:
            out[n] = {"missing": True}
            continue
        pr = e["Properties"]
        sx, sy, sz = int(pr.get("SizeX", 0)), int(pr.get("SizeY", 0)), int(pr.get("SizeZ", 0))
        bmin = vec(pr["Bounds"]["Min"])
        bmax = vec(pr["Bounds"]["Max"])
        inten = float(pr.get("Intensity", 1.0))
        b = open(raws[0], "rb").read()
        nbytes = sx * sy * sz * 8
        hdr = struct.pack("<II", nbytes, nbytes)
        pos = b.find(hdr)
        if pos < 4 or pos + 8 + 8 + nbytes > len(b):
            out[n] = {"missing": True, "why": "bulk payload not found"}
            continue
        payload = b[pos + 8 + 8: pos + 8 + 8 + nbytes]
        half = np.frombuffer(payload, "<f2").reshape(-1, 4)[:, :3].astype(np.float32)
        fn = "vf/%s.vf" % n
        open(os.path.join(ASSETS, fn), "wb").write(b"DI2F" + struct.pack("<III", sx, sy, sz) +
                                                   struct.pack("<7f", *bmin, *bmax, inten) + half.tobytes())
        out[n] = {"file": fn, "size": [sx, sy, sz], "bounds": [list(bmin), list(bmax)], "intensity": inten}
    return out


def export_meshes(names):
    """di2x mesh glbs -> .pmesh (UE space: cm, X fwd, Y right, Z up; CUE4Parse writes glTF (x, z, y) * 0.01)."""
    found = {}
    for f in glob.glob(os.path.join(ROOT, "extracted", "mesh", "**", "*.glb"), recursive=True):
        b = os.path.basename(f)[:-4]
        if b in names:
            found[b] = f
    missing = sorted(set(names) - set(found))
    if missing:
        lst = os.path.join(BUILD, "mesh_names.txt")
        open(lst, "w").write("\n".join(missing) + "\n")
        run([DI2X, "mesh", "@" + lst])
        for f in glob.glob(os.path.join(ROOT, "extracted", "mesh", "**", "*.glb"), recursive=True):
            b = os.path.basename(f)[:-4]
            if b in names:
                found[b] = f
    os.makedirs(os.path.join(ASSETS, "mesh"), exist_ok=True)
    out = {}
    for n in sorted(names):
        if n not in found:
            out[n] = {"missing": True}
            continue
        g, acc = load_glb(found[n])
        mesh = g["meshes"][0]
        P, N, TG, U0, U1, C, I, sections = [], [], [], [], [], [], [], []
        base = 0
        for prim in mesh["primitives"]:
            a = prim["attributes"]
            p = acc(a["POSITION"]).astype(np.float32)
            P.append(np.stack([p[:, 0], p[:, 2], p[:, 1]], -1) * 100.0)
            nn = acc(a["NORMAL"]).astype(np.float32) if "NORMAL" in a else np.zeros_like(p)
            N.append(np.stack([nn[:, 0], nn[:, 2], nn[:, 1]], -1))
            tg = acc(a["TANGENT"]).astype(np.float32) if "TANGENT" in a else np.tile(np.float32([1, 0, 0, 1]), (len(p), 1))
            # UE-space tangent; the glTF (x, z, y) mirror flips the bitangent sign back to UE's
            TG.append(np.stack([tg[:, 0], tg[:, 2], tg[:, 1], -tg[:, 3]], -1))
            U0.append(acc(a["TEXCOORD_0"]).astype(np.float32) if "TEXCOORD_0" in a else np.zeros((len(p), 2), np.float32))
            U1.append(acc(a["TEXCOORD_1"]).astype(np.float32) if "TEXCOORD_1" in a else np.zeros((len(p), 2), np.float32))
            if "COLOR_0" in a:
                c = acc(a["COLOR_0"])
                c = c.astype(np.float32) / (255.0 if c.dtype == np.uint8 else 65535.0 if c.dtype == np.uint16 else 1.0)
                if c.shape[1] == 3:
                    c = np.concatenate([c, np.ones((len(c), 1), np.float32)], -1)
            else:
                c = np.ones((len(p), 4), np.float32)
            C.append(c)
            idx = acc(prim["indices"]).reshape(-1).astype(np.uint32) + base
            # glTF (x, z, y) is a mirror of UE space: flip the winding back to UE's.
            tri = idx.reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
            mat = g.get("materials", [{}])[prim.get("material", 0)].get("name") if g.get("materials") else None
            sections.append({"first": sum(len(x) for x in I), "count": len(tri), "material": mat})
            I.append(tri)
            base += len(p)
        P, N, TG, U0, U1, C, I = (np.concatenate(x) for x in (P, N, TG, U0, U1, C, I))
        fn = "mesh/%s.pmesh" % n
        with open(os.path.join(ASSETS, fn), "wb") as f:
            f.write(b"DI2M" + struct.pack("<III", len(P), len(I), 1))   # flags 1: tangents present
            for arr in (P, N, TG, U0, U1, C):
                f.write(arr.astype("<f4").tobytes())
            f.write(I.astype("<u4").tobytes())
        out[n] = {"file": fn, "verts": int(len(P)), "indices": int(len(I)), "sections": sections,
                  "bounds_cm": [P.min(0).round(3).tolist(), P.max(0).round(3).tolist()]}
    return out


# --- main -----------------------------------------------------------------------------------------------------

def main():
    fetch = "--fetch" in sys.argv
    assets = "--no-assets" not in sys.argv
    os.makedirs(BUILD, exist_ok=True)
    data = os.path.join(ROOT, "game", "data")
    cos = json.load(open(os.path.join(data, "cosmetics.json"), encoding="utf-8"))
    he = json.load(open(os.path.join(data, "hit_effects.json"), encoding="utf-8"))
    vp = json.load(open(os.path.join(data, "viscera_parts.json"), encoding="utf-8"))
    exf = os.path.join(data, "explosions.json")
    ex = json.load(open(exf, encoding="utf-8")) if os.path.exists(exf) else {}
    # weapon / world-impact VFX roots (game/data/vfx_roots.json, written by the weapon-VFX session's
    # tools/weapon_vfx/build_weapon_vfx.py): {"ce": [...], "ps": [systems played directly, not via a CE]}
    vrf = os.path.join(data, "vfx_roots.json")
    vr = json.load(open(vrf, encoding="utf-8")) if os.path.exists(vrf) else {}
    # The fluid system's effects (game/data/fluids.json: CE_Acid_Puddle, CE_Extinguished_Fire, PS_Drips_*), and the
    # burning-fluid state CE_Fluid_State_Flammable (-> PS_Burning_Liquid; DA_FluidEnvMessageRelay_Ignite), played by
    # the gore session's burning-puddle port.
    flf = os.path.join(data, "fluids.json")
    fl_text = open(flf, encoding="utf-8").read() if os.path.exists(flf) else ""
    fluid_ce = sorted(set(re.findall(r"\b(CE_[A-Za-z0-9_]+)", fl_text)) | {"CE_Fluid_State_Flammable"})
    fluid_ps = sorted(set(re.findall(r"\b(PS_[A-Za-z0-9_]+)", fl_text)))
    closure = ce_closure(cos, he, vp, {"explosions": ex, "vfx": vr.get("ce", []), "fluids": fluid_ce})
    links = ce_links(cos, he, closure)
    idx = index_json()
    gradual = gradual_effects(idx)
    ps_names = sorted({l["ps"] for v in links.values() for l in v["ps"]})
    # Not reached through a CE: the gradual damage effects' systems, and the fluid system's drips
    # (DA_FluidTypeInfo_Blood.DripParticleType).
    extra = ["PS_Drips_Blood"] + [c["ps"] for c in gradual.get("candidates", []) if c.get("ps")]
    extra += [p for p in vr.get("ps", []) if isinstance(p, str)]
    extra += fluid_ps
    ps_names = sorted(set(ps_names) | set(extra))
    missing = [n for n in ps_names if n not in idx]
    if missing and fetch:
        lst = os.path.join(BUILD, "fetch_ps.txt")
        open(lst, "w").write("\n".join(missing) + "\n")
        run([DI2X, "json", "@" + lst])
        idx = index_json()
        missing = [n for n in ps_names if n not in idx]
    if missing:
        print("missing PS dumps (run with --fetch):", missing)
    systems = {}
    for n in ps_names:
        if n in idx:
            systems[n] = particle_system(idx[n])
    # Materials of every emitter (Required.Material; mesh emitters without bOverrideMaterial use the mesh's).
    mats, meshes = set(), set()
    for s in systems.values():
        for em in s["emitters"]:
            if not em:
                continue
            for m in em["modules"]:
                if m["m"] == "Required" and m.get("Material"):
                    mats.add(m["Material"])
                if m["m"] == "TypeDataMesh" and m.get("Mesh"):
                    meshes.add(m["Mesh"])
    missing_m = [n for n in mats if n not in idx]
    if missing_m and fetch:
        lst = os.path.join(BUILD, "fetch_mat.txt")
        open(lst, "w").write("\n".join(missing_m) + "\n")
        run([DI2X, "json", "@" + lst])
        idx = index_json()
    materials = {}
    for n in sorted(mats):
        fm = flatten_material(idx, n)
        if fm and fetch and fm["root"] != fm["chain"][-1]:
            pass
        materials[n] = fm
    # Parents not dumped yet (the chain stops at the first missing asset).
    if fetch:
        need = sorted({refname(e["Properties"].get("Parent")) for n in materials for _, e in material_chain(idx, n)
                       if e["Properties"].get("Parent")} - set(idx))
        if need:
            lst = os.path.join(BUILD, "fetch_parents.txt")
            open(lst, "w").write("\n".join(need) + "\n")
            run([DI2X, "json", "@" + lst])
            idx = index_json()
            materials = {n: flatten_material(idx, n) for n in sorted(mats)}
        # Shader-map dumps (compiled uniform defaults, shader resource hash / inline map) for every chain asset
        # that has none yet.
        chain_names = {c for n in mats for c, _ in material_chain(idx, n)}
        no_dump = sorted(c for c in chain_names if not os.path.exists(os.path.join(BUILD, "materials", c + ".json")))
        if no_dump:
            dump_shadermaps(no_dump)
            materials = {n: flatten_material(idx, n) for n in sorted(mats)}
    # Which vertex factories each material's compiled shader map has a base pass for: an emitter whose vertex factory
    # is missing cannot draw with its material (UE 4.27 swaps in the engine default material: recon/PARTICLES.md 4.3).
    for m in materials.values():
        if m and m.get("shader_map"):
            m["vertex_factories"] = shader_map_vfs(m["shader_map"])
    texnames = set()
    for m in materials.values():
        if m:
            texnames |= {t for t in m["textures"].values() if t}
            # constants inside the material graph that the compiled shaders sample (e.g. T_RoundSplatter_A)
            texnames |= {t for t in m.get("referenced_textures", []) if t}
    texnames |= EXTRA_TEXTURES
    textures, meshinfo, vector_fields = {}, {}, {}
    if assets:
        os.makedirs(ASSETS, exist_ok=True)
        open(os.path.join(ASSETS, ".gdignore"), "w").write("")
        textures = export_textures(idx, texnames)
        meshinfo = export_meshes(meshes)
        vf_names = sorted({m["EmitterInfo"]["LocalVectorField"]["Field"] for sv in systems.values() for em in sv["emitters"] if em
                           for m in em["modules"] if m.get("m") == "TypeDataGpu"
                           and (m.get("EmitterInfo") or {}).get("LocalVectorField", {}).get("Field")})
        vector_fields = export_vector_fields(vf_names, idx, fetch)
    elif os.path.exists(OUT_JSON):
        # --no-assets: keep the previous export's texture / mesh tables
        prev = json.load(open(OUT_JSON, encoding="utf-8"))
        textures, meshinfo = prev.get("textures", {}), prev.get("meshes", {})
        vector_fields = prev.get("vector_fields", {})
    # Which Cascade modules run at spawn / update in DI2's exe: a module is called only where its class overrides
    # UParticleModule::Spawn (vtable +0x240) / Update (+0x248). Resolved by tools/particles/module_funcs.py.
    engine = {}
    mf = os.path.join(BUILD, "module_funcs.json")
    if os.path.exists(mf):
        for cls, r in json.load(open(mf)).items():
            engine[cls.removeprefix("UParticleModule")] = {"spawn": bool(r.get("spawn")), "update": bool(r.get("update")),
                                                          "exe": {k: r.get(k) for k in ("ctor", "vtable", "spawn", "update")}}
    out = {"_doc": "DI2 hit particle effects (Cascade). Built by tools/build_particles.py; format and sources in "
                   "recon/PARTICLES.md. Units/axes are DI2's (UE): cm, X forward, Y right, Z up; rotations are "
                   "[Pitch, Yaw, Roll] degrees. Distribution 'op': 1 none, 2 random, 3 extreme (UE ERawDistributionOperation); "
                   "'lock': UE EDistributionVectorLockFlags (1 XY, 2 XZ, 3 YZ, 4 XYZ).",
           "engine_modules": engine, "ce": links, "gradual": gradual, "ps": systems, "materials": materials,
           "textures": textures, "meshes": meshinfo, "vector_fields": vector_fields}
    json.dump(out, open(OUT_JSON, "w"), separators=(",", ":"))
    print("%d CEs with particles, %d particle systems, %d emitters, %d materials, %d textures, %d meshes -> %s (%d KB)" % (
        len(links), len(systems), sum(len(s["emitters"]) for s in systems.values()), len(materials), len(textures),
        len(meshinfo), OUT_JSON, os.path.getsize(OUT_JSON) // 1024))


_VF_CACHE = {}


def shader_map_vfs(key):
    """Vertex factories with a base-pass pixel shader in a shader map ("<hash>" or "inline:<root>")."""
    if key in _VF_CACHE:
        return _VF_CACHE[key]
    sys.path.insert(0, os.path.join(ROOT, "tools", "shaders"))
    sys.path.insert(0, os.path.join(ROOT, "tools", "particles"))
    try:
        if key.startswith("inline:"):
            import inline_map
            rows = inline_map.shader_list(key[len("inline:"):], "TBasePassPS")
        else:
            import material_map
            rows = material_map.shader_list(key, "TBasePassPS")
        out = sorted({r["vf"] for r in rows if r["vf"]})
    except (Exception, SystemExit) as e:  # no shader archive / raw package for it: unknown (the runtime then trusts the material)
        print("vertex factories of %s: %s" % (key, e))
        out = None
    _VF_CACHE[key] = out
    return out


# Textures a particle material samples that are not material parameters (constants inside the material graph),
# found in the decompiled shaders (recon/PARTICLES.md 4).
EXTRA_TEXTURES = {"Good64x64TilingNoiseHighFreq"}

if __name__ == "__main__":
    main()
