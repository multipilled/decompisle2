shader_type spatial;
// Fallback for DI2 particle masters whose shaders are not transcribed yet (DI2ParticleMaterials._generic):
// the instance's first colour texture (SubUV frame from the instance basis z.x when the grid is > 1x1) times the
// particle colour, emulating the master's blend mode with premultiplied alpha, unshaded. APPROXIMATED: listed per
// master in recon/PARTICLES.md 5.
render_mode skip_vertex_transform, cull_disabled, blend_premul_alpha, depth_draw_never, unshaded;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_tex = false;
uniform bool tex_srgb = true;
uniform vec2 sub_images = vec2(1.0);
uniform int blend = 2;          // 0 opaque 1 masked 2 translucent 3 additive 4 alpha composite
uniform bool is_mesh = false;

varying vec4 v_color;
varying float v_sub;

void vertex() {
	v_color = COLOR;
	if (is_mesh) {
		vec4 w = MODEL_MATRIX * vec4(VERTEX, 1.0);
		VERTEX = (VIEW_MATRIX * w).xyz;
		NORMAL = normalize(mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX) * NORMAL);
		v_sub = 0.0;
	} else {
		vec3 world = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * VERTEX.x + MODEL_MATRIX[1].xyz * VERTEX.y;
		v_sub = MODEL_MATRIX[2].x;
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
		NORMAL = vec3(0.0, 0.0, 1.0);
	}
}

void fragment() {
	vec2 uv = UV;
	if (!is_mesh && (sub_images.x > 1.0 || sub_images.y > 1.0)) {
		float f = floor(v_sub);
		uv = (UV + vec2(mod(f, sub_images.x), floor(f / sub_images.x))) / sub_images;
	}
	vec4 t = has_tex ? texture(tex, uv) : vec4(1.0);
	vec3 c = t.rgb * v_color.rgb;
	float a = clamp(t.a * v_color.a, 0.0, 1.0);
	if (blend <= 1) {
		if (blend == 1 && a < 0.3333) discard;
		ALBEDO = c;
		ALPHA = 1.0;
	} else if (blend == 3) {
		ALBEDO = c * a;
		ALPHA = 0.0;
	} else if (blend == 4) {
		ALBEDO = c;
		ALPHA = a;
	} else {
		ALBEDO = c * a;
		ALPHA = a;
	}
}
