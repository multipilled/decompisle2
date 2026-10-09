shader_type spatial;
// DI2 PSM_Houdini_VertexAnimated_Fluid on mesh particles (DI2Particles). Transcribed from DI2's decompiled shaders:
//   FMeshParticleVertexFactory base pass VS 1693 / PS 1647 (PSMI_VertexAnimated_Fluid_03 permutation) and
//   PS 12057 / VS 12066 (PSMI_VertexAnimated_Fluid_11_Meat_02: UseColorRamp + UseReflectedColorBlend).
// Houdini VAT "fluid": the mesh's own positions are ignored; each vertex reads its position and octahedral normal
// from the textures at (UV0.x, UV0.y + frame / Frames), frame = ceil(Frames * clamp(DynamicParameter.z, 0,
// 1 - 1/Frames)) / Frames. Position = (tex * 1 + 0) * (BoundsMax - BoundsMin) + BoundsMin (the DI2 texture
// unpack scale/bias is the identity: no PT_*_Pos carries the PackedData bit-28 range), in mesh-local cm,
// then the particle transform. Shading: UE MSM_TwoSidedFoliage, BLEND_Masked (clip 0.3333).
// UE space -> Godot: (x, y, z) -> (x, z, y) * 0.01 (DI2Particles).
render_mode skip_vertex_transform, cull_back, depth_draw_opaque;

#include "res://shaders/di2_particle_twosided.gdshaderinc"

uniform sampler2D position_map : filter_nearest, repeat_disable;
uniform sampler2D normal_map : filter_nearest, repeat_disable;
uniform sampler2D noise64 : filter_linear_mipmap, repeat_enable;
uniform sampler2D diffuse_overlay : source_color, filter_linear_mipmap, repeat_enable;
uniform float frames = 1.0;
uniform float bounding_min = 0.0;
uniform float bounding_max = 1.0;
uniform vec3 diffuse_reflected_colour = vec3(0.01, 0.00035, 0.00035);
uniform vec3 diffuse_reflected_colour_blend = vec3(0.0);
uniform float density = 1.0;
uniform float fresnel_exponent = 1.0;
uniform float opacity = 1.0;
uniform float roughness_min = 0.5;
uniform float roughness_max = 0.5;
uniform float metallic = 0.0;
uniform bool use_reflected_colour_blend = false;
uniform bool use_color_ramp = false;
uniform float texture_blend = 0.0;
uniform float scale_color_diffuse = 1.0;
uniform int debug_mode = 0;     // test aid (autotest --debugvat): 1 = N.V (green facing, red away), no clip

varying vec4 v_color;
varying vec4 v_dyn;
varying float v_nx;          // object-space VAT normal .x (PS 1647 lerps roughness by it)
varying vec3 v_world;

vec3 oct_decode(vec2 n) {
	// VS 1693: sign per component, wrap the lower hemisphere, z = 1 - |x| - |y|
	vec2 s = vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	vec2 w = vec2(1.0 - abs(n.y), 1.0 - abs(n.x)) * s;
	float z = (1.0 - abs(n.x)) - abs(n.y);
	vec2 xy = z >= 0.0 ? n : w;
	return normalize(vec3(xy, z));
}

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	float f = ceil(frames * min(max(0.0, INSTANCE_CUSTOM.z), 1.0 - 1.0 / frames)) / frames;
	vec2 uv = vec2(UV.x, UV.y + f);
	vec3 n_ue = oct_decode(textureLod(normal_map, uv, 0.0).xy);
	vec3 p_ue = textureLod(position_map, uv, 0.0).xyz * (bounding_max - bounding_min) + bounding_min;
	v_nx = n_ue.x;
	vec3 p_local = vec3(p_ue.x, p_ue.z, p_ue.y) * 0.01;
	vec3 n_local = vec3(n_ue.x, n_ue.z, n_ue.y);
	vec4 world = MODEL_MATRIX * vec4(p_local, 1.0);
	v_world = world.xyz;
	VERTEX = (VIEW_MATRIX * world).xyz;
	vec3 nw = normalize(mat3(MODEL_MATRIX) * n_local);
	NORMAL = normalize(mat3(VIEW_MATRIX) * nw);
}

void fragment() {
	vec3 N = normalize(NORMAL);
	float fres = exp2(fresnel_exponent * log2(max(abs(1.0 - max(0.0, dot(N, VIEW))), 1e-6)));
	float k = 1.0 - fres * v_dyn.y;
	vec3 base;
	if (use_color_ramp && use_reflected_colour_blend) {
		// PS 12057: world-planar overlay at UE world (X, Y) / ScaleColorDifuse
		vec2 wxy = vec2(v_world.x, v_world.z) * 100.0 / scale_color_diffuse;
		vec3 ov = texture(diffuse_overlay, wxy).rgb;
		vec3 rc = mix(diffuse_reflected_colour, diffuse_reflected_colour_blend, v_dyn.w);
		base = clamp(k * mix(ov, rc, texture_blend), 0.0, 1.0);
	} else {
		base = clamp(diffuse_reflected_colour * k, 0.0, 1.0);
	}
	vec3 sss = min(vec3(1.0), exp2(log2(max(v_color.rgb, vec3(1e-30))) * density * k));
	float noise = texture(noise64, FRAGCOORD.xy / 64.0).r;
	uvec2 px = uvec2(FRAGCOORD.xy);
	float dither = float((px.y * 2u + px.x) % 5u);
	float op = opacity * (1.0 - clamp(sss.r * 2.0 - 0.5 + (noise + dither) * 0.2 - 0.5, 0.0, 1.0));
	if (debug_mode == 1) {
		float nv = dot(N, VIEW);
		ALBEDO = vec3(max(-nv, 0.0), max(nv, 0.0), 0.0);
		EMISSION = ALBEDO;
	} else {
		if (v_color.a * op - 0.3333 < 0.0) {
			discard;
		}
		ALBEDO = base + sss;  // + subsurface: indirect diffuse (di2_particle_twosided.gdshaderinc)
	}
	ROUGHNESS = clamp(v_nx * (roughness_min - roughness_max) + roughness_max, 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	BACKLIGHT = sss;
}
