#[compute]
#version 450
// DI2 FSplatterPS planar element (recon/SHADERS_FLESH.md §3.3) baked into one section's UV0 render targets, one
// invocation per covered texel (gore-core splatter_rt.rs is the CPU twin). Blend: ADD (saturating) for Decal and
// ApplyMin, MAX for ApplyMax (§3.6); Disp.a = coverage (1 where a non-subtractive element's box covers the texel).
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct Texel {
	vec4 pos_dlen;   // bind-pose position, |deform| (cm)
	vec4 nrm_texel;  // interpolated normal (not normalised, like the VS output), texel index (y * res + x)
	uvec4 tri;       // the section triangle's vertex indices
	vec4 bary;       // barycentrics in it
};
struct Posed {
	vec4 p;          // skinned position (stamp space) at the time of the hit
	vec4 n;          // skinned normal
};
layout(set = 0, binding = 0, std430) restrict readonly buffer Texels { Texel t[]; } texels;
layout(set = 0, binding = 1, rgba8) uniform restrict image2D disp_rt;
layout(set = 0, binding = 2, rgba8) uniform restrict image2D dif_rt;
layout(set = 0, binding = 3) uniform sampler2DArray stamps;
// FSplatterVS_World (DI2's default, bReferencePose false): the section's vertices skinned at the hit.
layout(set = 0, binding = 4, std430) restrict readonly buffer PosedVerts { Posed v[]; } posed;

layout(push_constant, std430) uniform Stamp {
	vec4 origin_hs;  // origin, UVScale / 2
	vec4 ax_depth;   // projection axis (into the body), DepthScale (x ClothingDepthScale on cloth)
	vec4 ay_fade;    // image +u axis, ScaleVec.x
	vec4 az_wrap;    // image +v axis, clamp(AngleWrap, 0, 1)
	vec4 tex;        // displacement layer, diffuse layer, flags, covered texel count
	vec4 wound;      // WoundScale.rgb (x ClothingDisplacementScale on .r for cloth), cloth section (0 / 1)
	vec4 fx;         // FXScale
	vec4 range;      // InputMinimum, InputRange, posed (1 = project against the skinned vertices), radial (1)
} st;
// Radial mode (FSplatterPS_OneElement_Radial, DismemberWithDecal's cut band; RE_DISMEMBER.md §8), bind pose:
//   origin_hs = the radial decal matrix's row y (axial distance y = dot(row, (p, 1)))
//   ax_depth / ay_fade = SafeRegionMatrix rows y / z (s.y, s.z: the radial plane)

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(st.tex.w)) {
		return;
	}
	Texel tx = texels.t[i];
	vec3 pos = tx.pos_dlen.xyz;
	vec3 nrm = tx.nrm_texel.xyz;
	if (st.range.z > 0.5) {
		pos = posed.v[tx.tri.x].p.xyz * tx.bary.x + posed.v[tx.tri.y].p.xyz * tx.bary.y + posed.v[tx.tri.z].p.xyz * tx.bary.z;
		nrm = posed.v[tx.tri.x].n.xyz * tx.bary.x + posed.v[tx.tri.y].n.xyz * tx.bary.y + posed.v[tx.tri.z].n.xyz * tx.bary.z;
	}
	uint flags0 = uint(st.tex.z + 0.5);
	if (st.range.w > 0.5) {
		float y = dot(st.origin_hs.xyz, pos) + st.origin_hs.w;
		float sy = dot(st.ax_depth.xyz, pos) + st.ax_depth.w;
		float sz = dot(st.ay_fade.xyz, pos) + st.ay_fade.w;
		float r = sqrt(sy * sy + sz * sz);
		float w = (abs(y) < 1.0 ? 1.0 : 0.0) * (1.0 - clamp(4.0 * (r - 1.0), 0.0, 1.0));
		if (w == 0.0) {
			return;   // the PS writes 0 to both targets: no change, no coverage
		}
		vec2 ruv = vec2(r > 0.0 ? clamp((sz / r) * 0.5 + 0.5, 0.0, 1.0) : 0.0, clamp(y * 0.5 + 0.5, 0.0, 1.0));
		float rr = abs(st.range.y) > 1e-6 ? st.range.y : 1.0;
		vec4 rdc = vec4(0.0);
		vec3 rwd = vec3(0.0);
		if (st.tex.y >= -0.5) {
			rdc = st.fx * (textureLod(stamps, vec3(ruv, floor(st.tex.y + 0.5)), 0.0) - st.range.x) / rr * w;
		}
		if (st.tex.x >= -0.5) {
			rwd = st.wound.xyz * (textureLod(stamps, vec3(ruv, floor(st.tex.x + 0.5)), 0.0).rgb - st.range.x) / rr * w;
			if ((flags0 & 4u) != 0u) {
				rwd.x *= 3.0 / max(1.0, tx.pos_dlen.w);
			}
		}
		int rres = imageSize(disp_rt).x;
		int rk = int(tx.nrm_texel.w + 0.5);
		ivec2 rp = ivec2(rk % rres, rk / rres);
		vec4 rw0 = imageLoad(disp_rt, rp);
		vec4 rd0 = imageLoad(dif_rt, rp);
		if ((flags0 & 2u) != 0u) {
			rw0 = vec4(max(rw0.rgb, max(rwd, vec3(0.0))), 1.0);
			rd0 = max(rd0, max(rdc, vec4(0.0)));
		} else if ((flags0 & 1u) != 0u) {
			rw0.rgb = clamp(rw0.rgb + min(rwd, vec3(0.0)), 0.0, 1.0);
			rd0 = clamp(rd0 + min(rdc, vec4(0.0)), 0.0, 1.0);
		} else {
			rw0 = vec4(clamp(rw0.rgb + rwd, 0.0, 1.0), 1.0);
			rd0 = clamp(rd0 + rdc, 0.0, 1.0);
		}
		imageStore(disp_rt, rp, rw0);
		imageStore(dif_rt, rp, rd0);
		return;
	}
	vec3 d = pos - st.origin_hs.xyz;
	float hs = max(st.origin_hs.w, 1e-6);
	float lx = dot(d, st.ay_fade.xyz) / hs;
	float ly = dot(d, st.az_wrap.xyz) / hs;
	float zp = dot(d, -st.ax_depth.xyz) / max(st.ax_depth.w, 1e-5);
	if (!(abs(lx) < 1.0 && abs(ly) < 1.0 && abs(zp) < 1.0)) {
		return;
	}
	vec2 uv = clamp(vec2(lx, ly) * 0.5 + 0.5, 0.0, 1.0);
	float fade = clamp(st.ay_fade.w - min(1.0, abs(zp)) * st.ay_fade.w, 0.0, 1.0);
	float a = st.az_wrap.w;
	float kr = 2.0 * a - 1.0;
	float kg = 4.0 * a - 1.0;
	float dr = 1.0 - max(0.0, -kr);
	float dg = 1.0 - max(0.0, -kg);
	float fw = dot(nrm, -st.ax_depth.xyz) * 0.5 + 0.5;
	float wr = dr > 0.0 ? clamp((fw + kr) / dr, 0.0, 1.0) : 0.0;
	float wg = dg > 0.0 ? clamp((fw + kg) / dg, 0.0, 1.0) : 0.0;
	uint flags = uint(st.tex.z + 0.5);
	bool cloth = st.wound.w > 0.5;
	bool filtered = ((flags & 16u) != 0u && !cloth) || ((flags & 32u) != 0u && cloth);
	float rng = abs(st.range.y) > 1e-6 ? st.range.y : 1.0;
	vec4 dc = vec4(0.0);
	vec3 wd = vec3(0.0);
	if (st.tex.y >= -0.5) {
		dc = st.fx * (textureLod(stamps, vec3(uv, floor(st.tex.y + 0.5)), 0.0) - st.range.x) / rng * fade * wg;
	}
	if (st.tex.x >= -0.5 && !filtered) {
		wd = st.wound.xyz * (textureLod(stamps, vec3(uv, floor(st.tex.x + 0.5)), 0.0).rgb - st.range.x) / rng * fade * vec3(wr, wg, wg);
		if ((flags & 4u) != 0u) {
			wd.x *= 3.0 / max(1.0, tx.pos_dlen.w);
		}
	}
	int res = imageSize(disp_rt).x;
	int k = int(tx.nrm_texel.w + 0.5);
	ivec2 p = ivec2(k % res, k / res);
	vec4 w0 = imageLoad(disp_rt, p);
	vec4 d0 = imageLoad(dif_rt, p);
	if ((flags & 2u) != 0u) {
		w0 = vec4(max(w0.rgb, max(wd, vec3(0.0))), 1.0);
		d0 = max(d0, max(dc, vec4(0.0)));
	} else if ((flags & 1u) != 0u) {
		w0.rgb = clamp(w0.rgb + min(wd, vec3(0.0)), 0.0, 1.0);
		d0 = clamp(d0 + min(dc, vec4(0.0)), 0.0, 1.0);
	} else {
		w0 = vec4(clamp(w0.rgb + wd, 0.0, 1.0), 1.0);
		d0 = clamp(d0 + dc, 0.0, 1.0);
	}
	imageStore(disp_rt, p, w0);
	imageStore(dif_rt, p, d0);
}
