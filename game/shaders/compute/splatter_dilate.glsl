#[compute]
#version 450
// DI2 FSplatterDilatePS_H / _V (recon/SHADERS_FLESH.md §3.7): one texel per pass, src -> dst over the whole target.
// Covered texels (Disp.a = 1) pass through; empty ones take the neighbour with the highest coverage (left/up first).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) uniform restrict readonly image2D src0;   // DispSplatterRT (alpha = coverage)
layout(set = 0, binding = 1, rgba8) uniform restrict readonly image2D src1;   // DiffuseSplatterRT
layout(set = 0, binding = 2, rgba8) uniform restrict writeonly image2D dst0;
layout(set = 0, binding = 3, rgba8) uniform restrict writeonly image2D dst1;
layout(push_constant, std430) uniform Pass {
	ivec4 dir;  // (1, 0, 1, 0) horizontal, (0, 1, 0, 0) vertical
} pc;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(src0);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	vec4 c0 = imageLoad(src0, p);
	vec4 c1 = imageLoad(src1, p);
	if (c0.a >= 1.0) {
		imageStore(dst0, p, vec4(c0.rgb, 1.0));
		imageStore(dst1, p, c1);
		return;
	}
	for (int s = -1; s <= 1; s += 2) {
		ivec2 n = p + pc.dir.xy * s;
		if (n.x < 0 || n.y < 0 || n.x >= size.x || n.y >= size.y) {
			continue;
		}
		vec4 a = imageLoad(src0, n);
		if (c0.a < a.a) {
			c0 = a * sign(a.a);
			c1 = imageLoad(src1, n) * sign(a.a);
		}
	}
	c0.a = pc.dir.z == 1 ? (c0.a > 0.0 ? 0.5 : 0.0) : 0.0;
	imageStore(dst0, p, c0);
	imageStore(dst1, p, c1);
}
