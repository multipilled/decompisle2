shader_type spatial;
// DI2 PSM_Houdini_VertexAnimated_Fluid_Translucent on mesh particles (DI2Particles): the translucent Houdini VAT
// splashes (acid / water / honey bullets, PS_ChemBomb, PS_Collision_Acid). BLEND_Translucent, MSM_Subsurface,
// TLM_Surface. Transcribed from DI2's decompiled base pass VS 4576 / PS 4579 (FMeshParticleVertexFactory,
// PSMI_VertexAnimated_Fluid_Translucent_03; _10_* share the switches Dynamic_Speed / Normalize_Data / Pack_Normal):
//   VS: the VAT decode of di2_particle_vat (VS 1693): frame = ceil(Frames * clamp(DynamicParameter.z, 0,
//       1 - 1/Frames)) / Frames, position = PositionMap(UV0.x, UV0.y + frame) * (Bounding Max - Min) + Min
//       (mesh-local cm, replaces the mesh position), octahedral NormalMap normal; v.w = ColorMap(UV0).x;
//   PS: N = the VAT normal through the particle transform; base = sat(Diffuse Reflected Colour);
//       roughness = sat(lerp(RoughnessMax, RoughnessMin, ColorMap.x)); metallic = sat(Metallic); specular 0.5 (the
//       Fury flag encoding with Fury off); opacity = sat(Diffuse Opacity Multiplier * particle a);
//       transmission = sat((1 - max(0, N . V))^Fresnel_Exponent * (Min - Max) + Max), absorption sat(Absorption
//       Density) (the shared tail's absorbed colour).
// DI2 then runs its forward TLM_Surface subsurface lighting; Godot uses its own BxDF and reflections (APPROXIMATED,
// recon/PARTICLES.md 5). Refraction (Refraction_Strength / _Distance) is UE's distortion pass: not ported.
render_mode cull_back, blend_mix, depth_draw_never;

uniform sampler2D position_map : filter_nearest, repeat_disable;
uniform sampler2D normal_map : filter_nearest, repeat_disable;
uniform sampler2D color_map : filter_linear_mipmap, repeat_enable;
uniform float frames = 1.0;
uniform float bounding_min = 0.0;
uniform float bounding_max = 1.0;
uniform vec3 diffuse_reflected_colour = vec3(1.0);
uniform float roughness_min = 0.5;
uniform float roughness_max = 0.5;
uniform float metallic = 0.0;
uniform float diffuse_opacity_multiplier = 1.0;
uniform float fresnel_exponent = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;

varying vec4 v_color;
varying float v_cm;

vec3 oct_decode(vec2 n) {
	vec2 s = vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	vec2 w = vec2(1.0 - abs(n.y), 1.0 - abs(n.x)) * s;
	float z = (1.0 - abs(n.x)) - abs(n.y);
	vec2 xy = z >= 0.0 ? n : w;
	return normalize(vec3(xy, z));
}

void vertex() {
	v_color = COLOR;
	float f = ceil(frames * min(max(0.0, INSTANCE_CUSTOM.z), 1.0 - 1.0 / frames)) / frames;
	vec2 uv = vec2(UV.x, UV.y + f);
	vec3 n_ue = oct_decode(textureLod(normal_map, uv, 0.0).xy);
	vec3 p_ue = textureLod(position_map, uv, 0.0).xyz * (bounding_max - bounding_min) + bounding_min;
	v_cm = textureLod(color_map, UV, 0.0).x;
	VERTEX = vec3(p_ue.x, p_ue.z, p_ue.y) * 0.01;
	NORMAL = vec3(n_ue.x, n_ue.z, n_ue.y);
}

void fragment() {
	vec3 N = normalize(NORMAL);
	float t = clamp(pow(max(abs(1.0 - max(0.0, dot(N, VIEW))), 1e-6), fresnel_exponent) * (min_transmission - max_transmission)
			+ max_transmission, 0.0, 1.0);
	float op = clamp(diffuse_opacity_multiplier * v_color.a, 0.0, 1.0);
	vec3 col = clamp(diffuse_reflected_colour, 0.0, 1.0);
	float e = 10.0 * clamp(absorption_density, 0.0, 1.0) * min(t, 1.0) * op;
	ALBEDO = min(vec3(1.0), pow(max(col, vec3(1e-6)), vec3(e))) * col;
	ALPHA = op;
	ROUGHNESS = clamp(mix(roughness_max, roughness_min, v_cm), 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = N;
}
