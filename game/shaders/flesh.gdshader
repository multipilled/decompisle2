// DI2 FLESH, transcribed from DI2's decompiled shaders (recon/SHADERS_FLESH.md) and splatter packing
// (recon/RE_FLESH.md "Batch packing").
//
// Layers: 0 skin (M_Skin), 1 cloth (M_Clothing), 2 muscle = interior shell, 3 bone, 4 organs, 5 eye, 6 hair,
// 7 other, 8 cut cap.
// Vertex data baked by GoreBody:
//   CUSTOM0.xyz  bind-pose position (stamps live in this space); CUSTOM0.w DI2 deform vector length (cm, 0 = n/a)
//   CUSTOM1..3   skin weight inside each of 12 cut slots' bone subtrees (severing hides/shows by these)
//   COLOR        DI2 vertex colour: r = detail mask, g = visibility (skin hidden under clothes until deformed)
// DI2 bakes its stamps into two UV0-space render targets per section (Disp = wound depth, blood, bruise, coverage;
// Dif = drips, cauterisation, fuel, water). GoreBody bakes them the same way on the CPU (gore-core splatter_rt.rs:
// bind-pose projection, FSplatterVS_Local; DI2's default is the skinned-world projection, UNVERIFIED #32) and this
// shader samples them (flesh_splatter.gdshaderinc). The per-vertex depth DI2's FSplatterDeformMeshCS accumulates
// arrives in vdepth_tex (GoreBody computes it on the CPU at hit time).
// Lighting: DI2's light pass per shading model in light() (recon/DEFERRED_LIGHTING.md §4; recon/SHADERS_FLESH.md §15):
// SubsurfaceProfile (skin, interior shell, bone, organs), Cloth (clothing, cut caps), Hair, DefaultLit (other).
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, sss_mode_skin;

uniform int layer = 0;
/// DI2 InitiallyHiddenMask section (e.g. the Thug's skeleton): not drawn until revealed.
uniform bool section_hidden = false;
/// DI2 subsections hidden in this section (viscera / skull / bone culling), bit = subsection id in CUSTOM0.w.
uniform int sub_hidden_lo = 0;
uniform int sub_hidden_hi = 0;
uniform bool two_sided = true;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D mro_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D ata_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_albedo = false;
uniform bool has_normal = false;
uniform bool has_mro = false;
uniform bool has_ata = false;
uniform bool use_alpha_clip = false;
uniform float alpha_clip = 0.333;

// M_Skin inputs (Walker values, §5.1); the per-section ones come from the MI chain.
uniform sampler2D gore_gradient : source_color, filter_linear, repeat_disable;   // Wound Gradient Map (clamp)
uniform sampler2D inner_tex : source_color, filter_linear_mipmap, repeat_enable; // Inner Diffuse Colour Map
uniform sampler2D inner_normal_tex : filter_linear_mipmap, repeat_enable;        // Inner Normal Map
uniform bool has_inner = false;
uniform sampler2D wound_noise : filter_linear_mipmap, repeat_enable;     // T_SkinSplatterWoundNoise_H
uniform sampler2D wound_noise_n : filter_linear_mipmap, repeat_enable;   // T_SkinSplatterWoundNoise_N
uniform sampler2D blood_detail : filter_linear_mipmap, repeat_enable;    // T_SkinBloodSplatterDetail_A
uniform sampler2D drips_tex : filter_linear_mipmap, repeat_enable;       // Blood Drip Map
uniform sampler2D bruise_tex : source_color, filter_linear_mipmap, repeat_enable;  // T_Bruise_D
uniform sampler2D char_tex : filter_linear_mipmap, repeat_enable;        // T_CauterizedFlesh_A
uniform sampler2D caut_n : filter_linear_mipmap, repeat_enable;          // T_CauterizedFlesh_N
uniform sampler2D fabric_tear : filter_linear_mipmap, repeat_enable;     // T_FabricTearDetail_A
uniform sampler2D fabric_detail : filter_linear_mipmap, repeat_enable;   // T_FabricSplatterDetail_A
uniform bool has_fabric_detail = false;
uniform sampler2D blood_n : filter_linear_mipmap, repeat_enable;         // T_SkinBloodSplatterDetail_ReduceNoise_N
uniform bool has_blood_n = false;
// TV_Global3dNoise (128^3 volume, exported as 128 slices stacked vertically: slice z = rows [z*128, (z+1)*128)).
uniform sampler2D noise3d : filter_linear, repeat_enable;
uniform bool has_noise3d = false;
uniform float epidermis_tiling = 32.0;
uniform float blood_splatter_tiling = 1.75;
uniform float blood_drip_tiling = 1.0;
uniform float caut_tiling = 2.25;
uniform float bruise_tiling = 6.0;
uniform float bruise_desat = 0.5;
uniform float inner_desat = 0.25;
uniform float inner_rough = 0.22;
uniform float opacity_offset = 0.0;
uniform vec3 blood_colour = vec3(0.8, 0.502, 0.48);
uniform vec3 bruise_tint = vec3(1.0);
uniform vec3 inner_tint = vec3(1.0);
uniform vec2 blood_uv_offset = vec2(1.4, 0.4);
// M_Clothing: '03 - Fabric Tear Map Tiling' and 'Rip Amount' (resolved per section from data/flesh_materials.json).
uniform float fabric_tear_tiling = 1.0;
uniform float rip_amount = 1.0;
// DI2 deform vector length when the mesh's deform stream isn't decoded yet (cm; 3 -> normalisation x1).
uniform float deform_fallback_cm = 3.0;

// --- DI2 light-pass inputs (data/flesh_materials.json "lighting", recon/SHADERS_FLESH.md §15) -----------------------
// M_Skin, MSM_SubsurfaceProfile (Walker values, PS 3213). SSS opacity source per permutation: 0 lerp(Base, Vein SSS,
// vein) (PS 3213 / 2071; veins aren't ported, vein = 0), 1 MRO.b (PS 3569), 2 MRO.b * sat(Translucency Adjustment +
// ATA.g) (skeleton PS 1939), 3 one (interior shell PS 3094; layer 2 always).
uniform int ssp_op = 0;
uniform float sss_base = 0.8;              // Base Subsurface Scattering
uniform float spec_occ_power = 1.0;        // Specular Occlusion Power
uniform float debug_oil = 0.0;             // Debug Oil Layer
uniform float translucency_adj = 0.0;      // Translucency Adjustment
uniform float base_desat = 0.0;            // Desaturation (of the Diffuse Colour Map)
uniform vec3 base_tint = vec3(1.0);        // Colour Tint
// Subsurface profile -> Godot's screen-space SSS: SSP_DefaultLightSkin, separable, ScatterRadius 1.5 cm.
uniform float sss_radius_m = 0.015;
uniform float godot_sss_scale = 0.05;      // ProjectSettings subsurface_scattering_scale (Godot default)
// M_Clothing, MSM_Cloth (M_Clothing master defaults, which MI_Breakage, the cut caps, inherits).
uniform float cloth_translucency = 0.25;   // Cloth Translucency
uniform float force_cloth = 0.0;           // Force Cloth
uniform float sheen_avg = 0.25;            // Sheen Colour Averaging Amount
uniform float sheen_desat = 0.1;           // Sheen Colour Desaturation
uniform float sheen_mult = 1.5;            // Sheen Colour Multiplier
uniform vec3 cloth_tint = vec3(1.0);       // Cloth Colour Tint
// M_Hair, MSM_Hair (M_Hair master defaults; PS 4056).
uniform sampler2D hair_data_tex : filter_linear_mipmap, repeat_enable;   // Packed Hair Data Map (linear)
uniform sampler2D hair_flow_tex : filter_linear_mipmap, repeat_enable;   // Flow Map (linear, BC5)
uniform bool has_hair_data = false;
uniform bool has_hair_flow = false;
uniform float hair_scatter = 1.0;          // Scatter
uniform float hair_roughness = 0.42;       // Roughness
uniform float hair_rough_var = 0.0;        // Roughness Variation
uniform float hair_flow_var = 0.3;         // Flow Variation
uniform float hair_root_occ = 0.1;         // Root Occlusion Amount
uniform float hair_root_occ_curve = 1.0;   // Root Occlusion Curve
uniform float hair_tex_occ = 1.0;          // Texture Occlusion Amount
uniform float hair_vtx_occ = 0.0;          // Vertex Alpha Occlusion Amount
uniform float hair_root_tip_curve = 1.0;   // Root-Tip Colour Curve
uniform float hair_bright_var = 0.0;       // Brightness Variation
uniform float hair_brightness = 1.0;       // Overall Brightness
uniform vec3 hair_root = vec3(0.109804, 0.07451, 0.047059);   // Root Colour
uniform vec3 hair_tip = vec3(0.109804, 0.07451, 0.05098);     // Tip Colour

// MPC_CharacterGameWideParams defaults (§5.1).
const float STD_WOUND_GRAD = 1.5;
const float EPI_START = 0.1;
const float EPI_END = 0.18;
const float SKIN_EDGE_SHIFT = 0.12;
const float SKIN_EDGE_CONTRAST = 4.0;
const float EDGE_FAT_NOISE = -1.0;
const float EDGE_EPI_NOISE = -0.7;
const float MEATMAN_POW = 20.0;
const float VTX_GRAD_POW = 3.0;
const float VTX_GRAD_AMT = 1.0;
const float VOL_TILING = 3.7;
const float VOL_MULT = 1.0;
const float VOL_OFFSET = -0.18;
const float BLOOD_MAX_COV = 0.8;
const float BLOOD_DETAIL_MASK = 1.5;
const float BLOOD_EDGE_CONTRAST = 1.2;
const float BLOOD_IN_WOUND_FADE = 1.5;
const float BLOOD_DENSITY = 12.0;
const float BLOOD_NRM_THRESH = 3.0;
const float BLOOD_ROUGH = 0.15;
const float DRIP_MAX_COV = 1.0;
const float DRIP_DETAIL = 1.0;
const float DRIP_EDGE_CONTRAST = 1.7;
const float CAUT_MAX = 0.75;
const float CAUT_WOUND_FALLOFF = 0.4;
const float CAUT_DETAIL = 1.2;
const float CAUT_EDGE_CONTRAST = 1.6;
const float CAUT_MAX_DARK = 0.98;
const float CAUT_ROUGH = 0.8;
const float BRUISE_INTENSITY = 1.0;
const float MAJOR_CUT_START = 0.9;
const float MAJOR_CUT_END = 1.0;
const float MAJOR_CUT_RAGGED = 10.0;
const float DEFORM_NRM_STRENGTH = 6.0;
const float DEFORM_NRM_JITTER = 0.007;
const vec3 FUEL_COLOUR = vec3(0.602512, 0.646108, 0.692708);
// M_Clothing (§6)
const float CLOTH_TEAR_SCALE = 5.0;
const float CLOTH_TEAR_DETAIL = 5.0;
const float CLOTH_CAVITY = 3.0;
const float CLOTH_DETAIL_MASK = 0.5;
const float CLOTH_WET_DARKENING = 0.15;
const float CLOTH_BLOOD_ROUGH = 0.25;

uniform vec4 wounds[192];
uniform int wound_count = 0;
uniform sampler2D vdepth_tex : filter_nearest, repeat_disable;
uniform int vdepth_w = 2048;
uniform bool has_vdepth = false;

#include "res://shaders/flesh_splatter.gdshaderinc"

varying vec3 rest_pos;
varying flat int sub_off;
varying vec4 sw0;
varying vec4 sw1;
varying vec4 sw2;
varying float dv;
varying float deform_cm;
// GBuffer values DI2's light pass reads (fragment -> light()).
varying float v_model;     // 0 SubsurfaceProfile, 1 Cloth, 2 Hair, 3 DefaultLit
varying float v_rough;     // GBuffer roughness (ROUGHNESS carries the reflection-pass roughness on cloth)
varying float v_spec_mul;  // 2*S': specular intensity from the GBuffer specular byte
varying float v_oil;       // SubsurfaceProfile: GBufferB.x lobe mix ("Oil Layer")
varying float v_op;        // SubsurfaceProfile: SSS opacity (CustomData.a)
varying float v_cloth;     // Cloth: CustomData.a
varying float v_bx;        // Cloth: GBufferB.x = min(0.99, lerp(Metallic, ClothTranslucency, Cloth)); Hair: scatter
varying vec3 v_fuzz;       // Cloth: sheen colour (CustomData.rgb, linear)
varying vec3 v_tan;        // Hair: strand tangent (GBufferA), view space
varying vec3 v_ncard;      // Hair: the card's vertex normal (CustomData.xyz, not flipped on back faces), view space


float tent(float x) { return 1.0 - abs(2.0 * x - 1.0); }
float contrast(float x, float c) { return clamp((x - 0.5) * c + 0.5, 0.0, 1.0); }
float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }

// TV_Global3dNoise sampled from its atlas; procedural value noise only if the atlas is missing.
float hash31(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x), mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x), mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}
vec4 noise3(vec3 p) {
	if (has_noise3d) {
		// Trilinear sample of the wrapped 128^3 volume from its slice atlas.
		vec3 w = fract(p);
		float z = w.z * 128.0 - 0.5;
		float z0 = floor(z);
		float t = z - z0;
		float s0 = mod(z0, 128.0);
		float s1 = mod(z0 + 1.0, 128.0);
		vec2 uv = vec2(w.x, w.y / 128.0);
		vec4 a = texture(noise3d, vec2(uv.x, uv.y + s0 / 128.0));
		vec4 b = texture(noise3d, vec2(uv.x, uv.y + s1 / 128.0));
		return mix(a, b, t);
	}
	return vec4(vnoise(p), vnoise(p + 17.3), vnoise(p + 41.9), vnoise(p * 1.7 + 7.1));
}

// UE "BlendAngleCorrectedNormals" (RNM) as decompiled: b' = (b.xy, b.z + 1), a' = (-a.xy, a.z).
vec3 rnm(vec3 base, vec3 detail) {
	vec3 b = vec3(base.xy, base.z + 1.0);
	vec3 a = vec3(-detail.xy, detail.z);
	return normalize(b * dot(b, a) - a * b.z);
}

vec3 unpack_dx(vec4 t) {
	vec2 xy = t.rg * 2.0 - 1.0;
	xy.y = -xy.y; // Unreal (DirectX) normal maps
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
}

float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
// GBufferB.y = sat(129/255 + min(0.5, S)); the light and reflection passes scale specular by 2*S' (<= 0.99213).
float di2_spec_mul(float S) { return clamp(min(round(255.0 * min(0.5, S)), 126.0) * (512.0 / 65025.0), 0.0, 1.0); }
float D_GGX(float a2, float NoH) { float d = (NoH * a2 - NoH) * NoH + 1.0; return a2 / (PI * d * d); }
float Vis_SJA(float a2, float NoV, float NoL) {
	float a = sqrt(a2);
	return 0.5 / (NoL * (NoV * (1.0 - a) + a) + NoV * (NoL * (1.0 - a) + a));
}
// UE 4.27 HairShading helpers (FastMath acosFast; Hair_g; Hair_F with IOR 1.55).
float asin_fast(float x) {
	float ax = abs(x);
	float r = (-0.156583 * ax + 0.5 * PI) * sqrt(1.0 - ax);
	return 0.5 * PI - (x >= 0.0 ? r : PI - r);
}
float hair_g(float B, float t) { return exp(-0.5 * t * t / (B * B)) / (2.506628 * B); }
float hair_f(float c) { float x = 1.0 - c; return 0.046521 + 0.953479 * x * x * x * x * x; }



void vertex() {
	rest_pos = CUSTOM0.xyz;
	// CUSTOM0.w = DI2 subsection id x 256 + deform vector length (cm).
	float sub_id = floor(CUSTOM0.w / 256.0);
	float dlen = CUSTOM0.w - sub_id * 256.0;
	deform_cm = dlen > 0.0 ? dlen : deform_fallback_cm;
	int sid = int(sub_id);
	// Hidden subsection: the whole triangle is discarded (flat, the provoking vertex's id). Collapsing vertices
	// stretched triangles whose corners straddle a subsection seam.
	sub_off = (((sid < 32 ? (sub_hidden_lo >> sid) : (sub_hidden_hi >> (sid - 32))) & 1) == 1) ? 1 : 0;
	sw0 = CUSTOM1;
	sw1 = CUSTOM2;
	sw2 = CUSTOM3;
	dv = 0.0;
	if (has_vdepth) {
		dv = texelFetch(vdepth_tex, ivec2(VERTEX_ID % vdepth_w, VERTEX_ID / vdepth_w), 0).r;
	}
	// DI2 base-pass VS: P = Position + Deform.xyz * depth (before skinning). GoreBody applies it to the bind-pose
	// vertices when the body's deform stream is decoded (CUSTOM0.w > 0); otherwise -normal x fallback length stands in.
	if (dlen <= 0.0) {
		VERTEX -= NORMAL * (deform_cm * 0.01) * dv;
	}
}

void fragment() {
	if (sub_off == 1) discard;
	// --- Severing -------------------------------------------------------------
	bool cap = layer == 8;
	float sev = -1.0;
	for (int k = 0; k < 12; k++) {
		if (((severed_mask >> k) & 1) == 1 && k != cap_slot) {
			sev = max(sev, past_cut(k, rest_pos, sw0, sw1, sw2));
		}
	}
	float seam = 0.0;
	if (di2_cut) {
		// DI2 dismember already split this section's triangles (body / limb): nothing to discard here.
	} else if (is_piece) {
		float own = past_cut(piece_slot, rest_pos, sw0, sw1, sw2);
		if ((own < 0.0 && piece_slot != cap_slot) || sev > 0.0) discard;
		seam = 1.0 - smoothstep(0.0, 0.2, own);
	} else {
		if (sev > 0.0) discard;
		seam = 1.0 - smoothstep(0.0, 0.2, -sev);
	}
	if (cap) seam = 0.0;
	if (section_hidden) discard;
	// M_EyeOcclusion has its own shader (eye_occlusion.gdshader); a flesh material on it draws nothing.
	if (layer == 9) discard;
	// DI2's skin and interior sections are single-sided.
	if (!two_sided && !FRONT_FACING) discard;

	// --- Base material --------------------------------------------------------
	vec4 base = has_albedo ? texture(albedo_tex, UV) : vec4(0.62, 0.52, 0.47, 1.0);
	vec4 ata4 = has_ata ? texture(ata_tex, UV) : vec4(1.0);
	float ata = ata4.r;
	vec3 mro = has_mro ? texture(mro_tex, UV).rgb : vec3(0.0, 0.65, 1.0);
	vec3 nts = has_normal ? unpack_dx(texture(normal_tex, UV)) : vec3(0.0, 0.0, 1.0);
	vec3 col = base.rgb;
	float rough = mro.g;
	float metal = mro.r;
	float alpha = ata;
	vec4 vc = COLOR;
	// Light-pass inputs the material branches set (skin: inner / opened wound / wet; cloth: wet; hair: AO, scatter, S).
	bool ssp = layer == 0 || (layer >= 2 && layer <= 4);
	float l_inner = 0.0;
	float l_open = 0.0;
	float l_wet = 0.0;
	float h_ao = 1.0;
	float h_scatter = 0.0;
	float h_S = 0.5;
	float cloth_amt = clamp(force_cloth + ata4.g, 0.0, 1.0);   // M_Clothing 'Cloth' = sat(Force Cloth + ATA.g)
	if (layer == 0 || layer == 3 || layer == 4) {
		// M_Skin base colour: Diffuse desaturated by 'Desaturation', x 'Colour Tint' (PS 3213 / 2071 / 1939).
		col = mix(col, vec3(lum(col)), base_desat) * base_tint;
	} else if (layer == 2) {
		// Interior shell (PS 3094): the inner diffuse desaturated by 'Inner Desaturation' x 'inner Colour Tint';
		// roughness 'inner Roughness' (no MRO in this permutation).
		col = mix(col, vec3(lum(col)), inner_desat) * inner_tint;
		rough = inner_rough;
	} else if (layer == 1 || cap) {
		col *= mix(vec3(1.0), cloth_tint, cloth_amt);   // M_Clothing: Diffuse x lerp(1, Cloth Colour Tint, Cloth)
	}

	if (layer <= 2 && !cap) {
		vec3 disp;
		vec4 dif;
		splatter_rt(UV, UV2, disp, dif);
		vec4 n3 = noise3(rest_pos * 100.0 / VOL_TILING);
		float nV = clamp(VOL_MULT * n3.w + VOL_OFFSET, 0.0, 1.0);
		float nS = 1.0 - (1.0 - n3.y) * (1.0 - n3.x);
		float vis = clamp(vc.g + (dv >= 0.001 ? 1.0 : 0.0), 0.0, 1.0);

		if (layer == 0) {
			// --- M_Skin (§5) ---
			float W = max(disp.r, VTX_GRAD_AMT * pw(clamp(dv, 0.0, 1.0), VTX_GRAD_POW));
			float g = STD_WOUND_GRAD * W;
			float inner = g > 0.5 ? 1.0 : 0.0;
			float e = clamp((g - EPI_START) / (max(EPI_START, EPI_END) - EPI_START), 0.0, 1.0);
			float T = tent(g);
			float nH = texture(wound_noise, UV * epidermis_tiling).g;
			float open = contrast(clamp(clamp(g + T * (nV - 0.5) * EDGE_FAT_NOISE - T * (nH - 0.5) * EDGE_EPI_NOISE, 0.0, 1.0) / SKIN_EDGE_SHIFT, 0.0, 1.0), SKIN_EDGE_CONTRAST);
			vec3 inner_d = has_inner ? texture(inner_tex, UV).rgb : vec3(0.0);
			inner_d = mix(inner_d, vec3(dot(inner_d, vec3(0.3, 0.59, 0.11))), inner_desat);
			vec3 inner_n = has_inner ? unpack_dx(texture(inner_normal_tex, UV)) : vec3(0.0, 0.0, 1.0);
			float U = clamp(pw(1.0 - clamp(inner_tint.g * inner_d.g, 0.0, 1.0), MEATMAN_POW) * mix(nH, nV, e), 0.0, 1.0);
			vec4 G = texture(gore_gradient, vec2(U, g));
			vec3 bt = texture(bruise_tex, UV * bruise_tiling).rgb;
			bt = mix(bt, vec3(dot(bt, vec3(0.3, 0.59, 0.11))), bruise_desat);
			vec3 bruise_col = mix(bruise_tint * vec3(0.557292, 0.142254, 0.139323), bt * bruise_tint, vc.r);
			float bruise_amt = mix(BRUISE_INTENSITY * disp.b * nS, BRUISE_INTENSITY * disp.b, vc.r);
			col *= mix(vec3(1.0), bruise_col, bruise_amt);
			col = mix(col, inner_tint * inner_d, inner);
			col = mix(col, G.rgb, G.a * open);
			// Blood, drips, wetness (§5.5)
			float B = min(BLOOD_MAX_COV, clamp(dif.a + disp.g + dif.b, 0.0, 1.0));
			float dB = texture(blood_detail, (UV + blood_uv_offset) * blood_splatter_tiling).g;
			float blood = contrast(clamp(tent(B) * (dB - 0.5) * BLOOD_DETAIL_MASK * vc.r + B, 0.0, 1.0), BLOOD_EDGE_CONTRAST) * mix(nS, dB, vc.r);
			float dR = min(DRIP_MAX_COV, dif.r);
			vec4 dm = texture(drips_tex, UV * blood_drip_tiling);
			float drip = dm.r * contrast(clamp(tent(dR) * (dm.g - 0.5) * DRIP_DETAIL + dR, 0.0, 1.0), DRIP_EDGE_CONTRAST);
			blood = max(blood, drip) * pw(1.0 - g, BLOOD_IN_WOUND_FADE);
			float wet = clamp(BLOOD_NRM_THRESH * blood, 0.0, 1.0);
			float fb = clamp(1e-5 + disp.g, 0.0, 1.0);
			float s = fb + dif.a + dif.b;
			vec3 mix_c = (fb / s) * blood_colour + vec3(dif.a / s) + (dif.b / s) * FUEL_COLOUR;
			mix_c = mix(mix_c, blood_colour, drip);
			col *= min(vec3(1.0), exp2(BLOOD_DENSITY * blood * log2(max(mix_c, vec3(1e-6)))));
			// Cauterisation (§5.6)
			float c0 = min(CAUT_MAX, dif.g) * pw(1.0 - g, CAUT_WOUND_FALLOFF);
			float caut = contrast(clamp(tent(c0) * mix(nS, (texture(char_tex, UV * caut_tiling).g - 0.5) * CAUT_DETAIL, vc.r) + c0, 0.0, 1.0), CAUT_EDGE_CONTRAST);
			col *= 1.0 - caut * CAUT_MAX_DARK;
			// Normals (§5.7): inner -> wound (height of W + detail) -> cauterisation.
			nts = mix(nts, inner_n, inner);
			vec2 duvx = dFdx(UV);
			vec2 duvy = dFdy(UV);
			float wx = dFdx(W);
			float wy = dFdy(W);
			float jd = duvx.x * duvy.y - duvx.y * duvy.x;
			vec2 dwduv = abs(jd) > 1e-12 ? vec2(wx * duvy.y - wy * duvx.y, wy * duvx.x - wx * duvy.x) / jd : vec2(0.0);
			vec3 height_n = normalize(vec3(DEFORM_NRM_STRENGTH * 2.0 * DEFORM_NRM_JITTER * dwduv, 2.0));
			vec3 detail_n = unpack_dx(texture(wound_noise_n, UV * epidermis_tiling));
			vec3 wound_n = rnm(height_n, rnm(inner_n, detail_n));
			nts = normalize(mix(nts, wound_n, G.a * open));
			if (has_blood_n) {
				vec3 bn = unpack_dx(texture(blood_n, (UV + blood_uv_offset) * blood_splatter_tiling));
				bn = normalize(mix(bn, vec3(0.0, 0.0, 1.0), clamp(0.5 * drip + (1.0 - vc.r), 0.0, 1.0)));
				nts = normalize(mix(nts, bn, wet * (1.0 - open)));
			}
			vec3 caut_nm = unpack_dx(texture(caut_n, UV * caut_tiling));
			nts = normalize(mix(nts, caut_nm, caut * (1.0 - open)));
			rough = mix(rough, inner_rough, inner);
			rough = mix(rough, inner_rough, G.a * open);
			rough = mix(rough, BLOOD_ROUGH, wet);
			rough = mix(rough, CAUT_ROUGH, caut);
			l_inner = inner;
			l_open = G.a * open;
			l_wet = wet;
			// Major cut (§5.8): the skin goes where the wound is through, showing the interior shell.
			float a = clamp((W - MAJOR_CUT_START) / (max(MAJOR_CUT_START, MAJOR_CUT_END) - MAJOR_CUT_START), 0.0, 1.0);
			float keep = clamp(1.0 - a - tent(a) * (1.0 + MAJOR_CUT_RAGGED * (inner_n.x + inner_n.y)), 0.0, 1.0);
			alpha = clamp(opacity_offset + keep, 0.0, 1.0) * ata * vis;
		} else if (layer == 1) {
			// --- M_Clothing (§6) ---
			float cav = clamp(CLOTH_CAVITY * (1.0 - abs(nts.z) / max(length(nts), 1e-5)), 0.0, 1.0);
			float b = disp.g + CLOTH_TEAR_SCALE * disp.r;
			b += cav * b;
			float B = min(BLOOD_MAX_COV, clamp(b + dif.a + dif.b, 0.0, 1.0));
			float dB = has_fabric_detail ? texture(fabric_detail, (UV + blood_uv_offset) * blood_splatter_tiling).g
					: texture(blood_detail, (UV + blood_uv_offset) * blood_splatter_tiling).g;
			float blood = contrast(clamp(tent(B) * (dB - 0.5) * CLOTH_DETAIL_MASK * vc.r + B, 0.0, 1.0), BLOOD_EDGE_CONTRAST) * mix(nS, dB, vc.r);
			float wet = clamp(BLOOD_NRM_THRESH * blood, 0.0, 1.0);
			float fb = clamp(1e-5 + b, 0.0, 1.0);
			float s = fb + dif.a + dif.b;
			vec3 mix_c = (fb / s) * blood_colour + (dif.a / s) * mix(vec3(1.0), col, CLOTH_WET_DARKENING) + (dif.b / s) * FUEL_COLOUR;
			col *= min(vec3(1.0), exp2(BLOOD_DENSITY * blood * log2(max(mix_c, vec3(1e-6)))));
			float c0 = min(CAUT_MAX, dif.g) * exp2(-1.737 * CAUT_WOUND_FALLOFF);
			float caut = contrast(clamp(tent(c0) * mix(nS, (texture(char_tex, UV * caut_tiling).g - 0.5) * CAUT_DETAIL, vc.r) + c0, 0.0, 1.0), CAUT_EDGE_CONTRAST);
			col *= 1.0 - caut * CAUT_MAX_DARK;
			rough = mix(mix(rough, CLOTH_BLOOD_ROUGH, wet), CAUT_ROUGH, caut);
			l_wet = wet;
			// Tear: wound depth rips holes in the cloth (bruise holds it together).
			float tear = clamp(CLOTH_TEAR_SCALE * disp.r - disp.b, 0.0, 1.0);
			float K = clamp((1.0 - tear) + tent(tear) * (texture(fabric_tear, UV * fabric_tear_tiling).r - 0.5) * CLOTH_TEAR_DETAIL - tent(tear) * cav, 0.0, 1.0);
			alpha = ata * (1.0 - rip_amount * (1.0 - K));
		} else {
			// --- Interior shell (§7): plain inner material, cut away where the wound is through. ---
			float W = max(0.0, disp.r);
			float a = clamp((W - MAJOR_CUT_START) / (max(MAJOR_CUT_START, MAJOR_CUT_END) - MAJOR_CUT_START), 0.0, 1.0);
			float keep = clamp(1.0 - a - tent(a) * (1.0 + MAJOR_CUT_RAGGED * (nts.x + nts.y)), 0.0, 1.0);
			alpha = clamp(opacity_offset + keep, 0.0, 1.0) * ata * vis;
		}
	}
	if (layer == 6) {
		// --- M_Hair (PS 4056). Packed Hair Data: x root-to-tip, y texture occlusion, z per-strand variation, w opacity.
		vec4 hd = has_hair_data ? texture(hair_data_tex, UV, -2.0) : vec4(1.0, 1.0, 0.5, 1.0);   // SampleBias -2
		vec3 hc = col;   // without the packed data: the packer's flat Root/Tip colour
		if (has_hair_data) {
			h_ao = clamp((pw(hd.x, hair_root_occ_curve) * hair_root_occ + 1.0 - hair_root_occ)
				* (hair_tex_occ * (hd.y - 1.0) + 1.0) * (hair_vtx_occ * (vc.a - 1.0) + 1.0), 0.0, 1.0);
			hc = clamp(mix(hair_root, hair_tip, pw(hd.x, hair_root_tip_curve)) * hair_brightness
				* (1.0 + hair_bright_var * (hd.z - 0.5)), 0.0, 1.0);
			col = hc * h_ao;
		}
		h_scatter = hair_scatter * dot(hc, vec3(0.333333));   // GBufferB.x: Kajiya-Kay scatter amount
		// Strand tangent (GBufferA): the flow map in tangent space, z = Flow Variation * (1 - 2 * variation); DirectX
		// green flipped as for the normal maps. UE flips flow.xy and the result on back faces, which leaves the same
		// vector as Godot's back-face-flipped NORMAL here. Without the flow map: (0, -1), the flow maps' mean direction.
		vec2 fl = has_hair_flow ? texture(hair_flow_tex, UV).rg * 2.0 - 1.0 : vec2(0.0, -1.0);
		vec3 ts = vec3(fl.x, -fl.y, hair_flow_var * (1.0 - 2.0 * hd.z));
		v_tan = normalize(TANGENT * ts.x + BINORMAL * ts.y + NORMAL * ts.z);
		v_ncard = FRONT_FACING ? NORMAL : -NORMAL;
		// --- M_Hair splatter (§7.1): the head's targets at UV1. Blood / water / fuel tint the strands like
		// the skin's absorption mix, wounds remove the hair, blood makes it wet (lower roughness).
		vec3 disp;
		vec4 dif;
		splatter_rt(UV, UV2, disp, dif);
		float f = clamp(disp.g + dif.a + dif.b, 0.0, 1.0) + 2.0 * disp.r;   // ChrSplatterHairRemovalScale 2
		float fb = clamp(1e-5 + disp.g, 0.0, 1.0);
		float s = fb + dif.a + dif.b;
		vec3 mix_c = (fb / s) * blood_colour + vec3(dif.a / s) + (dif.b / s) * FUEL_COLOUR;
		col *= min(vec3(1.0), exp2(BLOOD_DENSITY * f * log2(max(mix_c, vec3(1e-6)))));
		alpha *= 1.0 - clamp(2.0 * disp.r, 0.0, 1.0);
		// Wet look (PS 4056): roughness max(0.35, Roughness + variation) pulled to 0.25 by sat(f); specular
		// lerp(0.5 * AO, 0.5, sat(f)); base colour clamped to [0.018 * S, 0.875 + 0.125 * scatter].
		float sf = clamp(f, 0.0, 1.0);
		rough = mix(max(0.35, hair_roughness + hair_rough_var * (hd.z - 0.5)), 0.25, sf);
		h_S = mix(0.5 * h_ao, 0.5, sf);
		col = min(max(col, vec3(0.018 * h_S)), vec3(0.875 + 0.125 * h_scatter));
	}
	// (Eyes, layer 5, have their own shader: eye.gdshader, UE MSM_Eye lighting.)
	if (use_alpha_clip && alpha < alpha_clip) discard;
	if (!use_alpha_clip && layer <= 2 && alpha < 0.1) discard;

	// Raw ring at a severed cut (recreation stand-in for DI2's dismember splatter, UNVERIFIED until RE_DISMEMBER.md).
	// Back faces of two-sided sections render as the material itself, like UE's TwoSided (normal flipped by Godot).
	float n = texture(wound_noise, UV * 3.0).r;
	col = mix(col, texture(gore_gradient, vec2(n, 0.55)).rgb, smoothstep(0.25, 0.9, seam));

	// --- GBuffer -> DI2 light pass (recon/DEFERRED_LIGHTING.md §2, §4, §6; recon/SHADERS_FLESH.md §15) ---------------
	v_rough = clamp(rough, 0.0, 1.0);
	float rough_env = v_rough;
	if (ssp) {
		// MSM_SubsurfaceProfile (M_Skin: skin PS 3213 / 3569, interior shell 3094, viscera 2071, skeleton 1939).
		// Metallic forced to 0, F0 0.028; GBufferB.x = the "Oil Layer" lobe mix; CustomData.a = the SSS opacity.
		float O = mro.b;
		float S = layer == 2 ? 0.5 : mix(mix(0.5 * pw(O, spec_occ_power), 0.5, l_inner), 0.5, l_open);
		float oil = layer == 2 ? 0.0 : mro.r * (1.0 - l_inner) * (1.0 - l_open) * (1.0 - l_wet);
		float op = (layer == 2 || ssp_op == 3) ? 1.0 : ssp_op == 1 ? O
			: ssp_op == 2 ? O * clamp(translucency_adj + ata4.g, 0.0, 1.0) : sss_base;
		op = clamp(mix(mix(op, 1.0, l_inner), 1.0, l_open), 0.0, 1.0);
		col = clamp(min(max(col, vec3(0.018 * S)), vec3(0.875 + 0.125 * oil)), 0.0, 1.0);
		v_model = 0.0;
		v_spec_mul = di2_spec_mul(S);
		v_oil = clamp(debug_oil + oil, 0.0, 1.0);
		v_op = op;
		METALLIC = 0.0;
		// Godot's ambient F0 = 0.16 * SPECULAR^2: 0.028 with the 2*S' reflection multiplier folded in (recon/DANI.md 4.5).
		SPECULAR = sqrt(0.028 * v_spec_mul / 0.16);
		// Subsurface profile -> Godot's screen-space SSS: world radius onto the kernel, gated like DI2's recombine.
		SSS_STRENGTH = clamp(10.0 * op, 0.0, 1.0) * sss_radius_m * PROJECTION_MATRIX[0][0]
			/ (2.0 * max(-VERTEX.z, 0.01)) / godot_sss_scale;
	} else if (layer == 1 || cap) {
		// MSM_Cloth (M_Clothing PS 3410; the caps' MI_Breakage is M_Clothing). Wet cloth loses translucency and cloth.
		float mB = mix(clamp(mro.r, 0.0, 1.0), cloth_translucency, cloth_amt) * (1.0 - l_wet);
		float C = cloth_amt * (1.0 - l_wet);
		col = clamp(min(max(col, vec3(0.009)), vec3(0.875 + 0.125 * mB)), 0.0, 1.0);
		// Sheen (CustomData.rgb): the tinted diffuse, blended toward its average (smallest mip), desaturated, scaled.
		vec3 Dm = has_albedo ? textureLod(albedo_tex, UV, 16.0).rgb : base.rgb;
		vec3 fz = mix(base.rgb, Dm, sheen_avg) * mix(vec3(1.0), cloth_tint, cloth_amt);
		v_fuzz = clamp(sheen_mult * mix(fz, vec3(lum(fz)), sheen_desat), 0.0, 1.0);
		v_model = 1.0;
		v_spec_mul = 0.99213;   // M_Clothing writes GBufferB.y = 1
		v_cloth = C;
		v_bx = min(0.99, clamp(mB, 0.0, 1.0));
		METALLIC = v_bx * (1.0 - C);
		// Reflection pass: roughness -> 0.1 on full cloth, reflection x (1 - |NoV| * Cloth) x 2*S' (folded into F0).
		rough_env = mix(v_rough, 0.1, clamp((C - 0.9) * 10.0, 0.0, 1.0));
		SPECULAR = sqrt(0.04 * v_spec_mul * (1.0 - min(abs(dot(NORMAL, VIEW)), 1.0) * C) / 0.16);   // |N.V| can be 1 + eps
	} else if (layer == 6) {
		// MSM_Hair: GBufferA = strand tangent, GBufferB.x = scatter, CustomData = card normal (set above).
		v_model = 2.0;
		v_spec_mul = di2_spec_mul(h_S);
		v_bx = clamp(h_scatter, 0.0, 1.0);
		METALLIC = 0.0;
		SPECULAR = 0.5;   // DI2's hair ambient (FHairEnvironmentLightingPS) isn't decoded: Godot's ambient
	} else {
		// MSM_DefaultLit (other sections): Lambert + GGX, F0 lerp(0.04, BC, metallic), Specular 0.5.
		v_model = 3.0;
		v_spec_mul = 0.99213;
		METALLIC = metal;
		SPECULAR = sqrt(0.04 * v_spec_mul / 0.16);
	}

	ALBEDO = col;
	ROUGHNESS = rough_env;
	AO = mro.b;
	NORMAL_MAP = nts * 0.5 + 0.5;
}

// DI2's FDeferredLightPS BxDFs for punctual lights (recon/DEFERRED_LIGHTING.md §4.1 DefaultLit, §4.5 SubsurfaceProfile,
// §4.7 Hair, §4.8 Cloth; Global 2075 p1). Skin and cloth are the same code as player.gdshader. Godot multiplies
// DIFFUSE_LIGHT by ALBEDO * (1 - METALLIC) afterwards, LIGHT_COLOR carries PI, ATTENUATION holds the shadow.
void light() {
	vec3 lc = LIGHT_COLOR * ATTENUATION;
	float R = v_rough;
	if (v_model > 1.5 && v_model < 2.5) {
		// Hair (§4.7): UE 4.27 HairShading (Marschner R / TT / TRT + Kajiya-Kay scatter; deferred defaults: no backlit,
		// separable R, legacy absorption) on the strand tangent, x DI2's card term (1 - sat(-dot(Ncard, L)))^4.
		vec3 N = v_tan;
		vec3 BC = ALBEDO;
		float r = clamp(R, 1.0 / 255.0, 1.0);
		float r2 = r * r;
		float sL = clamp(dot(N, LIGHT), -1.0, 1.0);
		float sV = clamp(dot(N, VIEW), -1.0, 1.0);
		float VoL = dot(VIEW, LIGHT);
		float cosD = cos(0.5 * abs(asin_fast(sV) - asin_fast(sL)));
		vec3 Lp = LIGHT - sL * N;
		vec3 Vp = VIEW - sV * N;
		float cosPhi = dot(Lp, Vp) * inversesqrt(dot(Lp, Lp) * dot(Vp, Vp) + 1e-4);
		float cHP = sqrt(clamp(0.5 + 0.5 * cosPhi, 0.0, 1.0));
		// R: alpha -0.07 (sin -0.069943, cos 0.997551), B = r^2 * sqrt(2) * cos(phi/2), x 2*S'
		float shR = 2.0 * -0.069943 * (0.997551 * cHP * sqrt(max(1.0 - sV * sV, 0.0)) - 0.069943 * sV);
		vec3 S = vec3(hair_g(max(r2 * 1.414214 * cHP, 1e-5), sL + sV - shR) * 0.25 * cHP
			* hair_f(sqrt(clamp(0.5 + 0.5 * VoL, 0.0, 1.0))) * v_spec_mul);
		// TT: alpha 0.035, B = r^2 / 2
		float a = 1.0 / (1.19 / cosD + 0.36 * cosD);
		float h = cHP * (1.0 + a * (0.6 - 0.8 * cosPhi));
		float f = hair_f(cosD * sqrt(clamp(1.0 - h * h, 0.0, 1.0)));
		S += hair_g(0.5 * r2, sL + sV - 0.035) * exp(-3.65 * cosPhi - 3.98) * (1.0 - f) * (1.0 - f)
			* pow(BC, vec3(0.5 * sqrt(max(1.0 - h * a * h * a, 0.0)) / cosD));
		// TRT: alpha 0.14, B = 2 r^2
		f = hair_f(0.5 * cosD);
		S += hair_g(2.0 * r2, sL + sV - 0.14) * exp(17.0 * cosPhi - 16.78) * (1.0 - f) * (1.0 - f) * f
			* pow(BC, vec3(0.8 / cosD));
		// Kajiya-Kay scatter x GBufferB.x; its tint pow(BC / lum(BC), 1 - Shadow) is taken as lit (1).
		vec3 Nf = normalize(VIEW - N * dot(VIEW, N));
		S += sqrt(BC) * (1.0 / PI) * mix(clamp((dot(Nf, LIGHT) + 1.0) * 0.25, 0.0, 1.0), 1.0 - abs(sL), 0.33) * v_bx;
		float card = 1.0 - clamp(-dot(v_ncard, LIGHT), 0.0, 1.0);
		card *= card;
		SPECULAR_LIGHT += lc * max(S, vec3(0.0)) * (card * card);   // UE: Transmission (not x SpecularScale)
	} else {
		float NoLr = dot(NORMAL, LIGHT);
		float NoL = clamp(NoLr, 0.0, 1.0);
		float NoV = clamp(abs(dot(NORMAL, VIEW)) + 1e-5, 0.0, 1.0);
		vec3 H = normalize(VIEW + LIGHT);
		float NoH = clamp(dot(NORMAL, H), 0.0, 1.0);
		float VoH = clamp(dot(VIEW, H), 0.0, 1.0);
		float fc = pow(1.0 - VoH, 5.0);
		if (v_model < 0.5) {
			// SubsurfaceProfile (§4.5): Burley diffuse + two GGX lobes (R^2 "oil", R base) mixed by the oil amount
			if (NoL > 0.0) {
				float s = clamp(10.0 * v_op, 0.0, 1.0);
				float rA = mix(1.0, max(min(R * R, 1.0), 0.02), s);
				float rB = mix(1.0, max(clamp(R, 0.0, 1.0), 0.02), s);
				float rV = mix(rB, rA, v_oil);
				float F = fc + (1.0 - fc) * 0.028;                              // sat(50*0.028) = 1
				float k = 1.0 - F * v_oil;
				float spec = NoL * F * Vis_SJA(rV * rV * rV * rV, NoV, NoL)
					* (v_oil * D_GGX(rA * rA * rA * rA, NoH) + k * k * D_GGX(rB * rB * rB * rB, NoH));
				float fd90 = 0.5 + 2.0 * VoH * VoH * R;                          // Diffuse_Burley
				float diff = NoL / PI * (1.0 + (fd90 - 1.0) * pow(1.0 - NoV, 5.0)) * (1.0 + (fd90 - 1.0) * pow(1.0 - NoL, 5.0));
				DIFFUSE_LIGHT += lc * diff;
				SPECULAR_LIGHT += lc * spec * v_spec_mul * SPECULAR_AMOUNT;
			}
		} else if (v_model < 1.5) {
			// Cloth (§4.8): GGX + Charlie sheen, diffuse energy loss, ClothTranslucency back-scatter (also when NoL <= 0)
			float C = v_cloth;
			float m = v_bx;
			vec3 BC = ALBEDO;
			vec3 f0 = mix(vec3(0.04), BC * (1.0 - m * C), METALLIC);
			float a2 = max(R * R * R * R, 1e-8);
			vec3 spec1 = NoL * D_GGX(a2, NoH) * Vis_SJA(a2, NoV, NoL) * (clamp(50.0 * f0.g, 0.0, 1.0) * fc + (1.0 - fc) * f0);
			float ac = max(R, 0.08);
			float Dc = (2.0 + 1.0 / ac) * pow(max(1.0 - NoH * NoH, 0.0), 0.5 / ac) * (0.5 / PI);
			float Vc = 1.0 / (4.0 * (NoL + NoV - NoL * NoV));
			vec3 Fz = min(1.0, 50.0 * v_fuzz.g) * fc + (1.0 - fc) * v_fuzz;
			vec3 spec = mix(spec1, NoL * Dc * Vc * Fz, C);
			vec3 trans = clamp(C * m * BC, 0.0, 1.0) * (0.159155 + 2.522535 * pow(clamp(-dot(VIEW, LIGHT), 0.0, 1.0), 12.0))
				* pow(1.0 - clamp(-NoLr, 0.0, 1.0), 3.0);
			// DI2 DiffuseColor = BC*(1 - m*C)*(1 - metal); Godot applies BC*(1 - metal) itself
			vec3 diff = NoL / PI * (1.0 - m * C) * (1.0 - C * NoL * Vc * Fz) + trans / max(BC * (1.0 - METALLIC), vec3(1e-4));
			DIFFUSE_LIGHT += lc * diff;
			SPECULAR_LIGHT += lc * spec * v_spec_mul * SPECULAR_AMOUNT;     // DI2 also x sat(1 + SSAO - Cloth): not visible here
		} else if (NoL > 0.0) {
			// DefaultLit (§4.1): Lambert + GGX
			vec3 f0 = mix(vec3(0.04), ALBEDO, METALLIC);
			float a2 = max(R * R * R * R, 1e-8);
			vec3 spec = NoL * D_GGX(a2, NoH) * Vis_SJA(a2, NoV, NoL) * (clamp(50.0 * f0.g, 0.0, 1.0) * fc + (1.0 - fc) * f0);
			DIFFUSE_LIGHT += lc * NoL / PI;
			SPECULAR_LIGHT += lc * spec * v_spec_mul * SPECULAR_AMOUNT;
		}
	}
}
