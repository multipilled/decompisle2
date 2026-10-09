shader_type spatial;
// DI2 PSM_Liquid_Bits_Complex on GPU sprite particles (DI2Particles). BLEND_Translucent, MSM_Subsurface, TLM_Surface
// (translucency-volume diffuse + reflection-environment specular). Transcribed from DI2's decompiled base pass
// PS 12109 (FGPUSpriteVertexFactory; PSMI_Blood_Bits_Expensive_1x1 and PSMI_Acid_Bits_Expensive_1x1 share it):
//   shimmer UV = rotate(UV * Shimmering_Normals_(U,V)Tiling + RelativeTime * Shimmering_Speed/Direction.xy - 0.5,
//                       0.25 * RelativeTime) + 0.5 -> PT_Caustics_Noise_B_Tiling_N (shader-map constant), BC5;
//   droplet UV = UV + UV_Shimmer_Strength * shimmer.x (both axes; UV_Shimmer switch on in both MIs);
//   normal = RNM(droplet BC5 normal, lerp(shimmer, (0,0,1), Shimmering_Flatness) * (-1,-1,1)) =
//            t * dot(t, u) - t.z * u, t = (n.xy, n.z + 1); lerped toward (0,0,1) by Normal_Flatness; normalised;
//   colour = sat(Diffuse Reflected Colour) (particle rgb unused), opacity = Texture_Diffuse.a * particle a;
//   Roughness = sat(Roughness); Specular 0.5 (the packed 0.496 of PS 12109 with Fury off).
// Then the shared translucency tail (di2_particle_translucent.gdshaderinc). UE adds the reflection term un-scaled by
// opacity (it divides by max(0.1, opacity) before the SrcAlpha blend), so this uses premultiplied blending with
// ALBEDO * opacity: Godot's own reflections then stay at full strength like DI2's (APPROXIMATED: Godot's sky / probes
// instead of DI2's reflection captures).
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never;

#include "res://shaders/di2_particle_translucent.gdshaderinc"

uniform sampler2D texture_diffuse : filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D caustics_n : filter_linear_mipmap, repeat_enable;
uniform bool uv_shimmer = true;
uniform vec2 shimmer_tiling = vec2(1.0);
uniform vec2 shimmer_speed = vec2(0.0);
uniform float uv_shimmer_strength = 0.0;
uniform float shimmering_flatness = 0.0;
uniform float normal_flatness = 0.0;
uniform vec3 diffuse_reflected_colour = vec3(0.0);
uniform float roughness = 0.5;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;

varying vec4 v_color;
varying float v_time;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
	v_time = MODEL_MATRIX[2].y;
	vec3 right = MODEL_MATRIX[0].xyz;
	vec3 down = MODEL_MATRIX[1].xyz;
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

void fragment() {
	float ang = 0.25 * v_time;
	float s = sin(ang);
	float c = cos(ang);
	vec2 p = shimmer_tiling * UV + v_time * shimmer_speed - 0.5;
	vec2 suv = vec2(dot(vec2(c, -s), p), dot(vec2(s, c), p)) + 0.5;
	vec3 sh = di2_bc5(texture(caustics_n, suv).xy);
	vec2 duv = uv_shimmer ? UV + uv_shimmer_strength * sh.x : UV;
	vec3 t = di2_bc5(texture(texture_normal, duv).xy);
	t.z += 1.0;
	vec3 u = mix(sh, vec3(0.0, 0.0, 1.0), shimmering_flatness) * vec3(-1.0, -1.0, 1.0);
	vec3 tn = t * dot(t, u) - t.z * u;
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normal_flatness));
	float a_raw = texture(texture_diffuse, duv).a * v_color.a;
	float op = clamp(a_raw, 0.0, 1.0);
	vec3 col = clamp(diffuse_reflected_colour, 0.0, 1.0);
	float trans = di2_transmission(a_raw, opacity_to_transmission, min_transmission, max_transmission);
	ALBEDO = di2_absorbed(col, trans, op, absorption_density) * op;
	ALPHA = op;
	ROUGHNESS = clamp(roughness, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	BACKLIGHT = vec3(trans);
}
