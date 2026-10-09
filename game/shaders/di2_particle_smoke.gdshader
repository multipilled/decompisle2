shader_type spatial;
// DI2 PSM_Smoke_Transluscent_Lit on sprite particles (DI2Particles). Transcribed from DI2's decompiled base pass
// PS 11551 / VS 1249 (FParticleSpriteVertexFactory, permutation of PSMI_Blood_Dust_8x8: Is Blood, Near_Camera_Fade,
// Refraction, Motion_Vectors_Switch). BLEND_AlphaComposite (premultiplied: colour + dest * (1 - opacity)).
//   frame = DynamicParameter.x (the material's own flipbook), blend = frac; UV = (corner + (frame % U,
//   floor(frame / U))) / (U, V) for frame and frame + 1, each pushed along its motion vector texture
//   (2 * MV - 1) * blend (resp. 1 - blend) * Offset_Magic_Number; colour = lerp of both frames, alpha = their red.
//   colour = sat(pow(tex, Contrast_Color) * nearfade * particle rgb * depthfade)
//   opacity = sat(particle a * pow(red, Contrast_Opacity) * nearfade * Opacity_Boost * depthfade)
//   depthfade = sat((scene depth - pixel depth) / FadeDistance); nearfade = sat((view depth - NearFade_Offset) /
//   NearFade_Radius) (cm). Refraction (the Refraction switch) is not ported (no refraction pass here).
// Lighting: DI2's translucency volume lighting (SH ambient + directional with a Cornette-Shanks phase whose g comes
// from the opacity -> transmission curve) is approximated per light (di2_particle_translucent.gdshaderinc).
// TLM_VolumetricDirectional has no specular: SPECULAR 0 keeps Godot's sky reflections off.
// Also used for PSM_Liquid_Transluscent_Lit (PS 12586 PSMI_Acid_Smoke_02_8x8 / 11501): the same flipbook, normals,
// fades and contrasts, but opacity from the spritesheet's alpha (opacity_from_alpha) and TLM_Surface lighting
// (reflection captures with Roughness: surface_specular). Its WS sphere mask terms are not transcribed.
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never;

#include "res://shaders/di2_particle_translucent.gdshaderinc"

uniform sampler2D spritesheet : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D spritesheet_normals : filter_linear_mipmap, repeat_enable;
uniform sampler2D motion_vector : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 sub_images = vec2(1.0);
uniform float offset_magic_number = 0.0;
uniform bool use_motion_vectors = true;
uniform float normal_flatness = 0.0;
uniform float fade_distance = 50.0;
uniform bool near_camera_fade = false;
uniform float near_fade_offset = 0.0;
uniform float near_fade_radius = 1.0;
uniform float contrast_color = 1.0;
uniform float contrast_opacity = 1.0;
uniform float opacity_boost = 1.0;
uniform float opacity_to_transmission = 1.0;
uniform float min_transmission = 0.0;
uniform float max_transmission = 0.0;
uniform float absorption_density = 0.0;
uniform bool opacity_from_alpha = false;
uniform bool surface_specular = false;
uniform float roughness = 1.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;
varying float v_g;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
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

vec2 frame_uv(vec2 uv, float f) {
	return (uv + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
}

vec3 bc5n(vec2 uv) {
	return di2_bc5(texture(spritesheet_normals, uv).xy);
}

void fragment() {
	float blend = fract(v_dyn.x);
	float f0 = v_dyn.x - blend;
	vec2 uv0 = frame_uv(UV, f0);
	vec2 uv1 = frame_uv(UV, f0 + 1.0);
	if (use_motion_vectors) {
		uv0 -= (texture(motion_vector, uv0).xy * 2.0 - 1.0) * blend * offset_magic_number;
		uv1 += (texture(motion_vector, uv1).xy * 2.0 - 1.0) * (1.0 - blend) * offset_magic_number;
	}
	vec3 tn = mix(bc5n(uv0), bc5n(uv1), blend);
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normal_flatness));
	vec3 N = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
	// soft particle: scene depth - pixel depth (UE cm)
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene_depth = -sp.z / sp.w;
	float pixel_depth = -VERTEX.z;
	float depth_fade = clamp((scene_depth - pixel_depth) * 100.0 / max(fade_distance, 1e-5), 0.0, 1.0);
	float near_fade = near_camera_fade ? clamp((pixel_depth * 100.0 - near_fade_offset) / max(near_fade_radius, 1e-5), 0.0, 1.0) : 1.0;
	vec4 c4 = mix(texture(spritesheet, uv0), texture(spritesheet, uv1), blend);
	vec3 c = c4.rgb;
	float red = opacity_from_alpha ? c4.a : c.r;
	c = max(c, vec3(1e-6));
	vec3 col = clamp(pow(c, vec3(contrast_color)) * near_fade * v_color.rgb * depth_fade, 0.0, 1.0);
	float op = clamp(v_color.a * pow(max(red, 1e-6), contrast_opacity) * near_fade * opacity_boost * depth_fade, 0.0, 1.0);
	float trans = di2_transmission(op, opacity_to_transmission, min_transmission, max_transmission);
	ALBEDO = di2_absorbed(col, trans, op, absorption_density);
	ALPHA = op;
	NORMAL = N;
	BACKLIGHT = vec3(trans);
	SPECULAR = surface_specular ? 0.5 : 0.0;
	ROUGHNESS = surface_specular ? clamp(roughness, 0.0, 1.0) : 1.0;
}
