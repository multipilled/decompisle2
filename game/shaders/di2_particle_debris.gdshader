shader_type spatial;
// DI2 PSM_Debris on mesh particles (DI2Particles): PSMI_Viscera_Chunk (the flesh chunks). BLEND_Masked,
// MSM_TwoSidedFoliage, two-sided. The master's shader map is inline in its package (tools/particles/inline_map.py);
// transcribed from its FMeshParticleVertexFactory base pass PS 11860 (VS 1502):
//   uv = (U * UV0.x / UV_Tiles, V * UV0.y)  (the Diffuse atlas: U = UV_Tiles = 16 in the MI);
//   N = Normal (BC5) lerped toward (0, 0, 1) by Normal_Flatness, tangent space (two-sided sign);
//   base = sat(Diffuse.rgb * particle rgb); subsurface = sat(Subsurface_Mult * Diffuse.rgb * particle rgb);
//   roughness = sat(Roughness_Mult * MRO.g); metallic = sat(Metallic); specular 0.5 (DI2 packs it with its Fury flag);
//   clip(particle a * Diffuse.a - 0.3333).
// PSM_Debris_Dithering (PSMI_SawbladeLauncher_SawDebris), its FMeshParticleVertexFactory base pass PS 16137: the same
// expressions with uv = (U, V) * UV0 (no UV_Tiles) and a dithered mask instead of the 0.3333 clip:
//   clip((noise64(screen / 64) + (x + 2y) % 5) / 6 + particle a * Diffuse.a - 0.8333)   (dithered = true).
// Fury tint / desaturation terms off (gameplay view mode).
render_mode cull_disabled, depth_draw_opaque;

#include "res://shaders/di2_particle_twosided.gdshaderinc"

uniform sampler2D diffuse : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D mro : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(1.0);
uniform float uv_tiles = 1.0;
uniform float normal_flatness = 0.0;
uniform float roughness_mult = 1.0;
uniform float subsurface_mult = 1.0;
uniform float metallic = 0.0;
uniform bool dithered = false;
uniform sampler2D noise64 : filter_linear_mipmap, repeat_enable;

varying vec4 v_color;

void vertex() {
	v_color = COLOR;
}

void fragment() {
	vec2 uv = vec2(uv_scale.x * UV.x / uv_tiles, uv_scale.y * UV.y);
	vec3 tn;
	tn.xy = texture(normal_tex, uv).xy * 2.0 - 1.0;
	tn.z = sqrt(max(0.0, 1.0 - dot(tn.xy, tn.xy)));
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normal_flatness));
	vec4 d = texture(diffuse, uv);
	if (dithered) {
		uvec2 px = uvec2(FRAGCOORD.xy);
		float idx = float((px.y * 2u + px.x) % 5u);
		if ((texture(noise64, FRAGCOORD.xy / 64.0).r + idx) * 0.166666672 + v_color.a * d.a - 0.8333 < 0.0) {
			discard;
		}
	} else if (v_color.a * d.a - 0.3333 < 0.0) {
		discard;
	}
	vec3 c = d.rgb * v_color.rgb;
	BACKLIGHT = clamp(subsurface_mult * c, 0.0, 1.0);
	ALBEDO = clamp(c, 0.0, 1.0) + BACKLIGHT;  // + subsurface: indirect diffuse (di2_particle_twosided.gdshaderinc)
	ROUGHNESS = clamp(roughness_mult * texture(mro, uv).g, 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = normalize(tn.x * TANGENT + tn.y * BINORMAL + tn.z * NORMAL);
}
