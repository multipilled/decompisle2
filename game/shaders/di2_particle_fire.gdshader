shader_type spatial;
// DI2 PSM_Fire_AlphaComposite on sprite particles (DI2Particles). BLEND_AlphaComposite, MSM_Unlit. Transcribed from
// DI2's decompiled base pass PS 6748 (PSMI_Fire_02_8x8) and 12292 (PSMI_Flames_Whispy_InvertedFade01_8x8,
// UsesContactOpacity); both MIs have Emissive_Add and Motion_Vectors_Switch on.
//   flipbook: frame = floor(DynamicParameter.x), blend = frac; uv_f = (UV + (f mod U, floor(f / U))) / (U, V);
//   frame f pushed by -(2 MV - 1) * blend * Offset_Magic_Number, frame f + 1 by +(2 MV - 1) * (1 - blend) * OMN;
//   c = lerp(tex_f, tex_f+1, blend).rgb; cc = max(c, 1e-6)^Contrast_Color;
//   D = scene depth - pixel depth (cm); T = sat(D / PreBlackbody_DepthFade) * cc.r * DynamicParameter.y;
//   e = BlackBody(T) * (0.0004 T)^4 * particle rgb, desaturated by Desaturation_Fraction (Fury term off);
//   e *= Emissive_Add_Strength * (1 - mean(cc)) * sat(D / FadeDistance) [* contact] * exposure multiplier;
//   opacity: Fire_02 = sat(sat(D / FadeDistance) * Opacity_Boost * particle a * c.r^Contrast_Opacity);
//            UsesContactOpacity = sat(Opacity_Boost * particle a * c.r^Contrast_Opacity) * fade * contact,
//            contact = 1 - sat(D / ContactFadeDistance).
// Exposure multiplier = lerp(Bright, Dark Scene Multiplier, sat((X - Tb) / (Td - Tb))) / X (View[152].y, thresholds
// from MPC_Postprocess_Player), then * PreExposure: Godot uses PreExposure / X = 1 and scene_exposure_blend
// (0 = bright scene) like di2_particle_electric_distortion (APPROXIMATED, recon/PARTICLES.md 4.3).
// PS 7564 (Fire_Burst_01: Normals / Refraction) and 10019 (GroundFlames: WorldHeight_Falloff) add terms that are
// not transcribed (they use this shader without them).
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D spritesheet : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D motion_vector : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 sub_images = vec2(1.0);
uniform bool use_motion_vectors = true;
uniform float offset_magic_number = 0.0;
uniform float contrast_color = 1.0;
uniform float preblackbody_depthfade = 1.0;
uniform float desaturation_fraction = 0.0;
uniform float emissive_add_strength = 1.0;
uniform float fade_distance = 1.0;
uniform bool uses_contact_opacity = false;
uniform float contact_fade_distance = 1.0;
uniform float contrast_opacity = 1.0;
uniform float opacity_boost = 1.0;
uniform float bright_scene_multiplier = 1.0;
uniform float dark_scene_multiplier = 1.0;
uniform float scene_exposure_blend = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

vec2 frame_uv(vec2 uv, float f) {
	// HLSL fmod of a non-negative frame = mod
	return (uv + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
}

// UE Engine/Functions/Engine_MaterialFunctions01/Shading/BlackBody (as compiled in PS 12292)
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

void fragment() {
	float blend = fract(v_dyn.x);
	float f0 = v_dyn.x - blend;
	vec2 uv0 = frame_uv(UV, f0);
	vec2 uv1 = frame_uv(UV, f0 + 1.0);
	if (use_motion_vectors) {
		uv0 -= (texture(motion_vector, uv0).xy * 2.0 - 1.0) * blend * offset_magic_number;
		uv1 += (texture(motion_vector, uv1).xy * 2.0 - 1.0) * (1.0 - blend) * offset_magic_number;
	}
	vec3 c = max(mix(texture(spritesheet, uv0).rgb, texture(spritesheet, uv1).rgb, blend), vec3(1e-6));
	vec3 cc = pow(c, vec3(contrast_color));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float D = ((-sp.z / sp.w) - (-VERTEX.z)) * 100.0;
	float T = clamp(D / max(preblackbody_depthfade, 1e-5), 0.0, 1.0) * cc.r * v_dyn.y;
	vec3 e = blackbody(T) * v_color.rgb;
	e = mix(e, vec3(dot(e, vec3(0.3, 0.59, 0.11))), clamp(desaturation_fraction, 0.0, 1.0));
	float fade = clamp(D / max(fade_distance, 1e-5), 0.0, 1.0);
	float contact = uses_contact_opacity ? 1.0 - clamp(D / max(contact_fade_distance, 1e-5), 0.0, 1.0) : 1.0;
	e *= emissive_add_strength * (1.0 - dot(cc, vec3(0.33333))) * fade * contact;
	e *= mix(bright_scene_multiplier, dark_scene_multiplier, scene_exposure_blend);
	float o = opacity_boost * v_color.a * pow(c.r, contrast_opacity);
	ALBEDO = max(e, vec3(0.0));
	ALPHA = uses_contact_opacity ? clamp(o, 0.0, 1.0) * fade * contact : clamp(fade * o, 0.0, 1.0);
}
