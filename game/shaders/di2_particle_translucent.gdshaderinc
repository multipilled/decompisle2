// Shared tail of DI2's lit translucent particle masters (DI2Particles): PSM_Smoke_Transluscent_Lit (PS 11551),
// PSM_Liquid_Bits_Simple (PS 11162 / 13983 / 12193, GPU 11184 / 13978), PSM_Liquid_Bits_Complex (GPU 12109),
// PSM_Liquid_Transluscent_Lit and PSM_Whitewater. All of them compute, after their own colour / opacity:
//   transmission = sat(pow(max(opacity_pre_saturate, 1e-6), Opacity To Transmission Curve) * (Min - Max) + Max)
//   absorbed = min(1, colour^(10 * sat(Absorption Density) * min(transmission, 1) * opacity)) * colour
// and light the absorbed colour with DI2's translucency-volume term (g = 2 * min(transmission, 1) - 1):
//   ambient: SH irradiance along -g N blended with a Cornette-Shanks phase (k = -0.98 g) along the SH's dominant
//            direction, by sat(g) (Godot applies its own ambient to ALBEDO here: approximated);
//   directional: light * absorbed * ((sat(L . (-g N)) + (1 - |g|) / pi) * (1 - sat(g)) + 0.25 * CS(L . V) * sat(g)),
//   CS(mu) = 3 (1 - k^2)(1 + mu^2) / (2 (2 + k^2)(1 + k^2 - 2 k mu)^1.5).
// The including shader writes ALBEDO = absorbed and BACKLIGHT = vec3(transmission); light() reads g from it.
// DI2's Fury-mode desaturation (cb0[225], "Fury Highlight Desaturation", "Is Blood (For Fury Mode)") is a global
// gameplay view mode and is not ported (recon/PARTICLES.md 4.3).

float di2_transmission(float opacity_raw, float curve, float min_t, float max_t) {
	return clamp(pow(max(opacity_raw, 1e-6), curve) * (min_t - max_t) + max_t, 0.0, 1.0);
}

vec3 di2_absorbed(vec3 col, float trans, float op, float absorption_density) {
	float e = 10.0 * clamp(absorption_density, 0.0, 1.0) * min(trans, 1.0) * op;
	return min(vec3(1.0), pow(max(col, vec3(1e-6)), vec3(e))) * col;
}

// BC5 / TC_Normalmap tangent normal: xy * 2 - 1, z = sqrt(max(0, 1 - xy.xy))
vec3 di2_bc5(vec2 xy) {
	vec3 n;
	n.xy = xy * 2.0 - 1.0;
	n.z = sqrt(max(0.0, 1.0 - dot(n.xy, n.xy)));
	return n;
}

void light() {
	float g = 2.0 * min(BACKLIGHT.r, 1.0) - 1.0;
	float k = -0.98 * g;
	float mu = dot(LIGHT, VIEW);
	float cs = 3.0 * (1.0 - k * k) * (1.0 + mu * mu) / (2.0 * (2.0 + k * k) * pow(max(1.0 + k * k - 2.0 * k * mu, 1e-4), 1.5));
	float sg = clamp(g, 0.0, 1.0);
	float term = (clamp(dot(LIGHT, -g * NORMAL), 0.0, 1.0) + (1.0 - abs(g)) / PI) * (1.0 - sg) + 0.25 * cs * sg;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * term * (1.0 / PI);
}
