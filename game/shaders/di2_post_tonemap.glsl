#[compute]
#version 450
// DI2's tonemap pass (FTonemapPS p9533, Global 2527, + FTonemapVS p0, Global 2585; extracted/shaders/lighting/) for
// game/scripts/di2_post.gd, run on Godot's HDR colour buffer before Godot's own (linear, white 1) tonemap:
//   scene * OneOverPreExposure * ColorScale0 (+ bloom: NOT PORTED, UNVERIFIED #57)  -> absolute luminance
//   (mesopic / Purkinje block: NOT PORTED; identity for daylight luminances, UNVERIFIED #57)
//   * DefaultEyeExposure (VS o1.x = cb0[71].x: the eye adaptation's smoothed exposure)
//   * vignette 1 / (1 + |TonemapperParams.x * v|^2)^2, v = ScreenPos * (1, H/W) * sqrt(2) / sqrt(1 + (H/W)^2) (VS)
//   (film grain: GrainIntensity 0 -> 1; chromatic aberration / sharpen: NOT PORTED)
//   sRGB -> AP1 (the PS's 0.613191485.. matrix), * EditorNITLevel * 1e-4, ST-2084 (PQ) encode,
//   LUT lookup at PQ * 31/32 + 1/64 (32^3 LUT from DI2's FLUTBlenderPS, see di2_post.gd), * 1.05.
// The LUT already holds display (sRGB-encoded) values; Godot's tonemap then re-encodes linear -> sRGB, so the result
// is written back sRGB-decoded.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16f) uniform image2D color;
layout(set = 0, binding = 1) uniform sampler3D lut;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float scale;          // OneOverPreExposure * ColorScale0 * DefaultEyeExposure (scene buffer -> exposed)
	float vignette;       // TonemapperParams.x = VignetteIntensity
	float nit_level;      // EditorNITLevel
	float pad0;
	float pad1;
	float pad2;
} pc;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= int(pc.size.x) || p.y >= int(pc.size.y)) {
		return;
	}
	vec4 src = imageLoad(color, p);
	vec3 c = src.rgb * pc.scale;
	vec2 screen = (vec2(p) + 0.5) / pc.size * 2.0 - 1.0;
	float aspect = pc.size.y / pc.size.x;
	vec2 v = screen * vec2(1.0, aspect) * (1.41421354 / sqrt(aspect * aspect + 1.0)) * pc.vignette;
	float vm = 1.0 / (1.0 + dot(v, v));
	c *= vm * vm;
	vec3 ap1 = vec3(dot(vec3(0.613191485, 0.33951208, 0.0473663323), c), dot(vec3(0.0702069029, 0.916335821, 0.0134500116), c),
		dot(vec3(0.0206188709, 0.109567292, 0.869606733), c));
	vec3 y = pow(max(ap1 * pc.nit_level * 1e-4, vec3(0.0)), vec3(0.159301758));
	vec3 pq = pow((y * 18.8515625 + 0.8359375) / (y * 18.6875 + 1.0), vec3(78.84375));
	vec3 o = textureLod(lut, pq * 0.96875 + 0.015625, 0.0).rgb * 1.05;
	imageStore(color, p, vec4(srgb_to_linear(max(o, vec3(0.0))), src.a));
}
