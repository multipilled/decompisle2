// DI2 M_EyeOcclusion (MI_HumanFemaleEyeOverlay), transcribed from the decompiled PS 4166 (recon/SHADERS_FLESH.md
// §14.8 / Appendix B). A translucent, unlit card over each eye that replaces the eyeball behind it with a blurred,
// occlusion-tinted copy of the scene (wet meniscus / lid shadow). Wounds over the eye (Disp.r > 1/60) remove it.
// Body-mesh section: vertex data as in flesh.gdshader (CUSTOM0.xyz bind pose, CUSTOM1..3 cut-slot weights).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

#include "res://shaders/flesh_splatter.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D eye_o : filter_linear_mipmap, repeat_disable;     // T_Eye_O (View clamped sampler)
uniform bool has_eye_o = false;
uniform int layer = 9;
uniform float deform_fallback_cm = 3.0;
// MI_HumanFemaleEyeOverlay (set per section from data/flesh_materials.json)
uniform float overall_blur = 1.0;
uniform float oc_blur = 0.3;
uniform float oc_blur_f = 8.0;
uniform float bot_blur = 0.4;
uniform float bot_blur_f = 8.0;
uniform float perim_blur = 0.4;
uniform float perim_blur_f = 12.0;
uniform float tear_blur = 0.4;
uniform float tear_c = 0.78;
uniform float tear_f = 8.0;
uniform float oc_occ = 0.98;
uniform float oc_occ_f = 12.0;
uniform float ic_occ = 0.2;
uniform float ic_occ_f = 6.0;
uniform float top_occ = 0.98;
uniform float top_occ_f = 4.0;
uniform float bot_occ = 0.4;
uniform float bot_occ_f = 8.0;
uniform float overall_occ = 0.8;
uniform vec3 occ_colour = vec3(0.3);
const float OVERLAY_REMOVAL = 60.0;   // ChrSplatterEyeOverlayRemovalScale (MPC)

varying vec3 rest_pos;
varying vec4 sw0;
varying vec4 sw1;
varying vec4 sw2;
varying float deform_cm;

float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }

void vertex() {
	rest_pos = CUSTOM0.xyz;
	float dlen = CUSTOM0.w - floor(CUSTOM0.w / 256.0) * 256.0;   // CUSTOM0.w = subsection x 256 + deform cm
	deform_cm = dlen > 0.0 ? dlen : deform_fallback_cm;
	sw0 = CUSTOM1;
	sw1 = CUSTOM2;
	sw2 = CUSTOM3;
}

void fragment() {
	// Severing, as the rest of the body.
	float sev = -1.0;
	for (int k = 0; k < 12; k++) {
		if (((severed_mask >> k) & 1) == 1 && k != cap_slot) {
			sev = max(sev, past_cut(k, rest_pos, sw0, sw1, sw2));
		}
	}
	if (di2_cut) {
		// split by DI2's dismember already
	} else if (is_piece) {
		if (past_cut(piece_slot, rest_pos, sw0, sw1, sw2) < 0.0 || sev > 0.0) discard;
	} else if (sev > 0.0) {
		discard;
	}

	vec2 uv = UV;
	float blur = oc_blur * pw(1.0 - uv.x, oc_blur_f) + bot_blur * pw(uv.y, bot_blur_f)
			+ clamp(perim_blur * pw(1.0 - (has_eye_o ? texture(eye_o, uv).r : 1.0), perim_blur_f), 0.0, 1.0)
			+ tear_blur * (1.0 - min(1.0, abs((uv.x - tear_c) * tear_f)));
	// Linear depth (UE centimetres) of the opaque eyeball behind; the radius is in NDC.
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float lin_cm = max(1e-3, -vp.z / vp.w) * 100.0;
	float r = overall_blur * blur / lin_cm;
	vec2 K[16] = vec2[](vec2(0.0, -2.0), vec2(2.0, 0.0), vec2(0.0, 2.0), vec2(-2.0, 0.0), vec2(-1.0, -1.0), vec2(1.0, -1.0),
			vec2(-1.0, 1.0), vec2(1.0, 1.0), vec2(0.0, -1.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(-1.0, 0.0),
			vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec3 scene = vec3(0.0);
	for (int i = 0; i < 16; i++) {
		vec2 q = clamp(ndc + r * K[i], vec2(-0.999), vec2(0.999));
		// DI2 decodes its scene-colour copy as 10 * s^4; Godot's screen texture is linear already.
		scene += texture(screen_tex, q * 0.5 + 0.5).rgb;
	}
	scene /= 16.0;
	float occ = (1.0 - clamp(oc_occ * pw(1.0 - uv.x, oc_occ_f), 0.0, 1.0)) * (1.0 - clamp(ic_occ * pw(uv.x, ic_occ_f), 0.0, 1.0))
			* (1.0 - clamp(top_occ * pw(1.0 - uv.y, top_occ_f), 0.0, 1.0)) * (1.0 - clamp(bot_occ * pw(uv.y, bot_occ_f), 0.0, 1.0));
	occ = 1.0 - clamp(overall_occ * (occ - 1.0) + 1.0, 0.0, 1.0);
	// Wounds over the eye remove the overlay: the head's Disp.r at UV1.
	vec3 disp;
	vec4 dif;
	splatter_rt(UV, UV2, disp, dif);   // the head section's targets at UV1
	ALBEDO = scene * mix(vec3(1.0), occ_colour, occ);
	ALPHA = 1.0 - clamp(OVERLAY_REMOVAL * disp.r, 0.0, 1.0);   // x DI2's primitive fade byte / 254 (1 when shown)
}
