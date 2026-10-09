// DI2 landscape (M_LandscapeLite, the NH_04 terrain: tools/build_test_map.py landscape_build, game/scripts/di2_map.gd).
// Transcribed from DI2's own base-pass pixel shader for a 5-layer landscape component (ShaderArchive-DeadIsland 26989,
// FLandscapeVertexFactory TBasePassPSFNoLightMapPolicy of LandscapeMaterialInstanceConstant key E6C4D48E...;
// extracted/shaders/dis/DeadIsland_026989_landscape_5layer_ps.hlsl, recon/TEST_MAP.md "Landscape"):
//   uv          = absolute UE world XY (cm) / "Texture Tiling (in cm)" (cb3[27].x; the mesh's UV carries world XY cm)
//   h'_k        = saturate((Heightmap_k.g - 0.5) * "k - Height Blend Influence" + 0.5)   (the "_AHA" map's G)
//   b_k         = clamp(2 * w_k + h'_k - 1, 1e-4, 1), then b_k /= sum(b)       (UE's LB_HeightBlend on h'_k)
//   base colour = saturate(sum b_k * "k - Diffuse Colour Map".rgb * "k - Diffuse Colour Tint".rgb)
//   roughness   = sum b_k * saturate("k - Packed MRO Map".g + "k - Roughness Adjustment"); metallic 0; specular 0.5
//   normal      = the BC5 layer normals blended by b_k, reoriented (RNM) onto the landscape normal with the layer's
//                 tangent frame = world X / Y. Here: tangent-space NORMAL_MAP on the terrain's own X / Y tangent
//                 frame (equal for an unrotated landscape; UNVERIFIED row in recon/UNVERIFIED.md).
// Not ported: tessellation / displacement ("Displacement Amount"), the SubsurfaceDerived shading model's
// translucency / subsurface colour (GBuffer B.x = sum b_k * "Surface Translucency Adjustment"), procedural grass.
// Layer weights: COLOR.rgba = layers 1..4, UV2.x = layer 5 (from the cooked weightmaps, per vertex).
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;
#include "res://shaders/di2_fluid.gdshaderinc"

uniform sampler2D layer_albedo[5] : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_normal[5] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_mro[5] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_height[5] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 layer_tint[5];
uniform float layer_height_blend[5];
uniform float layer_roughness_adj[5];
uniform float tiling_cm = 400.0;

void fragment() {
	vec2 uv = UV / tiling_cm;
	float w[5] = float[5](COLOR.r, COLOR.g, COLOR.b, COLOR.a, UV2.x);
	float b[5];
	float sum = 0.0;
	for (int k = 0; k < 5; k++) {
		float h = clamp((texture(layer_height[k], uv).g - 0.5) * layer_height_blend[k] + 0.5, 0.0, 1.0);
		b[k] = clamp(2.0 * w[k] + h - 1.0, 0.0001, 1.0);
		sum += b[k];
	}
	vec3 albedo = vec3(0.0);
	vec3 n = vec3(0.0);
	float rough = 0.0;
	for (int k = 0; k < 5; k++) {
		float bk = b[k] / sum;
		albedo += bk * texture(layer_albedo[k], uv).rgb * layer_tint[k].rgb;
		vec2 xy = texture(layer_normal[k], uv).rg * 2.0 - 1.0;
		n += bk * vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
		rough += bk * clamp(texture(layer_mro[k], uv).g + layer_roughness_adj[k], 0.0, 1.0);
	}
	ALBEDO = clamp(albedo, 0.0, 1.0);
	METALLIC = 0.0;
	ROUGHNESS = rough;
	SPECULAR = 0.5;
	NORMAL_MAP = normalize(n) * 0.5 + 0.5;
	di2_fluid_compose((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, ALBEDO, ROUGHNESS, SPECULAR);
}
