#[compute]
#version 450
// UE 4.27 exponential height fog (ExponentialHeightFogCommon.ush: two layers, line integral) on Godot's HDR colour,
// before DI2's eye-adaptation histogram (game/scripts/di2_post.gd). Per layer, per metre (UE's per-cm values / 1000
// * 100): RayOriginTerms = Density * 2^(-Falloff * (CameraY - FogHeight)); integral = sum(RayOriginTerms *
// (1 - 2^(-Falloff * RayDirY)) / (Falloff * RayDirY)) * RayLength (small-falloff limit 0.693147 - 0.240227 x);
// ExpFogFactor = max(saturate(2^-integral), 1 - FogMaxOpacity); colour = scene * f + inscattering * (1 - f).
// Inscattering = InscatteringTextureTint * the cubemap's non-directional (lowest mip) colour, pre-exposed: beyond
// NonDirectionalInscatteringColorDistance UE uses that mip only. Sky pixels (no depth) are left unfogged.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16f) uniform image2D color;
layout(set = 0, binding = 1) uniform sampler2D depth;
layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inv_proj;        // clip -> view
	vec4 cam;             // camera world position (xyz), start distance (w)
	vec4 layer0;          // density / m, falloff / m, height (world y), unused
	vec4 layer1;
	vec4 inscatter;       // rgb pre-exposed inscattering colour, w = min opacity (1 - FogMaxOpacity)
	vec4 cam_basis_y;     // world-space y components of the camera's x, y, z axes (view -> world rotation row 1)
	vec2 size;
	vec2 pad;
} pc;

float layer_term(vec4 l, float ray_y) {
	float origin = l.x * exp2(-l.y * (pc.cam.y - l.z));
	float f = l.y * ray_y;
	f = max(-127.0, f);
	float sh = abs(f) > 1e-4 ? (1.0 - exp2(-f)) / f : 0.693147 - 0.240227 * f;
	return origin * sh;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= int(pc.size.x) || p.y >= int(pc.size.y)) {
		return;
	}
	vec2 uv = (vec2(p) + 0.5) / pc.size;
	float d = texelFetch(depth, p, 0).r;
	if (d <= 0.0) {
		return;
	}
	vec4 v = pc.inv_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 1.0 - 2.0 * d, 1.0);
	vec3 view_pos = v.xyz / v.w;
	float len = length(view_pos);
	float ray_y = dot(pc.cam_basis_y.xyz, view_pos);   // world-space vertical component of the camera -> pixel ray
	float exclude = max(0.0, len - pc.cam.w);
	float integral = (layer_term(pc.layer0, ray_y) + layer_term(pc.layer1, ray_y)) * exclude;
	float f = max(clamp(exp2(-integral), 0.0, 1.0), pc.inscatter.w);
	vec4 c = imageLoad(color, p);
	imageStore(color, p, vec4(c.rgb * f + pc.inscatter.rgb * (1.0 - f), c.a));
}
