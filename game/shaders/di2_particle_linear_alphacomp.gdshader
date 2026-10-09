shader_type spatial;
// DI2 PSM_Linear_AlphaComp_Lit (MSM_Unlit override, BLEND_AlphaComposite) on sprite / GPU sprite particles
// (DI2Particles). Transcribed from DI2's decompiled base pass PS:
//   12216 PSMI_Electric_Spark (GPU; Alpha_Channel, UV_Distort, Lightning_Threshold)
//   11331 PSMI_Plasma_Spark (GPU; Black Body, Lightning_Threshold)
//   6206  PSMI_Electric_Jolts_8x8 (sprite; Depth_Fade, Lightning_Threshold)
//   11957 PSMI_Explosion_Glow / 7181 Radial_Refraction_06 / 12517 _05 (sprite; Depth_Fade, Black Body / Refraction)
// erode = Lightning_Erode * clamp(max(Lightning_Erode_Min, RelativeTime), .., 1) (Lightning_Threshold);
// colour = pow(pow(tex, erode) * particle rgb, Colour_Contrast) [* depth fade];
// Black Body: T = BlackBody_Temperature * pow(particle r * pow(tex.r, erode), Colour_Contrast), colour = UE's
//   BlackBody(T) (Planckian locus -> XYZ -> linear sRGB) * (T * 0.0004)^4;
// opacity = sat(Opacity_Strength * pow(particle a * (tex.a or pow(tex.r, erode)), Opacity_Contrast)) [* depth fade].
// UseSelectChannel (PS 12268, PSMI_Radial_Refraction_01: Depth_Fade, UV_Distort, Refraction): one spritesheet channel
//   (green) times the particle rgba, colour = pow(that.rgb, Colour_Contrast), a = that.a; the distort noise is read from
//   its blue channel (the other permutations read alpha).
// "Strength" scales by 1/PreExposure (1 here). The Refraction switch drives UE's separate distortion pass, which is
// not ported (recon/PARTICLES.md 5).
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D spritesheet : filter_linear_mipmap, repeat_enable;
uniform sampler2D distort_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 sub_images = vec2(1.0);
uniform bool use_select_channel = false;
uniform bool alpha_channel = false;
uniform bool uv_distort = false;
uniform bool lightning_threshold = false;
uniform bool black_body = false;
uniform bool depth_fade = false;
uniform vec2 uv_tiling = vec2(1.0);
uniform vec2 uv_mov = vec2(0.0);
uniform float uv_distort_contrast = 1.0;
uniform float uv_distort_strength = 0.0;
uniform float lightning_erode = 1.0;
uniform float lightning_erode_min = 0.0;
uniform float colour_contrast = 1.0;
uniform float blackbody_temperature = 0.0;
uniform float opacity_contrast = 1.0;
uniform float opacity_strength = 1.0;
uniform float distance_fade = 1.0;

varying vec4 v_color;
varying float v_sub;
varying float v_time;

void vertex() {
	v_color = COLOR;
	v_sub = MODEL_MATRIX[2].x;
	v_time = MODEL_MATRIX[2].y;
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

// UE Engine/Functions/Engine_MaterialFunctions01/Shading/BlackBody (as compiled in PS 11331)
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
	vec2 uv = UV;
	if (sub_images.x > 1.0 || sub_images.y > 1.0) {
		float f = floor(v_sub);
		uv = (UV + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
	}
	if (uv_distort) {
		vec2 base = uv_tiling * UV * vec2(8.0, 4.0);
		vec4 n0 = texture(distort_noise, TIME * uv_mov + base);
		vec4 n1 = texture(distort_noise, TIME * uv_mov * -0.37 + base);
		float n = use_select_channel ? n0.z + n1.z : n0.a + n1.a;
		uv = UV + pow(max(n, 1e-6), uv_distort_contrast) * uv_distort_strength;
	}
	vec4 t = texture(spritesheet, uv);
	float erode = lightning_threshold ? lightning_erode * min(1.0, max(lightning_erode_min, v_time)) : 1.0;
	float fade = 1.0;
	if (depth_fade) {
		float d = texture(depth_tex, SCREEN_UV).r;
		vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
		fade = clamp(((-sp.z / sp.w) - (-VERTEX.z)) * 100.0 / max(distance_fade, 1e-5), 0.0, 1.0);
	}
	vec3 col;
	float a;
	if (use_select_channel) {
		vec4 c4 = v_color * t.g;
		col = pow(max(c4.rgb, vec3(1e-6)), vec3(colour_contrast));
		a = c4.a;
	} else if (black_body) {
		float v = pow(max(t.r, 1e-6), erode);
		float temp = blackbody_temperature * pow(max(v_color.r * v, 1e-6), colour_contrast);
		col = blackbody(temp);
		a = v_color.a * v;
	} else {
		vec3 c = pow(max(t.rgb, vec3(1e-6)), vec3(erode)) * v_color.rgb;
		col = pow(max(c, vec3(1e-6)), vec3(colour_contrast));
		a = v_color.a * (alpha_channel ? t.a : pow(max(t.r, 1e-6), erode));
	}
	col *= fade;
	float op = clamp(opacity_strength * pow(max(a, 1e-6), opacity_contrast) * fade, 0.0, 1.0);
	ALBEDO = max(col, vec3(0.0));
	ALPHA = op;
}
