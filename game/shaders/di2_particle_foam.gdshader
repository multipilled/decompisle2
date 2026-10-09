shader_type spatial;
// DI2 PSM_Whitewater_Foam on mesh particles (DI2Particles): PSMI_Fire_Foam, the glowing sphere under the burning-petrol
// flames (PS_Burning_Liquid "foam_mesh", PMesh_FX_Sphere). BLEND_AlphaComposite, MSM_Unlit, TwoSided. Transcribed
// from DI2's decompiled base pass VS 12355 / PS 12356 (FMeshParticleVertexFactory):
//   VS: world += (1, 1, 1) cm + N_w * WPO_Strength * PT_Linear_Noise(UV * (NoiseTileX, Y) + NoiseSpeed * time).x
//       (N_w = the instance transform times the mesh normal, not normalised: it carries the particle scale);
//   PS: m = 1 - sat(dot(TV_Global3dNoise((P + Panner_Direction * Speed * time) / "3D Noise Scale"), Volume_Mask)
//           / Softness), P = the pixel's absolute UE world position (cm);
//       D = scene depth - pixel depth (cm);
//       df = (1 - sat(D / max(1e-5, DynamicParameter.y)))^DepthFade_Brightness * sat(D / DepthFade_SoftEdgeDistance);
//       T = Temperature * Color.x * particle r * df * PT_Linear_Noise(UV * tile + NoiseSpeed * time).x * m;
//       rgb = max(0, BlackBody(T) * (0.0004 T)^4 * EmissiveAdd) (* PreExposure / View[152].y: 1 here, as the other
//       emissive transcriptions, recon/PARTICLES.md 4.3);
//       alpha = sat(Opacity_Boost * df * max(1e-6, AdditionalMask(UV).x)^2).
//   SelectionColor (editor) and Fury terms dropped; the height-fog / translucency-volume fog tail is left to Godot.
render_mode cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D linear_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D additional_mask : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise3d : filter_linear, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float wpo_strength = 0.0;
uniform vec2 noise_tile = vec2(1.0);
uniform float noise_speed = 1.0;
uniform vec3 panner_direction = vec3(0.0, 0.0, 1.0);
uniform float speed = 1.0;
uniform float noise_scale_3d = 64.0;
uniform vec4 volume_mask = vec4(0.0);
uniform float softness = 1.0;
uniform float depthfade_brightness = 1.0;
uniform float depthfade_soft_edge = 1.0;
uniform float temperature = 0.0;
uniform float color_x = 1.0;
uniform float emissive_add = 1.0;
uniform float opacity_boost = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	float n = textureLod(linear_noise, UV * noise_tile + noise_speed * TIME, 0.0).x;
	// world offset in cm (UE axes; (1,1,1) maps to itself under the (x, z, y) swap), brought back to mesh space
	VERTEX += 0.01 * (NORMAL * (wpo_strength * n) + inverse(mat3(MODEL_MATRIX)) * vec3(1.0));
}

vec3 blackbody(float t) {
	vec3 a = t * vec3(0.000154118257, 0.00084242021, 4.22806261e-5) + vec3(0.860117733, 1.0, 0.317398727);
	a += t * t * vec3(1.28641219e-7, 7.08145137e-7, 4.20481676e-8);
	float u = a.x / a.y;
	float v = a.z / (1.0 - t * 2.8974182e-5 + t * t * 1.61456057e-7);
	float d = 2.0 * u - 8.0 * v + 4.0;
	float x = 3.0 * u / d;
	float y = 2.0 * v / d;
	vec3 xyz = vec3(x / y, 1.0, (1.0 - x - y) / y);
	vec3 rgb = vec3(dot(vec3(3.2404542, -1.53713846, -0.498531401), xyz),
			dot(vec3(-0.969265997, 1.87601078, 0.0415560007), xyz),
			dot(vec3(0.0556433983, -0.204025894, 1.05722523), xyz));
	float k = 0.0004 * t;
	k *= k;
	return rgb * k * k;
}

void fragment() {
	vec3 wg = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 p = vec3(wg.x, wg.z, wg.y) * 100.0;
	float m = 1.0 - clamp(dot(texture(noise3d, (p + panner_direction * speed * TIME) / noise_scale_3d), volume_mask)
			/ softness, 0.0, 1.0);
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float D = ((-sp.z / sp.w) - (-VERTEX.z)) * 100.0;
	float df = pow(max(1.0 - clamp(D / max(1e-5, v_dyn.y), 0.0, 1.0), 1e-6), depthfade_brightness)
				* clamp(D / max(depthfade_soft_edge, 1e-5), 0.0, 1.0);
	float nz = texture(linear_noise, UV * noise_tile + TIME * noise_speed).x;
	float T = temperature * color_x * v_color.r * df * nz * m;
	ALBEDO = max(blackbody(T) * emissive_add, vec3(0.0));
	float am = max(1e-6, texture(additional_mask, UV).x);
	ALPHA = clamp(opacity_boost * df * am * am, 0.0, 1.0);
}
