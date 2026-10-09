"""Build the DI2 FLESH material data for the Godot port (local, personal use; nothing extracted is shared).

    python tools/shaders/build_flesh_materials.py        (miniconda python: needs zstandard, numpy, PIL)

Outputs
  game/data/flesh_materials.json    per body-mesh material section: resolved splatter parameters through the MI chain,
                                    master / kind, the textures with their sampler/address/sRGB as the base pass uses
                                    them; plus the texture table and MPC_CharacterGameWideParams.
  game/assets/di2/flesh/*.png       the FLESH textures, raw channels (no premultiply, native size), .gdignore'd.
Intermediates (local): extracted/shaders/flesh_build/ (material dumps, generated CUE4Parse texture dumper, raw pixels).

How values are resolved (recon/SHADERS_FLESH.md section 13):
  - material chain: MI -> Parent -> ... -> UMaterial, read with tools/shaders/shadermaps (CUE4Parse);
  - parameter value: the first instance in the chain (leaf first) that overrides it, else the master default as stored
    in the effective shader map's uniform expression set (DefaultValue / TextureIndex -> master ReferencedTextures);
  - effective shader map: the first chain entry with a static-permutation shader map (DI2 .ushaderresources hash),
    else the master's inline map;
  - samplers: the High-quality TBasePassPSFNoLightMapPolicy (TGPUSkinVertexFactoryDefault) of that map, decompiled;
    every t#.Sample*(s#) is resolved through the shader's resource table (UB index << 24 | resource << 8 | slot).
"""
import base64, json, os, re, shutil, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import frozen, material_map, decompile  # noqa: E402  (tools/shaders)

SH = os.path.join(ROOT, "extracted", "shaders")
BUILD = os.path.join(SH, "flesh_build")
MATS = os.path.join(BUILD, "materials")
OUT_JSON = os.path.join(ROOT, "game", "data", "flesh_materials.json")
OUT_TEX = os.path.join(ROOT, "game", "assets", "di2", "flesh")
SHADERMAPS = os.path.join(ROOT, "tools", "shaders", "shadermaps", "bin", "out", "shadermaps.exe")
DOTNET = os.path.join(ROOT, "tools", "dotnet10", "dotnet.exe")
ENV = dict(os.environ, DOTNET_ROOT=os.path.join(ROOT, "tools", "dotnet10"))

BODIES = {
    "walker": "DI2/Art/Characters/ZombieMale/Walker/SK_WalkerMaleCas01",
    "runner": "DI2/Art/Characters/ZombieMale/Runner/SK_RunnerMaleCas01",
    "shambler": "DI2/Art/Characters/ZombieMale/Shambler/SK_ShamMaleCas01",
    "thug": "DI2/Art/Characters/ZombieSpecial/Thug/SK_ThugA01",
    # Special archetypes (tools/archetype_bodies.py, recon/ARCHETYPES.md).
    "screamer": "DI2/Art/Characters/ZombieSpecial/Screamer/SK_Screamer01",
    "slobber": "DI2/Art/Characters/ZombieSpecial/Slobber/SK_SlobberA",
    "butcher": "DI2/Art/Characters/ZombieSpecial/Butcher/SK_Butcher01",
    "suicider": "DI2/Art/Characters/ZombieSpecial/Suicider/SK_SuiciderA",
}
# P2 variant bodies (mesh only, class clips): tools/archetype_bodies.py VARIANTS.
sys.path.insert(0, os.path.dirname(HERE))
from archetype_bodies import built  # noqa: E402
BODIES.update({b: v["mesh"] for b, v in built().items()})
# Base-material maps the existing material packer already exports; everything else a splatter permutation samples
# (FLESH constants, inner layers, drips, gore gradient, the 3D noise) is exported here.
BASE_TEXTURE_PARAMS = {"Diffuse Colour Map", "Normal Map", "Packed MRO Map (see tooltip!)", "Packed ATA Map (see tooltip!)",
                       "Detail Normal Map", "Detail Roughness Map", "Detail DRO Map"}
# Parameters the port asked for by name (always reported, even where a permutation doesn't use them).
FLESH_PARAMS = {
    "textures": ["Inner Diffuse Colour Map", "Inner Normal Map", "Wound Gradient Map", "Blood Drip Map"],
    "vectors": ["Blood Colour", "inner Colour Tint", "06 - Bruise Colour Tint", "BloodMapUVOffset", "LargeNoiseRandomOffset"],
    "scalars": ["Inner Desaturation", "inner Roughness", "Splatter Opacity Offset", "03 - Epidermis Map Tiling",
                "02 - Blood Splatter Map Tiling", "02 - Blood Drip Map Tiling", "07 - Cauterization Map Tiling",
                "01 - Bruise Map Tiling", "05 - Bruise Desaturation", "03 - Fabric Tear Map Tiling", "Rip Amount",
                "04 - Fatty Tissue Map Tiling"],
}
# The four base maps every section reports (and whose PNGs are exported when extracted/ doesn't already hold them).
BASE_MAPS = ["Diffuse Colour Map", "Normal Map", "Packed MRO Map (see tooltip!)", "Packed ATA Map (see tooltip!)"]
DI2X = os.path.join(ROOT, "tools", "di2x", "bin", "out", "di2x.exe")
EYE_MASTERS = {"M_EyeRefractive", "M_EyeOcclusion"}
# M_Hair's own maps (PS 4056: strand tangent from the flow map; root-tip / occlusion / variation from the packed data).
HAIR_MASTERS = {"M_Hair"}
HAIR_TEXTURE_PARAMS = {"Packed Hair Data Map", "Flow Map"}
# Default FSubsurfaceProfileStruct as DI2's exe builds it (0x143a50db0, recon/DEFERRED_LIGHTING.md §7.3); a profile
# asset serialises only the fields it overrides.
SSP_DEFAULTS = {
    "SurfaceAlbedo": [0.91058, 0.338275, 0.2718, 1.0], "MeanFreePathColor": [1.0, 0.0889637, 0.0720951, 1.0],
    "MeanFreePathDistance": 2.6748, "WorldUnitScale": 0.1, "bEnableBurley": False, "ScatterRadius": 1.2,
    "SubsurfaceColor": [0.48, 0.41, 0.28, 1.0], "FalloffColor": [1.0, 0.37, 0.3, 1.0],
    "BoundaryColorBleed": [1.0, 1.0, 1.0, 1.0], "ExtinctionScale": 1.0, "NormalScale": 0.08,
    "ScatteringDistribution": 0.93, "IOR": 1.55, "Roughness0": 0.75, "Roughness1": 1.3, "LobeMix": 0.85,
    "TransmissionTintColor": [1.0, 1.0, 1.0, 1.0],
}
VIEW_SAMPLERS = {0:"View.MaterialTextureBilinearWrapedSampler", 1: "View.MaterialTextureBilinearClampedSampler"}
QUALITY = {0: "Low", 1: "High", 2: "Medium"}


def game_to_pkg(object_path):
    """'/Game/A/B.0' -> 'DeadIsland/Content/A/B.uasset' ('/Engine/...' -> 'Engine/Content/...')."""
    p = object_path.split(".")[0]
    if p.startswith("/Game/"):
        return "DeadIsland/Content/" + p[6:] + ".uasset"
    if p.startswith("/Engine/"):
        return "Engine/Content/" + p[8:] + ".uasset"
    raise ValueError(object_path)


def short(object_path):
    return object_path.split("/")[-1].split(".")[0]


# --- material chain dumps ------------------------------------------------------------------------------------

def dump_materials(pkgs):
    """Run shadermaps.exe material on the given package paths (output <export>.json in MATS)."""
    if not pkgs:
        return
    rx = "^(" + "|".join(re.escape(p) for p in sorted(pkgs)) + ")$"
    r = subprocess.run([SHADERMAPS, "material",
                        os.path.join(SH, "archive", "ShaderArchive-DeadIsland-PCD3D_SM5.ushaderresources"),
                        os.path.join(SH, "name_candidates.txt"), MATS, rx], env=ENV, capture_output=True, text=True)
    bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    if r.returncode or bad:
        raise RuntimeError(r.stdout[-2000:] + r.stderr[-2000:])


def asset_json(object_path):
    """extracted/json/<package>.json for an asset (dumped with tools/di2x json if missing)."""
    pkg = game_to_pkg(object_path)
    dst = os.path.join(ROOT, "extracted", "json", pkg[:-7] + ".json")
    if not os.path.exists(dst):
        r = subprocess.run([DI2X, "json", "^" + re.escape(pkg) + "$"], env=ENV, capture_output=True, text=True)
        if not os.path.exists(dst):
            raise RuntimeError("di2x json failed for %s: %s" % (pkg, r.stdout[-500:]))
    return json.load(open(dst))


def attachment_materials(spec_path):
    """Materials of an AttachmentSpecAsset: each child spec's mesh slots (static or skeletal), with any per-spec
    override materials taking their slot. Returns [(material object path, mesh name, socket, mesh type)]."""
    out = []
    for e in asset_json(spec_path):
        p = e.get("Properties") or {}
        mesh = (p.get("Mesh") or p.get("SkeletalMesh") or {}).get("ObjectPath")
        if not mesh:
            continue
        overrides = [(x or {}).get("ObjectPath") for x in (p.get("OverrideMaterials") or p.get("Materials") or [])]
        for m in asset_json(mesh):
            mp = m.get("Properties") or {}
            slots = m.get("StaticMaterials") or m.get("SkeletalMaterials") or mp.get("StaticMaterials") or mp.get("SkeletalMaterials")
            if m.get("Type") not in ("StaticMesh", "SkeletalMesh") or not slots:
                continue
            for i, s in enumerate(slots):
                op = overrides[i] if i < len(overrides) and overrides[i] else \
                    (s.get("MaterialInterface") or s.get("Material") or {}).get("ObjectPath")
                if op:
                    out.append((op, short(mesh), p.get("SocketName"), m["Type"]))
    return out


def load_material(name, cache):
    if name not in cache:
        cache[name] = json.load(open(os.path.join(MATS, name + ".json")))
    return cache[name]


def chains_for(leaf_paths):
    """Dump every material along each chain; returns {leaf object path: [material json, ...] leaf first}."""
    os.makedirs(MATS, exist_ok=True)
    cache, by_path = {}, {}
    todo = {game_to_pkg(p) for p in leaf_paths}
    seen = set()
    while todo:
        dump_materials(todo - seen)
        seen |= todo
        nxt = set()
        for pkg in todo:
            name = os.path.basename(pkg)[:-7]
            m = load_material(name, cache)
            assert m["path"] == pkg, ("export name collision", name, m["path"], pkg)
            by_path[pkg] = m
            par = (m["properties"].get("Properties", {}).get("Parent") or {}).get("ObjectPath")
            if par and game_to_pkg(par) not in seen:
                nxt.add(game_to_pkg(par))
        todo = nxt
    out = {}
    for p in leaf_paths:
        chain, pkg = [], game_to_pkg(p)
        while pkg:
            m = by_path[pkg]
            chain.append(m)
            par = (m["properties"].get("Properties", {}).get("Parent") or {}).get("ObjectPath")
            pkg = game_to_pkg(par) if par else None
        out[p] = chain
    return out


def high_resource(m):
    for r in m.get("resources") or []:
        sm = r.get("LoadedShaderMap")
        if sm and sm["ShaderMapId"]["QualityLevel"] == "High":
            return sm
    return None


def effective_map(chain):
    """(chain entry, High shader map) of the first material in the chain that owns a shader map."""
    for m in chain:
        sm = high_resource(m)
        if sm:
            return m, sm
    return None, None


# --- shader resource table + samples -------------------------------------------------------------------------

def srt(code):
    """FBaseShaderResourceTable token streams: per-UB offset slots (ResourceTableBits' highest bit + 1), entries
    UB << 24 | resource << 8 | bind, 0xffffffff end. (decompile.srt dropped UB 0 resource 0; this one doesn't.)"""
    p = 0
    bits = struct.unpack_from("<I", code, p)[0]; p += 4
    nslots = bits.bit_length()
    out = {}
    for name in ("srv", "sampler", "uav", "layout_hashes", "texture"):
        n = struct.unpack_from("<i", code, p)[0]; p += 4
        vals = list(struct.unpack_from("<%dI" % n, code, p)); p += 4 * n
        if name == "layout_hashes":
            continue
        ents = [v for v in vals[nslots:] if v != 0xffffffff] if vals else []
        out[name] = [{"ub": v >> 24, "resource": (v >> 8) & 0xffff, "bind": v & 0xff} for v in ents]
    return out


def material_resource_names(ues):
    """Material uniform buffer resource index -> name (UE4.27 CreateBufferStruct order: Texture2D_i/Sampler pairs,
    TextureCube, Texture2DArray, VolumeTexture pairs, virtual-texture resources, then the two world-group samplers)."""
    utp = ues["UniformTextureParameters"]
    names = []
    for kind, lst in (("Texture2D", utp[0]), ("TextureCube", utp[1]), ("Texture2DArray", utp[2]), ("VolumeTexture", utp[3])):
        for i, t in enumerate(lst):
            names += [("%s_%d" % (kind, i), t), ("%s_%dSampler" % (kind, i), t)]
    nres = len(ues["UniformBufferLayoutInitializer"]["Resources"])
    while len(names) < nres - 2:
        names.append(("VirtualTexture resource", None))
    names += [("Wrap_WorldGroupSettings", None), ("Clamp_WorldGroupSettings", None)]
    return names


def base_pass_samples(key, ues, vf="TGPUSkinVertexFactoryDefault"):
    """Decompile the High TBasePassPSFNoLightMapPolicy of shader map `key` for vertex factory `vf` (GPUSkin Default for
    the bodies, FLocalVertexFactory for static-mesh attachments) and list, per material texture resource, how it is
    sampled."""
    rows = [r for r in material_map.shader_list(key, "^TBasePassPSFNoLightMapPolicy$")
            if r["quality"] == 1 and r["vf"] == vf]
    if not rows:
        return None, {}
    idx = rows[0]["lib_index"]
    code = open(os.path.join(SH, "DeadIsland", "%06d.bin" % idx), "rb").read()
    _, meta = decompile.split(code)
    ubs = meta.get("uniform_buffers", {})
    label = "BasePassPS_%s%s" % (key[:8], "" if vf == "TGPUSkinVertexFactoryDefault" else "_" + vf)
    stem = os.path.join(SH, "dis", "DeadIsland_%06d_%s" % (idx, label))
    if not os.path.exists(stem + ".hlsl"):
        decompile.run("DeadIsland", idx, label)
    hlsl = open(stem + ".hlsl").read()
    t = srt(code)
    res = material_resource_names(ues)

    def name_of(e):
        ub = ubs.get("cb%d" % e["ub"], "UB%d" % e["ub"])
        if ub == "Material":
            n, tp = res[e["resource"]] if e["resource"] < len(res) else ("res%d" % e["resource"], None)
            return "Material." + n, tp
        if ub == "View" and e["resource"] in VIEW_SAMPLERS:
            return VIEW_SAMPLERS[e["resource"]], None
        return "%s.res%d" % (ub, e["resource"]), None

    tex = {e["bind"]: name_of(e) for e in t["texture"] + t["srv"]}
    smp = {e["bind"]: name_of(e)[0] for e in t["sampler"]}
    uses = {}
    for m in re.finditer(r"\bt(\d+)\.(Sample\w*|Load)\(\s*(?:s(\d+)_s)?", hlsl):
        b, op, s = int(m.group(1)), m.group(2), m.group(3)
        tn, tp = tex.get(b, ("t%d" % b, None))
        if not tn.startswith("Material."):
            continue
        sampler = smp.get(int(s), "s" + s) if s is not None else None
        uses.setdefault(tn, {"param": (tp or {}).get("ParameterName") if tp else None, "ops": set()})["ops"].add(
            (op, sampler))
    for v in uses.values():
        v["ops"] = [{"op": o, "sampler": s} for o, s in sorted(v["ops"], key=lambda x: (x[0], x[1] or ""))]
    # Which interpolator the splatter RTs are sampled with (GPU skin VS: TEXCOORD0.xy = UV0 from ATTRIBUTE5,
    # TEXCOORD1.xy = UV1 from ATTRIBUTE6; checked in the skin VS 3184 and the hair VS 4083).
    sig = dict((m.group(1), m.group(2)) for m in re.finditer(r"\bv(\d+)\s*:\s*(\w+)", hlsl))
    splat_regs = [b for b, (n, tp) in tex.items() if tp and tp.get("ParameterName") in ("SplatterDisplace", "SplatterDiffuse")]
    coords = set()
    for b in splat_regs:
        for m in re.finditer(r"\bt%d\.Sample\w*\(\s*s\d+_s,\s*v(\d+)\.(\w+)" % b, hlsl):
            coords.add("%s.%s" % (sig.get(m.group(1), "v" + m.group(1)), m.group(2)))
    uses["__splatter_coords__"] = sorted(coords)
    return idx, uses


# --- resolution ----------------------------------------------------------------------------------------------

def mi_overrides(chain):
    """Leaf-first instance overrides: {kind: {name: (value, source)}}."""
    out = {"scalars": {}, "vectors": {}, "textures": {}, "switches": {}}
    for m in chain:
        p = m["properties"].get("Properties", {})
        src = m["export"]
        for x in p.get("ScalarParameterValues") or []:
            out["scalars"].setdefault(x["ParameterInfo"]["Name"], (x["ParameterValue"], src))
        for x in p.get("VectorParameterValues") or []:
            v = x["ParameterValue"]
            out["vectors"].setdefault(x["ParameterInfo"]["Name"], ([v["R"], v["G"], v["B"], v["A"]], src))
        for x in p.get("TextureParameterValues") or []:
            out["textures"].setdefault(x["ParameterInfo"]["Name"], ((x["ParameterValue"] or {}).get("ObjectPath"), src))
        for x in ((p.get("StaticParameters") or {}).get("StaticSwitchParameters") or []):
            out["switches"].setdefault(x["ParameterInfo"]["Name"], (x["Value"], src))
    return out


RENDER_PROPS = {  # FMaterialInstanceBasePropertyOverrides field -> UE4.27 UMaterial default (engine, used when unset)
    "BlendMode": "BLEND_Opaque", "TwoSided": False, "OpacityMaskClipValue": 0.3333, "ShadingModel": "MSM_DefaultLit"}


def render_settings(chain):
    """Blend mode, two-sidedness, mask clip and shading model: the first instance (leaf first) whose
    BasePropertyOverrides has bOverride_<X>, else the master's property, else the UE default (marked)."""
    out = {}
    master = chain[-1]["properties"].get("Properties", {})
    for prop, dflt in RENDER_PROPS.items():
        for m in chain[:-1]:
            bpo = m["properties"].get("Properties", {}).get("BasePropertyOverrides") or {}
            if bpo.get("bOverride_" + prop):
                out[prop] = {"value": bpo.get(prop, dflt), "source": m["export"]}
                break
        else:
            if prop in master:
                out[prop] = {"value": master[prop], "source": chain[-1]["export"]}
            else:
                out[prop] = {"value": dflt, "source": "UE default"}
    return out


def subsurface_profile(chain):
    """UE 4.27 UMaterialInstance::GetSubsurfaceProfile_Internal: the first instance (leaf first) with
    bOverrideSubsurfaceProfile set, else the master's SubsurfaceProfile. (An instance can serialise a profile without
    the override flag; it is then ignored.)"""
    for m in chain:
        p = m["properties"].get("Properties", {})
        if m is chain[-1] or p.get("bOverrideSubsurfaceProfile"):
            sp = (p.get("SubsurfaceProfile") or {}).get("ObjectPath")
            return {"value": short(sp) if sp else None, "asset": sp, "source": m["export"]}


def subsurface_profile_settings(object_path):
    """The profile asset's Settings, with the exe's defaults for the fields it doesn't serialise."""
    s = next(e for e in asset_json(object_path) if e.get("Type") == "SubsurfaceProfile").get("Properties", {}).get("Settings", {})
    out = {}
    for k, dflt in SSP_DEFAULTS.items():
        if k in s:
            v = s[k]
            out[k] = {"value": [v[c] for c in "RGBA"] if isinstance(v, dict) else v, "source": "asset"}
        else:
            out[k] = {"value": dflt, "source": "engine default (exe 0x143a50db0)"}
    out["kernel"] = "burley" if out["bEnableBurley"]["value"] else "separable"
    return out


def lighting_block(entry, profiles):
    """Uniforms game/shaders/flesh.gdshader's DI2 light pass reads (recon/SHADERS_FLESH.md §15), from the resolved
    parameters: {"uniforms": {uniform: number | bool | [r, g, b]}, "textures": {uniform: {"texture", "flag"}}}.
    Only parameters this entry resolves are written; the shader's defaults cover the rest."""
    sc, vec, tex = entry["params"]["scalars"], entry["params"]["vectors"], entry["params"]["textures"]
    u, t = {}, {}

    def s(param, uniform):
        v = (sc.get(param) or {}).get("value")
        if v is not None:
            u[uniform] = v

    def c(param, uniform):
        v = (vec.get(param) or {}).get("value")
        if v is not None:
            u[uniform] = v[:3]

    master, kind, sw = entry["master"], entry["kind"], entry.get("static_switches", {})
    if master == "M_Skin":
        # SSS opacity (CustomData.a) source per base-pass permutation:
        #   0 lerp(Base, Vein SSS, vein mask): veins on (skin PS 3213, viscera PS 2071)
        #   1 MRO.b: skin with 'Enable Zombie Veins Effect' off (PS 3569)
        #   2 MRO.b * sat('Translucency Adjustment' + ATA.g): viscera family with both vein switches off (skeleton PS 1939)
        #   3 constant 1: interior shell (PS 3094)
        veins, cheap = sw.get("Enable Zombie Veins Effect"), sw.get("Enable Cheap Zombie Veins Effect")
        if kind == "interior_shell":
            u["ssp_op"] = 3
        elif kind == "skin":
            u["ssp_op"] = 0 if veins else 1
        elif veins:
            u["ssp_op"] = 0
        elif not cheap:
            u["ssp_op"] = 2
        # (viscera family with only the cheap veins on: no decoded permutation; the shader default applies)
        s("Base Subsurface Scattering", "sss_base")
        s("Specular Occlusion Power", "spec_occ_power")
        s("Debug Oil Layer", "debug_oil")
        s("Translucency Adjustment", "translucency_adj")
        if kind != "interior_shell":
            s("Desaturation", "base_desat")
            c("Colour Tint", "base_tint")
        sp = profiles.get((entry.get("subsurface_profile") or {}).get("value"))
        if sp:
            # Godot's screen-space SSS radius: separable kernel = ScatterRadius (cm), Burley = MFP distance x WorldUnitScale
            r_cm = sp["MeanFreePathDistance"]["value"] * sp["WorldUnitScale"]["value"] if sp["bEnableBurley"]["value"] \
                else sp["ScatterRadius"]["value"]
            u["sss_radius_m"] = r_cm * 0.01
    elif master == "M_Clothing":
        s("Cloth Translucency", "cloth_translucency")
        s("Force Cloth", "force_cloth")
        s("Sheen Colour Averaging Amount", "sheen_avg")
        s("Sheen Colour Desaturation", "sheen_desat")
        s("Sheen Colour Multiplier", "sheen_mult")
        c("Cloth Colour Tint", "cloth_tint")
    elif master == "M_Hair":
        for param, uniform in [("Scatter", "hair_scatter"), ("Roughness", "hair_roughness"),
                               ("Roughness Variation", "hair_rough_var"), ("Flow Variation", "hair_flow_var"),
                               ("Root Occlusion Amount", "hair_root_occ"), ("Root Occlusion Curve", "hair_root_occ_curve"),
                               ("Texture Occlusion Amount", "hair_tex_occ"), ("Vertex Alpha Occlusion Amount", "hair_vtx_occ"),
                               ("Root-Tip Colour Curve", "hair_root_tip_curve"), ("Brightness Variation", "hair_bright_var"),
                               ("Overall Brightness", "hair_brightness")]:
            s(param, uniform)
        c("Root Colour", "hair_root")
        c("Tip Colour", "hair_tip")
        for param, uniform, flag in [("Packed Hair Data Map", "hair_data_tex", "has_hair_data"),
                                     ("Flow Map", "hair_flow_tex", "has_hair_flow")]:
            v = (tex.get(param) or {}).get("value")
            if v:
                t[uniform] = {"texture": v, "flag": flag}
    return {"uniforms": u, "textures": t}


def resolve(chain):
    master = chain[-1]
    mprops = master["properties"].get("Properties", {})
    ref = [(t or {}).get("ObjectPath") for t in (mprops.get("CachedExpressionData") or {}).get("ReferencedTextures", [])]
    owner, sm = effective_map(chain)
    ov = mi_overrides(chain)
    entry = {"chain": [m["export"] for m in chain], "master": master["export"],
             "used_with_splatter": bool(mprops.get("bUsedWithSplatter", False)),
             "static_switches": {k: v[0] for k, v in ov["switches"].items()},
             "shader_map": {"owner": owner["export"] if owner else None,
                            "resource_hash": owner.get("shader_resource_hash") if owner else None}}
    used = {"scalars": {}, "vectors": {}, "textures": {}}
    ues = None
    if sm:
        ues = sm["Content"]["MaterialCompilationOutput"]["UniformExpressionSet"]
        for x in ues["UniformScalarParameters"]:
            used["scalars"][x["ParameterName"]] = x["DefaultValue"]
        for x in ues["UniformVectorParameters"]:
            d = x["DefaultValue"]
            used["vectors"][x["ParameterName"]] = [d["R"], d["G"], d["B"], d["A"]]
        slots = {}
        for kind_i, prefix in ((0, "Texture2D"), (3, "VolumeTexture")):
            for i, x in enumerate(ues["UniformTextureParameters"][kind_i]):
                dflt = ref[x["TextureIndex"]] if x["TextureIndex"] < len(ref) else None
                key = x["ParameterName"] or "const %s" % (short(dflt) if dflt else "%s_%d" % (prefix, i))
                used["textures"][key] = dflt
                slots[key] = "%s_%d" % (prefix, i)
        entry["_slots"] = slots
    params = {}
    for kind in ("scalars", "vectors", "textures"):
        extra = FLESH_PARAMS[kind] + (BASE_MAPS if kind == "textures" else [])
        names = list(used[kind]) + [n for n in dict.fromkeys(extra) if n not in used[kind]]
        d = {}
        for n in names:
            if n in ov[kind]:
                v, src = ov[kind][n]
            elif n in used[kind]:
                v, src = used[kind][n], master["export"] + " (default)"
            else:
                v, src = None, None
            if kind == "textures" and v:
                v = short(v)
            d[n] = {"value": v, "source": src, "used": n in used[kind]}
            if kind == "textures" and n in entry.get("_slots", {}):
                d[n]["slot"] = entry["_slots"][n]
        params[kind] = d
    entry.pop("_slots", None)
    entry["params"] = params
    entry["render"] = render_settings(chain)
    texnames = {x["ParameterName"] for x in (ues["UniformTextureParameters"][0] if ues else [])}
    entry["samples_splatter"] = sorted(texnames & {"SplatterDisplace", "SplatterDiffuse"})
    interior = ov["switches"].get("Interior Shell Material", (False,))[0]
    if not entry["samples_splatter"]:
        kind = "none"
    elif master["export"] == "M_Skin":
        kind = "interior_shell" if interior else "skin"
    elif master["export"] == "M_Clothing":
        kind = "clothing"
    else:
        kind = "other_splatter"
    entry["kind"] = kind
    return entry, owner, ues


# --- textures --------------------------------------------------------------------------------------------------

TEXDUMP_CS = r'''// Generated by tools/shaders/build_flesh_materials.py: decode textures (UTexture2D / UVolumeTexture) to raw pixels.
using CUE4Parse.Compression; using CUE4Parse.Encryption.Aes; using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports.Texture; using CUE4Parse.UE4.Objects.Core.Misc; using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion.Textures; using Newtonsoft.Json;
const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
var root = args[0]; var outDir = args[2]; Directory.CreateDirectory(outDir);
var toolDir = Path.Combine(root, "tools", "di2x", "bin", "out");
OodleHelper.Initialize(Path.Combine(toolDir, OodleHelper.OodleFileName));
ZlibHelper.Initialize(Path.Combine(toolDir, ZlibHelper.DllName));
var detex = Path.Combine(toolDir, CUE4Parse_Conversion.Textures.BC.DetexHelper.DLL_NAME);
if (CUE4Parse_Conversion.Textures.BC.DetexHelper.LoadDll(detex)) CUE4Parse_Conversion.Textures.BC.DetexHelper.Initialize(detex);
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
            var mipIndex = t.GetFirstMipIndex();
            var mip = t.GetMip(mipIndex);
            var ct = t.DecodeMip(mipIndex);
            if (ct == null) throw new Exception("decode failed");
            File.WriteAllBytes(Path.Combine(outDir, e.Name + ".raw"), ct.Data);
            meta.Add(new {
                name = e.Name, path = path.Trim(), cls = e.ExportType, width = ct.Width, height = ct.Height,
                decoded = ct.PixelFormat.ToString(), pixel_format = t.Format.ToString(),
                mip_size = new[] { mip.SizeX, mip.SizeY, mip.SizeZ }, slices = t.PlatformData.GetNumSlices(),
                srgb = t.SRGB, address = new[] { t.GetTextureAddressX().ToString(), t.GetTextureAddressY().ToString() },
                filter = t.Filter.ToString(), lod_group = t.LODGroup.ToString(), compression = t.CompressionSettings.ToString(),
            });
            Console.WriteLine($"ok   {e.Name} {ct.Width}x{ct.Height} {ct.PixelFormat}");
        }
    }
    catch (Exception ex) { Console.WriteLine($"FAIL {path}: {ex.Message}"); }
}
File.WriteAllText(Path.Combine(outDir, "meta.json"), JsonConvert.SerializeObject(meta, Formatting.Indented));
'''
TEXDUMP_PROJ = '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings><Nullable>disable</Nullable></PropertyGroup>
  <ItemGroup><PackageReference Include="CUE4Parse" Version="1.2.2.202610" />
    <PackageReference Include="CUE4Parse-Conversion" Version="1.2.2.202610" /></ItemGroup>
</Project>
'''


def dump_textures(pkgs):
    proj = os.path.join(BUILD, "texdump")
    os.makedirs(proj, exist_ok=True)
    open(os.path.join(proj, "Program.cs"), "w").write(TEXDUMP_CS)
    open(os.path.join(proj, "texdump.csproj"), "w").write(TEXDUMP_PROJ)
    exe = os.path.join(proj, "bin", "out", "texdump.exe")
    r = subprocess.run([DOTNET, "build", "-c", "Release", "-o", os.path.join(proj, "bin", "out"), proj],
                       env=ENV, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout[-3000:])
    lst = os.path.join(BUILD, "textures.txt")
    open(lst, "w").write("\n".join(sorted(pkgs)))
    raw = os.path.join(BUILD, "raw")
    r = subprocess.run([exe, ROOT, lst, raw], env=ENV, capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
    if fails:
        raise RuntimeError("\n".join(fails))
    return raw, json.load(open(os.path.join(raw, "meta.json")))


def write_png(raw_dir, m, dst):
    """Raw decoded pixels -> PNG, channels untouched (RGBA kept unassociated; no premultiply, no resize)."""
    import numpy as np
    from PIL import Image
    data = open(os.path.join(raw_dir, m["name"] + ".raw"), "rb").read()
    w, h, f = m["width"], m["height"], m["decoded"]
    if f in ("PF_B8G8R8A8", "PF_R8G8B8A8"):
        a = np.frombuffer(data, np.uint8).reshape(h, w, 4)
        if f == "PF_B8G8R8A8":
            a = a[..., [2, 1, 0, 3]]
        Image.fromarray(np.ascontiguousarray(a), "RGBA").save(dst)
        return "RGBA8"
    if f == "PF_G8":
        Image.fromarray(np.frombuffer(data, np.uint8).reshape(h, w), "L").save(dst)
        return "L8"
    if f == "PF_FloatRGBA":
        write_exr_half(dst[:-4] + ".exr", np.frombuffer(data, np.float16).reshape(h, w, 4))
        return "EXR_RGBA_HALF"
    raise NotImplementedError(f)


def write_exr_half(dst, rgba):
    """Minimal uncompressed scanline OpenEXR (HALF channels A,B,G,R) so HDR data stays exact."""
    import numpy as np
    h, w, _ = rgba.shape

    def attr(name, typ, data):
        return name.encode() + b"\0" + typ.encode() + b"\0" + struct.pack("<i", len(data)) + data
    chans = b"".join(c.encode() + b"\0" + struct.pack("<iB3xii", 1, 0, 1, 1) for c in "ABGR") + b"\0"
    box = struct.pack("<iiii", 0, 0, w - 1, h - 1)
    hdr = (struct.pack("<ii", 20000630, 2) + attr("channels", "chlist", chans) + attr("compression", "compression", b"\0")
           + attr("dataWindow", "box2i", box) + attr("displayWindow", "box2i", box) + attr("lineOrder", "lineOrder", b"\0")
           + attr("pixelAspectRatio", "float", struct.pack("<f", 1.0)) + attr("screenWindowCenter", "v2f", struct.pack("<ff", 0, 0))
           + attr("screenWindowWidth", "float", struct.pack("<f", 1.0)) + b"\0")
    lines = []
    for y in range(h):
        row = b"".join(np.ascontiguousarray(rgba[y, :, c]).astype("<f2").tobytes() for c in (3, 2, 1, 0))
        lines.append(struct.pack("<ii", y, len(row)) + row)
    off = len(hdr) + 8 * h
    table = b""
    for l in lines:
        table += struct.pack("<Q", off)
        off += len(l)
    open(dst, "wb").write(hdr + table + b"".join(lines))


# --- main ------------------------------------------------------------------------------------------------------

def main():
    os.makedirs(BUILD, exist_ok=True)
    sections = {}
    for body, mesh in BODIES.items():
        mesh_json = json.load(open(os.path.join(ROOT, "extracted", "json", "DeadIsland", "Content", mesh + ".json")))
        mats_json = json.load(open(os.path.join(ROOT, "game", "assets", "di2", body, body + ".materials.json")))
        sk = next(e for e in mesh_json if e.get("Type") == "SkeletalMesh")
        for s in sk["SkeletalMaterials"]:
            op = (s.get("Material") or s.get("MaterialInterface") or {}).get("ObjectPath")
            if not op:
                continue
            name = short(op)
            sec = sections.setdefault(name, {"asset": op, "bodies": [], "layer": (mats_json.get(name) or {}).get("layer"),
                                             "in_pack": []})
            if name in mats_json and body not in sec["in_pack"]:
                sec["in_pack"].append(body)
            assert sec["asset"] == op, ("same name, different asset", name)
            if body not in sec["bodies"]:
                sec["bodies"].append(body)
        # Spawn-time swaps (CharacterInitialStateWrapper, as tools/build_character_states.py reads it): material
        # variants (source -> replacement) and the initial attachment's materials.
        st = next((e["Properties"]["State"] for e in mesh_json if e.get("Type") == "CharacterInitialStateWrapper"), {})
        for v in st.get("MaterialVariants", []):
            for sub in v.get("Substitutions", []):
                src = (sub.get("SourceMaterial") or {}).get("ObjectPath")
                rep = (sub.get("ReplacementMaterial") or {}).get("ObjectPath")
                if not src or not rep or short(src) == short(rep):
                    continue   # identity substitution: already a mesh section
                sec = sections.setdefault(short(rep), {"asset": rep, "bodies": [], "in_pack": [], "layer": None})
                assert sec["asset"] == rep, ("same name, different asset", short(rep))
                sec.setdefault("variant_of", short(src))
                assert sec["variant_of"] == short(src), ("replacement of two sources", short(rep))
                sec["layer"] = sec["layer"] or (mats_json.get(short(src)) or {}).get("layer")
                sec["layer_source"] = "source material " + short(src)
                if body not in sec["bodies"]:
                    sec["bodies"].append(body)
        att = (st.get("InitialAttachmentSpec") or {}).get("ObjectPath")
        if att:
            for op, mesh_name, socket, mesh_type in attachment_materials(att):
                sec = sections.setdefault(short(op), {"asset": op, "bodies": [], "in_pack": [], "layer": None})
                sec.update({"attachment": short(att), "attachment_mesh": mesh_name, "attachment_socket": socket,
                            "vf": "FLocalVertexFactory" if mesh_type == "StaticMesh" else "TGPUSkinVertexFactoryDefault"})
                if body not in sec["bodies"]:
                    sec["bodies"].append(body)
    chains = chains_for([s["asset"] for s in sections.values()])

    textures, samples_cache, out_mats, base_textures, eye_textures, hair_textures = {}, {}, {}, set(), set(), set()
    profiles = {}
    for name, sec in sorted(sections.items()):
        entry, owner, ues = resolve(chains[sec["asset"]])
        if entry["render"]["ShadingModel"]["value"] == "MSM_SubsurfaceProfile":
            entry["subsurface_profile"] = subsurface_profile(chains[sec["asset"]])
            sp = entry["subsurface_profile"]
            if sp["asset"] and sp["value"] not in profiles:
                profiles[sp["value"]] = {"asset": sp["asset"], **subsurface_profile_settings(sp["asset"])}
        vf = sec.get("vf", "TGPUSkinVertexFactoryDefault")
        head = {"asset": sec["asset"], "bodies": sec["bodies"], "in_materials_json": sec["in_pack"], "pack_layer": sec["layer"]}
        if "variant_of" in sec:
            head.update(variant_of=sec["variant_of"], pack_layer_source=sec.get("layer_source"))
        if "attachment" in sec:
            head.update(attachment=sec["attachment"], attachment_mesh=sec["attachment_mesh"],
                        attachment_socket=sec["attachment_socket"], vertex_factory=vf)
            if head["pack_layer"] is None and entry["kind"] == "clothing":
                head.update(pack_layer="cloth", pack_layer_source="derived: kind clothing (M_Clothing splatter permutation)")
        entry = {**head, **entry}
        key = (owner or {}).get("shader_resource_hash")
        if ues is not None and key and entry["kind"] != "none":
            if (key, vf) not in samples_cache:
                samples_cache[(key, vf)] = base_pass_samples(key, ues, vf)
            ps, uses = samples_cache[(key, vf)]
            entry["base_pass_ps"] = {"archive": "DeadIsland", "index": ps, "vertex_factory": vf}
            coords = uses.get("__splatter_coords__", [])
            entry["splatter_uv"] = {"interpolators": coords,
                                    "uv_channel": sorted({0 if c.startswith("TEXCOORD0.xy") else 1 if c.startswith("TEXCOORD1.xy") else -1 for c in coords})}
            by_param = {}
            for res_name, u in uses.items():
                if res_name == "__splatter_coords__":
                    continue
                slot = res_name.split(".", 1)[1].replace("Sampler", "")
                by_param.setdefault(slot, []).extend(u["ops"])
            for pname, d in entry["params"]["textures"].items():
                d["samples"] = by_param.get(d.get("slot"), [])
        elif entry["kind"] == "none":
            entry.pop("base_pass_ps", None)
        # textures to export: every non-base texture of splatter permutations (+ requested ones wherever set), and
        # the four base maps of every section (written only when extracted/ doesn't hold them, see below)
        for pname, d in entry["params"]["textures"].items():
            if not d["value"] or d["value"] in ("None",):
                continue
            if pname in BASE_MAPS:
                base_textures.add(d["value"])
                continue
            if entry["master"] in EYE_MASTERS and not d["value"].startswith("RVT_"):
                eye_textures.add(d["value"])   # eyes: every texture their base pass uses (§14)
                continue
            if entry["master"] in HAIR_MASTERS and pname in HAIR_TEXTURE_PARAMS:
                hair_textures.add(d["value"])   # hair: flow map + packed hair data (PS 4056)
                continue
            if entry["kind"] not in ("skin", "interior_shell", "clothing") and pname not in FLESH_PARAMS["textures"]:
                continue   # eyes / hair / viscera: their splatter path only uses the shared FLESH textures
            if pname in BASE_TEXTURE_PARAMS or d["value"].startswith("RVT_"):
                continue
            textures.setdefault(d["value"], None)
        out_mats[name] = entry

    for entry in out_mats.values():
        entry["lighting"] = lighting_block(entry, profiles)

    # resolve texture object paths from the chains (overrides) and master ReferencedTextures
    paths = {}
    for chain in chains.values():
        for m in chain:
            p = m["properties"].get("Properties", {})
            for x in p.get("TextureParameterValues") or []:
                op = (x["ParameterValue"] or {}).get("ObjectPath")
                if op:
                    paths[short(op)] = op
            for t in (p.get("CachedExpressionData") or {}).get("ReferencedTextures", []):
                if t and t.get("ObjectPath"):
                    paths[short(t["ObjectPath"])] = t["ObjectPath"]
    for n in eye_textures:
        textures.setdefault(n, "eye")
    for n in hair_textures:
        textures.setdefault(n, "hair")
    for n in base_textures:
        if n not in textures:
            textures[n] = "base"
    want = {paths[n] for n in textures if n in paths}
    missing = [n for n in textures if n not in paths]
    assert not missing, missing
    # Base-map PNGs already under extracted/ (where pack_materials.py finds them by name) aren't duplicated.
    extracted_png = {}
    for sub in ("mesh", "tex"):
        for dp, _, files in os.walk(os.path.join(ROOT, "extracted", sub)):
            for f in files:
                if f.endswith(".png"):
                    extracted_png.setdefault(f[:-4], os.path.relpath(os.path.join(dp, f), ROOT).replace("\\", "/"))
    raw_dir, meta = dump_textures({game_to_pkg(p) for p in want})
    if os.path.isdir(OUT_TEX):
        shutil.rmtree(OUT_TEX)   # generated folder (this script is its only writer)
    os.makedirs(OUT_TEX, exist_ok=True)
    open(os.path.join(OUT_TEX, ".gdignore"), "w").write("")
    tex_out = {}
    for m in meta:
        t = {"role": {"base": "base_map", "eye": "eye", "hair": "hair"}.get(textures.get(m["name"]), "flesh")}
        if t["role"] == "base_map" and m["name"] in extracted_png:
            layout, res_path = None, None
            t["extracted_png"] = extracted_png[m["name"]]
        else:
            layout = write_png(raw_dir, m, os.path.join(OUT_TEX, m["name"] + ".png"))
            ext = ".exr" if layout.startswith("EXR") else ".png"
            res_path = "res://assets/di2/flesh/%s%s" % (m["name"], ext)
        t.update({"png": res_path, "asset": m["path"], "class": m["cls"],
                  "width": m["width"], "height": m["height"], "png_layout": layout, "pixel_format": m["pixel_format"],
                  "srgb": m["srgb"], "address": m["address"], "filter": m["filter"], "lod_group": m["lod_group"],
                  "compression": m["compression"]})
        if m["cls"] == "VolumeTexture":
            sx, sy, sz = m["mip_size"]
            t["volume"] = {"size": [sx, sy, sz], "atlas": "slices stacked vertically: slice z occupies rows [z*%d, (z+1)*%d)" % (sy, sy)}
        tex_out[m["name"]] = t

    mpc = json.load(open(os.path.join(ROOT, "extracted", "json", "DeadIsland", "Content", "DIShared", "Core", "Materials",
                                      "MPC_CharacterGameWideParams.json")))[0]["Properties"]
    mpc_out = {"scalars": {x["ParameterName"]: x.get("DefaultValue", 0.0) for x in mpc.get("ScalarParameters", [])},
               "vectors": {x["ParameterName"]: [x.get("DefaultValue", {}).get(c, 0.0) for c in "RGBA"]
                           for x in mpc.get("VectorParameters", [])}}
    doc = {
        "_about": "DI2 FLESH material data for the port, from the user's own install (tools/shaders/build_flesh_materials.py). "
                  "Schema and sampler notes: recon/SHADERS_FLESH.md section 13.",
        "samplers": {
            "View.MaterialTextureBilinearWrapedSampler": "View UB resource 0 (shared material sampler; bilinear, wrap)",
            "View.MaterialTextureBilinearClampedSampler": "View UB resource 1 (shared material sampler; bilinear, clamp)",
            "Material.<Texture>Sampler": "the texture asset's own sampler state: its 'address' and 'filter' below",
            "Material.Wrap_WorldGroupSettings": "material shared sampler (wrap, world texture-group filtering)",
        },
        "materials": out_mats,
        "subsurface_profiles": dict(sorted(profiles.items())),
        "textures": dict(sorted(tex_out.items())),
        "mpc": {"MPC_CharacterGameWideParams": mpc_out},
    }
    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    json.dump(doc, open(OUT_JSON, "w"), indent=1)
    print("%d materials, %d textures -> %s" % (len(out_mats), len(tex_out), OUT_JSON))


if __name__ == "__main__":
    main()
