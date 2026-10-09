"""Build Dani's (DI2 FemBerserker, first person) render data for the Godot port. Personal use; reads the user's own
install / extracted files only, never runs the game.

    miniconda python tools/build_dani_materials.py        (needs zstandard, numpy, PIL; .NET 10 in tools/dotnet10)

Outputs
  game/data/dani_materials.json      every FP section's material resolved through its MI chain to the master (textures,
                                     scalars, vectors, static switches, render settings, subsurface profile, decompiled
                                     base-pass PS + the player.gdshader variant transcribed from it), the texture table,
                                     the mesh / component setup (FP mesh + the hidden TP shadow body), the player-hand
                                     blood system (PlayerHandsMaterialComponent data + the exe constants from
                                     recon/DANI.md) and the MPC values the shaders read.
  game/assets/di2/dani/flesh/        (.gdignore'd, loaded raw by game/scripts/dani_visual.gd)
     <texture>.dds                   the cooked texture exactly as DI2 ships it: same pixel format (BC1/BC3/BC5/...),
                                     every cooked mip, no re-encode. sRGB is recorded per texture (DDS can't say it).
     TV_Global3dNoise.rgba3d         the 128^3 volume noise, mip 0, RGBA8 slices (z-major), header-less.
     dani_fp.skin8.bin               all 8 cooked bone influences per dani_fp.glb vertex (the CUE4Parse glTF writer keeps 4).
     dani_tp_shadow.glb              SK_FemBerserker (third-person body, the FP shadow caster), copied from extracted/mesh.

Material resolution reuses the FLESH session's code read-only (tools/shaders/build_flesh_materials.py: chain dumps,
resolve(), base-pass sampler table) with its build folder redirected to extracted/shaders/dani_build/.
Static analysis notes, sources and open items: recon/DANI.md.
"""
import json
import os
import shutil
import struct
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "shaders"))
sys.path.insert(0, os.path.join(HERE, "deform"))
import build_flesh_materials as B  # noqa: E402  (read-only reuse)
from di2mesh import Reader, find_lod_starts, parse_lod  # noqa: E402  (read-only reuse)
from glb import Glb  # noqa: E402

B.BUILD = os.path.join(ROOT, "extracted", "shaders", "dani_build")
B.MATS = os.path.join(B.BUILD, "materials")
OUT_JSON = os.path.join(ROOT, "game", "data", "dani_materials.json")
OUT_DIR = os.path.join(ROOT, "game", "assets", "di2", "dani", "flesh")
RES_DIR = "res://assets/di2/dani/flesh"
JSON_ROOT = os.path.join(ROOT, "extracted", "json", "DeadIsland", "Content")
FEM = "DI2/Art/Characters/Players/FemBerserker/"
FP_MESH = FEM + "SK_FemBerserkerFP"
TP_MESH = FEM + "SK_FemBerserker"
GLB_FP = os.path.join(ROOT, "game", "assets", "di2", "dani", "dani_fp.glb")
GLB_TP_SRC = os.path.join(ROOT, "extracted", "mesh", "DeadIsland", "Content", FEM.replace("/", os.sep) + "SK_FemBerserker.glb")
RAW_FP = os.path.join(ROOT, "extracted", "raw", "DeadIsland", "Content", FEM.replace("/", os.sep) + "SK_FemBerserkerFP.uasset")

# Decompiled High-quality TBasePassPSFNoLightMapPolicy (GPUSkin Default) of each FP shader map -> the player.gdshader
# variant transcribed from it (recon/DANI.md section 4). An unknown PS stops the build: it needs reading first.
PS_VARIANT = {
    9326: "skin_staged_veinmap",     # MI_FemBerserkerFPHandR/L: M_Skin, Staged Splatter Mode + Zombie Veins (vein normal map)
    12717: "skin_staged_cheapveins",  # MI_FemBerserkerSkin/SkinArmL: + Enable Cheap Zombie Veins Effect
    5740: "skin",                     # MI_FemBerserkerBandFP/BandCardsFP: M_Skin default permutation
    4452: "cloth",                    # MI_FemBerserkerUpper/LowerBody, FPBracelet: M_Clothing + Detail Mapping
    9445: "cloth_staged",             # MI_FemBerserkerFPGlove: M_Clothing, Staged Splatter Mode
}
# MPC_CharacterGameWideParams / MPC_GameWideParams entries the five PS read (annotated slots, recon/DANI.md 4.1).
MPC_USED = {
    "MPC_CharacterGameWideParams": ["StagedSplatterBloodDensity", "StagedSplatterNormalsBlendThreshold",
                                    "StagedSplatterDynamicNormalsJitter", "StagedSplatterDynamicNormalsStrength",
                                    "StagedSplatterEdgeContrast", "StagedSplatterDriedBloodCavityPower",
                                    "CutSceneHandBloodSplatter", "FurySkinRedIsolationScale", "FurySkinRedDesaturation",
                                    "FurySkinNonRedDesaturation", "FuryClothNonRedDesaturation", "ChrFuryTint",
                                    "ChrLandscapeBlendMaxDistance", "Max Base Color Blend", "Frost Roughness"],
    "MPC_GameWideParams": ["ZombieVeinsCinematic"],
}


def jload(rel):
    return json.load(open(os.path.join(JSON_ROOT, rel + ".json")))


def export_of(objs, typ):
    return next(e for e in objs if e.get("Type") == typ)


def obj_path(x):
    return (x or {}).get("ObjectPath") or (x or {}).get("AssetPathName")


# --- mesh / components -------------------------------------------------------------------------------------------

def mesh_info(rel):
    objs = jload(rel)
    sk = export_of(objs, "SkeletalMesh")
    secs = [{"slot": i, "material": B.short(obj_path(s.get("Material") or s.get("MaterialInterface")))}
            for i, s in enumerate(sk["SkeletalMaterials"])]
    lod0 = sk["LODModels"][0]["Sections"]
    for s in secs:
        sec = next((x for x in lod0 if x["MaterialIndex"] == s["slot"]), None)
        if sec:
            s.update(lod0_vertices=sec["NumVertices"], lod0_triangles=sec["NumTriangles"],
                     max_bone_influences=sec["MaxBoneInfluences"], cast_shadow=sec["bCastShadow"])
    out = {"asset": "/Game/" + rel, "sections": secs,
           "skeleton": B.short(obj_path(sk["Properties"]["Skeleton"])),
           "physics_asset": B.short(obj_path(sk["Properties"].get("PhysicsAsset")))}
    masks = next((e for e in objs if e.get("Type") == "CharacterMaterialMasks"), None)
    if masks:
        p = masks["Properties"]
        out["character_material_masks"] = {"MaterialSectionNames": p.get("MaterialSectionNames"),
                                           "PlayerHandsData": p.get("PlayerHandsData", [])}
    dimasks = next((e for e in objs if e.get("Type") == "DIEngineMaterialMasks"), None)
    if dimasks:
        out["di_engine_material_masks"] = {k: (v if not isinstance(v, int) or v < 2 ** 53 else str(v))
                                           for k, v in dimasks["Properties"]["Masks"].items()}
    return out


def components():
    base = jload("DI2/Core/Player/BP_Base_Player")
    fem = jload("DI2/Player/Characters/Berserker/BP_Berserker_Female")
    keep = ("bOnlyOwnerSee", "bOwnerNoSee", "CastShadow", "bCastHiddenShadow", "bRenderNearest", "AnimClass",
            "RelativeLocation", "RelativeRotation", "FieldOfView", "AttachParent", "SkeletalMesh")
    out = {}
    for bp, label in ((base, "BP_Base_Player"), (fem, "BP_Berserker_Female")):
        for e in bp:
            if e.get("Name") in ("MeshFirstPerson", "CharacterMesh0", "FirstPersonPlayerCamera"):
                p = e.get("Properties") or {}
                d = out.setdefault(e["Name"], {"type": e["Type"]})
                for k in keep:
                    if k in p:
                        v = p[k]
                        d[k] = {"value": B.short(obj_path(v)) if isinstance(v, dict) and obj_path(v) else v, "source": label}
    return out


# --- 8-influence skin side-car ---------------------------------------------------------------------------------------

def skin8(glb_path, out_bin):
    """All cooked influences of SK_FemBerserkerFP LOD0 per glb vertex. glb vertices are matched to cooked ones the way
    tools/deform/export_deform.py does it (SharpGLTF keeps triangle order, dedups vertices, drops degenerates).
    Record per glb primitive (in file order): u32 vertex count, then per vertex 8 x u16 glTF joint index (skin joints
    order == the mesh RefSkeleton order CUE4Parse writes) and 8 x u8 weight (sum 255), heaviest first."""
    d = open(RAW_FP, "rb").read()
    lod, _ = parse_lod(d, find_lod_starts(d)[0])
    r = Reader(d, lod["skin_offset"])
    r.strip()
    variable = r.boolean(); maxinf = r.u32(); r.u32(); nv = r.u32(); b16 = r.boolean()
    es, n, off = r.bulk()
    assert not variable and es == 1 and nv == lod["NumVertices"], (variable, es, nv)
    isz = 2 if b16 else 1
    raw = np.frombuffer(d, np.uint8, count=n, offset=off).reshape(nv, maxinf * (isz + 1))
    local = raw[:, :maxinf * isz].copy().view("<u2" if b16 else np.uint8).reshape(nv, maxinf).astype(np.int64)
    wts = raw[:, maxinf * isz:].astype(np.int64)
    assert (wts.sum(1) == 255).all()
    g = Glb(glb_path)
    prims = g.primitives()
    enabled = [(i, s) for i, s in enumerate(lod["sections"]) if not s["bDisabled"]]
    assert len(prims) == len(enabled)
    P = lod["positions"].astype(np.float32) * np.float32(0.01)
    upos = P[:, [0, 2, 1]]
    blob = bytearray()
    stats = {"vertices": 0, "with_influence_beyond_4": 0, "max_weight_beyond_4": 0.0, "top4_match_glb": 0}
    for (mi, pi, mat, p), (si, s) in zip(prims, enabled):
        gpos = g.accessor(p["attributes"]["POSITION"])
        gidx = g.accessor(p["indices"]).reshape(-1, 3).astype(np.int64)
        gj = g.accessor(p["attributes"]["JOINTS_0"]).astype(np.int64)
        gw = g.accessor(p["attributes"]["WEIGHTS_0"]).astype(np.float64)
        tris = lod["indices"][s["BaseIndex"]: s["BaseIndex"] + 3 * s["NumTriangles"]].reshape(-1, 3)
        if tris.max() < s["NumVertices"]:
            tris = tris + s["BaseVertexIndex"]
        gmap = np.full(len(gpos), -1, np.int64)
        k = 0
        for t in tris:
            if k < len(gidx) and np.array_equal(upos[t], gpos[gidx[k]]):
                for c in range(3):
                    if gmap[gidx[k][c]] < 0:
                        gmap[gidx[k][c]] = t[c]
                k += 1
        assert k == len(gidx) and (gmap >= 0).all(), (mat, k, len(gidx))
        bm = s["BoneMap"].astype(np.int64)
        L, W = local[gmap], wts[gmap]
        J = bm[L]                                         # section bone map -> RefSkeleton (= glTF joint) index
        order = np.argsort(-W, axis=1, kind="stable")
        J = np.take_along_axis(J, order, 1); W = np.take_along_axis(W, order, 1)
        J = np.where(W > 0, J, 0)
        if maxinf < 8:
            J = np.pad(J, ((0, 0), (0, 8 - maxinf))); W = np.pad(W, ((0, 0), (0, 8 - maxinf)))
        # check: the glb's 4 influences are this vertex's 4 heaviest (CUE4Parse keeps 4 and renormalises)
        match = sum(1 for v in range(len(gpos))
                    if set(J[v, :4][W[v, :4] > 0].tolist()) == set(gj[v][gw[v] > 0].tolist()))
        stats["top4_match_glb"] += match
        stats["vertices"] += len(gpos)
        beyond = W[:, 4:].sum(1)
        stats["with_influence_beyond_4"] += int((beyond > 0).sum())
        stats["max_weight_beyond_4"] = max(stats["max_weight_beyond_4"], float(beyond.max()) / 255.0)
        blob += struct.pack("<I", len(gpos))
        rec = np.zeros(len(gpos), dtype=[("p", "<f4", 3), ("j", "<u2", 8), ("w", "u1", 8)])
        rec["p"] = gpos; rec["j"] = J[:, :8]; rec["w"] = W[:, :8]
        blob += rec.tobytes()
    open(out_bin, "wb").write(bytes(blob))
    stats["format"] = ("per glb primitive: u32 count, then count x (3 x f32 glTF position, 8 x u16 glTF joint, 8 x u8 "
                       "weight/255), heaviest first; matched to Godot's vertices by position (its importer reorders them)")
    stats["cooked_max_bone_influences"] = int(maxinf)
    # glTF skin joint -> bone name (Godot's skin binds are not in glTF joint order; the runtime maps by name)
    stats["joints"] = [g.json["nodes"][j].get("name", "") for j in g.json["skins"][0]["joints"]]
    return stats


# --- textures: exact cooked mips -> DDS ------------------------------------------------------------------------------

MIPDUMP_CS = r'''// Generated by tools/build_dani_materials.py: dump every cooked mip of UTexture2D / UVolumeTexture, untouched.
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
            if (e is not UTexture t || e is not (UTexture2D or UVolumeTexture)) continue;
            var pd = t.PlatformData; var first = t.GetFirstMipIndex();
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
                name = e.Name, path = path.Trim(), cls = e.ExportType, pixel_format = t.Format.ToString(),
                srgb = t.SRGB, address = new[] { t.GetTextureAddressX().ToString(), t.GetTextureAddressY().ToString() },
                filter = t.Filter.ToString(), lod_group = t.LODGroup.ToString(), compression = t.CompressionSettings.ToString(),
                first_mip = first, total_mips = pd.Mips.Length, mips,
            });
            Console.WriteLine($"ok   {e.Name} {t.Format} mips {mips.Count}/{pd.Mips.Length - first}");
        }
    }
    catch (Exception ex) { Console.WriteLine($"FAIL {path}: {ex.Message}"); }
}
File.WriteAllText(Path.Combine(outDir, "meta.json"), JsonConvert.SerializeObject(meta, Formatting.Indented));
'''
MIPDUMP_PROJ = B.TEXDUMP_PROJ.replace("texdump", "mipdump")

# EPixelFormat -> (DDS FourCC or None, DXGI format, bytes per 4x4 block or per pixel, block compressed)
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
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | (0x80000 if bc else 0x8)   # CAPS HEIGHT WIDTH PIXELFORMAT MIPMAPCOUNT LINEARSIZE|PITCH
    pitch = mip_bytes(fmt, w, h) if bc else w * bpb
    pf = struct.pack("<II4sIIIII", 32, 0x4, (fourcc or "DX10").encode(), 0, 0, 0, 0, 0)
    caps = 0x1000 | 0x8 | 0x400000                                            # TEXTURE | COMPLEX | MIPMAP
    hdr = b"DDS " + struct.pack("<IIIIIII", 124, flags, h, w, pitch, 0, len(mips)) + b"\0" * 44 + pf + \
        struct.pack("<IIIII", caps, 0, 0, 0, 0)
    if not fourcc:
        hdr += struct.pack("<IIIII", dxgi, 3, 0, 1, 0)                        # TEXTURE2D, 1 array slice
    total = sum(m["bytes"] for m in mips)
    for m in mips:
        assert m["bytes"] == mip_bytes(fmt, m["w"], m["h"]) * max(1, m["d"]), (dst, m, fmt)
    open(dst, "wb").write(hdr + data[:total])


def dump_mips(pkgs):
    proj = os.path.join(B.BUILD, "mipdump")
    os.makedirs(proj, exist_ok=True)
    open(os.path.join(proj, "Program.cs"), "w").write(MIPDUMP_CS)
    open(os.path.join(proj, "mipdump.csproj"), "w").write(MIPDUMP_PROJ)
    r = subprocess.run([B.DOTNET, "build", "-c", "Release", "-o", os.path.join(proj, "bin", "out"), proj],
                       env=B.ENV, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout[-3000:])
    lst = os.path.join(B.BUILD, "mip_textures.txt")
    open(lst, "w").write("\n".join(sorted(pkgs)))
    raw = os.path.join(B.BUILD, "mips")
    r = subprocess.run([os.path.join(proj, "bin", "out", "mipdump.exe"), ROOT, lst, raw], env=B.ENV,
                       capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    if fails or r.returncode:
        raise RuntimeError("\n".join(fails) + r.stderr[-2000:])
    return raw, json.load(open(os.path.join(raw, "meta.json")))


# --- hand blood (PlayerHandsMaterialComponent) ----------------------------------------------------------------------

def hand_blood():
    fem = jload("DI2/Player/Characters/Berserker/BP_Berserker_Female")
    comp = export_of(fem, "PlayerHandsMaterialComponent")["Properties"]
    settings = {}
    for kv in comp["BloodSettings"]:
        v = kv["Value"]
        smap = obj_path(v["StagedTextureMap"])
        stm = export_of(jload(smap.split(".")[0][len("/Game/"):]), "StagedTextureMap")["Properties"]
        settings[kv["Key"]] = {
            "StagedTextureMap": B.short(smap),
            "stages_highest_to_lowest": [{"texture": B.short(obj_path(x["Texture"])), "RequiredScore": x["RequiredScore"]}
                                         for x in stm["SortedTexturesHighestToLowest"]],
            "TextureParameterName": v["TextureParameterName"], "FlowAnimationDuration": v["FlowAnimationDuration"],
            "FlowAnimationTextureParameterName": v["FlowAnimationTextureParameterName"],
            "RequiredOnScreenTimeBeforeAnimation": v["RequiredOnScreenTimeBeforeAnimation"],
            "source": "BP_Berserker_Female.PlayerHandsMaterialComponent.BloodSettings + " + B.short(smap)}
    base = jload("DI2/Core/Player/BP_Base_Player")
    bcomp = export_of(base, "PlayerHandsMaterialComponent")["Properties"]
    visuals = {}
    for k, v in bcomp.items():
        asset = B.short(obj_path(v))
        lst = export_of(jload(obj_path(v).split(".")[0][len("/Game/"):]), "HandsVisualsDataAsset")["Properties"]
        for ent in lst["PlayersHandsUpdateList"]:
            if "BP_Berserker_Female" in obj_path(ent["Character"]):
                visuals[k.replace("HandsDataAsset_Debug", "")] = {
                    "asset": asset, "materials": {x["Key"].split("::")[1]: B.short(obj_path(x["Value"])) for x in ent["NewMaterial"]}}
    ce = jload("DIShared/Effects/CosmeticFX/Player/CE_Player_Autophage")
    effects = []
    for e in ce:
        if e.get("Type") == "MaterialFloatParameterMap":
            p = e["Properties"]
            effects.append({"cosmetic_effect": "CE_Player_Autophage", "effect": "CosmeticEffect_PlayerHandMaterial",
                            "MaterialParameterName": p["MaterialParameterName"],
                            "Expression": p["Expression"]["Expression"].strip(), "bUseCustomCurve": p.get("bUseCustomCurve", False),
                            "curve_keys": [{"time": k["Time"], "value": k["Value"], "interp": k["InterpMode"],
                                            "tangent_mode": k["TangentMode"], "arrive": k["ArriveTangent"], "leave": k["LeaveTangent"]}
                                           for k in p["CustomCurve"]["EditorCurveData"]["Keys"]]})
    native = {
        "CurrentHandBloodinessValue": "UPlayerHandsMaterialComponent+0x1c0, float, replicated (OnRep_CurrentHandBloodinessValue)",
        "add_on_melee_hit": {"value": "clamp(B + inc, 0, 1)", "inc": "MeleeArchetypeData.BloodinessIncrementPerHit",
                             "BloodinessIncrementPerHit_default": 0.1, "critical_multiplier": 3.0,
                             "source": "exe: weapon on-hit FUN_14170c360 -> AddHandBloodiness FUN_1418138b0; default from the "
                                       "FMeleeArchetypeData ctor FUN_1416e4e00 (+0x400 = 0x3dcccccd); x3 when the impact's "
                                       "DSDamageData+9 bool (bCriticalHit, inferred from reflection layout) is set; no DI2 asset overrides the default"},
        "stage_select": "first entry of SortedTexturesHighestToLowest with RequiredScore <= B (FUN_141af6070); if it differs "
                        "from the MID's current texture: set it and set FlowAnimationTextureParameterName = 0 (FUN_141559700/FUN_141554fc0)",
        "flow_animation": "component tick (FUN_141829950 -> FUN_14182b780) while flagged: a section whose phase is 0 waits until the "
                          "hands have been on screen RequiredOnScreenTimeBeforeAnimation seconds, then phase = clamp(phase + dt / "
                          "max(FlowAnimationDuration, 1.19e-7), 0, 1) (FUN_141559630); flag stays while any phase < 1",
        "decay": "none over time; B is set to 0 when a weapon stowed longer than melee.StowedTimeForClean is equipped (FUN_141700550 "
                 "-> FUN_1416eaa20) and by three weapon routines that first write weapon+0xc20 (FUN_1416eb140/eb190/ed340, purpose unverified)",
        "melee.StowedTimeForClean": {"value": 5.0, "source": "CVar registered at FUN_1404fde50 (0x40a00000)"},
    }
    return {"BloodSettings": settings, "PlayerHandsVisuals": visuals, "cosmetic_effects": effects, "native": native}


# --- main --------------------------------------------------------------------------------------------------------------

def main():
    os.makedirs(B.BUILD, exist_ok=True)
    fp = mesh_info(FP_MESH)
    tp = mesh_info(TP_MESH)
    hb = hand_blood()
    variants = {}
    for k, v in hb["PlayerHandsVisuals"].items():
        for persp, mi in v["materials"].items():
            if persp == "FirstPersonMesh":
                variants.setdefault(mi, []).append(k)
    leaves = {}
    fp_objs, tp_objs = jload(FP_MESH), jload(TP_MESH)
    for objs in (fp_objs, tp_objs):
        for s in export_of(objs, "SkeletalMesh")["SkeletalMaterials"]:
            op = obj_path(s.get("Material") or s.get("MaterialInterface"))
            leaves[B.short(op)] = op
    for mi in variants:
        leaves.setdefault(mi, "/Game/" + FEM + mi + "." + "0")
    chains = B.chains_for(list(leaves.values()))
    fp_names = {s["material"] for s in fp["sections"]}
    mats, want_tex = {}, {}
    samples_cache = {}
    for name, op in sorted(leaves.items()):
        chain = chains[op]
        entry, owner, ues = B.resolve(chain)
        role = "fp" if name in fp_names else ("hands_visual_variant" if name in variants else "tp_shadow")
        entry = {"asset": op, "role": role, **entry}
        if name in variants:
            entry["hands_visual_states"] = variants[name]
        ssp = None
        for m in chain:
            sp = (m["properties"].get("Properties") or {}).get("SubsurfaceProfile")
            if sp:
                ssp = {"value": B.short(obj_path(sp)), "source": m["export"]}
                break
        entry["subsurface_profile"] = ssp
        key = (owner or {}).get("shader_resource_hash")
        if role != "tp_shadow" and ues is not None and key:
            if key not in samples_cache:
                samples_cache[key] = B.base_pass_samples(key, ues)
            ps, uses = samples_cache[key]
            entry["base_pass_ps"] = {"archive": "DeadIsland", "index": ps, "vertex_factory": "TGPUSkinVertexFactoryDefault"}
            if ps not in PS_VARIANT and role == "fp":
                raise SystemExit("unread base-pass PS %s for %s: decompile and transcribe it first" % (ps, name))
            entry["shader_variant"] = PS_VARIANT.get(ps)   # story-state variants: recorded, not transcribed (recon/DANI.md)
            by_slot = {}
            for res_name, u in uses.items():
                if res_name != "__splatter_coords__":
                    by_slot.setdefault(res_name.split(".", 1)[1].replace("Sampler", ""), []).extend(u["ops"])
            for d in entry["params"]["textures"].values():
                d["samples"] = by_slot.get(d.get("slot"), [])
        # textures to export: every texture the FP permutations use; TP shadow sections only need their opacity map
        for pname, d in entry["params"]["textures"].items():
            v = d["value"]
            if not v or v == "None" or v.startswith("RVT_"):
                continue
            if role == "fp" and d["used"]:
                want_tex.setdefault(v, "fp")
            elif role == "tp_shadow" and d["used"] and pname in ("Packed ATA Map (see tooltip!)", "Packed Hair Data Map"):
                want_tex.setdefault(v, "tp_opacity")
        mats[name] = entry
    for st in hb["BloodSettings"].values():
        for x in st["stages_highest_to_lowest"]:
            want_tex.setdefault(x["texture"], "staged_blood")
    # texture object paths (chain overrides, master ReferencedTextures, staged texture maps)
    paths = {}
    for chain in chains.values():
        for m in chain:
            p = m["properties"].get("Properties", {})
            for x in p.get("TextureParameterValues") or []:
                if obj_path(x.get("ParameterValue")):
                    paths[B.short(obj_path(x["ParameterValue"]))] = obj_path(x["ParameterValue"])
            for t in (p.get("CachedExpressionData") or {}).get("ReferencedTextures", []):
                if obj_path(t):
                    paths[B.short(obj_path(t))] = obj_path(t)
    for st in hb["BloodSettings"].values():
        sm = jload("DI2/Player/Characters/Berserker/" + st["StagedTextureMap"])
        for x in export_of(sm, "StagedTextureMap")["Properties"]["SortedTexturesHighestToLowest"]:
            paths[B.short(obj_path(x["Texture"]))] = obj_path(x["Texture"])
    missing = [n for n in want_tex if n not in paths]
    assert not missing, missing
    raw_dir, meta = dump_mips({B.game_to_pkg(paths[n]) for n in want_tex})
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)          # generated folder; this script is its only writer
    os.makedirs(OUT_DIR)
    open(os.path.join(OUT_DIR, ".gdignore"), "w").write("")
    textures = {}
    for m in meta:
        data = open(os.path.join(raw_dir, m["name"] + ".mips"), "rb").read()
        t = {"role": want_tex.get(m["name"], "fp"), "asset": m["path"], "class": m["cls"], "pixel_format": m["pixel_format"],
             "srgb": m["srgb"], "address": m["address"], "filter": m["filter"], "lod_group": m["lod_group"],
             "compression": m["compression"], "width": m["mips"][0]["w"], "height": m["mips"][0]["h"],
             "mips": len(m["mips"]), "cooked_first_mip": m["first_mip"], "cooked_total_mips": m["total_mips"]}
        if m["cls"] == "VolumeTexture":
            mm = m["mips"][0]
            assert m["pixel_format"] == "PF_B8G8R8A8"
            vol = np.frombuffer(data, np.uint8, count=mm["w"] * mm["h"] * mm["d"] * 4).reshape(mm["d"], mm["h"], mm["w"], 4)
            open(os.path.join(OUT_DIR, m["name"] + ".rgba3d"), "wb").write(vol[..., [2, 1, 0, 3]].tobytes())
            t.update(file=RES_DIR + "/" + m["name"] + ".rgba3d", depth=mm["d"], mips=1,
                     layout="RGBA8, slice z at byte offset z*w*h*4 (BGRA swizzled to RGBA), mip 0 only")
        else:
            write_dds(os.path.join(OUT_DIR, m["name"] + ".dds"), m["pixel_format"], m["mips"], data)
            t["file"] = RES_DIR + "/" + m["name"] + ".dds"
        textures[m["name"]] = t
    stats = skin8(GLB_FP, os.path.join(OUT_DIR, "dani_fp.skin8.bin"))
    fp["skin8"] = {"file": RES_DIR + "/dani_fp.skin8.bin", **stats}
    shutil.copyfile(GLB_TP_SRC, os.path.join(OUT_DIR, "dani_tp_shadow.glb"))
    tp["glb"] = RES_DIR + "/dani_tp_shadow.glb"
    profiles = {}
    for n in sorted({m["subsurface_profile"]["value"] for m in mats.values() if m.get("subsurface_profile")}):
        profiles[n] = export_of(jload("DIShared/Core/Materials/" + n), "SubsurfaceProfile")["Properties"]["Settings"]
    mpc = {}
    for coll, names in MPC_USED.items():
        p = jload("DIShared/Core/Materials/" + coll)[0]["Properties"]
        sc = {x["ParameterName"]: x.get("DefaultValue", 0.0) for x in p.get("ScalarParameters", [])}
        vc = {x["ParameterName"]: [x.get("DefaultValue", {}).get(c, 0.0) for c in "RGBA"] for x in p.get("VectorParameters", [])}
        mpc[coll] = {n: (sc[n] if n in sc else vc[n]) for n in names}
    doc = {
        "_about": "DI2 Dani (FemBerserker) first-person render data, from the user's own install by tools/build_dani_materials.py. "
                  "Sources, shader transcription and open items: recon/DANI.md.",
        "fp_mesh": fp, "tp_shadow_mesh": tp, "components": components(),
        "materials": mats, "textures": dict(sorted(textures.items())), "subsurface_profiles": profiles,
        "mpc": mpc, "hand_blood": hb,
    }
    json.dump(doc, open(OUT_JSON, "w"), indent=1)
    print("%d materials, %d textures, skin8 %s -> %s" % (len(mats), len(textures), stats, OUT_JSON))


if __name__ == "__main__":
    main()
