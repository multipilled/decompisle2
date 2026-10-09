// Shared by flesh.gdshader and eye_occlusion.gdshader: DI2 splatter render targets, and severing.

// DI2 splatter render targets (GoreBody bakes every stamp into them, gore-core splatter_rt.rs):
//   splat_disp = DispSplatterRT (R wound depth, G blood, B bruise, A coverage)
//   splat_dif  = DiffuseSplatterRT (R drips, G cauterisation, B fuel, A water)
// sampled at UV0, or at UV1 (Godot UV2) for the eyes, eye overlay and hair, which read the head section's targets.
uniform sampler2D splat_disp : filter_linear, repeat_enable;
uniform sampler2D splat_dif : filter_linear, repeat_enable;
uniform bool has_splat_rt = false;
uniform bool splat_uv2 = false;

void splatter_rt(vec2 uv, vec2 uv2, out vec3 disp, out vec4 dif) {
	disp = vec3(0.0);
	dif = vec4(0.0);
	if (has_splat_rt) {
		vec2 t = splat_uv2 ? uv2 : uv;
		disp = texture(splat_disp, t).rgb;
		dif = texture(splat_dif, t);
	}
}

uniform int severed_mask = 0;
/// This section's triangles were split by DI2's dismember (GoreBody.di2_cut): the cut-slot discard doesn't apply.
uniform bool di2_cut = false;
uniform bool is_piece = false;
uniform int piece_slot = 0;
/// Cut slot a cap closes: its own (~0.5) weight there must not hide it.
uniform int cap_slot = -1;
/// Per cut slot: plane normal (towards the severed side) and offset in bind pose; zero = cut at the joint.
uniform vec4 cut_planes[12];

float pick(vec4 v, int c) {
	return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w));
}

float slot_w(int k, vec4 a, vec4 b, vec4 c) {
	return k < 4 ? pick(a, k) : (k < 8 ? pick(b, k - 4) : pick(c, k - 8));
}

// How far past cut k a point is (> 0 = on the severed side), in slot-weight units (GoreBody's PLANE_SCALE).
float past_cut(int k, vec3 p, vec4 a, vec4 b, vec4 c) {
	vec4 pl = cut_planes[k];
	float side = dot(pl.xyz, pl.xyz) > 0.25 ? (dot(pl.xyz, p) - pl.w) * 12.0 : 1.0;
	return min(slot_w(k, a, b, c) - 0.5, side);
}
