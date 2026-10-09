// DI2 eyeball: M_EyeRefractive (recon/SHADERS_FLESH.md §14, PS 3791) shaded with UE 4.27's MSM_Eye lighting
// (ShadingModels.ush EyeBxDF, the non-IRIS_NORMAL path DI2's GBuffer layout matches: IrisNormal in CustomData.yz,
// IrisDistance in Metallic, IrisMask = 1 - CustomData.w).
//   cornea: GGX specular on the wet surface normal N; DI2's light pass (recon/DEFERRED_LIGHTING.md §4.9): Specular 1.0
//   is stored as S' = 0.49606, so F0 = 0.08 * S' = 0.0397, and the specular is x 2*S' = 0.99213
//   sclera: N.L;  iris: (IrisNormal.L) x caustic, the caustic normal pulled toward -N by IrisMask x IrisDistance
// Body-mesh section: vertex data as flesh.gdshader (CUSTOM0.xyz bind pose, CUSTOM0.w subsection x 256 + deform cm,
// CUSTOM1..3 cut-slot weights); the head section's splatter targets at UV1 (blood in the eye).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/flesh_splatter.gdshaderinc"

uniform int layer = 5;
uniform bool section_hidden = false;
uniform int sub_hidden_lo = 0;
uniform int sub_hidden_hi = 0;
uniform bool use_alpha_clip = false;
uniform float alpha_clip = 0.333;
uniform bool two_sided = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;   // ScleraColor
uniform bool has_albedo = false;
uniform sampler2D iris_tex : source_color, filter_linear_mipmap, repeat_disable;     // IrisColor (View clamped)
uniform sampler2D eye_wet_n : filter_linear_mipmap, repeat_disable;                  // NormalMap = T_EyeWet_N
uniform sampler2D eye_dir_n : filter_linear_mipmap, repeat_enable;                   // T_Eye_N
uniform sampler2D midplane : filter_linear_mipmap, repeat_enable;                    // T_EyeMidPlaneDisplacement_Example
uniform sampler2D blood_detail : filter_linear_mipmap, repeat_enable;                // T_SkinBloodSplatterDetail_A
uniform bool has_iris = false;
uniform bool has_eye_wet_n = false;
uniform bool has_eye_dir_n = false;
uniform bool has_midplane = false;
uniform float iris_scale = 1.0;
uniform float limbus_w_color = 0.06;
uniform float limbus_w_shading = 0.05;
uniform float flatten_normal = 0.95;
uniform float lens_ior = 1.376;
uniform float iris_depth = 1.0;
uniform float pupil_size = 0.75;
uniform float iris_brightness = 0.6;
uniform float aggressive_iris = 0.0;
uniform float limbus_darkening = 0.0;
uniform float limbus_darkening_falloff = 6.0;
uniform float sclera_brightness = 0.22;
uniform float veins = 1.0;
uniform float sclera_roughness = 0.1;
uniform float iris_roughness = 0.1;
uniform float iris_concavity_scale = 0.15;
uniform float iris_concavity_power = 0.55;
uniform vec3 blood_colour = vec3(0.963542, 0.843099, 0.843099);
const float IRIS_R = 0.16;                                         // compiled-in iris UV radius
const vec3 AGGRESSIVE_EYES_COLOR = vec3(1.5, 0.718995, 0.691243);  // MPC
const float EYE_BLOOD_MAX = 0.6;                                   // ChrSplatterEyeBloodMaxCoverage
const float EYE_BLOOD_DETAIL = 1.5;                                // ChrSplatterEyeBloodDetailStrength
const float BLOOD_DENSITY = 12.0;                                  // ChrSplatterBloodDensity

varying vec3 rest_pos;
varying flat int sub_off;
varying vec4 sw0;
varying vec4 sw1;
varying vec4 sw2;
// fragment -> light: DI2's eye GBuffer terms
varying vec3 v_iris_n;
varying float v_iris_mask;
varying float v_iris_dist;

float tent(float x) { return 1.0 - abs(2.0 * x - 1.0); }
float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }
float smooth01(float x) { return x * x * (3.0 - 2.0 * x); }
vec3 unpack_dx(vec4 t) {
	vec2 xy = t.rg * 2.0 - 1.0;
	xy.y = -xy.y; // Unreal (DirectX) normal maps
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
}

void vertex() {
	rest_pos = CUSTOM0.xyz;
	sw0 = CUSTOM1;
	sw1 = CUSTOM2;
	sw2 = CUSTOM3;
	int sid = int(floor(CUSTOM0.w / 256.0));
	// Hidden subsection: the whole triangle is discarded (flat, the provoking vertex's id). Collapsing vertices
	// stretched triangles whose corners straddle a subsection seam.
	sub_off = (((sid < 32 ? (sub_hidden_lo >> sid) : (sub_hidden_hi >> (sid - 32))) & 1) == 1) ? 1 : 0;
}

void fragment() {
	if (sub_off == 1) discard;
	// Severing, as the rest of the body.
	float sev = -1.0;
	for (int k = 0; k < 12; k++) {
		if (((severed_mask >> k) & 1) == 1 && k != cap_slot) {
			sev = max(sev, past_cut(k, rest_pos, sw0, sw1, sw2));
		}
	}
	if (di2_cut) {
	} else if (is_piece) {
		if (past_cut(piece_slot, rest_pos, sw0, sw1, sw2) < 0.0 || sev > 0.0) discard;
	} else if (sev > 0.0) {
		discard;
	}
	if (section_hidden) discard;

	vec3 T = TANGENT;
	vec3 B = BINORMAL;
	vec3 Nv = NORMAL;
	vec3 V = VIEW;
	// +u / +v surface directions from the UV derivatives (the iris parallax runs along them).
	vec3 px = dFdx(VERTEX);
	vec3 py = dFdy(VERTEX);
	vec2 ux = dFdx(UV);
	vec2 uy = dFdy(UV);
	float det = ux.x * uy.y - uy.x * ux.y;
	vec3 pu = abs(det) > 1e-12 ? (px * uy.y - py * ux.y) / det : T;
	vec3 pv = abs(det) > 1e-12 ? (py * ux.x - px * uy.x) / det : B;

	vec2 iuv = (UV - 0.5) / iris_scale + 0.5;                 // x (1 + ChrIrisShrinkFixAmount ...) = 1 at MPC defaults
	float d = length(iuv - 0.5);
	float maskC = smooth01(clamp(1.0 - (d - (IRIS_R - limbus_w_color)) / limbus_w_color, 0.0, 1.0));
	float maskS = smooth01(clamp(1.0 - (d - (IRIS_R - limbus_w_shading)) / limbus_w_shading, 0.0, 1.0));
	vec3 nw = has_eye_wet_n ? unpack_dx(texture(eye_wet_n, UV)) : vec3(0.0, 0.0, 1.0);
	vec3 nt = mix(nw, vec3(0.0, 0.0, 1.0), mix(flatten_normal, 1.0, maskC));
	vec3 N = normalize(nt.x * T + nt.y * B + nt.z * Nv);
	vec3 ne = has_eye_dir_n ? unpack_dx(texture(eye_dir_n, UV)) : vec3(0.0, 0.0, 1.0);
	vec3 Ei = normalize(ne.x * T + ne.y * B + ne.z * Nv);
	// Refraction at the cornea onto the recessed iris plane (§14.4).
	float eta = 1.00029 / lens_ior;
	float c = dot(N, V);
	float k = 1.0 - eta * eta * (1.0 - c * c);
	vec3 Rd = normalize((eta * c - sqrt(max(k, 0.0))) * N - eta * V);
	vec2 iuvr = iuv;
	if (has_midplane) {
		float h0 = texture(midplane, vec2(0.5 + IRIS_R * iris_scale, 0.5)).r;
		float h = max(0.0, texture(midplane, UV).r - h0) * iris_depth;
		float ve = dot(V, Ei);
		vec3 off = -Rd * h / (0.325 + 0.675 * ve * ve);
		vec3 tu = normalize(pu - dot(pu, Ei) * Ei);
		vec3 tv = normalize(pv - dot(pv, Ei) * Ei);
		iuvr = iuv - maskC * IRIS_R * vec2(dot(tu, off), dot(tv, off));
	}
	// Pupil, iris, limbus, sclera (§14.5).
	vec2 c0 = (iuvr - 0.5) / (2.0 * IRIS_R);
	float L = length(c0);
	float pp = clamp(pupil_size * (1.0 - 2.0 * L), 0.0, 1.0);
	vec2 c1 = (L > 0.0 ? c0 / L : vec2(0.0)) * 0.5 * (1.0 - pp);
	vec3 iris = has_iris ? texture(iris_tex, 0.5 + c1).rgb : vec3(0.1);
	iris *= aggressive_iris * AGGRESSIVE_EYES_COLOR + iris_brightness;
	iris *= 1.0 - pw(min(1.0, length(limbus_darkening * c1)), limbus_darkening_falloff);
	vec3 sclera_rgb = has_albedo ? texture(albedo_tex, UV).rgb : vec3(0.9);
	vec3 sclera = mix(vec3(1.0), sclera_rgb, veins) * sclera_brightness;
	vec3 col = mix(sclera, iris, maskC);
	// Blood from wounds over the eye (§14.6): the head section's targets at UV1.
	vec3 D;
	vec4 dif;
	splatter_rt(UV, UV2, D, dif);
	float Eb = min(EYE_BLOOD_MAX, max(max(D.r, D.g), D.b));
	float bn = texture(blood_detail, 0.5 * (UV + 0.2 * (D.r + D.g - D.b))).r;
	Eb = clamp(tent(Eb) * (bn - 0.5) * EYE_BLOOD_DETAIL + Eb, 0.0, 1.0);
	col *= min(vec3(1.0), exp2(BLOOD_DENSITY * Eb * log2(max(blood_colour, vec3(1e-6)))));

	ALBEDO = col;
	NORMAL = N;
	ROUGHNESS = mix(sclera_roughness, iris_roughness, maskC);
	METALLIC = 0.0;
	// Ambient (DI2 reflection pass, recon/DEFERRED_LIGHTING.md §6): MSM_Eye's SpecularColor is 0.028, x 2*S' = 0.99213;
	// Godot's ambient F0 = 0.16 * SPECULAR^2.
	SPECULAR = sqrt(0.028 * 0.99213 / 0.16);
	v_iris_n = Ei;
	v_iris_mask = min(1.0, maskS);
	v_iris_dist = min(1.0, pw(length(iuvr - 0.5) / IRIS_R * iris_concavity_scale, iris_concavity_power));
}

// UE 4.27 EyeBxDF (ShadingModels.ush), non-IRIS_NORMAL path.
void light() {
	vec3 N = NORMAL;
	float NoL = clamp(dot(N, LIGHT), 0.0, 1.0);
	vec3 lc = LIGHT_COLOR * ATTENUATION;
	// F_Schlick at V.H with F0 = 0.08 * S' (S' = 0.49606: the eye's Specular 1.0 through the GBuffer byte); the iris /
	// sclera transmission uses the same F.
	vec3 H = normalize(VIEW + LIGHT);
	float VoH = clamp(dot(VIEW, H), 0.0, 1.0);
	float fc = pow(1.0 - VoH, 5.0);
	float f0 = 0.08 * 0.49606;
	float F = fc + (1.0 - fc) * f0;                                     // sat(50 * f0) = 1
	// Cornea specular: D_GGX x Vis_SmithJointApprox x F, x 2*S' (= 0.99213) x the light's specular amount.
	if (NoL > 0.0) {
		float NoV = clamp(abs(dot(N, VIEW)) + 1e-5, 0.0, 1.0);
		float NoH = clamp(dot(N, H), 0.0, 1.0);
		float a2 = max(ROUGHNESS * ROUGHNESS * ROUGHNESS * ROUGHNESS, 1e-8);
		float dd = (NoH * a2 - NoH) * NoH + 1.0;
		float Dg = a2 / (PI * dd * dd);
		float a = sqrt(a2);
		float vis = 0.5 / (NoL * (NoV * (1.0 - a) + a) + NoV * (NoL * (1.0 - a) + a));
		SPECULAR_LIGHT += lc * NoL * Dg * vis * F * 0.99213 * SPECULAR_AMOUNT;
	}
	// Iris / sclera diffuse ("Transmission" in UE's eye model), Lambert x (1 - F) with F at V.H.
	vec3 caustic_n = normalize(mix(v_iris_n, -N, v_iris_mask * v_iris_dist));
	float iris_nol = clamp(dot(v_iris_n, LIGHT), 0.0, 1.0);
	float power = mix(12.0, 1.0, iris_nol);
	float caustic = 0.8 + 0.2 * (power + 1.0) * pow(clamp(dot(caustic_n, LIGHT), 0.0, 1.0), power);
	float iris_term = iris_nol * caustic;
	float sclera_term = NoL;
	DIFFUSE_LIGHT += lc * mix(sclera_term, iris_term, v_iris_mask) * (1.0 - F) * (1.0 / PI);
}
