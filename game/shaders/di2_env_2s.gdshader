// DI2 level geometry, TwoSided materials (see di2_env.gdshaderinc).
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;
#define DI2_ENV_MASKED_ALLOWED
#include "res://shaders/di2_env.gdshaderinc"
