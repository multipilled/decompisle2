// Props (Dani's arms, weapons): Unreal texture set + accumulated blood overlay.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D mro_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D ata_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D blood_detail : filter_linear_mipmap, repeat_enable;
uniform bool has_albedo = false;
uniform bool has_normal = false;
uniform bool has_mro = false;
uniform bool has_ata = false;
uniform bool use_alpha_clip = false;
uniform float alpha_clip = 0.333;
uniform vec4 tint : source_color = vec4(1.0);
/// 0..1, grows as the weapon/arms hit things (DI2's weapon blood overlay).
uniform float blood_amount = 0.0;

void fragment() {
	vec4 base = has_albedo ? texture(albedo_tex, UV) : vec4(0.6, 0.6, 0.6, 1.0);
	if (use_alpha_clip && has_ata && texture(ata_tex, UV).r < alpha_clip) discard;
	vec3 mro = has_mro ? texture(mro_tex, UV).rgb : vec3(0.0, 0.6, 1.0);
	float b = smoothstep(1.0 - blood_amount, 1.0 - blood_amount + 0.15, texture(blood_detail, UV * 1.5).r) * step(0.001, blood_amount);
	ALBEDO = mix(base.rgb * tint.rgb, vec3(0.2, 0.01, 0.01), b * 0.9);
	METALLIC = mro.r * (1.0 - b);
	ROUGHNESS = mix(mro.g, 0.25, b);
	AO = mro.b;
	if (has_normal) {
		vec2 xy = texture(normal_tex, UV).rg * 2.0 - 1.0;
		xy.y = -xy.y;
		NORMAL_MAP = vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy)))) * 0.5 + 0.5;
	}
}
