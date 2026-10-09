shader_type spatial;
// DI2 PSM_Debris on GPU sprites (DI2Particles): PSMI_Rock_Debris_4x1 (GPU_SubUV on), the stones of PS_Pipe_Bomb_Explosion
// and other explosions. BLEND_Masked (clip 0.3333), MSM_TwoSidedFoliage. Transcribed from DI2's decompiled base pass
// PS 11865 (FGPUSpriteVertexFactory; VS 6946). The same graph as the mesh version (di2_particle_debris, PS 11860),
// with the GPU_SubUV atlas pick:
//   r = the GPU VF's per-particle PseudoRandom (VS 6946: frac of a polynomial hash of the particle's simulation-texture
//       coordinate + the emitter seed); uv = ((U * UV.x + U ceil(U r) * V ceil(V r)) / UV_Tiles, V * UV.y);
//   N = BC5 Normal lerped toward (0, 0, 1) by Normal_Flatness on the sprite basis;
//   base = sat(Diffuse.rgb * particle rgb), subsurface = sat(Subsurface_Mult * base), roughness = sat(Roughness_Mult *
//   MRO.g), metallic = sat(Metallic), specular 0.5; clip(particle a * Diffuse.a - 0.3333).
// The port's random is a hash of the instance index (DI2's simulation-texture slot is not modelled): APPROXIMATED.
render_mode skip_vertex_transform, cull_disabled, depth_draw_opaque;

#include "res://shaders/di2_particle_twosided.gdshaderinc"

uniform sampler2D diffuse : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D mro : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(1.0);
uniform float uv_tiles = 1.0;
uniform bool gpu_subuv = false;
uniform float normal_flatness = 0.0;
uniform float roughness_mult = 1.0;
uniform float subsurface_mult = 1.0;
uniform float metallic = 0.0;

varying vec4 v_color;
varying float v_rand;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
	v_rand = fract(sin(float(INSTANCE_ID) * 12.9898 + 78.233) * 43758.5453);
	vec3 right = MODEL_MATRIX[0].xyz;
	vec3 down = MODEL_MATRIX[1].xyz;
	vec3 world = MODEL_MATRIX[3].xyz + right * VERTEX.x + down * VERTEX.y;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 n = normalize(cross(down, right));
	if (dot(n, cam - world) < 0.0) {
		n = -n;
	}
	v_t = normalize(mat3(VIEW_MATRIX) * normalize(right));
	v_b = normalize(mat3(VIEW_MATRIX) * normalize(down));
	v_n = normalize(mat3(VIEW_MATRIX) * n);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = v_n;
}

void fragment() {
	float ux = uv_scale.x * UV.x;
	if (gpu_subuv) {
		vec2 c = uv_scale * ceil(uv_scale * v_rand);
		ux += c.x * c.y;
	}
	vec2 uv = vec2(ux / uv_tiles, uv_scale.y * UV.y);
	vec3 tn;
	tn.xy = texture(normal_tex, uv).xy * 2.0 - 1.0;
	tn.z = sqrt(max(0.0, 1.0 - dot(tn.xy, tn.xy)));
	tn = normalize(mix(tn, vec3(0.0, 0.0, 1.0), normal_flatness));
	vec4 d = texture(diffuse, uv);
	if (v_color.a * d.a - 0.3333 < 0.0) {
		discard;
	}
	vec3 c = d.rgb * v_color.rgb;
	BACKLIGHT = clamp(subsurface_mult * c, 0.0, 1.0);
	ALBEDO = clamp(c, 0.0, 1.0) + BACKLIGHT;  // + subsurface: indirect diffuse (di2_particle_twosided.gdshaderinc)
	ROUGHNESS = clamp(roughness_mult * texture(mro, uv).g, 0.0, 1.0);
	METALLIC = clamp(metallic, 0.0, 1.0);
	SPECULAR = 0.5;
	NORMAL = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
}
