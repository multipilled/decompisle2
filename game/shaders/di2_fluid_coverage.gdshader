shader_type canvas_item;
render_mode blend_mix, unshaded;
// One puddle's M_FluidDecal coverage in DI2Fluids' top-down fluid map (FDeferredDecalPS, shader archive 10960;
// recon/RE_FLUIDS.md §5): p in decal space, a = 1 - min(1, y^2 + z^2), dither = (1 - a^2)^DitherFalloffCurve *
// (MaxDither - MinDither) + MinDither, ign = interleaved gradient noise of the map texel - 0.5,
// coverage = sat((ign * dither + 1) * OpacityScale * a^2) * opacity. The decal's depth fade is applied per pixel by
// di2_fluid.gdshaderinc. COLOR (the rect's colour): r = the puddle's height in the map's range, a = its opacity.

uniform float dither_curve = 8.0;    // M_FluidDecal "Dither Falloff Curve"
uniform float max_dither = 0.5;      // "Max Dither"
uniform float min_dither = 0.02;     // "Min Dither"
uniform float opacity_scale = 1.0;   // MI_BloodDecal "Opacity Scale"

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float a = 1.0 - min(1.0, dot(p, p));
	float ign = fract(52.9829178 * fract(dot(FRAGCOORD.xy, vec2(0.0671105608, 0.00583714992)))) - 0.5;
	float d = pow(max(1.0 - a * a, 1e-6), dither_curve) * (max_dither - min_dither) + min_dither;
	float cov = clamp((ign * d + 1.0) * opacity_scale * a * a, 0.0, 1.0) * COLOR.a;
	COLOR = vec4(COLOR.r, COLOR.g, COLOR.b, cov);   // r height, g / b the type selector sources (di2_fluid.gdshaderinc)
}
