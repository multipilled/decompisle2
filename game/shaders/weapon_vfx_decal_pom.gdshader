shader_type spatial;
// DI2 M_DecalPOM_DNR (MD_DeferredDecal, DBM_DBuffer_ColorNormalRoughness, BLEND_Translucent): the bullet / melee
// impact decals of the CE_Collision_* effects (MI_DecalBullet_*, MI_DecalBulletSpray_*, MI_DecalMelee*_*).
// Transcribed from DI2's decompiled FDeferredDecalPS (ShaderArchive-DeadIsland index 861, quality High; shader map
// BB361826... shared by the MIs; recon/WEAPON_VFX.md §5):
//   OS = decal-local position of the scene surface behind the pixel (SvPositionToDecal, [-1,1]^3); discard outside.
//   uv = OS.zy * 0.5 + 0.5 (U along decal Z, V along decal Y; the decal projects along +X into the surface).
//   POM: V = normalize(camera - S) in the decal tangent frame (T = Z, B = Y, N = -X); P = -V.xy / V.z * Depth;
//     steps = lerp(POMMaxSteps 25, POMMinSteps 4, min(1, |V.z|)) (MPC_GameWideParams); linear search over the
//     height map (SampleGrad with the base uv derivatives) from ray height 1 down by 1/steps, at most
//     floor(steps) + 2 samples, then one secant step; uv += offset.
//   N = BC5 normal (xy * 2 - 1, z = sqrt(1 - |xy|^2)) -> world: -N.z * X + N.y * Y + N.x * Z (unit decal axes).
//   colour = sat(lerp(1, "04 - Diffuse Colour Tint", ARA.b) * Diffuse.rgb); roughness = sat("05 - Roughness
//   Adjustment" + ARA.g); opacity = sat(4 - 4 |OS.x|) * DecalParams.x * DecalParams.y * sat(ARA.r)
//   (DecalParams = screen-size fade, lifetime fade: UDecalComponent SetFadeOut / SetFadeIn / SetFadeScreenSize).
// DI2 writes colour / normal / roughness into its DBuffer and the base pass blends them over the surface by opacity
// before lighting. Here the decal is a box drawn after the opaque pass that rebuilds the surface from the depth
// buffer, is lit at that surface (LIGHT_VERTEX) with the decal's attributes and blended by opacity: the same for
// base colour; normal / roughness are blended after lighting instead of before (APPROXIMATED), the surface's own
// metallic / specular are not kept (0 / 0.5, DI2's DBufferC writes; UNVERIFIED for non-dielectric surfaces).
// Decals also land on anything whose depth falls inside the box (DI2 excludes actors with bReceivesDecals off).
render_mode cull_front, depth_test_disabled, depth_draw_never, blend_mix;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D height_map : filter_linear_mipmap_anisotropic, repeat_enable;      // "Height Map (see tooltip!)"
uniform sampler2D normal_map : filter_linear_mipmap_anisotropic, repeat_enable;      // "03 - Normal Map" (BC5)
uniform sampler2D ara_map : filter_linear_mipmap_anisotropic, repeat_enable;         // "02 - Packed ARA Map"
uniform sampler2D diffuse_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable; // "01 - Diffuse Colour Map"
uniform vec3 diffuse_tint = vec3(1.0);   // "04 - Diffuse Colour Tint" (master default (1, 1, 1))
uniform float pom_depth = 0.03;          // "Depth" (master default 0.03; the bullet MIs 0.2)
uniform float roughness_adjust = 0.0;    // "05 - Roughness Adjustment" (master default 0)
uniform float pom_min_steps = 4.0;       // MPC_GameWideParams.POMMinSteps
uniform float pom_max_steps = 25.0;      // MPC_GameWideParams.POMMaxSteps
instance uniform float decal_fade = 1.0; // DecalParams.x * DecalParams.y

varying vec3 v_ax;   // decal +X (projection, into the surface) * half size, world
varying vec3 v_ay;   // decal +Y * half size
varying vec3 v_az;   // decal +Z * half size

void vertex() {
	// Node basis (WeaponVfx.spawn_decal): column 0 = decal X * DecalSize.X, column 1 = decal Z * DecalSize.Z,
	// column 2 = decal Y * DecalSize.Y (Godot units), on a 2 x 2 x 2 box.
	v_ax = MODEL_MATRIX[0].xyz;
	v_az = MODEL_MATRIX[1].xyz;
	v_ay = MODEL_MATRIX[2].xyz;
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 view_pos = vp.xyz / vp.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;
	vec3 d = world - MODEL_MATRIX[3].xyz;
	vec3 os = vec3(dot(d, v_ax) / dot(v_ax, v_ax), dot(d, v_ay) / dot(v_ay, v_ay), dot(d, v_az) / dot(v_az, v_az));
	if (any(lessThan(vec3(1.0) + os, vec3(0.0))) || any(lessThan(vec3(1.0) - os, vec3(0.0)))) {
		discard;
	}
	vec3 ux = normalize(v_ax);
	vec3 uy = normalize(v_ay);
	vec3 uz = normalize(v_az);
	vec3 o01 = os * 0.5 + 0.5;
	vec2 uv0 = o01.zy;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 v = normalize(cam - world);
	// Tangent frame (T, B, N) = (Z, Y, -X).
	vec2 vt = vec2(dot(uz, v), dot(uy, v));
	float vz = dot(-ux, v);
	vec2 p = -vt / vz * pom_depth;
	float steps = mix(pom_max_steps, pom_min_steps, min(1.0, abs(vz)));
	float max_i = 2.0 + floor(steps);
	float dh = 1.0 / steps;
	vec2 step_uv = p * dh;
	vec2 ddx_uv = dFdx(uv0);
	vec2 ddy_uv = dFdy(uv0);
	vec2 offs = vec2(0.0);
	float ray = 1.0;
	float prev_ray = 1.0;
	float prev_h = 1.0;
	for (int i = 0; i < 64; i++) {
		if (float(i) >= max_i) {
			break;
		}
		float h = textureGrad(height_map, uv0 + offs, ddx_uv, ddy_uv).x;
		if (ray < h) {
			float a = prev_ray - prev_h;
			float b = h - ray;
			float t = b / (a + b);
			offs = -t * step_uv + offs;
			break;
		}
		prev_ray = ray;
		prev_h = h;
		ray -= dh;
		offs += step_uv;
	}
	vec2 uv = uv0 + offs;
	vec2 nxy = texture(normal_map, uv).xy * 2.0 - 1.0;
	vec3 nt = vec3(nxy, sqrt(max(0.0, 1.0 - dot(nxy, nxy))));
	vec3 nw = normalize(-nt.z * ux + nt.y * uy + nt.x * uz);
	vec3 ara = texture(ara_map, uv).xyz;
	vec3 tint = ara.z * (diffuse_tint - 1.0) + 1.0;
	ALBEDO = clamp(tint * texture(diffuse_map, uv).rgb, 0.0, 1.0);
	ROUGHNESS = clamp(roughness_adjust + ara.y, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	LIGHT_VERTEX = view_pos;
	ALPHA = clamp(4.0 - 4.0 * abs(os.x), 0.0, 1.0) * decal_fade * clamp(ara.x, 0.0, 1.0);
}
