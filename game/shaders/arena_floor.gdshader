shader_type spatial;
// The test arena's floor (main.gd: the former StandardMaterial3D, albedo colour x seamless noise at uv x 40,
// roughness 0.9), with DI2's fluid compose so blood puddles multiply into it (di2_fluid.gdshaderinc).
#include "res://shaders/di2_fluid.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(0.36, 0.34, 0.31, 1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float uv_scale = 40.0;
uniform float roughness_value = 0.9;

void fragment() {
	ALBEDO = albedo_color.rgb * texture(albedo_texture, UV * uv_scale).rgb;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.5;
	di2_fluid_compose((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, ALBEDO, ROUGHNESS, SPECULAR);
}
