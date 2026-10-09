shader_type spatial;
// DI2 PSM_Translucent_Bubbles on mesh particles (DI2Particles): PSMI_Translucent_Acid_Bubbles_Lingering, the acid
// bubbles of PS_Acid_Lingering_Smoke / PS_Ranged_Acid_Lingering_Smoke. BLEND_Translucent, MSM_Subsurface,
// TLM_Surface. Transcribed from DI2's decompiled base pass PS 12574 (FMeshParticleVertexFactory, inline shader map of
// PSM_Translucent_Bubbles; the Mask parameter is not sampled by the compiled graph):
//   N = lerp(BC5 PT_Caustics_Noise_B_Tiling_N(UV0), (0, 0, 1), Normals_Flatness) on the mesh tangent basis;
//   f = sat((scene depth - pixel depth) / DepthFade_Distance); w = (1 - f) * f (fades at the surface and far behind);
//   op = ((1 - max(0, N . V))^ExponentIn * (1 - BaseReflectFractionIn) + BaseReflectFractionIn)^Mask_Contrast
//        * particle a * w;
//   transmission = sat(op^Opacity To Transmission Curve * (Min - Max) + Max), absorption = sat(Absorption Density)
//   (the shared tail, di2_particle_translucent.gdshaderinc); base = sat(Diffuse Reflected Colour);
//   roughness = sat(Roughness), specular 0.5 (Fury flag off), alpha = sat(op).
// DI2 then runs its forward TLM_Surface lighting with the subsurface BxDF; Godot lights the surface with its own
// BxDF (GGX + Lambert, reflections from the sky / probes): APPROXIMATED (recon/PARTICLES.md 5).
render_mode cull_back, blend_mix, depth_draw_never;


uniform sampler2D normals : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float normals_flatness = 0.0;
uniform float depth_fade_distance = 1.0;
uniform float exponent_in = 1.0;
uniform float base_reflect_fraction = 0.0;
uniform float mask_contrast = 1.0;
uniform vec3 diffuse_reflected_colour = vec3(1.0);
uniform float roughness = 0.5;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;

varying vec4 v_color;

// the helpers of di2_particle_translucent.gdshaderinc (not included: its light() is the TLM_Volumetric term)
float di2_transmission(float opacity_raw, float curve, float min_t, float max_t) {
	return clamp(pow(max(opacity_raw, 1e-6), curve) * (min_t - max_t) + max_t, 0.0, 1.0);
}

vec3 di2_absorbed(vec3 col, float trans, float op, float ad) {
	float e = 10.0 * clamp(ad, 0.0, 1.0) * min(trans, 1.0) * op;
	return min(vec3(1.0), pow(max(col, vec3(1e-6)), vec3(e))) * col;
}

vec3 di2_bc5(vec2 xy) {
	vec3 n;
	n.xy = xy * 2.0 - 1.0;
	n.z = sqrt(max(0.0, 1.0 - dot(n.xy, n.xy)));
	return n;
}

void vertex() {
	v_color = COLOR;
}

void fragment() {
	vec3 tn = di2_bc5(texture(normals, UV).xy);
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normals_flatness));
	vec3 N = normalize(tn.x * TANGENT + tn.y * BINORMAL + tn.z * NORMAL);
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float D = ((-sp.z / sp.w) - (-VERTEX.z)) * 100.0;
	float f = clamp(D / max(depth_fade_distance, 1e-5), 0.0, 1.0);
	float fr = pow(max(abs(1.0 - max(0.0, dot(N, VIEW))), 1e-6), exponent_in);
	fr = fr * (1.0 - base_reflect_fraction) + base_reflect_fraction;
	float op = pow(max(fr, 1e-6), mask_contrast) * v_color.a * (1.0 - f) * f;
	float trans = di2_transmission(op, opacity_to_transmission, min_transmission, max_transmission);
	float a = clamp(op, 0.0, 1.0);
	ALBEDO = di2_absorbed(clamp(diffuse_reflected_colour, 0.0, 1.0), trans, a, absorption_density);
	ALPHA = a;
	ROUGHNESS = clamp(roughness, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = N;
}
