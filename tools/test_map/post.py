"""DI2's post-process chain for the test map: effective FPostProcessSettings, eye adaptation, the LUT blender's
constants and its GLSL port. Used by tools/build_test_map.py; everything here is cited in recon/TEST_MAP.md
("Exposure and tone mapping"). Static data only; DI2's exe and shaders are never run.

Sources (DI2 exe 'DeadIsland-Win64-Shipping.exe', DI2 global shader archive; tools/re_exposure/*):
  - FPostProcessSettings defaults: the fully serialised struct in BPC_PostProcess_Reticle InitialPPMaterials (522
    fields, every bOverride_* false = the struct constructor's values).
  - Unbound post-process volumes / components blend in priority order; a field applies where its bOverride_* is set
    (a set override whose value equals the archetype default is not serialised, so the default stands).
  - Eye adaptation: DI2's histogram pixel shader (Global 1553 FEyeAdaptationPS) and FHistogramCS (Global 2481); the
    parameter struct layout from the exe's shader-parameter registration (tools/re_exposure/ub_members.py).
  - LUT: DI2's FLUTBlenderPS permutation 1 (Global 2460, one grading LUT); cbuffer offsets from the shader's frozen
    FShaderParameterBindings (tools/re_exposure/bindings.py).
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re_exposure"))
import hlsl2glsl  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
JSON_ROOT = os.path.join(ROOT, "extracted", "json")
DEFAULTS_PKG = "DeadIsland/Content/DIShared/Effects/Blueprints/BPC_PostProcess_Reticle"
LUT_HLSL = os.path.join(ROOT, "extracted", "shaders", "lighting", "Global_002460_LUTBlenderPS_p1.hlsl")

# exe constants (static reads, tools/re_exposure/disasm.py at the CVar registrations)
LENS_ATTENUATION = 0.65          # r.EyeAdaptation.LensAttenuation default (0x140660936); its help text: "0.65 to match
LUMINANCE_MAX = 0.78 / 0.65      # previous versions (1.0cd/m^2 becomes 1.2 at EV100)" -> EV100 luminance 1.2 * 2^EV
EXP_TRANSITION_DISTANCE = 1.5    # r.EyeAdaptation.ExponentialTransitionDistance default (0x1406608be)
BLACK_BUCKET_INFLUENCE = 0.0     # r.EyeAdaptation.BlackHistogramBucketInfluence default (xorps at 0x140660846)
OUTPUT_DEVICE = 0                # r.HDR.Display.OutputDevice default (xor r8d at 0x140663df6): "0: sRGB (LDR)"
EDITOR_NIT_LEVEL = 160.0         # Editor.HDRNITLevel default (0x14065a09e), read by the LUT and tonemap parameter code


def _json(pkg):
    return json.load(open(os.path.join(JSON_ROOT, pkg + ".json"), encoding="utf-8"))


def defaults():
    for e in _json(DEFAULTS_PKG):
        pp = (e.get("Properties") or {}).get("InitialPPMaterials")
        if pp and "FilmSlope" in pp:
            return {k: v for k, v in pp.items() if not k.startswith("bOverride_")}
    raise RuntimeError("no FPostProcessSettings defaults in " + DEFAULTS_PKG)


def effective(settings):
    """FPostProcessSettings seen by a camera in the play area: defaults, then each unbound enabled volume / component
    by ascending priority (BlendWeight 1 everywhere in NH_04). Bound volumes are left out: NH_04's are in T01 (mansion
    interiors, disabled) and T07 (sewer colour grading), away from the T04 test area. Returns (settings, sources)."""
    eff = defaults()
    src = {}
    vols = [v for v in settings["post_process"] if v["unbound"] and v["enabled"]]
    for v in sorted(vols, key=lambda v: v["priority"]):
        s = v["settings"]
        for k, on in s.items():
            if not k.startswith("bOverride_") or not on:
                continue
            key = k[len("bOverride_"):]
            if key in s:
                eff[key] = s[key]
            src[key] = v["actor"]
    return eff, src


def _ref_pkg(ref):
    """'/Game/DSCore/Lighting/Curve_ExposureComp.0' -> 'DeadIsland/Content/DSCore/Lighting/Curve_ExposureComp'."""
    p = ref.split(".")[0]
    return "DeadIsland/Content/" + p[len("/Game/"):]


def curve_keys(ref):
    for e in _json(_ref_pkg(ref)):
        fc = (e.get("Properties") or {}).get("FloatCurve")
        if fc is not None:
            return {"keys": [[k["Time"], k["Value"], k.get("InterpMode", "RCIM_Linear"), k.get("ArriveTangent", 0.0),
                              k.get("LeaveTangent", 0.0)] for k in fc.get("Keys", [])],
                    "pre": fc.get("PreInfinityExtrap", "RCCE_Constant"), "post": fc.get("PostInfinityExtrap", "RCCE_Constant")}
    return None


def ev100_to_luminance(ev):
    return LUMINANCE_MAX * 2.0 ** ev


def eye_adaptation(eff):
    """Runtime parameters for game/scripts/di2_post.gd (SDR controls; bUseSeparateHDRExposureControls only switches
    which set an HDR display uses). Histogram range: HistogramLogMin/Max are EV100 (ExtendDefaultLuminanceRange) ->
    log2 luminance = EV + log2(LUMINANCE_MAX)."""
    lo = eff["HistogramLogMin"] + math.log2(LUMINANCE_MAX)
    hi = eff["HistogramLogMax"] + math.log2(LUMINANCE_MAX)
    scale = 1.0 / (hi - lo)
    return {
        "method": eff.get("AutoExposureMethod"),
        "low_percent": eff["AutoExposureLowPercent"] * 0.01, "high_percent": eff["AutoExposureHighPercent"] * 0.01,
        "min_luminance": ev100_to_luminance(eff["AutoExposureMinBrightness"]),
        "max_luminance": ev100_to_luminance(eff["AutoExposureMaxBrightness"]),
        "bias": eff.get("AutoExposureBias", 0.0),
        "bias_curve": curve_keys(eff["AutoExposureBiasCurve"]) if eff.get("AutoExposureBiasCurve") else None,
        "speed_up": eff["AutoExposureSpeedUp"], "speed_down": eff["AutoExposureSpeedDown"],
        "histogram_scale": scale, "histogram_bias": -lo * scale, "luminance_min": 2.0 ** lo,
        "black_bucket_influence": BLACK_BUCKET_INFLUENCE, "transition_distance": EXP_TRANSITION_DISTANCE,
        "derived_clamp_influence": eff.get("DerivedBrightnessClampInfluence"),
        "derived_max_scale": eff.get("DerivedMaxBrightnessScale"), "derived_max_pow": eff.get("DerivedMaxBrightnessPow"),
        "luminance_max_factor": LUMINANCE_MAX,
    }


def _v4(v, d=(1.0, 1.0, 1.0, 1.0)):
    if v is None:
        return list(d)
    if isinstance(v, dict):
        if "X" in v:
            return [v["X"], v["Y"], v["Z"], v.get("W", 1.0)]
        return [v["R"], v["G"], v["B"], v.get("A", 1.0)]
    return [float(v)] * 4


def _u(i):
    return struct.unpack("<f", struct.pack("<I", i))[0]


GRADING = ["ColorSaturation", "ColorContrast", "ColorGamma", "ColorGain", "ColorOffset"]


def lut_cb0(eff, lut_size):
    """FLUTBlenderPS p1 $Globals (75 float4). Struct offset -> register from the frozen bindings (bindings.py):
    LUTWeights[] 40.x/41.x, LUTSizes[] 45.x/46.x (uint), ColorScale 49.yzw, OverlayColor 50, bUseMobileTonemapper 51.x,
    UserGamma 51.w, BlackPoint 52.x, WhitePoint 52.y, WhiteTemp 52.z, WhiteTint 52.w, grading 53..57 (all), 58..62
    (shadows), 63..67 (midtones), 68..72 (highlights), ColorCorrectionShadowsMax 73.x, HighlightsMin 73.y,
    EditorNITLevel 73.z, bUseIdentityLUT 73.w, MappingPolynomial 26.xyz, InverseGamma 27.xyz, legacy tonemapper
    matrices 28..35, HDRBrightness 36.y, FilmSlope 36.z, FilmToe 36.w, FilmShoulder 37.x, FilmBlackClip 37.y,
    FilmWhiteClip 37.z, MinToeParameters 38, MaxToeParameters 39, OutputDevice 74.x, OutputGamut 74.y (uint)."""
    cb = [[0.0] * 4 for _ in range(75)]
    w = float(eff.get("ColorGradingIntensity", 1.0)) if eff.get("ColorGradingLUT") else 0.0
    cb[40][0], cb[41][0] = 1.0 - w, w
    cb[45][0], cb[46][0] = _u(32), _u(lut_size)
    cb[49][1:4] = _v4(eff.get("SceneColorTint"))[:3]
    cb[50] = [0.0, 0.0, 0.0, 0.0]
    cb[51][0] = _u(0)
    cb[51][3] = 1.0                  # UserGamma (user display calibration; default unverified, UNVERIFIED #57)
    cb[52][0], cb[52][1] = 0.0, 1.0  # BlackPoint / WhitePoint (same)
    cb[52][2], cb[52][3] = eff["WhiteTemp"], eff["WhiteTint"]
    for base, suffix in ((53, ""), (58, "Shadows"), (63, "Midtones"), (68, "Highlights")):
        for i, g in enumerate(GRADING):
            d = (0.0, 0.0, 0.0, 0.0) if g == "ColorOffset" else (1.0, 1.0, 1.0, 1.0)
            cb[base + i] = _v4(eff.get(g + suffix), d)
    cb[73] = [eff["ColorCorrectionShadowsMax"], eff["ColorCorrectionHighlightsMin"], EDITOR_NIT_LEVEL, _u(0)]
    cb[26][0:3] = [0.0, 1.0, 0.0]          # MappingPolynomial: only the Rec709 / gamma devices read it
    cb[27][0:3] = [1.0 / 2.2, 1.0, 1.0]    # InverseGamma: same
    cb[36][1:4] = [1.0, eff["FilmSlope"], eff["FilmToe"]]
    cb[37][0:3] = [eff["FilmShoulder"], eff["FilmBlackClip"], eff["FilmWhiteClip"]]
    cb[38] = [eff["DS_FilmMinToe"], eff["DS_FilmMinToeLowLum"], eff["DS_FilmMinToeHiLum"], 0.0]
    cb[39] = [eff["DS_FilmMaxToe"], eff["DS_FilmMaxToeLowLum"], eff["DS_FilmMaxToeHiLum"], 0.0]
    cb[74][0], cb[74][1] = _u(OUTPUT_DEVICE), _u(0)
    return [struct.unpack("<I", struct.pack("<f", x))[0] for r in cb for x in r]


GLSL_HEAD = """#[compute]
#version 450
// GENERATED by tools/build_test_map.py (tools/test_map/post.py + tools/re_exposure/hlsl2glsl.py) from DI2's
// FLUTBlenderPS p1 (Global 2460). Personal-use local data: lives in game/assets/di2/maps/<map>/, never committed.
// One invocation per LUT texel: v0 = slice UV, v2 = slice (the PS's SV_RenderTargetArrayIndex).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, std140) uniform CB0 { vec4 cb0[75]; };
layout(set = 0, binding = 1, std140) uniform CB1 { vec4 cb1[240]; };
layout(set = 0, binding = 2) uniform sampler2D t0;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image3D lut_out;
layout(set = 0, binding = 4, std140) uniform EA { vec4 ea[4]; };
vec4 _load_t1(vec4 v) { return ea[int(v.x)]; }
"""


def lut_glsl():
    icb, body = hlsl2glsl.translate(open(LUT_HLSL).read())
    return (GLSL_HEAD + hlsl2glsl.HELPERS + icb + "\n"
            + "void _main(vec2 v0, vec4 v1, uint v2, out vec4 o0) {\n  o0 = vec4(0.0);\n" + body + "\n}\n"
            + "void main() {\n  uvec3 id = gl_GlobalInvocationID;\n"
            + "  if (any(greaterThanEqual(id, uvec3(32)))) return;\n  vec4 o0;\n"
            + "  _main((vec2(id.xy) + 0.5) / 32.0, vec4(vec2(id.xy) + 0.5, 0.0, 1.0), id.z, o0);\n"
            + "  imageStore(lut_out, ivec3(id), o0);\n}\n")


def block(settings):
    eff, src = effective(settings)
    keep = ["AutoExposureMethod", "AutoExposureMinBrightness", "AutoExposureMaxBrightness", "AutoExposureBias",
            "AutoExposureBiasCurve", "AutoExposureLowPercent", "AutoExposureHighPercent", "AutoExposureSpeedUp",
            "AutoExposureSpeedDown", "HistogramLogMin", "HistogramLogMax", "DerivedBrightnessClampInfluence",
            "DerivedMaxBrightnessScale", "DerivedMaxBrightnessPow", "WhiteTemp", "WhiteTint", "ColorGamma",
            "ColorGradingLUT", "ColorGradingIntensity", "VignetteIntensity", "SceneFringeIntensity", "BloomIntensity",
            "BloomSizeScale", "BloomThreshold", "FilmSlope", "FilmToe", "FilmShoulder", "FilmBlackClip", "FilmWhiteClip",
            "DS_FilmMinToe", "DS_FilmMaxToe", "MesopicBoostCurve", "GrainIntensity", "AmbientOcclusionIntensity",
            "AmbientOcclusionRadius", "SceneColorTint"]
    return eff, {"effective": {k: eff.get(k) for k in keep}, "sources": {k: src[k] for k in keep if k in src},
                 "eye_adaptation": eye_adaptation(eff), "vignette_intensity": eff["VignetteIntensity"],
                 "editor_nit_level": EDITOR_NIT_LEVEL}


# --- time of day: sun colour / shadows, height fog (BP_BasicTimeOfDay) ---------------------------------------------

def _tod_cdo_and_templates(cls):
    """BP_BasicTimeOfDay class default object properties and its component templates by name."""
    d = _json("DeadIsland/Content/DSCore/Lighting/" + cls.removesuffix("_C"))
    cdo = next((e.get("Properties") or {} for e in d if e.get("Name") == "Default__" + cls), {})
    return cdo, {e["Name"]: e.get("Properties") or {} for e in d if "Type" in e}


def component_template(owner, comp, cls="BP_BasicTimeOfDay_C"):
    return _tod_cdo_and_templates(cls)[1].get(comp, {})


def temperature_color(t):
    """FLinearColor::MakeFromColorTemperature (UE 4.27; the same Planckian-locus constants appear in DI2's LUT shader,
    Global 2460 lines 71-84): CIE 1960 uv -> xy -> XYZ (Y = 1) -> linear sRGB."""
    u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
    v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
    x = 3 * u / (2 * u - 8 * v + 4)
    y = 2 * v / (2 * u - 8 * v + 4)
    X, Y, Z = x / y, 1.0, (1 - x - y) / y
    return [3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
            0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z]


def sun_shadows(tpl):
    """Godot cascade settings from the sun component template (BP_BasicTimeOfDay NODE_AddDirectionalLightComponent-2:
    Stationary, DynamicShadowDistanceStationaryLight 22500 cm, 4 cascades, ShadowDistanceFadeoutFraction 0.2,
    CascadeTransitionFraction 0.3). CascadeDistributionExponent is not set -> ULightComponent default 3.0; UE splits
    cascade i at (e^i - 1) / (e^N - 1) of the distance."""
    dist = tpl.get("DynamicShadowDistanceStationaryLight", tpl.get("DynamicShadowDistanceMovableLight", 20000.0)) / 100.0
    n = int(tpl.get("DynamicShadowCascades", 3))
    e = float(tpl.get("CascadeDistributionExponent", 3.0))
    splits = [(e ** i - 1) / (e ** n - 1) for i in range(1, n)]
    return {"shadow_distance": dist, "shadow_cascades": n, "shadow_splits": splits,
            "shadow_fade": float(tpl.get("ShadowDistanceFadeoutFraction", 0.1)),
            "shadow_blend": float(tpl.get("CascadeTransitionFraction", 0.1)) > 0.0}


def height_fog(tod, cfg):
    """UE 4.27 exponential height fog as BP_BasicTimeOfDay.SetupFogComponent sets it (json_bp graph): FogDensity =
    'Fog Density', FogHeightFalloff = 'Fog Height Falloff', second fog = 'Second Fog Density / Height Falloff / Height
    Offset', InscatteringColorCubemap = SkyCubemap, InscatteringTextureTint = Sky Brightness * Distant Fog Brightness
    Tweak (FogUsesSkyBrightness), StartDistance = 'Fog Start Distance', component at the actor + (0, 0, Fog Z Axis
    Offset). Instance values override the class defaults. UE divides density and falloff by 1000 (per cm); here per
    metre: density / 10, falloff / 10. Heights are relative to the map's spawn floor (Godot y)."""
    cdo, tpl = _tod_cdo_and_templates(tod["class"])
    p = dict(cdo)
    p.update(tod["properties"])
    pkg = next(x for x in cfg.get("lighting", []) if os.path.splitext(os.path.basename(x))[0] == tod["level"])
    root_z = None
    for e in _json(os.path.splitext(pkg)[0]):
        if e.get("Name") == "SharedRoot" and e.get("Outer") == tod["actor"] or (e.get("Name") == "SharedRoot" and root_z is None):
            loc = (e.get("Properties") or {}).get("RelativeLocation")
            if loc:
                root_z = loc["Z"]
    floor_z = (cfg.get("origin") or cfg["seed"])[2]
    h = (root_z + p.get("Fog Z Axis Offset", 0.0) - floor_z) / 100.0
    fc = tpl.get("NODE_AddExponentialHeightFogComponent-3", {})
    return {"layers": [[p.get("Fog Density", 0.02) / 10.0, p.get("Fog Height Falloff", 0.2) / 10.0, h],
                       [p.get("Second Fog Density", 0.0) / 10.0, p.get("Second Fog Height Falloff", 0.2) / 10.0,
                        h + p.get("Second Fog Height Offset", 0.0) / 100.0]],
            "tint": (p.get("Sky Brightness", 1.0) * p.get("Distant Fog Brightness Tweak", 1.0)) if p.get("FogUsesSkyBrightness")
            else p.get("Distant Fog Brightness Tweak", 1.0),
            "start_distance": p.get("Fog Start Distance", 0.0) / 100.0, "max_opacity": fc.get("FogMaxOpacity", 1.0),
            "volumetric": bool(fc.get("bEnableVolumetricFog", False)), "cubemap": p.get("SkyCubemap"),
            "fog_height_ue": root_z, "full_directional_distance": p.get("Far Fog Cubemap Directionality Distance", 0.0) / 100.0}
