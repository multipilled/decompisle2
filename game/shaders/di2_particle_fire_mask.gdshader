shader_type spatial;
// DI2 PSM_Fire_OpacityMask on sprite / GPU sprite particles (DI2Particles). BLEND_AlphaComposite, MSM_Unlit.
// Transcribed from DI2's decompiled base pass PS 6901 (FParticleSpriteVertexFactory) and PS 6894
// (FGPUSpriteVertexFactory); every MI on this master compiles to them (PSMI_Turbulent_FlamesFuel_Masked_16x8 /
// _Flames_Masked_16x8 shader map 805595B1, PSMI_FlamesMasked_Whispy_8x8 AAB2ED53). The burning-petrol flames.
//   flipbook: as PSM_Fire_AlphaComposite (frame floor(DynamicParameter.x), blend frac, motion vectors * OMN);
//   c = max(lerp(tex_f, tex_f+1, blend).rgb, 1e-6); cc = c^Contrast_Color;
//   bb = BlackBody(BlackBodyBias * DynamicParameter.y) * (0.0004 T)^4;
//   fuel = (1 - sat((1 - (particle z - pixel z)) / FuelHeightFalloff)^0.8) * max(0, 0.8 (1 - cc.r) + 0.1)
//          (z in cm, pixel = the sprite fragment's own world position, particle = PARTICLE_POSITION);
//   e = lerp(bb, FuelColor, UsesFuel * fuel) * particle rgb * Emissive_Add_Strength * (1 - mean(cc));
//   e *= lerp(sat(e), luma(sat(e)), sat(Desaturation_Fraction)) (Fury term off) * exposure multiplier;
//   op = c^Contrast_Opacity * particle a * Opacity_Boost (a vector); fade = sat((scene depth - pixel depth) / 30 cm);
//   out rgb = e * op * fade, alpha = sat(op.r * fade). SelectionColor (editor) and the Fury desaturation dropped;
//   height fog / translucency-volume fog terms after it are left to Godot.
// GPU sprites (PS 6894) have no DynamicParameter: the compiler folds it to 0, so frame 0 (UV / SubImages), no
// motion-vector offset, and BlackBody(0) = 0 (only the fuel colour emits): `gpu` reproduces that.
// Exposure multiplier as di2_particle_fire (scene_exposure_blend, APPROXIMATED, recon/PARTICLES.md 4.3).
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D spritesheet : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D motion_vector : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 sub_images = vec2(1.0);
uniform bool use_motion_vectors = true;
uniform bool gpu = false;
uniform float offset_magic_number = 0.0;
uniform float contrast_color = 1.0;
uniform float contrast_opacity = 1.0;
uniform float opacity_boost = 1.0;
uniform float blackbody_bias = 1.0;
uniform float desaturation_fraction = 0.0;
uniform float emissive_add_strength = 1.0;
uniform float uses_fuel = 0.0;
uniform vec3 fuel_color = vec3(0.0);
uniform float fuel_height_falloff = 1.0;
uniform float bright_scene_multiplier = 1.0;
uniform float dark_scene_multiplier = 1.0;
uniform float scene_exposure_blend = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying float v_pz;

void vertex() {
	v_color = COLOR;
	v_dyn = gpu ? vec4(0.0) : INSTANCE_CUSTOM;
	v_pz = MODEL_MATRIX[3].y * 100.0;  // particle centre, UE z (cm) = Godot y * 100
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

vec2 frame_uv(vec2 uv, float f) {
	return (uv + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
}

// UE BlackBody material function as compiled in PS 6901
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
	vec3 bb = blackbody(blackbody_bias * v_dyn.y);
	float wz = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y * 100.0;
	float fh = pow(max(clamp((1.0 - (v_pz - wz)) / fuel_height_falloff, 0.0, 1.0), 1e-6), 0.8);
	float fuel = (1.0 - fh) * max(0.0, (1.0 - cc.r) * 0.8 + 0.1);
	vec3 e = mix(bb, fuel_color, uses_fuel * fuel) * v_color.rgb;
	e *= emissive_add_strength * (1.0 - dot(cc, vec3(0.33333)));
	vec3 s = clamp(e, 0.0, 1.0);
	s = mix(s, vec3(dot(s, vec3(0.3, 0.59, 0.11))), clamp(desaturation_fraction, 0.0, 1.0));
	e *= s * mix(bright_scene_multiplier, dark_scene_multiplier, scene_exposure_blend);
	vec3 op = pow(c, vec3(contrast_opacity)) * v_color.a * opacity_boost;
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float D = ((-sp.z / sp.w) - (-VERTEX.z)) * 100.0;
	float fade = clamp(D * 0.0333333351, 0.0, 1.0);
	ALBEDO = max(e * op * fade, vec3(0.0));
	ALPHA = clamp(op.r * fade, 0.0, 1.0);
}
