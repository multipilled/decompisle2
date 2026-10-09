// DI2's fluid compose for opaque world materials (recon/RE_FLUIDS.md §5-6). DI2Fluids draws each puddle's
// M_FluidDecal coverage (dither and opacity included) into a top-down fluid map (di2_fluid_map: a = coverage,
// alpha-over; r = the puddles' surface height, coverage-weighted, over di2_fluid_height). Per pixel this applies the
// decal's depth fade (1 - |dy| / DecalSize.X), FFluidDetailFilterPS's sharpening (permutation 1:
// sat((c - .5) * 12 + .5) * c) and FFluidComposePS: the surface is multiplied by the fluid's transmittance
// T = min(1, C^(FluidDensity * c^2)) (blend RT1 = {Add, SrcAlpha, SrcColor}: dst * T + T * w * c), and specular /
// roughness move to (0.35, FluidRoughness) by sqrt(c) (RT2, G|B). The colour C comes from FFluidComposePS's type
// selector: sel = sat((1 - FluidType.rgb) / (t.w + 1e-7)) (t.w = 0 here), C = lerp(Water, Blood, sel.x), then toward
// lerp(Fuel, FuelEdge, 1 - c^2) by sel.z (and toward the acid pair by sel.y: no acid fluid is produced, not encoded).
// The map's g / b hold 1 - FluidType.r / 1 - FluidType.b, coverage-weighted (blood (0, 1, 1) -> g; fuel (1, 1, 0) -> b).
// View[231..236] = Acid, AcidEdge, Fuel, FuelEdge, Water, Blood is the FPostProcessSettings member order (UNVERIFIED
// #61); which GBuffer RT1 is and the detail filter's ripple normal are UNVERIFIED (#54).
// Usage: #include "res://shaders/di2_fluid.gdshaderinc" and, at the end of fragment(),
//   di2_fluid_compose((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, ALBEDO, ROUGHNESS, SPECULAR);

global uniform sampler2D di2_fluid_map;
global uniform vec4 di2_fluid_area;     // world x, z of the map's corner, its size x, z (m)
global uniform vec4 di2_fluid_color;    // FPostProcessSettings BloodColor (rgb, w)
global uniform vec4 di2_fluid_fuel;     // FuelColor (the level's BP_BasicTimeOfDay post process, fluids.json level_colors)
global uniform vec4 di2_fluid_fuel_edge; // FuelEdgeColor (same source)
global uniform vec4 di2_fluid_water;    // WaterColor (FPostProcessSettings ctor 0x143a89db0)
global uniform vec4 di2_fluid_params;   // FluidDensity, FluidRoughness, compose Specular (UE), DecalSize.X (m)
global uniform vec2 di2_fluid_height;   // the r channel's world height range (m)

float di2_fluid_coverage_t(vec3 wp, out vec4 t) {
	t = vec4(0.0);
	vec2 uv = (wp.xz - di2_fluid_area.xy) / di2_fluid_area.zw;
	if (uv.x <= 0.0 || uv.y <= 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
		return 0.0;
	}
	t = texture(di2_fluid_map, uv);
	if (t.a < 0.001) {
		return 0.0;
	}
	float h = mix(di2_fluid_height.x, di2_fluid_height.y, clamp(t.r / t.a, 0.0, 1.0));
	return t.a * max(0.0, 1.0 - abs(wp.y - h) / di2_fluid_params.w);
}

float di2_fluid_coverage(vec3 wp) {
	vec4 t;
	return di2_fluid_coverage_t(wp, t);
}

void di2_fluid_compose(vec3 wp, inout vec3 albedo, inout float roughness, inout float specular) {
	vec4 t;
	float c = di2_fluid_coverage_t(wp, t);
	if (c < 0.001) {
		return;
	}
	c = clamp((c - 0.5) * 12.0 + 0.5, 0.0, 1.0) * c;
	if (c < 0.001) {
		return;
	}
	// FFluidComposePS's type selector (sel.y, acid, not encoded).
	vec2 sel = clamp(t.gb / 1e-7, 0.0, 1.0);
	vec4 col = mix(di2_fluid_water, di2_fluid_color, sel.x);
	col = mix(col, mix(di2_fluid_fuel, di2_fluid_fuel_edge, 1.0 - c * c), sel.y);
	vec3 tr = min(vec3(1.0), pow(max(col.rgb, vec3(1e-6)), vec3(di2_fluid_params.x * c * c)));
	albedo = tr * (albedo + col.w * c);
	float s = sqrt(c);
	// UE Specular S -> F0 = 0.08 S; Godot SPECULAR -> F0 = 0.16 SPECULAR^2.
	specular = mix(specular, sqrt(0.5 * di2_fluid_params.z), s);
	roughness = mix(roughness, di2_fluid_params.y, s);
}
