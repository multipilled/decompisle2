shader_type spatial;
// DI2 PSM_BloodDripsEnviro: a deferred-decal material (MD_DeferredDecal, DecalBlendMode DBM_CustomFluid, TwoSided)
// drawn on mesh particles (ParticleCube) as a mesh decal. Coverage transcribed from DI2's decompiled
// FMeshDecalsPS 1598 (FMeshParticleVertexFactory; PSMI_BloodDripsEnviro and _Big share it):
//   S = world position of the scene surface behind the pixel (scene depth along the view ray);
//   d = S - particle position; (dX, dY, dZ) = d . (particle transform rows = local X/Y/Z axes * size), UE cm;
//   div = Divide00 * DynamicParameter.y * particle alpha; uvYZ = (dY, dZ) / div + .5, uvXZ = (dX, dZ) / div + .5,
//   uvXY = (dX, dY) / div + .5;
//   n = TV_Global3dNoise(S / "3D Noise Scale").xy (absolute UE world), m = (sat(n) - .5) * 2;
//   side = lerp(T(sat(uvYZ) + DistortionHeight m), T(sat(uvXZ) + DistortionHeight m), |camera forward . UE Y|);
//   top  = T(sat(m * Distortion + uvXY));  T = T_RoundSplatter_A.r, f(x) = min(1, max(1e-6, 2x)^2);
//   coverage = f(top) * f(side) * clamp(n.y, 0.3, 1).
// DI2 writes coverage into its fluid buffer (MRT0 = ((1 - "Fluid Type" colour) * a, a), MRT1.x = a, MRT2 = (N, a));
// the global passes FFluidDetailFilterPS (Global 1856 / 1857) and FFluidComposePS (Global 1858) turn it into GBuffer
// base colour / specular / roughness (recon/RE_FLUIDS.md): sel = sat((1 - typeRGB) / typeW) picks the fluid colour
// (blood's "Fluid Type" (0, 1, 1) -> View[236]), colour = min(1, rgb^(FluidDensity * c^2)), base-colour alpha =
// colour.w * c, GBufferB = (metallic 0, specular 0.35, roughness FluidRoughness) at alpha sqrt(c).
// FluidDensity 10 and FluidRoughness 0.08 are AFluidParamsUpdateActor's constructor defaults (exe 0x1436ff060, traced
// by the gore session). The colours are game/data/fluids.json "compose" (DI2's FPostProcessSettings BloodColor ...,
// level_colors for Fuel / FuelEdge) picked by the MI's "color" (= its Fluid Type) with FFluidComposePS's selector:
// C = lerp(Water, Blood, sel.x), toward lerp(Fuel, FuelEdge, 1 - c^2) by sel.z, toward lerp(Acid, AcidEdge, 1 - c^2)
// by sel.y (View[231..236] = Acid, AcidEdge, Fuel, FuelEdge, Water, Blood: the member order, UNVERIFIED as in
// di2_fluid.gdshaderinc). Lit overlay with FFluidDetailFilterPS permutation 1's edge sharpening
// k = sat((c - .5) * sharpen + .5) * c (the detail-noise permutation 0 is not ported). DI2 multiplies the surface's
// base colour by T = min(1, C^(FluidDensity c^2)) and adds T * C.w * c; the overlay cannot read the surface, so it
// draws T at alpha k (the C.w term is dropped: APPROXIMATED).
// recon/PARTICLES.md 4.5.
render_mode cull_disabled, blend_mix, depth_draw_never;

uniform sampler2D splatter : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise3d : filter_linear, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float divide00 = 25.0;
uniform float noise_scale = 50.0;
uniform float distortion = 0.2;
uniform float distortion_height = 0.15;
uniform vec4 fluid_type = vec4(0.0, 1.0, 1.0, 0.0);  // the MI's "color" (blood)
uniform vec3 water_colour = vec3(0.95);
uniform vec3 blood_colour = vec3(0.88, 0.195553, 0.146666);
uniform vec3 fuel_colour = vec3(0.733507, 0.338542, 0.8125);
uniform vec3 fuel_edge_colour = vec3(0.947917, 0.69714, 0.16786);
uniform vec3 acid_colour = vec3(0.890017, 1.0, 0.057292);
uniform vec3 acid_edge_colour = vec3(0.782943, 1.0, 0.140625);
uniform float fluid_roughness = 0.08;
uniform float fluid_density = 10.0;
uniform float fluid_specular = 0.35;
uniform float sharpen = 12.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying vec3 v_origin;
varying vec3 v_ax;   // UE local X axis * size (Godot coordinates)
varying vec3 v_ay;   // UE local Y axis * size
varying vec3 v_az;   // UE local Z axis * size

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	v_origin = MODEL_MATRIX[3].xyz;
	// instance basis = S * B_ue * S (S swaps y / z): column 0 = UE X axis, column 1 = UE Z axis, column 2 = UE Y axis
	v_ax = MODEL_MATRIX[0].xyz;
	v_az = MODEL_MATRIX[1].xyz;
	v_ay = MODEL_MATRIX[2].xyz;
}

float shape(float x) {
	return min(1.0, pow(max(1e-6, x + x), 2.0));
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 sw = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
	vec3 d = sw - v_origin;
	float dx = 100.0 * dot(d, v_ax);
	float dy = 100.0 * dot(d, v_ay);
	float dz = 100.0 * dot(d, v_az);
	float div = divide00 * v_dyn.y * v_color.a;
	vec2 uv_yz = vec2(dy, dz) / div + 0.5;
	vec2 uv_xz = vec2(dx, dz) / div + 0.5;
	vec2 uv_xy = vec2(dx, dy) / div + 0.5;
	vec3 s_ue = vec3(sw.x, sw.z, sw.y) * 100.0;
	vec2 n = texture(noise3d, s_ue / noise_scale).xy;
	vec2 m = (clamp(n, 0.0, 1.0) - 0.5) * 2.0;
	vec3 fwd = -INV_VIEW_MATRIX[2].xyz;
	float a_yz = texture(splatter, clamp(uv_yz, 0.0, 1.0) + distortion_height * m).r;
	float a_xz = texture(splatter, clamp(uv_xz, 0.0, 1.0) + distortion_height * m).r;
	float side = shape(mix(a_yz, a_xz, abs(fwd.z)));
	float top = shape(texture(splatter, clamp(m * distortion + uv_xy, 0.0, 1.0)).r);
	float cov = top * side * clamp(n.y, 0.3, 1.0);
	if (cov < 0.001) {
		discard;
	}
	float c = clamp(cov, 0.0, 1.0);
	float k = clamp((c - 0.5) * sharpen + 0.5, 0.0, 1.0) * c;
	vec3 sel = clamp((1.0 - fluid_type.rgb) / (fluid_type.w + 1e-7), 0.0, 1.0);
	float e = 1.0 - k * k;
	vec3 col = mix(water_colour, blood_colour, sel.x);
	col = mix(col, mix(fuel_colour, fuel_edge_colour, e), sel.z);
	col = mix(col, mix(acid_colour, acid_edge_colour, e), sel.y);
	ALPHA = k;  // DI2: base colour at colour.w * c, specular / roughness at sqrt(c) (one alpha here)
	ALBEDO = min(vec3(1.0), pow(max(col, vec3(1e-6)), vec3(fluid_density * k * k)));
	ROUGHNESS = fluid_roughness;
	SPECULAR = sqrt(fluid_specular * 0.5);  // UE F0 = 0.08 S, Godot F0 = 0.16 S^2 (as di2_fluid.gdshaderinc)
	// the overlay shades the scene surface behind the cube: its normal from the reconstructed position
	vec3 nv = normalize(cross(dFdx(vp.xyz), dFdy(vp.xyz)));
	NORMAL = dot(nv, VIEW) < 0.0 ? -nv : nv;
}
