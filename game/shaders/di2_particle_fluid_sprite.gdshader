shader_type spatial;
// DI2 PSM_Liquid_FluidSprite on sprite particles (DI2Particles): PSMI_Liquid_FluidSprite_00, the blood / acid liquid
// sprite sheets of the blunt hits (PS_Blood_Blunt_*) and acid bombs. BLEND_Translucent, MSM_Subsurface,
// TLM_VolumetricPerVertexDirectional. Transcribed from DI2's decompiled base pass PS 11482
// (FParticleSpriteVertexFactory, UsesAlphaMask on):
//   t = Spritesheet(UV of the current sub-image: Required SubImages, the VF's TexCoord0 = one frame, no blend);
//   N = lerp(BC5 Spritesheet_Normal, (0, 0, 1), FlattenNormal) on the sprite basis;
//   colour = sat(particle rgb * lerp(LowColorMulty, 1, t.r)) (Fury term off);
//   opacity = DynamicParameter.x * t.a * sat(floor(particle a + t.r)) (alpha erodes the sheet by its red);
//   transmission / absorption: the shared lit-translucency tail (di2_particle_translucent.gdshaderinc).
// DI2 lights this per vertex (TLM_VolumetricPerVertexDirectional); Godot lights it per pixel with the same term
// (APPROXIMATED, recon/PARTICLES.md 5).
render_mode skip_vertex_transform, cull_disabled, blend_mix, depth_draw_never;

#include "res://shaders/di2_particle_translucent.gdshaderinc"

uniform sampler2D spritesheet : filter_linear_mipmap, repeat_enable;
uniform sampler2D spritesheet_normal : filter_linear_mipmap, repeat_enable;
uniform bool spritesheet_srgb = false;
uniform vec2 sub_images = vec2(1.0);
uniform float flatten_normal = 0.0;
uniform float low_color_multy = 0.1;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying float v_sub;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	v_sub = MODEL_MATRIX[2].x;
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
	vec2 uv = UV;
	if (sub_images.x > 1.0 || sub_images.y > 1.0) {
		float f = floor(v_sub);
		uv = (UV + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
	}
	vec4 t = texture(spritesheet, uv);
	if (spritesheet_srgb) {
		t.rgb = mix(t.rgb / 12.92, pow((t.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), t.rgb));
	}
	vec3 tn = normalize(mix(di2_bc5(texture(spritesheet_normal, uv).xy), vec3(0.0, 0.0, 1.0), flatten_normal));
	vec3 N = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	vec3 col = clamp(v_color.rgb * mix(low_color_multy, 1.0, t.r), 0.0, 1.0);
	float op_raw = v_dyn.x * t.a * clamp(floor(v_color.a + t.r), 0.0, 1.0);
	float op = clamp(op_raw, 0.0, 1.0);
	float trans = di2_transmission(op_raw, opacity_to_transmission, min_transmission, max_transmission);
	ALBEDO = di2_absorbed(col, trans, op, absorption_density);
	ALPHA = op;
	NORMAL = N;
	BACKLIGHT = vec3(trans);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
