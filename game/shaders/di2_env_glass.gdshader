// DI2 level geometry, translucent blend modes (see di2_env.gdshaderinc).
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, diffuse_burley, specular_schlick_ggx;
#define DI2_ENV_TRANSLUCENT
#include "res://shaders/di2_env.gdshaderinc"
