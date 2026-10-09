shader_type spatial;
// DI2 PSM_FireDebris (PSMI_FireDebris) on GPU / CPU sprites (DI2Particles): the burning embers / ash flakes of the
// fire hits (PS_Blunt_Fire*, PS_Counter_Fire_Directional_Local). BLEND_Masked (clip 0.3333), default lit, opaque
// GBuffer. Transcribed from DI2's decompiled base pass PS 12656 (FGPUSpriteVertexFactory, inline shader map of
// PSM_FireDebris; CPU sprites PS 12664 are the same graph):
//   N = tangent-space T_FireDebris_N (BC5, z = sqrt(1 - x^2 - y^2)) on the sprite basis;
//   d = T_FireDebris_D.xy; a' = 1 - particle alpha;
//   clip(sat(floor(d.x + a')) - 0.3333): only texels with d.x >= particle alpha stay (the flake burns away);
//   emissive = Color1.rgb * (1 - sat(floor(d.x + a' - Edge))): the band alpha <= d.x < alpha + Edge glows
//              (Color1 = (25000, 100, 0): the hot rim), * PreExposure (1 here, recon/PARTICLES.md 4.3);
//   base colour = sat(particle rgb * d.y); metallic 0, specular 0.5, roughness 0.95 (the compiled constant:
//   View.RoughnessOverrideParameter (0, 1) leaves it). SelectionColor (editor) and Fury terms dropped.
render_mode skip_vertex_transform, cull_disabled, depth_draw_opaque;

uniform sampler2D diffuse : filter_linear_mipmap, repeat_enable;  // linear (T_FireDebris_D is not sRGB)
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 color1 = vec3(0.0);
uniform float edge = 0.1;

varying vec4 v_color;
varying vec3 v_t;
varying vec3 v_b;
varying vec3 v_n;

void vertex() {
	v_color = COLOR;
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
	vec3 tn;
	tn.xy = texture(normal_tex, UV).xy * 2.0 - 1.0;
	tn.z = sqrt(max(0.0, 1.0 - dot(tn.xy, tn.xy)));
	vec2 d = texture(diffuse, UV).xy;
	float a1 = 1.0 - v_color.a;
	if (clamp(floor(d.x + a1), 0.0, 1.0) - 0.3333 < 0.0) {
		discard;
	}
	float glow = 1.0 - clamp(floor(d.x + a1 - edge), 0.0, 1.0);
	ALBEDO = clamp(v_color.rgb * d.y, 0.0, 1.0);
	EMISSION = max(color1 * glow, vec3(0.0));
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = 0.95;
	NORMAL = normalize(tn.x * v_t + tn.y * v_b + tn.z * v_n);
}
