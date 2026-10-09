shader_type spatial;
// DI2 PSM_Dither_Blood_Opaque_MeshFlipbook on mesh particles (DI2Particles). Transcribed from DI2's decompiled
// FMeshParticleVertexFactory base pass PS 11680 (PSMI_Dither_Blood_Particle_Flipbook): caustic-noise normal at
// UV0 * tiling + RelativeTime * Speed/Direction, fresnel k = 1 - fresnel * DynamicParameter.y, base colour =
// sat(DiffuseReflectedColour * k), subsurface = min(1, ParticleColor^(Density * k)), dithered mask clip 0.3333.
// UE MSM_TwoSidedFoliage. The particle transform is applied by Godot (DI2Particles mesh instance transform).
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/di2_particle_twosided.gdshaderinc"

uniform sampler2D normals : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise64 : filter_linear_mipmap, repeat_enable;
uniform sampler2D sprite_mask : filter_linear_mipmap, repeat_enable;
uniform vec2 normals_tiling = vec2(1.0);
uniform vec2 speed_direction = vec2(0.0);
uniform float normals_flatness = 0.0;
uniform vec3 diffuse_reflected_colour = vec3(0.01, 0.0, 0.0);
uniform float density = 1.0;
uniform float fresnel_exponent = 1.0;
uniform float opacity = 1.0;
uniform float roughness = 0.5;
uniform float metallic = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
}

void fragment() {
	// PARTICLE_TIME (the particle's RelativeTime) arrives in INSTANCE_CUSTOM.w (DI2Particles; this PS reads only .y
	// of the dynamic parameter).
	vec2 nuv = normals_tiling * UV + v_dyn.w * speed_direction;
	vec3 tn;
	tn.xy = texture(normals, nuv).xy * 2.0 - 1.0;
	tn.z = sqrt(max(0.0, 1.0 - dot(tn.xy, tn.xy)));
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normals_flatness));
	vec3 N = normalize(tn.x * TANGENT + tn.y * BINORMAL + tn.z * NORMAL);
	float fres = exp2(fresnel_exponent * log2(max(abs(1.0 - max(0.0, dot(N, VIEW))), 1e-6)));
	float k = 1.0 - fres * v_dyn.y;
	vec3 sss = min(vec3(1.0), exp2(log2(max(v_color.rgb, vec3(1e-30))) * density * k));
	float noise = texture(noise64, FRAGCOORD.xy / 64.0).r;
	uvec2 px = uvec2(FRAGCOORD.xy);
	float dither = float((px.y * 2u + px.x) % 5u);
	float op = opacity * (1.0 - clamp(sss.r * 2.0 - 0.5 + (noise + dither) * 0.2 - 0.5, 0.0, 1.0));
	if (v_color.a * op - 0.3333 < 0.0) {
		discard;
	}
	ALBEDO = clamp(diffuse_reflected_colour * k, 0.0, 1.0) + sss;  // + subsurface (indirect)
	ROUGHNESS = clamp(roughness, 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = N;
	BACKLIGHT = sss;
}
