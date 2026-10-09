shader_type spatial;
// DI2 PSM_ParticleNoise_Unlit on sprite particles (DI2Particles): the lingering-fire "local_fire" emitters
// (PSMI_Fire_Lingering_Local / _Propagation_Local). BLEND_AlphaComposite, MSM_Unlit. The master's shader map is inline
// in its package (tools/particles/inline_map.py); transcribed from its FParticleSpriteVertexFactory base pass PS 11588:
//   t = the particle's RelativeTime (PARTICLE_TIME), dyn = DynamicParameter;
//   base = UV * (UTiling, VTiling) * clamp(dyn.x, 0.6, 1) + dyn.xy;
//   noise_k = Noise_Texture(rotate(base + t * Speed/Direction_k.xy * dyn.z - .5, a_k * t) + .5), with
//     (a_k, channel) = (0.10, x), (0.05, y), (0.07, z), (0.11, x);
//   n = max(1e-6, Animated_Noise_Strength * n1 * n2 * n3 * n4)^Animated_Noise_Contrast;
//   v = Detail_Mask(UV * 6 + (0, GameTime)).x * n * particle r * Opacity_Mask(UV).x;
//   d = sat((scene depth - pixel depth) / DepthFade_Distance), f = d * (1 - d);
//   T = v * f * Temperature; colour = UE BlackBody(T) * (0.0004 T)^4, desaturated by Desaturation;
//   opacity = sat(particle a * v * f). The Strength term scales by 1 / PreExposure (1 here; recon/PARTICLES.md 4.3).
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D opacity_mask : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_mask : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec2 tiling = vec2(1.0);
uniform vec2 speed1 = vec2(0.0);
uniform vec2 speed2 = vec2(0.0);
uniform vec2 speed3 = vec2(0.0);
uniform vec2 speed4 = vec2(0.0);
uniform float noise_strength = 1.0;
uniform float noise_contrast = 1.0;
uniform float depth_fade_distance = 1.0;
uniform float temperature = 0.0;
uniform float desaturation = 0.0;

varying vec4 v_color;
varying vec4 v_dyn;
varying float v_time;

void vertex() {
	v_color = COLOR;
	v_dyn = INSTANCE_CUSTOM;
	v_time = MODEL_MATRIX[2].y;
	vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

vec2 rot(vec2 p, float a) {
	float s = sin(a);
	float c = cos(a);
	p -= 0.5;
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y) + 0.5;
}

// UE Engine/Functions/Engine_MaterialFunctions01/Shading/BlackBody (as compiled in PS 11588)
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
	float t = v_time;
	vec2 base = UV * tiling * clamp(v_dyn.x, 0.6, 1.0) + v_dyn.xy;
	float n1 = texture(noise_tex, rot(base + t * speed1 * v_dyn.z, 0.10 * t)).x;
	float n2 = texture(noise_tex, rot(base + t * speed2 * v_dyn.z, 0.05 * t)).y;
	float n3 = texture(noise_tex, rot(base + t * speed3 * v_dyn.z, 0.07 * t)).z;
	float n4 = texture(noise_tex, rot(base + t * speed4 * v_dyn.z, 0.11 * t)).x;
	float n = pow(max(1e-6, noise_strength * (n1 * n2) * (n3 * n4)), noise_contrast);
	float detail = texture(detail_mask, vec2(UV.x * 6.0, UV.y * 6.0 + TIME)).x;
	float v = texture(opacity_mask, UV).x * (v_color.r * (detail * n));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float d = clamp(((-sp.z / sp.w) - (-VERTEX.z)) * 100.0 / max(depth_fade_distance, 1e-5), 0.0, 1.0);
	float f = (1.0 - d) * d;
	float T = v * f * temperature;
	vec3 c = blackbody(T);
	c = mix(c, vec3(dot(c, vec3(0.3, 0.59, 0.11))), desaturation);
	ALBEDO = max(c, vec3(0.0));
	ALPHA = clamp(v_color.a * v * f, 0.0, 1.0);
}
