// DI2 level geometry (tools/build_test_map.py -> game/assets/di2/maps/<map>/, built by game/scripts/di2_map.gd).
// The base maps every DI2 environment master shares (M_Opaque & co., DIShared/Core/Materials): "Diffuse Colour Map",
// "Normal Map" (BC5, UE/DirectX green), "Packed MRO Map (see tooltip)" (R metallic, G roughness, B occlusion), the
// masked blend's opacity from the diffuse alpha, and the MI's colour tint when it has one. Detail maps, vertex-colour
// layer blends and the rest of each master's feature switches are not ported (see recon/TEST_MAP.md).
// Variants: di2_env.gdshader (one-sided), di2_env_2s.gdshader (TwoSided), di2_env_glass.gdshader (translucent).

#ifndef DI2_ENV_TRANSLUCENT
#include "res://shaders/di2_fluid.gdshaderinc"
#endif
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D mro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_albedo = false;
uniform bool has_normal = false;
uniform bool has_mro = false;
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4 tint : source_color = vec4(1.0);
uniform bool use_alpha_clip = false;
uniform float alpha_clip = 0.3333;
uniform float roughness_default = 0.5;
uniform float opacity = 1.0;

void fragment() {
	vec4 base = has_albedo ? texture(albedo_tex, UV) : base_color;
#ifdef DI2_ENV_MASKED_ALLOWED
	if (use_alpha_clip && base.a < alpha_clip) discard;
#endif
	vec3 mro = has_mro ? texture(mro_tex, UV).rgb : vec3(0.0, roughness_default, 1.0);
	ALBEDO = base.rgb * tint.rgb;
	METALLIC = mro.r;
	ROUGHNESS = mro.g;
	AO = mro.b;
	if (has_normal) {
		vec2 xy = texture(normal_tex, UV).rg * 2.0 - 1.0;
		xy.y = -xy.y;
		NORMAL_MAP = vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy)))) * 0.5 + 0.5;
	}
#ifdef DI2_ENV_TRANSLUCENT
	ALPHA = opacity * (has_albedo ? base.a : 1.0);
#else
	// DI2 fluid compose (puddles) into the surface, game/shaders/di2_fluid.gdshaderinc (gore session).
	di2_fluid_compose((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, ALBEDO, ROUGHNESS, SPECULAR);
#endif
}
