#[compute]
#version 450
// DI2's eye-adaptation histogram (FHistogramCS, Global 2481, extracted/shaders/lighting/Global_002481_HistogramCS.hlsl)
// for game/scripts/di2_post.gd. Per input texel: luminance = mean(rgb) * OneOverPreExposure, max(LuminanceMin),
// log2, saturate(* HistogramScale + HistogramBias) * 63; the weight is split bilinearly between the two neighbouring
// of 64 bins, the lower bin's share scaled by BlackHistogramBucketInfluence when it is bin 0; the meter mask is DI2's
// default (white, weight 1). DI2 histograms the half-resolution scene colour: one invocation here = one half-res
// texel = the mean of a 2x2 full-res block (APPROXIMATED: DI2's downsample filter is not traced). Weights are summed in
// 1/1024 fixed point (no float atomics in GLSL); only their ratios matter (percent cut-offs, weighted mean).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16f) uniform readonly image2D scene;
layout(set = 0, binding = 1, std430) buffer Hist { uint bins[64]; };
layout(push_constant, std430) uniform Params {
	vec2 size;
	float one_over_pre_exposure;
	float luminance_min;
	float histogram_scale;
	float histogram_bias;
	float black_bucket_influence;
	float pad;
} pc;

shared uint lbins[64];

void main() {
	uint li = gl_LocalInvocationIndex;
	lbins[li] = 0u;
	barrier();
	ivec2 p = ivec2(gl_GlobalInvocationID.xy) * 2;
	if (p.x + 1 < int(pc.size.x) && p.y + 1 < int(pc.size.y)) {
		vec3 c = imageLoad(scene, p).rgb + imageLoad(scene, p + ivec2(1, 0)).rgb + imageLoad(scene, p + ivec2(0, 1)).rgb
			+ imageLoad(scene, p + ivec2(1, 1)).rgb;
		c *= 0.25 * pc.one_over_pre_exposure;
		float l = max(pc.luminance_min, dot(c, vec3(1.0 / 3.0)));
		float pos = clamp(log2(l) * pc.histogram_scale + pc.histogram_bias, 0.0, 1.0) * 63.0;
		uint b = uint(pos);
		uint b1 = min(63u, b + 1u);
		float f = fract(pos);
		float w0 = (b == 0u) ? (1.0 - f) * pc.black_bucket_influence : 1.0 - f;
		atomicAdd(lbins[b], uint(w0 * 1024.0 + 0.5));
		atomicAdd(lbins[b1], uint(f * 1024.0 + 0.5));
	}
	barrier();
	atomicAdd(bins[li], lbins[li]);
}
