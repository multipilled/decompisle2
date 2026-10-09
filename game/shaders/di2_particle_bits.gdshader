shader_type spatial;
// DI2 PSM_Liquid_Bits_Simple on sprite / GPU sprite particles (DI2Particles). BLEND_AlphaComposite, MSM_Subsurface,
// TLM_VolumetricPerVertexDirectional. Transcribed from DI2's decompiled base pass PS (FParticleSpriteVertexFactory /
// FGPUSpriteVertexFactory permutations):
//   11162 / 11184 PSMI_Blood_Bits_1x1: c = sat(Spritesheet * particle) (rgba), transmission from the unsaturated a;
//   13983 / 13978 PSMI_Hit_Impact_Brightspot_1x1 (Brightspot): rgb = sat(Brightspot_Strength * tex.rgb * particle.rgb);
//   12193 PSMI_Env_BloodDrop_1x1 (UsesAlphaMask off): rgb = sat(tex.rgb * particle.rgb), a = tex.r * particle.a.
// Normal: Spritesheet_Normal (BC5) lerped toward (0, 0, 1) by FlattenNormal (unclamped: -2 extrapolates), normalised,
// in the sprite's tangent frame. Then the shared translucency tail (di2_particle_translucent.gdshaderinc).
// Emissive = SelectionColor * SelectionColor.w (editor selection; 0 in every MI) is dropped.
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never;

#include "res://shaders/di2_particle_translucent.gdshaderinc"

uniform sampler2D spritesheet : filter_linear_mipmap, repeat_enable;
uniform sampler2D spritesheet_normal : filter_linear_mipmap, repeat_enable;
uniform bool brightspot = false;
uniform bool alpha_from_red = false;   // PS 12193 (UsesAlphaMask off)
uniform float brightspot_strength = 1.0;
uniform float flatten_normal = 0.0;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;

varying vec4 v_color;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
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
	vec3 tn = di2_bc5(texture(spritesheet_normal, UV).xy);
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), flatten_normal));
	vec4 t = texture(spritesheet, UV);
	vec3 col;
	float a_raw;
	if (alpha_from_red) {
		col = clamp(t.rgb * v_color.rgb, 0.0, 1.0);
		a_raw = t.r * v_color.a;
	} else {
		vec4 c = t * v_color;
		col = clamp((brightspot ? brightspot_strength : 1.0) * c.rgb, 0.0, 1.0);
		a_raw = c.a;
	}
	float op = clamp(a_raw, 0.0, 1.0);
	float trans = di2_transmission(a_raw, opacity_to_transmission, min_transmission, max_transmission);
	ALBEDO = di2_absorbed(col, trans, op, absorption_density);
	ALPHA = op;
	NORMAL = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	BACKLIGHT = vec3(trans);
	SPECULAR = 0.0;  // TLM_VolumetricPerVertexDirectional: no specular term in DI2
	ROUGHNESS = 1.0;
}
