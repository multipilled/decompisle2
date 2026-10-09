shader_type spatial;
// DI2 PSM_Explosion_AlphaComposite on sprite / GPU sprite particles (DI2Particles): explosions (molotov, pipe bomb,
// barrels, acid / electric bombs) and the ranged-weapon muzzle flashes. BLEND_AlphaComposite, MSM_Subsurface,
// TLM_VolumetricDirectional, TwoSided. Transcribed from DI2's decompiled base pass PS 6868 (PSMI_Explosion_07_10x10,
// PSMI_RangedWeapons_Muzzle_8x8, PSMI_Muzzleflash_8x8: Fire / Normals / Refraction / BlackBody), 7350
// (PSMI_Fire_Burst_02_8x8), 6787 (PSMI_Explosion_08_10x10 + _Massive: + Near_Camera_Fade) and 8464
// (PSMI_Explosion_08_Smoke_10x10: Fire off). GPU sprites (PS 6841) have no DynamicParameter (folded to 0: frame 0,
// no fire / multiple-scattering emissive): `gpu`.
//   flipbook: frame floor(DynamicParameter.x), blend frac, motion vectors * Offset_Magic_Number (as the smoke master);
//   N = lerp of both frames' BC5 normals, lerp to (0, 0, 1) by Normal_Flatness;
//   nf = sat((view depth - NearFade_Offset) / NearFade_Radius) (cm; 1 without Near_Camera_Fade);
//   smoke: s = lerp(smoke_f, smoke_f+1); col = sat(s.rgb^Contrast_Smoke * nf * particle rgb * fade4);
//          op = s.a^Contrast_Opacity * nf * particle a * Opacity_Boost * fade4 (transmission from it, alpha = sat);
//          fade4 = sat((max of 4 scene-depth taps at +-1/4 pixel - pixel depth) / FadeDistance);
//   fire (Fire switch): fc = lerp(fire_f, fire_f+1)^Contrast_Fire * nf; T = DynamicParameter.y * fc.r;
//          ef = BlackBody(T) * DynamicParameter.z, desaturated by sat(Desaturation_Fraction) (Fury term off),
//          * Emissive_Add_Strength * (1 - mean(fc));
//   multiple scattering: d = |pixel - (particle centre + (0, 0, MultipleScattering_ZOffset))| (cm),
//          T = MultipleScattering_Temperature * DynamicParameter.w
//              * sat((1 - d / DynamicParameter.w) / max(1 - MultipleScattering_SphereHardness, 1e-5))^MS_Contrast;
//   emissive = (BlackBody_ms + ef) * sat((scene depth - pixel depth) / FadeDistance) (1 tap) * exposure multiplier.
//   BlackBody(T) = UE's material function * (0.0004 T)^4. Exposure multiplier as di2_particle_fire (APPROXIMATED).
// Lighting: the lit-translucency tail shared with the smoke master (di2_particle_translucent.gdshaderinc).
// The Refraction switch (UE's distortion pass), SelectionColor and the Fury desaturation are not ported.
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never;

#include "res://shaders/di2_particle_translucent.gdshaderinc"

uniform sampler2D smoke_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D fire_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normals_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D motion_vector : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 sub_images = vec2(1.0);
uniform float offset_magic_number = 0.0;
uniform bool gpu = false;
uniform bool fire = true;
uniform float normal_flatness = 0.0;
uniform float fade_distance = 50.0;
uniform bool near_camera_fade = false;
uniform float near_fade_offset = 0.0;
uniform float near_fade_radius = 1.0;
uniform float contrast_smoke = 1.0;
uniform float contrast_opacity = 1.0;
uniform float contrast_fire = 1.0;
uniform float opacity_boost = 1.0;
uniform float desaturation_fraction = 0.0;
uniform float emissive_add_strength = 1.0;
uniform float ms_temperature = 0.0;
uniform float ms_hardness = 0.0;
uniform float ms_contrast = 1.0;
uniform float ms_zoffset = 0.0;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;
uniform float bright_scene_multiplier = 1.0;
uniform float dark_scene_multiplier = 1.0;
uniform float scene_exposure_blend = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;
varying vec3 v_centre;

void vertex() {
	v_color = COLOR;
	v_dyn = gpu ? vec4(0.0) : INSTANCE_CUSTOM;
	vec3 right = MODEL_MATRIX[0].xyz;
	vec3 down = MODEL_MATRIX[1].xyz;
	v_centre = MODEL_MATRIX[3].xyz;
	vec3 world = MODEL_MATRIX[3].xyz + right * VERTEX.x + down * VERTEX.y;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 n = normalize(cross(down, right));
	if (dot(n, cam - world) < 0.0) {
		n = -n;
	}
	v_t = normalize(mat3(VIEW_MATRIX) * normalize(right));
	v_b = normalize(mat3(VIEW_MATRIX) * normalize(down));
	v_n = normalize(mat3(VIEW_MATRIX) * n);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = v_n;
}

vec2 frame_uv(vec2 uv, float f) {
	return (uv + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
}

vec3 blackbody(float t) {
	vec3 a = t * vec3(0.000154118257, 0.00084242021, 4.22806261e-5) + vec3(0.860117733, 1.0, 0.317398727);
	a += t * t * vec3(1.28641219e-7, 7.08145137e-7, 4.20481676e-8);
	float u = a.x / a.y;
	float v = a.z / (1.0 - t * 2.8974182e-5 + t * t * 1.61456057e-7);
	float d = 2.0 * u - 8.0 * v + 4.0;
	float x = 3.0 * u / d;
	float y = 2.0 * v / d;
	vec3 xyz = vec3(x / y, 1.0, (1.0 - x - y) / y);
	vec3 rgb = vec3(dot(vec3(3.2404542, -1.53713846, -0.498531401), xyz),
			dot(vec3(-0.969265997, 1.87601078, 0.0415560007), xyz),
			dot(vec3(0.0556433983, -0.204025894, 1.05722523), xyz));
	float k = 0.0004 * t;
	k *= k;
	return rgb * k * k;
}

float scene_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 sp = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -sp.z / sp.w;
}

void fragment() {
	float blend = fract(v_dyn.x);
	float f0 = v_dyn.x - blend;
	vec2 uv0 = frame_uv(UV, f0);
	vec2 uv1 = frame_uv(UV, f0 + 1.0);
	uv0 -= (texture(motion_vector, uv0).xy * 2.0 - 1.0) * blend * offset_magic_number;
	uv1 += (texture(motion_vector, uv1).xy * 2.0 - 1.0) * (1.0 - blend) * offset_magic_number;
	vec3 tn = mix(di2_bc5(texture(normals_tex, uv0).xy), di2_bc5(texture(normals_tex, uv1).xy), blend);
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normal_flatness));
	vec3 N = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	float pixel_depth = -VERTEX.z;
	float nf = near_camera_fade ? clamp((pixel_depth * 100.0 - near_fade_offset) / max(near_fade_radius, 1e-5), 0.0, 1.0) : 1.0;
	// emissive: 1-tap depth fade
	float fade1 = clamp((scene_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - pixel_depth) * 100.0 / max(fade_distance, 1e-5), 0.0, 1.0);
	vec3 e = vec3(0.0);
	if (fire) {
		vec3 wg = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec3 c_ue = vec3(v_centre.x, v_centre.z, v_centre.y) * 100.0 + vec3(0.0, 0.0, ms_zoffset);
		float d = length(vec3(wg.x, wg.z, wg.y) * 100.0 - c_ue);
		float s = clamp((1.0 - d / max(v_dyn.w, 1e-5)) / max(1.0 - ms_hardness, 1e-5), 0.0, 1.0);
		float tms = ms_temperature * v_dyn.w * pow(max(s, 1e-6), ms_contrast);
		vec3 fc = pow(max(mix(texture(fire_tex, uv0).rgb, texture(fire_tex, uv1).rgb, blend), vec3(1e-6)), vec3(contrast_fire)) * nf;
		vec3 ef = blackbody(v_dyn.y * fc.r) * v_dyn.z;
		ef = mix(ef, vec3(dot(ef, vec3(0.3, 0.59, 0.11))), clamp(desaturation_fraction, 0.0, 1.0));
		ef *= emissive_add_strength * (1.0 - dot(fc, vec3(0.33333)));
		e = (blackbody(tms) + ef) * fade1 * mix(bright_scene_multiplier, dark_scene_multiplier, scene_exposure_blend);
	}
	// smoke: 4-tap max depth fade at +-1/4 pixel (diagonals)
	vec2 dx = dFdx(SCREEN_UV) * 0.25;
	vec2 dy = dFdy(SCREEN_UV) * 0.25;
	float sd = max(max(scene_depth(SCREEN_UV - dx - dy, INV_PROJECTION_MATRIX), scene_depth(SCREEN_UV + dx - dy, INV_PROJECTION_MATRIX)),
			max(scene_depth(SCREEN_UV - dx + dy, INV_PROJECTION_MATRIX), scene_depth(SCREEN_UV + dx + dy, INV_PROJECTION_MATRIX)));
	float fade4 = clamp((sd - pixel_depth) * 100.0 / max(fade_distance, 1e-5), 0.0, 1.0);
	vec4 s4 = max(mix(texture(smoke_tex, uv0), texture(smoke_tex, uv1), blend), vec4(1e-6));
	vec3 col = clamp(pow(s4.rgb, vec3(contrast_smoke)) * nf * v_color.rgb * fade4, 0.0, 1.0);
	float op_raw = pow(s4.a, contrast_opacity) * nf * v_color.a * opacity_boost * fade4;
	float op = clamp(op_raw, 0.0, 1.0);
	float trans = di2_transmission(op_raw, opacity_to_transmission, min_transmission, max_transmission);
	ALBEDO = di2_absorbed(col, trans, op, absorption_density);
	EMISSION = max(e, vec3(0.0));
	ALPHA = op;
	NORMAL = N;
	BACKLIGHT = vec3(trans);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
