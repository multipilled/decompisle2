shader_type spatial;
// DI2 PSM_BurningLiquidSplash on sprite / GPU sprite particles (DI2Particles): the blood / acid / burning liquid
// splashes, spit trails and smoke trails. BLEND_Translucent, DefaultLit, TLM_VolumetricNonDirectional (the master's
// defaults). The master's shader map is inline in its package (tools/particles/inline_map.py); transcribed from its
// FParticleSpriteVertexFactory base pass PS 11996 (GPU sprites: PS 12016, same expressions):
//   base = sat(BC.rgb * particle rgb), opacity = sat(BC.a * particle a);
//   lighting (translucency volume, non-directional: no normal) = base * (ambient SH * 0.886 + directional light
//   colour * shadowing / pi); Godot: its ambient on ALBEDO plus light() adding LIGHT_COLOR / pi without N.L.
// The FlattenNormal / WS sphere / Height parameters have no effect in this lighting mode's compiled shader.
// Also PSM_BlowMind_Chunks (PSMI_BlowMind_Chunks, GPU sprites), its base pass PS 13532: same lighting, with
//   base = sat(BC.rgb * BC_Detail(uv * (DetailTileX, DetailTileY)).rgb) (no particle rgb: use_color_rgb = false),
//   opacity = sat(particle a * BC.a), emissive = max(0, SelectionColor.rgb * SelectionColor.a).
render_mode skip_vertex_transform, cull_disabled, blend_mix, depth_draw_never;

uniform sampler2D bc : filter_linear_mipmap, repeat_enable;
uniform bool bc_srgb = false;
uniform sampler2D detail : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool detail_srgb = false;
uniform vec2 detail_tile = vec2(1.0);
uniform bool use_color_rgb = true;
uniform vec3 emissive = vec3(0.0);

varying vec4 v_color;

void vertex() {
	v_color = COLOR;
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec4 t = texture(bc, UV);
	if (bc_srgb) {
		t.rgb = mix(t.rgb / 12.92, pow((t.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), t.rgb));
	}
	vec3 dt = texture(detail, UV * detail_tile).rgb;
	if (detail_srgb) {
		dt = mix(dt / 12.92, pow((dt + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), dt));
	}
	vec3 rgb = t.rgb * dt * (use_color_rgb ? v_color.rgb : vec3(1.0));
	ALBEDO = clamp(rgb, 0.0, 1.0);
	ALPHA = clamp(t.a * v_color.a, 0.0, 1.0);
	EMISSION = max(emissive, vec3(0.0));
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (1.0 / PI);
}
