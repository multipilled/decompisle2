shader_type spatial;
// DI2 PSM_ElectricDistortion on sprite particles (DI2Particles). BLEND_AlphaComposite, unlit emissive. Transcribed
// from DI2's decompiled base pass PS 2917 (PSMI_ElectricDistortion_02, UsesContactOpacity) and 12243 (_04):
//   uv = rotate(UV - .5, 2 pi DynamicParameter.x) + .5;
//   n = Noise(UV * (U_Tiling, V_Tiling) * (8, 4) + 0.5 GameTime).x; uv += min(1, max(1e-6, 2 (n - .5) UV_Distort_Strength)^UV_Distort_Contrast);
//   m = min(1, max(1e-6, Mask(uv).x * lerp(Multy, MultyFar, sat(|pixel - camera| / DistanceCompensation)))^Power);
//   c = max(1e-6, particle rgb * m)^Colour_Contrast;
//   UsesContactOpacity: k = 1 - sat((scene depth - pixel depth) / DepthFade_Distance) (visible near surfaces), else 1;
//   colour = c * k * E, opacity = sat(Opacity_Strength * max(1e-6, m)^Opacity_Contrast * k).
// E = DI2's exposure compensation: lerp(Bright, Dark Scene Multiplier * 4.7e-5, sat((X - Tb) / (Td - Tb))) / X with
// X = View[152].y and Tb / Td = MPC_Postprocess_Player AdvExpCompThresholdBright (5e-5) / Dark (0.005), then the
// base pass' * PreExposure. With PreExposure = X the displayed value is c * multiplier * 4.7e-5 (the particle colours
// are HDR). Godot has no DI2 exposure: scene_exposure_blend picks the multiplier (0 = bright scene, the daylight
// arena; 1 = dark) and PreExposure / X = 1 (APPROXIMATED, recon/PARTICLES.md 4.3). The Refraction scalar drives
// UE's distortion pass, not ported.
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D mask_tex : source_color, filter_linear_mipmap, repeat_enable;  // T_ElectricStrike01_A is sRGB
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 uv_tiling = vec2(1.0);
uniform float uv_distort_strength = 0.0;
uniform float uv_distort_contrast = 1.0;
uniform float multy = 1.0;
uniform float multy_far = 1.0;
uniform float distance_compensation = 1.0;
uniform float power = 1.0;
uniform float colour_contrast = 1.0;
uniform bool uses_contact_opacity = false;
uniform float depth_fade_distance = 1.0;
uniform float opacity_contrast = 1.0;
uniform float opacity_strength = 0.0;
uniform float bright_scene_multiplier = 1.0;
uniform float dark_scene_multiplier = 1.0;
uniform float scene_exposure_blend = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying vec3 v_world;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	v_world = world;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float a = 6.28318548 * v_dyn.x;
	float s = sin(a);
	float c = cos(a);
	vec2 p = UV - 0.5;
	vec2 uv = vec2(dot(p.yx, vec2(-s, c)), dot(p.yx, vec2(c, s))) + 0.5;
	float n = texture(noise_tex, uv_tiling * UV * vec2(8.0, 4.0) + TIME * 0.5).x;
	uv += min(1.0, pow(max(1e-6, 2.0 * (n - 0.5) * uv_distort_strength), uv_distort_contrast));
	float dist_cm = length(v_world - INV_VIEW_MATRIX[3].xyz) * 100.0;
	float k = mix(multy, multy_far, clamp(dist_cm / distance_compensation, 0.0, 1.0));
	float m = min(1.0, pow(max(1e-6, texture(mask_tex, uv).x * k), power));
	vec3 col = pow(max(vec3(1e-6), v_color.rgb * m), vec3(colour_contrast));
	float fade = 1.0;
	if (uses_contact_opacity) {
		float d = texture(depth_tex, SCREEN_UV).r;
		vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
		fade = 1.0 - clamp(((-sp.z / sp.w) - (-VERTEX.z)) * 100.0 / max(depth_fade_distance, 1e-5), 0.0, 1.0);
	}
	float mult = mix(bright_scene_multiplier, dark_scene_multiplier, scene_exposure_blend) * 4.7e-5;
	ALBEDO = max(col * fade * mult, vec3(0.0));
	ALPHA = clamp(opacity_strength * pow(max(1e-6, m), opacity_contrast) * fade, 0.0, 1.0);
}
