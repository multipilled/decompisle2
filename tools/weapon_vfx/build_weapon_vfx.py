"""DI2 weapon and world-impact cosmetic data -> game/data/weapon_vfx.json (+ game/data/vfx_roots.json).

What a gun shows when it fires and what a weapon leaves on a world surface, from the user's own install
(di2x json dumps in extracted/json; personal use). The runtime is game/scripts/weapon_vfx.gd; the write-up with
the exe addresses is recon/WEAPON_VFX.md.

Sources:
  weapons.json (tools/build_weapons.py)       each weapon's blueprint, ObjectSet collections, ImpactConfiguration
  DA_EffectSetCollection_* / DA_EffectSet_*   the gun's ObjectSet keys MuzzleFlare / AmmoEject / Tracer: groups of
                                              {expression, weighted CosmeticEffectsDefinition items}
  BP_Weapon_* HitscanProjectileSpawnModule    ProjectileTracerEffectType (a ParticleSystem)
  BP_Weapon_* EquippableComponent             FactsSetWhenHeld (MaterialGridRow = Bullet_<type>, ...)
  SK_* / SKEL_* SkeletalMeshSocket            Muzzle / AmmoEject sockets with their rotation
  AM_*_Weapon montages                        BP_AnimNotify_SpawnParticleSystemOnWeapon (shell ejects)
  CollisionEffectsRegistry_*                  the material grid: row x physical material -> CosmeticEffectsDefinition
  PM_* (DIShared/Core/Materials/Physics)      physical materials (SurfaceType)
  cosmetics.json CE_Collision_* Decal effects decal material / size / rotation / fades

usage: python tools/weapon_vfx/build_weapon_vfx.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402

OUT = ROOT / "game/data/weapon_vfx.json"
ROOTS = ROOT / "game/data/vfx_roots.json"
REF = re.compile(r"^(\w+)'([^']+)'$")


def refname(o):
    if not isinstance(o, dict) or "ObjectName" not in o:
        return None
    m = REF.match(o["ObjectName"])
    return m.group(2).split(":")[-1].split(".")[-1] if m else o["ObjectName"]


def props(pkg, typ=None, name=None):
    for e in A.load(pkg) or []:
        if (typ is None or e.get("Type") == typ) and (name is None or e.get("Name") == name):
            return e.get("Properties") or {}
    return None


# --- Gun cosmetics ----------------------------------------------------------------------------------------------

def anim_set_data(name):
    """AnimSetData groups: [{name, expr, items [[weight, CE]]}] (AnimSetSelectionOrder_Random within a group)."""
    p = props(name, "AnimSetData")
    if not p:
        return []
    out = []
    for g in p.get("Groups", []):
        items = [[it.get("Weight", 1.0), refname(it.get("Asset"))] for it in g.get("Items", []) if it.get("Asset")]
        out.append({"name": g.get("Name"), "expr": (g.get("Expression") or {}).get("Expression", ""),
                    "order": refname(g.get("Order")) or "", "allow_null": g.get("bAllowSingleNullEntry", False),
                    "items": items})
    return out


def effect_set_collection(name):
    """ObjectSet collection -> {key: groups}; an AnimSet_DataDriven with no Data gives [] (DI2 plays nothing)."""
    d = A.load(name) or []
    objs = {e["Name"]: e for e in d}
    coll = next((e for e in d if e["Type"] == "AnimSetCollection"), None)
    out = {}
    for kv in (coll or {}).get("Properties", {}).get("AnimSetData", []):
        a = (kv.get("Value") or {}).get("AnimSet")
        o = objs.get(a["ObjectName"].split(":")[-1].rstrip("'")) if a else None
        data = refname((o.get("Properties") or {}).get("Data")) if o else None
        if o and o["Type"] == "AnimSet_Single":
            ce = refname((o.get("Properties") or {}).get("Asset"))
            out[kv["Key"]] = [{"name": "", "expr": "", "order": "", "allow_null": False, "items": [[1.0, ce]]}] if ce else []
        else:
            out[kv["Key"]] = anim_set_data(data) if data else []
    return out


def mesh_sockets(mesh):
    """Mesh + skeleton sockets: name -> {bone, loc (UE cm, bone space), rot [Pitch, Yaw, Roll], scale}."""
    out = {}
    d = A.load(mesh) or []
    skel = None
    for e in d:
        if e.get("Type") == "SkeletalMesh":
            skel = A.anyref(e.get("Skeleton") or (e.get("Properties") or {}).get("Skeleton"))
    sources = [d] + ([A.load(skel.split(".")[-1])] if skel and A.load(skel.split(".")[-1]) else [])
    for src in sources:
        for e in src or []:
            if e.get("Type") != "SkeletalMeshSocket":
                continue
            q = e.get("Properties") or {}
            loc = q.get("RelativeLocation") or {}
            rot = q.get("RelativeRotation") or {}
            sc = q.get("RelativeScale") or {}
            out.setdefault(q.get("SocketName"), {
                "bone": q.get("BoneName"),
                "loc": [loc.get("X", 0.0), loc.get("Y", 0.0), loc.get("Z", 0.0)],
                "rot": [rot.get("Pitch", 0.0), rot.get("Yaw", 0.0), rot.get("Roll", 0.0)],
                "scale": [sc.get("X", 1.0), sc.get("Y", 1.0), sc.get("Z", 1.0)]})
    return out


def bp_components(bp):
    """Every export of the blueprint chain (most derived first) as (bp, export)."""
    out, name = [], bp
    for _ in range(8):
        d = A.load(name)
        if not d:
            break
        out += [(name, e) for e in d]
        cls = next((e for e in d if e["Type"] == "BlueprintGeneratedClass"), {})
        sup = A.anyref(cls.get("Super")) if cls.get("Super") else None
        name = sup.split(".")[-1].removesuffix("_C") if sup else None
        if not name:
            break
    return out


def held_facts(bp):
    """EquippableComponent.EquippableData.FactsSetWhenHeld, most derived blueprint wins per fact name."""
    out = {}
    for _, e in bp_components(bp):
        if e.get("Type") != "WeaponEquippableComponent":
            continue
        for f in ((e.get("Properties") or {}).get("EquippableData") or {}).get("FactsSetWhenHeld", []):
            t = f.get("Type", "")
            v = f.get("StringValue") if t.endswith("String") else f.get("bBooleanValue") if t.endswith("Boolean") else \
                f.get("IntegerValue") if t.endswith("Integer") else f.get("FloatValue")
            out.setdefault(f["Name"], v)
    return out


# HitscanProjectileSpawnModule cosmetic properties (cooked only where they differ from the native defaults, which
# are in recon/WEAPON_VFX.md and applied by the runtime).
SPAWNER_COSMETIC = ("MuzzleOriginBoneOrSocketName", "MuzzleFlashEffectType", "ProjectileTracerEffectType",
                    "EjectedAmmoCasingsEffectType", "AmmoEjectBoneOrSocketName",
                    "FakeProjectileSpeedForCosmeticImpactDelay", "bUseSweptSphereOverRay", "SweptSphereRadius",
                    "bForceAllocateImpactGroupIDForEachShotEvent")


def spawner_cosmetics(bp):
    """The first fire mode's HitscanProjectileSpawnModule cosmetic properties (most derived blueprint)."""
    for _, e in bp_components(bp):
        if e.get("Type") == "HitscanProjectileSpawnModule":
            p = e.get("Properties") or {}
            return {k: (refname(p[k]) if isinstance(p[k], dict) else p[k]) for k in SPAWNER_COSMETIC if k in p}
    return {}


def weapon_montages(cls_file):
    """Every '_Weapon' montage a held-item class plays (data/classes/<class>.json)."""
    d = json.loads(cls_file.read_text(encoding="utf-8"))
    return sorted(set(re.findall(r'"m": "(AM_[A-Za-z0-9_]+)"', json.dumps(d))))


def montage_particle_notifies(montage):
    """BP_AnimNotify_SpawnParticleSystemOnWeapon notifies: [{t (montage s), ps, socket}]."""
    d = A.load(montage) or []
    objs = {e["Name"]: e for e in d}
    m = next((e for e in d if e["Type"] == "AnimMontage"), None)
    out = []
    for n in ((m or {}).get("Properties") or {}).get("Notifies", []):
        ref = n.get("Notify")
        if not ref:
            continue
        o = objs.get(ref["ObjectName"].split(":")[-1].rstrip("'"))
        if not o or "SpawnParticleSystemOnWeapon" not in o["Type"]:
            continue
        p = o.get("Properties") or {}
        out.append({"t": round(A.link_time(n), 6), "ps": refname(p.get("ParticleSystemTemplate")),
                    "socket": p.get("InSocket"), "notify": o["Type"]})
    return out


# --- World impacts -----------------------------------------------------------------------------------------------

GCH = "BP_GameCollisionHandler"


def registry(name):
    """UGameCollisionEffectsRegistry: Colliders (surface 0..63 = EPhysicalSurface, physical materials, actor classes,
    custom names), a symmetric Colliders x Colliders ColliderTable of CosmeticEffectsDefinitions (MakeCascadeDefinition
    = fall through to the material / surface column), and the name / material / class -> collider index maps."""
    p = props(name, "GameCollisionEffectsRegistry")
    if p is None:
        return None
    cols = [{"name": c["Name"], "type": c["Type"].split("::")[-1]} for c in p.get("Colliders", [])]
    table = [refname(x) if x else None for x in p.get("ColliderTable", [])]
    return {"colliders": cols,
            "names": {x["Key"]: x["Value"] for x in p.get("NameToCollidersMap", [])},
            "materials": {re.sub(r".*\.", "", x["Key"].rstrip("'")): x["Value"] for x in p.get("MaterialToCollidersMap", [])},
            "classes": {x["Key"]: x["Value"] for x in p.get("ClassToCollidersMapSoft", [])},
            "table": table}


def physical_materials():
    """PM_* -> {surface: EPhysicalSurface index, class}. SurfaceTypeN -> N; absent = SurfaceType_Default (0)."""
    out = {}
    for name, path in A.index().items():
        if not name.startswith("PM_") or "/Physics/" not in path.as_posix():
            continue
        for e in A.load(name) or []:
            if "PhysicalMaterial" in e.get("Type", ""):
                st = (e.get("Properties") or {}).get("SurfaceType")
                out[name] = {"surface": int(st.removeprefix("SurfaceType")) if st else 0, "class": e["Type"]}
    return out


def surface_names():
    """DefaultEngine.ini PhysicsSettings.PhysicalSurfaces (only these keys are read; the file holds a secret)."""
    ini = ROOT / "extracted/raw/DeadIsland/Config/DefaultEngine.ini"
    out = {0: "Default"}
    for line in ini.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = re.match(r"\+PhysicalSurfaces=\(Type=SurfaceType(\d+),Name=\"([^\"]+)\"\)", line.strip())
        if m:
            out[int(m.group(1))] = m.group(2)
    return out


def default_phys_material():
    ini = ROOT / "extracted/raw/DeadIsland/Config/DefaultEngine.ini"
    for line in ini.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("DefaultPhysMaterialName="):
            return line.split("=", 1)[1].strip().split("/")[-1].split(".")[0]
    return None


# UConditionalTreeNode_MaterialGridCosmeticEffect native defaults (ctor 0x141b887f0): bPrefer... 0,
# bFallbackIfKBFactFailed 1, bFallbackIfKBFactEmpty 1, MaterialGridRowFactName "MaterialGridRow", MaterialGridRow None.
GRID_DEFAULTS = {"prefer_kb": False, "fallback_failed": True, "fallback_empty": True, "row_fact": "MaterialGridRow",
                 "row": None, "registry": None}


def grid_nodes(trees):
    """Every MaterialGridCosmeticEffect node of the given hit-effect trees with all its fields (cooked over defaults)."""
    out = {}
    for t in trees:
        for e in A.load(t) or []:
            if e.get("Type") != "ConditionalTreeNode_MaterialGridCosmeticEffect":
                continue
            p = e.get("Properties") or {}
            n = dict(GRID_DEFAULTS)
            if "bPreferMaterialGridRowNameFromImpactKnowledgebase" in p:
                n["prefer_kb"] = bool(p["bPreferMaterialGridRowNameFromImpactKnowledgebase"])
            if "bFallbackIfKBFactFailed" in p:
                n["fallback_failed"] = bool(p["bFallbackIfKBFactFailed"])
            if "bFallbackIfKBFactEmpty" in p:
                n["fallback_empty"] = bool(p["bFallbackIfKBFactEmpty"])
            if p.get("MaterialGridRowFactName"):
                n["row_fact"] = p["MaterialGridRowFactName"].get("NameStorage") or n["row_fact"]
            if p.get("MaterialGridRow") not in (None, "None"):
                n["row"] = p["MaterialGridRow"]
            if p.get("OverrideEffectsRegistry"):
                n["registry"] = refname(p["OverrideEffectsRegistry"])
            out.setdefault(t, {})[e["Name"]] = n
    return out


def collision_decals(ces):
    """The Decal effects of the impact CEs (cosmetics.json), keyed by CE."""
    cos = json.loads((ROOT / "game/data/cosmetics.json").read_text(encoding="utf-8"))
    out = {}
    for c in ces:
        ds = [e for e in cos.get(c, {}).get("effects", []) if e.get("type") == "Decal"]
        if ds:
            out[c] = ds
    return out


# --- Decal materials ------------------------------------------------------------------------------------------------

DECAL_TEX_DIR = ROOT / "game/assets/di2/weapon_vfx/decals"
TEX_EXPORT = ROOT / "extracted/tex"
# Master materials whose decal shader is transcribed (game/shaders/weapon_vfx_decal_pom.gdshader).
DECAL_MASTERS = {"M_DecalPOM_DNR"}


def material_chain(name):
    """MI -> parent -> ... -> root material: [(name, properties, type)]."""
    out, cur = [], name
    for _ in range(8):
        d = A.load(cur)
        if not d:
            dump = ROOT / "extracted/weapon_vfx_build/materials" / (cur + ".json")
            if dump.exists():
                pr = json.loads(dump.read_text(encoding="utf-8")).get("properties") or {}
                out.append((cur, pr.get("Properties") or {}, pr.get("Type", "Material")))
            break
        e = next((x for x in d if x.get("Type") in ("Material", "MaterialInstanceConstant")), None)
        if e is None:
            break
        out.append((cur, e.get("Properties") or {}, e["Type"]))
        if e["Type"] == "Material":
            break
        cur = refname((e.get("Properties") or {}).get("Parent"))
        if not cur:
            break
    return out


def master_defaults(master):
    """Root material parameter defaults: CachedExpressionData.Parameters (ParameterInfos ordered scalars, vectors,
    textures; Data.Offsets[k] / Counts)."""
    d = A.load(master) or []
    e = next((x for x in d if x.get("Type") == "Material"), None)
    if e is None:
        # the master's shadermaps.exe dump (extracted/weapon_vfx_build/materials, see recon/WEAPON_VFX.md)
        dump = ROOT / "extracted/weapon_vfx_build/materials" / (master + ".json")
        if dump.exists():
            e = json.loads(dump.read_text(encoding="utf-8")).get("properties")
    out = {"scalars": {}, "vectors": {}, "textures": {}}
    if not e:
        return out
    P = ((e.get("Properties") or {}).get("CachedExpressionData") or {}).get("Parameters") or {}
    names = [x["Name"] for x in (P.get("Data") or {}).get("ParameterInfos", [])]
    sv, vv, tv = P.get("ScalarValues", []), P.get("VectorValues", []), P.get("TextureValues", [])
    k = 0
    for v in sv:
        out["scalars"][names[k]] = v
        k += 1
    for v in vv:
        out["vectors"][names[k]] = [v.get("R", 0.0), v.get("G", 0.0), v.get("B", 0.0), v.get("A", 0.0)]
        k += 1
    for v in tv:
        out["textures"][names[k]] = refname(v)
        k += 1
    return out


def decal_material(mi):
    chain = material_chain(mi)
    if not chain:
        return None
    master = chain[-1][0] if chain[-1][2] == "Material" else None
    info = master_defaults(master) if master else {"scalars": {}, "vectors": {}, "textures": {}}
    for name, p, typ in reversed(chain[:-1] if master else chain):
        for x in p.get("ScalarParameterValues", []) or []:
            info["scalars"][x["ParameterInfo"]["Name"]] = x["ParameterValue"]
        for x in p.get("VectorParameterValues", []) or []:
            v = x["ParameterValue"]
            info["vectors"][x["ParameterInfo"]["Name"]] = [v.get("R", 0.0), v.get("G", 0.0), v.get("B", 0.0), v.get("A", 0.0)]
        for x in p.get("TextureParameterValues", []) or []:
            info["textures"][x["ParameterInfo"]["Name"]] = refname(x["ParameterValue"])
    info["master"] = master
    info["chain"] = [c[0] for c in chain]
    return info


def copy_decal_textures(mats):
    """Exported texture PNGs (tools/di2x.sh tex) -> game/assets/di2/weapon_vfx/decals (.gdignore'd, loaded raw)."""
    import shutil
    DECAL_TEX_DIR.mkdir(parents=True, exist_ok=True)
    (DECAL_TEX_DIR / ".gdignore").write_text("")
    pngs = {f.stem: f for f in TEX_EXPORT.rglob("*.png")}
    missing = set()
    for m in mats.values():
        if not m or m.get("master") not in DECAL_MASTERS:
            continue
        for t in m["textures"].values():
            if not t:
                continue
            if t in pngs:
                dst = DECAL_TEX_DIR / (t + ".png")
                if not dst.exists() or dst.stat().st_mtime < pngs[t].stat().st_mtime:
                    shutil.copy2(pngs[t], dst)
            else:
                missing.add(t)
    return sorted(missing)


def compose_decal_textures(mats):
    """Godot Decal textures for each M_DecalPOM_DNR MI (game/assets/di2/weapon_vfx/decals/<MI>_{albedo,normal,orm}.png),
    composed from the MI's maps the way DI2's FDeferredDecalPS 861 combines them (recon/WEAPON_VFX.md section 5):
      albedo.rgb = sat(lerp(1, "04 - Diffuse Colour Tint", ARA.b) * Diffuse.rgb) (in linear, stored sRGB),
      albedo.a   = sat(ARA.r) (opacity);
      normal     = BC5 normal (r, 1 - g): Godot's decal decode flips green (y = 1 - 2g) and rebuilds z;
      orm        = (1, sat("05 - Roughness Adjustment" + ARA.g), 0): AO untouched, roughness, metallic 0.
    The height map (parallax occlusion) has no Godot Decal equivalent and is only used by the "pom" renderer."""
    from PIL import Image
    import numpy as np
    out = {}
    for mi, m in mats.items():
        if not m or m.get("master") not in DECAL_MASTERS:
            continue
        t = m["textures"]
        names = {k: t.get(k) for k in ("01 - Diffuse Colour Map", "02 - Packed ARA Map (see tooltip!)", "03 - Normal Map")}
        files = {k: DECAL_TEX_DIR / (v + ".png") for k, v in names.items() if v}
        if len(files) < 3 or not all(f.exists() for f in files.values()):
            continue
        dst = {k: DECAL_TEX_DIR / f"{mi}_{k}.png" for k in ("albedo", "normal", "orm")}
        newest = max(f.stat().st_mtime for f in files.values())
        if all(d.exists() and d.stat().st_mtime >= newest for d in dst.values()):
            out[mi] = {k: d.stem for k, d in dst.items()}
            continue
        dif = Image.open(files["01 - Diffuse Colour Map"]).convert("RGBA")
        size = dif.size
        ara = np.asarray(Image.open(files["02 - Packed ARA Map (see tooltip!)"]).convert("RGBA").resize(size, Image.BILINEAR)).astype(np.float32) / 255.0
        nrm = np.asarray(Image.open(files["03 - Normal Map"]).convert("RGBA").resize(size, Image.BILINEAR)).astype(np.float32) / 255.0
        d = np.asarray(dif).astype(np.float32) / 255.0
        lin = np.where(d[..., :3] <= 0.04045, d[..., :3] / 12.92, ((d[..., :3] + 0.055) / 1.055) ** 2.4)
        tint = np.array(m["vectors"].get("04 - Diffuse Colour Tint", [1, 1, 1, 1])[:3], dtype=np.float32)
        lin = np.clip((ara[..., 2:3] * (tint - 1.0) + 1.0) * lin, 0.0, 1.0)
        srgb = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
        alb = np.dstack([srgb, np.clip(ara[..., 0], 0.0, 1.0)])
        nm = np.dstack([nrm[..., 0], 1.0 - nrm[..., 1], np.ones(size[::-1], np.float32), np.ones(size[::-1], np.float32)])
        rough = np.clip(float(m["scalars"].get("05 - Roughness Adjustment", 0.0)) + ara[..., 1], 0.0, 1.0)
        orm = np.dstack([np.ones_like(rough), rough, np.zeros_like(rough), np.ones_like(rough)])
        for k, a in (("albedo", alb), ("normal", nm), ("orm", orm)):
            Image.fromarray((np.clip(a, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGBA").save(dst[k])
        out[mi] = {k: dst_.stem for k, dst_ in dst.items()}
    return out


def mpc_scalars(name, keys):
    d = A.load(name) or []
    e = next((x for x in d if x.get("Type") == "MaterialParameterCollection"), None)
    out = {}
    for x in ((e or {}).get("Properties") or {}).get("ScalarParameters", []):
        if x.get("ParameterName") in keys:
            out[x["ParameterName"]] = x.get("DefaultValue", 0.0)
    return out


def main():
    weapons = json.loads((ROOT / "game/data/weapons.json").read_text(encoding="utf-8"))
    class_files = {json.loads(f.read_text(encoding="utf-8")).get("di2"): f for f in (ROOT / "game/data/classes").glob("*.json")}
    out = {"_source": "tools/weapon_vfx/build_weapon_vfx.py (DI2 data; recon/WEAPON_VFX.md)",
           "weapons": {}, "effect_sets": {}, "montage_notifies": {}}
    for wid, w in sorted(weapons.items()):
        if not isinstance(w, dict) or w.get("kind") not in ("ranged", "melee"):
            continue
        he = w.get("hit_effects") or {}
        entry = {"blueprint": w.get("blueprint"), "kind": w["kind"], "env_tree": he.get("environment"),
                 "impact_facts": he.get("facts", {}), "held_facts": held_facts(w["blueprint"]) if w.get("blueprint") else {}}
        if w["kind"] == "ranged":
            sets = [s for s in he.get("causer_sets", []) if s.startswith("DA_EffectSetCollection_")]
            entry["effect_sets"] = sets
            entry["spawner"] = spawner_cosmetics(w["blueprint"])
            entry["sockets"] = {k: v for k, v in mesh_sockets(w.get("mesh_asset") or "").items()
                                if k and ("Muzzle" in k or "Eject" in k)}
            for s in sets:
                out["effect_sets"].setdefault(s, effect_set_collection(s))
            cf = class_files.get(w.get("class"))
            if cf:
                for mname in weapon_montages(cf):
                    if mname.endswith("_Weapon") or "Weapon" in mname:
                        ns = montage_particle_notifies(mname)
                        if ns:
                            out["montage_notifies"][mname] = ns
        out["weapons"][wid] = entry
    # World impacts: every registry an environment tree reaches (grid node override, else the game collision
    # handler's EffectsRegistry), the physical materials and the surface names.
    gch = None
    for e in A.load(GCH) or []:
        if e.get("Type") == "GameCollisionRegistry":
            gch = refname((e.get("Properties") or {}).get("EffectsRegistry"))
    out["default_registry"] = gch
    he = json.loads((ROOT / "game/data/hit_effects.json").read_text(encoding="utf-8"))
    regs = {gch} | {n.get("registry") for t in he["trees"].values() for n in t["nodes"].values()
                    if n.get("k") == "grid" and n.get("registry")}
    out["registries"] = {r: registry(r) for r in sorted(x for x in regs if x)}
    env_trees = sorted({w["env_tree"] for w in out["weapons"].values() if w.get("env_tree")})
    out["grid_nodes"] = grid_nodes(env_trees)
    out["physical_materials"] = physical_materials()
    out["surfaces"] = surface_names()
    out["default_physical_material"] = default_phys_material()
    OUT.write_text(json.dumps(out, indent=1))
    ces = sorted({it[1] for s in out["effect_sets"].values() for groups in s.values() for g in groups
                  for it in g["items"] if it[1]})
    ps = sorted({v for w in out["weapons"].values() for k, v in w.get("spawner", {}).items()
                 if k.endswith("EffectType") and v} |
                {n["ps"] for ns in out["montage_notifies"].values() for n in ns if n["ps"]})
    # Impact CEs the arena can reach: every bullet / melee row of every registry (all columns).
    for r in out["registries"].values():
        if not r:
            continue
        n = len(r["colliders"])
        for row in [c["name"] for c in r["colliders"] if c["type"] == "Custom" and (c["name"].startswith("Bullet") or c["name"].startswith("Melee"))]:
            i = r["names"][row]
            ces += [x for x in r["table"][i * n:(i + 1) * n] if x and x.startswith("CE_")]
    ces = sorted(set(ces))
    # Non-particle parts of those CEs that WeaponVfx plays itself (decals); the rest (audio, PhysicalizedWorld) is
    # listed in recon/WEAPON_VFX.md as not ported.
    out["ce_decals"] = collision_decals(ces)
    mis = sorted({e["DecalMaterial"]["n"] for v in out["ce_decals"].values() for e in v if e.get("DecalMaterial")})
    out["decal_materials"] = {m: decal_material(m) for m in mis}
    missing_tex = copy_decal_textures(out["decal_materials"])
    for mi, tex in compose_decal_textures(out["decal_materials"]).items():
        out["decal_materials"][mi]["godot_decal"] = tex
    out["mpc"] = mpc_scalars("MPC_GameWideParams", {"POMMinSteps", "POMMaxSteps"})
    nodump = [m for m, v in out["decal_materials"].items() if v is None]
    print(f"decal materials: {len(mis)} ({len(nodump)} not dumped), textures missing: {len(missing_tex)}")
    OUT.write_text(json.dumps(out, indent=1))
    ROOTS.write_text(json.dumps({"_source": "tools/weapon_vfx/build_weapon_vfx.py", "ce": ces, "ps": ps}, indent=1))
    print(f"{len(out['weapons'])} weapons, {len(out['effect_sets'])} effect sets, "
          f"{len(out['montage_notifies'])} montages with particle notifies; roots: {len(ces)} CEs, {len(ps)} PSs")


if __name__ == "__main__":
    main()
