// Shared light() of DI2's MSM_TwoSidedFoliage particle masters (DI2Particles): the VAT fluid, dither and debris
// shaders write ALBEDO = base colour + subsurface colour, BACKLIGHT = the subsurface colour, ROUGHNESS / METALLIC /
// SPECULAR. UE 4.27 lights TwoSidedFoliage's indirect diffuse with DiffuseColor + SubsurfaceColor
// (BasePassPixelShader DiffuseColorForIndirect += SubsurfaceColor): Godot's ambient / sky uses ALBEDO, so the sum goes
// there; the direct terms below use the base colour (ALBEDO - BACKLIGHT) only. UE's extra skylight lookup along -N
// for the subsurface (SkyLightDiffuse) is folded into that ambient term (APPROXIMATED).
// UE 4.27 TwoSidedBxDF = DefaultLit (Lambert + GGX / SmithJointApprox / Schlick, Specular 0.5) + transmission:
// WrapNoL = sat((-NoL + 0.5) / 1.5^2), Scatter = D_GGX(0.36, sat(-VoL)), * SubsurfaceColor. DI2's deferred light
// pass is custom and not decoded (recon/DANI.md 7.1); this is the stock UE BxDF.
void light() {
	float NoL = dot(NORMAL, LIGHT);
	vec3 lc = LIGHT_COLOR * ATTENUATION;
	if (NoL > 0.0) {
		vec3 H = normalize(VIEW + LIGHT);
		float NoV = clamp(abs(dot(NORMAL, VIEW)) + 1e-5, 0.0, 1.0);
		float NoH = clamp(dot(NORMAL, H), 0.0, 1.0);
		float VoH = clamp(dot(VIEW, H), 0.0, 1.0);
		// Godot multiplies DIFFUSE_LIGHT by ALBEDO (base + subsurface): scale it back to the base colour
		vec3 base = max(ALBEDO - BACKLIGHT, vec3(0.0));
		DIFFUSE_LIGHT += lc * NoL * (1.0 / PI) * base / max(ALBEDO, vec3(1e-5));
		float a2 = max(ROUGHNESS * ROUGHNESS * ROUGHNESS * ROUGHNESS, 1e-8);
		float d = (NoH * a2 - NoH) * NoH + 1.0;
		float D = a2 / (PI * d * d);
		float a = sqrt(a2);
		float vis = 0.5 / (NoL * (NoV * (1.0 - a) + a) + NoV * (NoL * (1.0 - a) + a));
		vec3 f0 = mix(vec3(0.04), max(ALBEDO - BACKLIGHT, vec3(0.0)), METALLIC);
		float fc = pow(1.0 - VoH, 5.0);
		vec3 F = clamp(50.0 * f0.g, 0.0, 1.0) * fc + (1.0 - fc) * f0;
		SPECULAR_LIGHT += lc * NoL * D * vis * F;
	}
	float wrap_nol = clamp((-NoL + 0.5) / 2.25, 0.0, 1.0);
	float x = clamp(-dot(VIEW, LIGHT), 0.0, 1.0);
	float sa2 = 0.36;
	float sd = (x * sa2 - x) * x + 1.0;
	float scatter = sa2 / (PI * sd * sd);
	SPECULAR_LIGHT += lc * wrap_nol * scatter * BACKLIGHT * (1.0 / PI);
}
