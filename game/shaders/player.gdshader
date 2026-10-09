// Dani (DI2 FemBerserker) first-person materials: a transcription of DI2's decompiled base-pass pixel shaders.
// Source of every formula: recon/DANI.md section 4 (decompiled HLSL in extracted/shaders/annotated/DeadIsland_*_DaniPS_*).
// Data (textures, scalars, vectors, MPC values) comes from game/data/dani_materials.json via game/scripts/dani_visual.gd.
//   variant 0 skin_staged_veinmap    PS 9326  (MI_FemBerserkerFPHandR/L: M_Skin, Staged Splatter Mode, Zombie Veins + vein normal map)
//   variant 1 skin_staged_cheapveins PS 12717 (MI_FemBerserkerSkin/SkinArmL: + Enable Cheap Zombie Veins Effect)
//   variant 2 skin                   PS 5740  (MI_FemBerserkerBandFP/BandCardsFP: M_Skin default permutation)
//   variant 3 cloth                  PS 4452  (MI_FemBerserkerUpper/LowerBody, FPBracelet: M_Clothing + Detail Mapping)
//   variant 4 cloth_staged           PS 9445  (MI_FemBerserkerFPGlove: M_Clothing, Staged Splatter Mode)
// Terms that are exactly zero for the player in normal play are left out and listed in recon/DANI.md 4.6: landscape RVT blend
// (LandscapeBlend 0), frost (Freeze Amount 0), selection emissive (SelectionColor 0), the character fade dither (fully shown).
// Two-sided materials are built from this file at runtime with cull_disabled (dani_visual.gd); the code handles both.
// light() is DI2's own light pass (FDeferredLightPS, recon/DEFERRED_LIGHTING.md): dual-lobe "oil" skin with Burley
// diffuse and F0 0.028, Charlie cloth with ClothTranslucency back-scatter, specular x 2*S' from the GBuffer byte.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, sss_mode_skin;

// --- textures (sRGB only where DI2's texture asset is sRGB: the _D maps) -------------------------------------------
// DI2 samples almost everything through the shared View material sampler (s0, wrap); the few own-sampler taps are noted.
uniform sampler2D tex_diffuse : source_color, filter_linear_mipmap_anisotropic, repeat_enable;      // Diffuse Colour Map
uniform sampler2D tex_normal : filter_linear_mipmap_anisotropic, repeat_enable;                     // Normal Map (BC5)
uniform sampler2D tex_mro : filter_linear_mipmap_anisotropic, repeat_enable;                        // Packed MRO Map
uniform sampler2D tex_ata : filter_linear_mipmap_anisotropic, repeat_enable;                        // Packed ATA Map
uniform sampler2D tex_detail_normal : filter_linear_mipmap_anisotropic, repeat_enable;              // Detail Normal Map
uniform sampler2D tex_detail_rough : filter_linear_mipmap_anisotropic, repeat_enable;               // Detail Roughness / DRO Map (.g)
uniform sampler2D tex_veins_normal : filter_linear_mipmap_anisotropic, repeat_enable;               // Zombie Veins Normal Map (variant 0)
uniform sampler2D tex_staged_blood : filter_linear_mipmap_anisotropic, repeat_enable;               // Staged Blood Map (component-driven)
uniform sampler2D tex_cutscene_blood : filter_linear_mipmap_anisotropic, repeat_enable;             // CutScene Blood Map
uniform sampler3D tex_noise3d : filter_linear, repeat_enable;                                       // TV_Global3dNoise (own sampler, wrap)

uniform int variant = 0;
uniform float mip_bias = 0.0;            // View.MaterialTextureMipBias (0 at default settings)

// --- M_Skin / M_Clothing parameters (resolved per section through the MI chain; names = DI2 parameter names) ----------
uniform float detail_tiling = 22.0;                  // Detail Tiling
uniform float detail_normal_strength = 1.0;          // Detail Normal Strength
uniform float detail_roughness_strength = 1.0;       // Detail Roughness Strength
uniform float roughness_adjustment = 0.0;            // Roughness Adjustment
uniform float specular_occlusion_power = 1.0;        // Specular Occlusion Power
uniform float desaturation = 0.0;                    // Desaturation
uniform vec3 colour_tint = vec3(1.0);                // Colour Tint (skin) / Cloth Colour Tint (cloth)
uniform float translucency_adjustment = 0.0;         // Translucency Adjustment (variant 2)
uniform float base_sss = 0.9;                        // Base Subsurface Scattering
uniform float vein_sss = 1.0;                        // Vein Subsurface Scattering
// veins (variants 0/1); off while ZombieVeinBlendWeight = 0 (CE_Player_Autophage drives it, recon/DANI.md 5.4)
uniform float zombie_vein_blend_weight = 0.0;        // ZombieVeinBlendWeight
uniform float zombie_veins_cinematic = 0.0;          // MPC_GameWideParams.ZombieVeinsCinematic
uniform float larger_veins_move_less = 0.4;
uniform vec3 distortion_noise_speed = vec3(-0.2, -0.2, 0.0);
uniform float distortion_noise_scale = 0.09;
uniform vec4 distortion_mix_n = vec4(0.0);           // preshader V7 of 'Distortion Noise Channel Mix' (dani_visual.gd)
uniform vec3 pulse_noise_speed = vec3(-0.35, 0.0, 0.0);
uniform float pulse_noise_scale = 0.015;
uniform vec4 pulse_mix_n = vec4(0.0);                // preshader V14 of 'Pulse Noise Channel Mix'
uniform float pulse_range_min = 0.0;
uniform float pulse_range_max = 1.0;
uniform float min_uv_distortion = 0.005;
uniform float max_uv_distortion = 0.01;
uniform float freeze_amount = 0.0;
uniform float vein_skin_distort_falloff = 0.14;
uniform float distortion_affects_vein_intensity = 0.3;
uniform float vein_intensity_min = 0.3;
uniform float vein_intensity_max = 1.0;
uniform float vein_base_normals_distort = 0.6;
uniform float vein_skin_distort = 1.0;
uniform float vein_base_normal_flatten_power = 0.1;  // variant 1 only
uniform float veins_normal_strength = 2.0;           // Veins Normal Strength x Aggressive Veins Normal
uniform float vein_mask_erode = 3.0;
uniform float blendweight_normals_curve = 2.5;
uniform vec3 veins_blood_colour = vec3(0.75, 0.454687, 0.433594);
uniform float veins_blood_density = 10.0;            // Veins Blood Density x Aggressive Veins Density
uniform float vein_roughness = 0.45;
// staged blood (variants 0/1/4); MPC_CharacterGameWideParams StagedSplatter* and the component's phase
uniform float splatter_animation_phase = 0.5;        // Splatter Animation Phase (PlayerHandsMaterialComponent flow animation)
uniform float staged_metal_blend_pow = 1.0;          // StagedSplatterMetalBlendPow
uniform float staged_blood_density = 6.0;
uniform float staged_normals_blend_threshold = 4.0;
uniform float staged_normals_jitter = 0.0035;
uniform float staged_normals_strength = 2.0;
uniform float staged_edge_contrast = 10.0;
uniform float staged_dried_cavity_power = 0.6;
uniform float cutscene_hand_blood = 0.0;             // MPC CutSceneHandBloodSplatter
// cloth (variants 3/4)
uniform float force_cloth = 0.0;
uniform float cloth_translucency = 0.25;
uniform float sheen_averaging = 0.38;
uniform float sheen_desaturation = 0.1;
uniform float sheen_multiplier = 1.4;
uniform float fury_death_desaturation_override = 0.0;
// Fury post look (DI2 View[225].y, 0 outside Fury mode) and MPC Fury values
uniform float fury_view = 0.0;
uniform vec3 fury_tint = vec3(1.0);
uniform float fury_skin_red_isolation = 2.0;
uniform float fury_skin_red_desat = 0.0;
uniform float fury_skin_nonred_desat = 1.0;
uniform float fury_cloth_nonred_desat = 1.0;
// masked opacity
uniform float clip_value = 0.1;                      // OpacityMaskClipValue
// subsurface profile -> Godot screen-space SSS (recon/DANI.md 4.5: approximation, Godot has no Burley/separable profile)
uniform float sss_radius_m = 0.0005;                 // Burley: MeanFreePathDistance x WorldUnitScale cm; separable: ScatterRadius cm (/100)
uniform float godot_sss_scale = 0.05;                // ProjectSettings subsurface_scattering_scale

varying vec3 v_bind;     // UE bind-pose position (cm, UE axes) = TEXCOORD2.xy/3.x (CUSTOM0, written by dani_visual.gd)
varying float v_model;    // 0 MSM_SubsurfaceProfile (M_Skin), 1 MSM_Cloth (M_Clothing)
varying float v_rough;    // GBuffer roughness (ROUGHNESS carries the reflection-pass roughness on cloth)
varying float v_spec_mul; // 2*S': DI2's specular intensity from the GBuffer specular byte
varying float v_oil;      // skin: GBufferB.x lobe mix ("Oil Layer")
varying float v_op;       // skin: subsurface opacity (CustomData.a)
varying float v_cloth;    // cloth: 'Cloth' amount
varying float v_bx;       // cloth: GBufferB.x = min(0.99, lerp(Metallic, ClothTranslucency, Cloth))
varying vec3 v_fuzz;      // cloth: fuzz (sheen) colour, linear

void vertex() {
	v_bind = CUSTOM0.xyz;
}

float sat(float x) { return clamp(x, 0.0, 1.0); }
float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }
float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 unpack_n(vec2 xy) { xy = xy * 2.0 - 1.0; return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy)))); }
// UE BlendAngleCorrectedNormals as compiled: b' = (b.xy, b.z + 1), d' = (-d.xy, d.z); b' * dot(b', d') - d' * b'.z
vec3 rnm(vec3 b, vec3 d) {
	vec3 bb = vec3(b.xy, b.z + 1.0);
	vec3 dd = vec3(-d.xy, d.z);
	return bb * dot(bb, dd) - dd * bb.z;
}
float staged_step(float g, float ph) { return sat((g + ph - 0.5) * staged_edge_contrast + 0.5); }
// One staged map's height normal (4 taps at +-jitter) and its centre tap; PS 9326 lines 219-261 / 262-295.
vec3 staged_normal(sampler2D t, vec2 uv, float ph, out vec3 s0, out float m0) {
	s0 = texture(t, uv).xyz;
	m0 = staged_step(s0.g, ph);
	float h0 = s0.r * m0;
	float j = staged_normals_jitter;
	vec2 a = texture(t, uv + vec2(j, 0.0)).rg;
	vec2 b = texture(t, uv + vec2(0.0, j)).rg;
	vec2 c = texture(t, uv - vec2(j, 0.0)).rg;
	vec2 d = texture(t, uv - vec2(0.0, j)).rg;
	float ha = a.r * staged_step(a.g, ph) - h0, hb = b.r * staged_step(b.g, ph) - h0;
	float hc = c.r * staged_step(c.g, ph) - h0, hd = d.r * staged_step(d.g, ph) - h0;
	return vec3(staged_normals_strength * (hc - ha), staged_normals_strength * (hd - hb), 2.0);
}

void fragment() {
	// UE-equivalent tangent frame (view space): Godot flips only NORMAL on back faces; its BINORMAL is the mirror of
	// UE's (verified on the cooked tangents, recon/DANI.md 4.2) -> B_ue = -BINORMAL.
	vec3 Nv = normalize(FRONT_FACING ? NORMAL : -NORMAL);
	vec3 Tv = normalize(TANGENT);
	vec3 Bv = -normalize(BINORMAL);
	vec2 uv0 = UV;
	vec2 uv1 = UV;           // TEXCOORD1: SK_FemBerserkerFP has one UV channel; the skin VF repeats the last one [engine]
	vec4 vc = COLOR;
	float vis = sat(vc.g);   // sat(Color.g + (Deform.w >= 0.001)); the player's deform depth is 0
	bool skin = variant <= 2;
	bool staged = variant <= 1 || variant == 4;
	vec3 ata = texture(tex_ata, uv0).xyz;

	// --- zombie veins: distortion + pulse noise (PS 9326 lines 121-155, PS 12717 same) -------------------------------
	float vblend = 0.0, vmask = 0.0, vint = 0.0;
	vec2 uv_a = uv0, uv_b = uv0, uv_vein = uv0;
	float hvein = 1.0;
	if (variant <= 1) {
		float pulse_move = 1.0 - ata.g * larger_veins_move_less;
		vec4 n1 = texture(tex_noise3d, v_bind * distortion_noise_scale + fract(distortion_noise_speed * TIME));
		float dn = (dot(n1, distortion_mix_n) - 0.5) * 2.0;
		vec4 n2 = texture(tex_noise3d, v_bind * pulse_noise_scale + fract(pulse_noise_speed * TIME));
		float pn = sat((dot(n2, pulse_mix_n) - pulse_range_min) / (pulse_range_max - pulse_range_min));
		float dist = mix(min_uv_distortion * (1.0 - freeze_amount), max_uv_distortion * (1.0 - freeze_amount), pn) * vc.r * dn;
		uv_vein = (variant == 0 ? uv1 : uv0) + pulse_move * dist;
		hvein = max(1e-6, texture(tex_ata, uv_vein, mip_bias).g);       // own sampler + SampleBias
		vint = mix(vein_intensity_min, vein_intensity_max, dn * distortion_affects_vein_intensity + pn);
		float w = dist * pulse_move * vint * zombie_vein_blend_weight * pw(hvein, vein_skin_distort_falloff);
		uv_a = uv0 + w * vein_base_normals_distort;
		uv_b = uv0 + w * vein_skin_distort;
		vmask = sat(vint * pw(hvein, vein_mask_erode));
		vblend = sat(sat(zombie_veins_cinematic) + zombie_vein_blend_weight);
	}

	// --- base + detail normal ----------------------------------------------------------------------------------------
	vec2 duv = detail_tiling * uv_b;
	vec3 nb = unpack_n(texture(tex_normal, uv_a).rg);
	if (variant == 1) {
		nb = mix(nb, vec3(0.0, 0.0, 1.0), pw(ata.g, vein_base_normal_flatten_power));   // PS 12717 lines 158-164
	}
	vec3 dn3 = unpack_n(texture(tex_detail_normal, duv).rg);
	vec3 n = rnm(nb, mix(vec3(0.0, 0.0, 1.0), dn3, detail_normal_strength * ata.b));

	// --- vein normal ---------------------------------------------------------------------------------------------------
	if (variant == 0) {
		// derivative (cotangent) frame of the vein UV, PS 9326 lines 178-210. The cross products are taken in the
		// opposite order to UE's because the Godot mesh is the (x,z,y) mirror of UE's (cross(Ma,Mb) = -M cross(a,b)).
		vec3 dpx = dFdx(VERTEX), dpy = dFdy(VERTEX);
		vec2 dux = dFdx(uv_vein), duy = dFdy(uv_vein);
		vec3 r1 = cross(Nv, dpy);
		vec3 r2 = cross(dpx, Nv);
		vec3 tt = r1 * dux.x + r2 * duy.x;
		vec3 bb = r1 * dux.y + r2 * duy.y;
		float inv = inversesqrt(max(max(dot(tt, tt), dot(bb, bb)), 1e-30));
		vec3 nv = unpack_n(texture(tex_veins_normal, uv_vein, mip_bias).rg);
		vec3 wv = tt * inv * nv.x + bb * inv * nv.y + Nv * nv.z;
		vec3 ts = vec3(dot(Tv, wv), dot(Bv, wv), dot(Nv, wv));
		n = mix(n, (ts - vec3(0.0, 0.0, 1.0)) * veins_normal_strength + vec3(0.0, 0.0, 1.0), vblend * vmask);
	} else if (variant == 1) {
		vec3 nv = unpack_n(texture(tex_normal, uv_vein, mip_bias).rg);                    // cheap veins: base map, own sampler
		n = mix(n, mix(vec3(0.0, 0.0, 1.0), nv, veins_normal_strength), vblend * vmask);
	}

	// --- staged blood (PlayerHandsMaterialComponent textures) -----------------------------------------------------------
	float c0 = 0.5 - 0.5 / staged_edge_contrast;
	float ph = splatter_animation_phase * (c0 + c0) - c0;
	float amt = 0.0, dried = 0.0, m = 0.0, cav = 0.0;
	if (staged) {
		vec3 s0; float m0;
		vec3 c0v; float mc;
		vec3 ns = staged_normal(tex_staged_blood, uv0, ph, s0, m0);
		vec3 nc = staged_normal(tex_cutscene_blood, uv0, ph, c0v, mc);
		float sel = (abs(cutscene_hand_blood) > 1e-5 && cutscene_hand_blood >= 0.0) ? 1.0 : 0.0;
		cav = max(0.0, 1.0 - abs(n.z / length(n)));
		vec2 rb = mix(s0.rb, c0v.rb, sel);
		amt = rb.x; dried = rb.y;
		m = mix(m0, mc, sel);
		n = mix(n, mix(ns, nc, sel), sat(staged_normals_blend_threshold * (amt + cav) * m));
	}
	float blood = pw(dried, staged_dried_cavity_power) * cav + dried + (amt + cav) * m;
	vec3 absorb = staged ? min(vec3(1.0), exp2(vec3(-0.321928, -3.321928, -4.321928) * (staged_blood_density * blood))) : vec3(1.0);

	// --- world normal (UE TransformTangentNormalToWorld; M_Clothing then flips world XY on back faces) ----------------
	vec3 N = n.x * Tv + n.y * Bv + n.z * Nv;
	if (variant >= 3 && !FRONT_FACING) {
		vec3 nw = (INV_VIEW_MATRIX * vec4(N, 0.0)).xyz;    // UE world XY (horizontal) = Godot world XZ
		nw.xz = -nw.xz;
		N = (VIEW_MATRIX * vec4(nw, 0.0)).xyz;
	}
	NORMAL = normalize(N);

	vec3 base;
	float metallic, rough, spec, alpha, cloth = 0.0, sss = 0.0, bx = 0.0;   // skin: metallic = the oil amount
	vec3 fuzz = vec3(0.0);
	if (skin) {
		// --- M_Skin (PS 9326 / 12717 lines 494-575, PS 5740) ----------------------------------------------------------
		vec2 uvs = uv_b;
		vec3 mro = texture(tex_mro, uvs).xyz;
		spec = 0.5 * pw(mro.z, specular_occlusion_power);
		metallic = staged ? mro.x * pw(absorb.r, staged_metal_blend_pow) : mro.x;
		vec3 d = texture(tex_diffuse, uvs).rgb;
		d = mix(d, vec3(lum(d)), desaturation);
		vec3 c = colour_tint * d;
		vec3 cc = max(vec3(1e-6), c);
		float red = sat((min(cc.r / cc.g, cc.r / cc.b) - 1.0) / fury_skin_red_isolation) * (fury_skin_red_desat - fury_skin_nonred_desat);
		rough = sat(roughness_adjustment + mro.y + detail_roughness_strength * ata.b * (texture(tex_detail_rough, duv).g - 0.5));
		float fd = sat(red * sat(-10.0 * (rough - 0.4)) + fury_skin_nonred_desat);
		c = mix(c, mix(c, vec3(lum(c)), fd) * fury_tint, fury_view);
		float vcol = pw(vblend, blendweight_normals_curve) * vmask;
		if (variant <= 1) {
			c *= min(vec3(1.0), exp2(log2(veins_blood_colour) * (veins_blood_density * vcol)));
			rough = mix(rough, vein_roughness, vcol);
			rough = sat(rough * (1.0 - sat(m + dried)));
			sss = mix(base_sss, vein_sss, vcol);
		} else {
			sss = sat(mro.z * sat(translucency_adjustment + ata.g));
		}
		base = clamp(min(max(c * absorb, vec3(0.018 * spec)), vec3(metallic * 0.125 + 0.875)), 0.0, 1.0);
		alpha = ata.r * vis;
	} else {
		// --- M_Clothing, MSM_Cloth (PS 4452 lines 380-470, PS 9445 lines 410-480) ----------------------------------------
		vec2 mr = texture(tex_mro, uv0).xy;
		cloth = sat(force_cloth + ata.g);
		float mclo = mix(sat(mr.x), cloth_translucency, cloth);          // GBufferB.x: metallic, translucency where cloth
		if (staged) {
			mclo *= pw(absorb.r, staged_metal_blend_pow);
		}
		vec3 tint = mix(vec3(1.0), colour_tint, cloth);
		vec3 d = texture(tex_diffuse, uv0).rgb;
		vec3 c = d * tint;
		float fd = sat(sat(fury_cloth_nonred_desat) + fury_death_desaturation_override);
		if (variant == 3) {
			c = mix(c, mix(c, vec3(lum(c)), fd) * fury_tint, fury_view);
		}
		base = clamp(min(max(c * absorb, vec3(0.009)), vec3(mclo * 0.125 + 0.875)), 0.0, 1.0);
		rough = sat(mr.y + detail_roughness_strength * ata.b * (texture(tex_detail_rough, duv).g - 0.5) + roughness_adjustment);
		if (staged) {
			rough = sat(rough * (1.0 - sat(m + dried)));
		}
		// fuzz colour from the diffuse's last mip (SampleLevel 16 = the average colour)
		vec3 s = mix(c, textureLod(tex_diffuse, uv0, 16.0).rgb * tint, sheen_averaging);
		s = clamp(sheen_multiplier * mix(s, vec3(lum(s)), sheen_desaturation), 0.0, 1.0);
		if (variant == 3) {
			s = mix(s, mix(s, vec3(lum(s)), fd) * fury_tint, fury_view);
		}
		fuzz = s * absorb;
		// DI2 packs ClothTranslucency into the metallic slot (B.x); the light pass uses metal = B.x*(1 - Cloth)
		bx = min(0.99, mclo);
		metallic = bx * (1.0 - cloth);
		spec = 0.5;              // no Specular input: GBuffer specular is DI2's encoding of the 0.5 default
		alpha = ata.r;
	}

	// --- GBuffer -> DI2 light pass (recon/DEFERRED_LIGHTING.md §2, §4.5, §4.8) ----------------------------------------
	// Specular byte = flag + 7-bit intensity: the light and reflection passes scale all specular by 2*S' (<= 0.992).
	float spec_mul = sat(min(round(255.0 * min(0.5, spec)), 126.0) * (512.0 / 65025.0));
	ALBEDO = base;
	v_model = skin ? 0.0 : 1.0;
	v_rough = rough;
	v_spec_mul = spec_mul;
	v_fuzz = fuzz;
	v_cloth = cloth;
	float nov = abs(dot(NORMAL, VIEW));
	if (skin) {
		// MSM_SubsurfaceProfile: GBufferB.x is the "Oil Layer" lobe mix (sat('Debug Oil Layer' + M*absorb^pow)), not metal;
		// metallic is forced to 0 and F0 fixed at 0.028.
		METALLIC = 0.0;
		v_oil = sat(metallic);
		v_op = sss;
		ROUGHNESS = rough;
		// Godot's ambient dielectric F0 = 0.16*SPECULAR^2: F0 0.028 with DI2's 2*S' reflection multiplier folded in
		// (exact on the F0 term; recon/DANI.md 4.5). DI2's second (oil) reflection lobe is not ported.
		SPECULAR = sqrt(0.028 * spec_mul / 0.16);
		// Subsurface profile -> Godot screen-space SSS: world radius onto the kernel, gated like DI2's recombine sat(10*op)
		float depth = max(-VERTEX.z, 0.01);
		float uv_radius = sss_radius_m * PROJECTION_MATRIX[0][0] / (2.0 * depth);
		SSS_STRENGTH = sat(10.0 * sss) * uv_radius / godot_sss_scale;
	} else {
		// MSM_Cloth: GBufferB.x = min(0.99, lerp(M, ClothTranslucency, Cloth)); metal = B.x*(1 - Cloth); F0 base 0.04.
		v_bx = bx;
		METALLIC = metallic;
		// reflection pass: roughness -> 0.1 on full cloth, reflection x (1 - |NoV|*Cloth) x 2*S' (folded into F0)
		ROUGHNESS = mix(rough, 0.1, sat((cloth - 0.9) * 10.0));
		SPECULAR = sqrt(0.04 * spec_mul * (1.0 - nov * cloth) / 0.16);
	}
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = clip_value;
}

float D_GGX(float a2, float NoH) { float d = (NoH * a2 - NoH) * NoH + 1.0; return a2 / (PI * d * d); }
float Vis_SJA(float a2, float NoV, float NoL) {
	float a = sqrt(a2);
	return 0.5 / (NoL * (NoV * (1.0 - a) + a) + NoV * (NoL * (1.0 - a) + a));
}

// DI2's FDeferredLightPS BxDFs for punctual lights (recon/DEFERRED_LIGHTING.md §4.5 skin, §4.8 cloth; decompiled from
// Global 2075 p1). Godot multiplies DIFFUSE_LIGHT by ALBEDO * (1 - METALLIC) afterwards and LIGHT_COLOR carries PI;
// ATTENUATION holds the shadow (DI2 lights cloth transmission with the surface shadow too).
void light() {
	float NoLr = dot(NORMAL, LIGHT);
	float NoL = clamp(NoLr, 0.0, 1.0);
	float NoV = clamp(abs(dot(NORMAL, VIEW)) + 1e-5, 0.0, 1.0);
	vec3 H = normalize(VIEW + LIGHT);
	float NoH = clamp(dot(NORMAL, H), 0.0, 1.0);
	float VoH = clamp(dot(VIEW, H), 0.0, 1.0);
	float fc = pow(1.0 - VoH, 5.0);
	float R = v_rough;
	vec3 lc = LIGHT_COLOR * ATTENUATION;
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
	} else {
		// Cloth (§4.8): GGX + Charlie sheen, diffuse energy loss, ClothTranslucency back-scatter transmission
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
	}
}
