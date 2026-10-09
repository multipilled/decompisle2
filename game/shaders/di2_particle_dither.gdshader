shader_type spatial;
// DI2 PSM_Dither_Blood_Opaque on sprite particles (CPU and GPU sprites; DI2Particles). Transcribed from DI2's
// decompiled base pass PS 10974 (FParticleSpriteVertexFactory) / 10991 (FGPUSpriteVertexFactory), permutation
// Particle_Sprites (PSMI_Dither_Blood_Dust). Sprite placement is done on the CPU (DI2Particles
// Emitter._sprite_transform = ParticleSpriteVertexFactory GetTangents); the instance basis carries
// right * size (x), down * size (y) and (SubImageIndex, RelativeTime, 0) (z). UE MSM_TwoSidedFoliage, masked 0.3333.
render_mode skip_vertex_transform, cull_disabled, depth_draw_opaque;

#include "res://shaders/di2_particle_twosided.gdshaderinc"

uniform sampler2D normals : filter_linear_mipmap, repeat_enable;
uniform sampler2D sprite_mask : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise64 : filter_linear_mipmap, repeat_enable;
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
varying float v_time;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
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
	vec2 nuv = normals_tiling * UV + v_time * speed_direction;
	vec3 tn;
	tn.xy = texture(normals, nuv).xy * 2.0 - 1.0;
	tn.z = sqrt(max(0.0, 1.0 - dot(tn.xy, tn.xy)));
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normals_flatness));
	vec3 N = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	float fres = exp2(fresnel_exponent * log2(max(abs(1.0 - max(0.0, dot(N, VIEW))), 1e-6)));
	float k = 1.0 - fres * v_dyn.y;
	float mask = texture(sprite_mask, UV).a;
	vec3 sss = min(vec3(1.0), exp2(log2(max(v_color.rgb, vec3(1e-30))) * density * k));
	float noise = texture(noise64, FRAGCOORD.xy / 64.0).r;
	uvec2 px = uvec2(FRAGCOORD.xy);
	float dither = float((px.y * 2u + px.x) % 5u);
	float op = opacity * (1.0 - clamp(sss.r * 2.0 - 0.5 + (noise + dither) * 0.2 - 0.5, 0.0, 1.0));
	if (v_color.a * mask * op - 0.3333 < 0.0) {
		discard;
	}
	BACKLIGHT = clamp(sss * mask, 0.0, 1.0);
	ALBEDO = clamp(diffuse_reflected_colour, 0.0, 1.0) + BACKLIGHT;  // + subsurface (indirect)
	ROUGHNESS = clamp(roughness, 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = N;
}
