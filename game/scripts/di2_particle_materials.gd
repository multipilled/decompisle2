class_name DI2ParticleMaterials
## Godot materials for DI2's particle material instances (DI2Particles). Each DI2 master material (PSM_*) whose
## shaders were decompiled has a transcription in game/shaders/di2_particle_*.gdshader; an instance's parameters
## come from game/data/particles.json "materials" (MI overrides over the compiled shader map's defaults).
## Masters not transcribed yet use di2_particle_generic.gdshader (APPROXIMATED, listed in recon/PARTICLES.md 5).

enum Kind { SPRITE, MESH, GPU, NONE }

## master material -> shader per emitter kind (sprite / mesh / gpu sprite)
const FAMILY := {
	"PSM_Houdini_VertexAnimated_Fluid": {Kind.MESH: "di2_particle_vat.gdshader"},
	"PSM_Dither_Blood_Opaque": {Kind.SPRITE: "di2_particle_dither.gdshader", Kind.GPU: "di2_particle_dither.gdshader"},
	"PSM_Dither_Blood_Opaque_MeshFlipbook": {Kind.MESH: "di2_particle_dither_mesh.gdshader"},
	"PSM_Smoke_Transluscent_Lit": {Kind.SPRITE: "di2_particle_smoke.gdshader", Kind.GPU: "di2_particle_smoke.gdshader"},
	"PSM_Liquid_Transluscent_Lit": {Kind.SPRITE: "di2_particle_smoke.gdshader", Kind.GPU: "di2_particle_smoke.gdshader"},
	"PSM_Whitewater": {Kind.SPRITE: "di2_particle_smoke.gdshader", Kind.GPU: "di2_particle_smoke.gdshader"},
	"PSM_Liquid_Bits_Simple": {Kind.SPRITE: "di2_particle_bits.gdshader", Kind.GPU: "di2_particle_bits.gdshader"},
	"PSM_Liquid_Bits_Complex": {Kind.SPRITE: "di2_particle_bits_complex.gdshader", Kind.GPU: "di2_particle_bits_complex.gdshader"},
	"PSM_Linear_AlphaComp_Lit": {Kind.SPRITE: "di2_particle_linear_alphacomp.gdshader", Kind.GPU: "di2_particle_linear_alphacomp.gdshader"},
	"PSM_BloodDripsEnviro": {Kind.MESH: "di2_particle_drip_decal.gdshader"},
	"PSM_ElectricDistortion": {Kind.SPRITE: "di2_particle_electric_distortion.gdshader", Kind.GPU: "di2_particle_electric_distortion.gdshader"},
	"PSM_Fire_AlphaComposite": {Kind.SPRITE: "di2_particle_fire.gdshader", Kind.GPU: "di2_particle_fire.gdshader"},
	"PSM_Debris": {Kind.MESH: "di2_particle_debris.gdshader", Kind.SPRITE: "di2_particle_debris_sprite.gdshader", Kind.GPU: "di2_particle_debris_sprite.gdshader"},
	"PSM_ParticleNoise_Unlit": {Kind.SPRITE: "di2_particle_noise.gdshader", Kind.GPU: "di2_particle_noise.gdshader"},
	"PSM_BurningLiquidSplash": {Kind.SPRITE: "di2_particle_liquid_splash.gdshader", Kind.GPU: "di2_particle_liquid_splash.gdshader"},
	"PSM_BlowMind_Chunks": {Kind.GPU: "di2_particle_liquid_splash.gdshader"},
	"PSM_Debris_Dithering": {Kind.MESH: "di2_particle_debris.gdshader"},
	"PSM_Whitewater_Foam": {Kind.MESH: "di2_particle_foam.gdshader"},
	"PSM_FireDebris": {Kind.SPRITE: "di2_particle_fire_debris.gdshader", Kind.GPU: "di2_particle_fire_debris.gdshader"},
	"PSM_Translucent_Bubbles": {Kind.MESH: "di2_particle_bubbles.gdshader"},
	"PSM_Explosion_AlphaComposite": {Kind.SPRITE: "di2_particle_explosion.gdshader", Kind.GPU: "di2_particle_explosion.gdshader"},
	"PSM_Liquid_FluidSprite": {Kind.SPRITE: "di2_particle_fluid_sprite.gdshader"},
	"PSM_Houdini_VertexAnimated_Fluid_Translucent": {Kind.MESH: "di2_particle_vat_translucent.gdshader"},
	"PSM_Fire_OpacityMask": {Kind.SPRITE: "di2_particle_fire_mask.gdshader", Kind.GPU: "di2_particle_fire_mask.gdshader"},
}


static func build(mi_name: String, mi: Dictionary, kind: int, required: Dictionary) -> Material:
	var root: String = mi.get("root", "")
	var fam: Dictionary = FAMILY.get(root, {})
	var file: String = fam.get(kind, "")
	var m := ShaderMaterial.new()
	m.resource_name = mi_name
	# The compiled shader map has no base pass for this emitter's vertex factory (particles.json "vertex_factories",
	# tools/build_particles.py): DI2 cannot draw it with this material (UE 4.27 swaps in the engine default material).
	var vfs = mi.get("vertex_factories")
	var need: String = {Kind.SPRITE: "FParticleSpriteVertexFactory", Kind.GPU: "FGPUSpriteVertexFactory",
		Kind.MESH: "FMeshParticleVertexFactory"}.get(kind, "")
	if vfs is Array and need != "" and not (vfs as Array).has(need):
		m.shader = DI2Particles.shader("di2_particle_hidden.gdshader")
		return m
	if file == "":
		m.shader = DI2Particles.shader("di2_particle_generic.gdshader")
		_generic(m, mi, kind, required)
		return m
	m.shader = DI2Particles.shader(file)
	var S: Dictionary = mi.get("scalars", {})
	var V: Dictionary = mi.get("vectors", {})
	var T: Dictionary = mi.get("textures", {})
	var W: Dictionary = mi.get("switches", {})
	m.set_shader_parameter("noise64", DI2Particles.texture("Good64x64TilingNoiseHighFreq"))
	match root:
		"PSM_Houdini_VertexAnimated_Fluid":
			m.set_shader_parameter("position_map", DI2Particles.texture(T.get("PositionMap", "")))
			m.set_shader_parameter("normal_map", DI2Particles.texture(T.get("NormalMap", "")))
			m.set_shader_parameter("frames", float(S.get("Frames", 1.0)))
			m.set_shader_parameter("bounding_min", float(S.get("Bounding Min", 0.0)))
			m.set_shader_parameter("bounding_max", float(S.get("Bounding Max", 1.0)))
			m.set_shader_parameter("diffuse_reflected_colour", _c3(V.get("Diffuse Reflected Colour", [0, 0, 0, 1])))
			m.set_shader_parameter("diffuse_reflected_colour_blend", _c3(V.get("Diffuse Reflected ColourBlend", [0, 0, 0, 1])))
			m.set_shader_parameter("density", float(S.get("Density", 1.0)))
			m.set_shader_parameter("fresnel_exponent", float(S.get("Fresnel_Exponent", 1.0)))
			m.set_shader_parameter("opacity", float(S.get("Opacity", 1.0)))
			m.set_shader_parameter("roughness_min", float(S.get("RoughnessMin", 0.5)))
			m.set_shader_parameter("roughness_max", float(S.get("RoughnessMax", 0.5)))
			m.set_shader_parameter("metallic", float(S.get("Metallic", 0.0)))
			m.set_shader_parameter("use_reflected_colour_blend", W.get("UseReflectedColorBlend", false))
			m.set_shader_parameter("use_color_ramp", W.get("UseColorRamp", false))
			m.set_shader_parameter("texture_blend", float(S.get("TextureBlend", 0.0)))
			m.set_shader_parameter("scale_color_diffuse", float(S.get("ScaleColorDifuse", 1.0)))
			var ov: String = T.get("DiffuseOverla[", "")
			m.set_shader_parameter("diffuse_overlay", DI2Particles.texture(ov) if ov and ov != "WhiteSquareTexture" else null)
		"PSM_Dither_Blood_Opaque", "PSM_Dither_Blood_Opaque_MeshFlipbook":
			if root == "PSM_Dither_Blood_Opaque_MeshFlipbook":
				m.set_meta("time_in_w", true)  # PS 11680 reads only DynamicParameter.y; .w carries RelativeTime
			m.set_shader_parameter("normals", DI2Particles.texture(T.get("Normals", "")))
			m.set_shader_parameter("sprite_mask", DI2Particles.texture(T.get("Sprite_Mask", "")))
			m.set_shader_parameter("normals_tiling", Vector2(float(S.get("Normals_UTiling", 1.0)), float(S.get("Normals_VTiling", 1.0))))
			var sd: Array = V.get("Speed/Direction", [0, 0, 0, 0])
			m.set_shader_parameter("speed_direction", Vector2(float(sd[0]), float(sd[1])))
			m.set_shader_parameter("normals_flatness", float(S.get("Normals_Flatness", 0.0)))
			m.set_shader_parameter("diffuse_reflected_colour", _c3(V.get("Diffuse Reflected Colour", [0, 0, 0, 1])))
			m.set_shader_parameter("density", float(S.get("Density", 1.0)))
			m.set_shader_parameter("fresnel_exponent", float(S.get("Fresnel_Exponent", 1.0)))
			m.set_shader_parameter("opacity", float(S.get("Opacity", 1.0)))
			m.set_shader_parameter("roughness", float(S.get("Roughness", 0.5)))
			m.set_shader_parameter("metallic", float(S.get("Metallic", 0.0)))
		"PSM_Whitewater":
			# PS 2751 (PSMI_Whitewater_02_8x8): the smoke master's flipbook / normals / translucency with its own names:
			# colour = sat(pow(Smoke_Spritesheet.rgb, Contrast_Smoke) * particle rgb * depth fade), opacity =
			# Opacity_Boost * particle a * pow(Smoke_Spritesheet.a, Contrast_Opacity) * depth fade. The
			# "Use Fake Self Shadow" permutation (Whitewater_Bits_1x1_Acid, PS 11766) adds terms not transcribed.
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Smoke_Spritesheet", "")))
			m.set_shader_parameter("spritesheet_normals", DI2Particles.texture(T.get("Normals_Spritesheet", "")))
			m.set_shader_parameter("motion_vector", DI2Particles.texture(T.get("Motion_Vector_SpriteSheet", "")))
			m.set_shader_parameter("use_motion_vectors", true)
			m.set_shader_parameter("sub_images", Vector2(float(S.get("SubImagesU", 1.0)), float(S.get("SubImagesV", 1.0))))
			m.set_shader_parameter("offset_magic_number", float(S.get("Offset_Magic_Number", 0.0)))
			m.set_shader_parameter("normal_flatness", float(S.get("Normal_Flatness", 0.0)))
			m.set_shader_parameter("fade_distance", float(S.get("FadeDistance", 1.0)))
			m.set_shader_parameter("near_camera_fade", W.get("Near_Camera_Fade", false))
			m.set_shader_parameter("near_fade_offset", float(S.get("NearFade_Offset", 0.0)))
			m.set_shader_parameter("near_fade_radius", float(S.get("NearFade_Radius", 1.0)))
			m.set_shader_parameter("contrast_color", float(S.get("Contrast_Smoke", 1.0)))
			m.set_shader_parameter("contrast_opacity", float(S.get("Contrast_Opacity", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 1.0)))
			m.set_shader_parameter("opacity_from_alpha", true)
			_transmission(m, S)
		"PSM_Smoke_Transluscent_Lit", "PSM_Liquid_Transluscent_Lit":
			# Alpha_Channel (PSMI_Acid_Smoke_02_8x8, PS 12586): opacity = pow(spritesheet a, Contrast_Opacity), else red
			m.set_shader_parameter("opacity_from_alpha", W.get("Alpha_Channel", false))
			if root == "PSM_Liquid_Transluscent_Lit":
				m.set_shader_parameter("surface_specular", true)    # TLM_Surface
				m.set_shader_parameter("roughness", float(S.get("Roughness", 0.5)))
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Spritesheet", "")))
			m.set_shader_parameter("spritesheet_normals", DI2Particles.texture(T.get("Spritesheet_Normals", "")))
			m.set_shader_parameter("motion_vector", DI2Particles.texture(T.get("Motion_Vector", "")))
			m.set_shader_parameter("sub_images", Vector2(float(S.get("SubImagesU", 1.0)), float(S.get("SubImagesV", 1.0))))
			m.set_shader_parameter("offset_magic_number", float(S.get("Offset_Magic_Number", 0.0)))
			m.set_shader_parameter("use_motion_vectors", W.get("Motion_Vectors_Switch", false))
			m.set_shader_parameter("normal_flatness", float(S.get("Normal_Flatness", 0.0)))
			m.set_shader_parameter("fade_distance", float(S.get("FadeDistance", 1.0)))
			m.set_shader_parameter("near_camera_fade", W.get("Near_Camera_Fade", false))
			m.set_shader_parameter("near_fade_offset", float(S.get("NearFade_Offset", 0.0)))
			m.set_shader_parameter("near_fade_radius", float(S.get("NearFade_Radius", 1.0)))
			m.set_shader_parameter("contrast_color", float(S.get("Contrast_Color", 1.0)))
			m.set_shader_parameter("contrast_opacity", float(S.get("Contrast_Opacity", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 1.0)))
			m.set_shader_parameter("opacity_to_transmission", float(S.get("Opacity To Transmission Curve", 1.0)))
			m.set_shader_parameter("min_transmission", float(S.get("Min Transmission", 0.0)))
			m.set_shader_parameter("max_transmission", float(S.get("Max Transmission", 0.0)))
			m.set_shader_parameter("absorption_density", float(S.get("Absorption Density", 0.0)))
		"PSM_Liquid_Bits_Simple":
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Spritesheet", "")))
			m.set_shader_parameter("spritesheet_normal", DI2Particles.texture(T.get("Spritesheet_Normal", "")))
			m.set_shader_parameter("brightspot", W.get("Brightspot", false))
			# PS 12193 (UsesAlphaMask off): alpha = tex.r * particle a; the master's default (PS 11162) reads tex.a
			m.set_shader_parameter("alpha_from_red", not W.get("UsesAlphaMask", true))
			m.set_shader_parameter("brightspot_strength", float(S.get("Brightspot_Strength", 1.0)))
			m.set_shader_parameter("flatten_normal", float(S.get("FlattenNormal", 0.0)))
			_transmission(m, S)
		"PSM_Liquid_Bits_Complex":
			m.set_shader_parameter("texture_diffuse", DI2Particles.texture(T.get("Texture_Diffuse", "")))
			m.set_shader_parameter("texture_normal", DI2Particles.texture(T.get("Texture_Normal", "")))
			m.set_shader_parameter("caustics_n", DI2Particles.texture("PT_Caustics_Noise_B_Tiling_N"))  # PS 12109 constant
			m.set_shader_parameter("uv_shimmer", W.get("UV_Shimmer", false))
			m.set_shader_parameter("shimmer_tiling", Vector2(float(S.get("Shimmering_Normals_UTiling", 1.0)), float(S.get("Shimmering_Normals_VTiling", 1.0))))
			var ss: Array = V.get("Shimmering_Speed/Direction", [0, 0, 0, 0])
			m.set_shader_parameter("shimmer_speed", Vector2(float(ss[0]), float(ss[1])))
			m.set_shader_parameter("uv_shimmer_strength", float(S.get("UV_Shimmer_Strength", 0.0)))
			m.set_shader_parameter("shimmering_flatness", float(S.get("Shimmering_Flatness", 0.0)))
			m.set_shader_parameter("normal_flatness", float(S.get("Normal_Flatness", 0.0)))
			m.set_shader_parameter("diffuse_reflected_colour", _c3(V.get("Diffuse Reflected Colour", [0, 0, 0, 1])))
			m.set_shader_parameter("roughness", float(S.get("Roughness", 0.5)))
			_transmission(m, S)
		"PSM_Linear_AlphaComp_Lit":
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Spritesheet", "")))
			var dn = T.get("DistortNoise", "PT_Linear_Noise_Caustic_03")
			m.set_shader_parameter("distort_noise", DI2Particles.texture(dn) if dn else null)
			m.set_shader_parameter("sub_images", Vector2(float(required.get("SubImages_Horizontal", 1)), float(required.get("SubImages_Vertical", 1))))
			m.set_shader_parameter("alpha_channel", W.get("Alpha_Channel", false))
			m.set_shader_parameter("use_select_channel", W.get("UseSelectChannel", false))  # PS 12268
			m.set_shader_parameter("uv_distort", W.get("UV_Distort", false))
			m.set_shader_parameter("lightning_threshold", W.get("Lightning_Threshold", false))
			m.set_shader_parameter("black_body", W.get("Black Body", false))
			m.set_shader_parameter("depth_fade", W.get("Depth_Fade", false))
			m.set_shader_parameter("uv_tiling", Vector2(float(S.get("U_Tiling", 1.0)), float(S.get("V_Tiling", 1.0))))
			m.set_shader_parameter("uv_mov", Vector2(float(S.get("U_Mov", 0.0)), float(S.get("V_Mov", 0.0))))
			m.set_shader_parameter("uv_distort_contrast", float(S.get("UV_Distort_Contrast", 1.0)))
			m.set_shader_parameter("uv_distort_strength", float(S.get("UV_Distort_Strength", 0.0)))
			m.set_shader_parameter("lightning_erode", float(S.get("Lightning_Erode", 1.0)))
			m.set_shader_parameter("lightning_erode_min", float(S.get("Lightning_Erode_Min", 0.0)))
			m.set_shader_parameter("colour_contrast", float(S.get("Colour_Contrast", 1.0)))
			m.set_shader_parameter("blackbody_temperature", float(S.get("BlackBody_Temperature", 0.0)))
			m.set_shader_parameter("opacity_contrast", float(S.get("Opacity_Contrast", 1.0)))
			m.set_shader_parameter("opacity_strength", float(S.get("Opacity_Strength", 1.0)))
			m.set_shader_parameter("distance_fade", float(S.get("DistanceFade", 1.0)))
		"PSM_BloodDripsEnviro":
			m.set_shader_parameter("splatter", DI2Particles.texture("T_RoundSplatter_A"))  # FMeshDecalsPS 1598 constant
			m.set_shader_parameter("noise3d", DI2Particles.texture3d("TV_Global3dNoise"))  # ditto (Material.res4)
			m.set_shader_parameter("divide00", float(S.get("Divide00", 1.0)))
			m.set_shader_parameter("noise_scale", float(S.get("3D Noise Scale", 1.0)))
			m.set_shader_parameter("distortion", float(S.get("Distortion", 0.0)))
			m.set_shader_parameter("distortion_height", float(S.get("DistortionHeight", 0.0)))
			var ft: Array = V.get("color", [0, 1, 1, 0])  # the MI's Fluid Type (blood (0, 1, 1, 0))
			m.set_shader_parameter("fluid_type", Vector4(float(ft[0]), float(ft[1]), float(ft[2]), float(ft[3])))
			_fluid_compose(m)
		"PSM_ElectricDistortion":
			m.set_shader_parameter("noise_tex", DI2Particles.texture(T.get("Noise", "")))
			m.set_shader_parameter("mask_tex", DI2Particles.texture(T.get("Mask", "")))
			m.set_shader_parameter("uv_tiling", Vector2(float(S.get("U_Tiling", 1.0)), float(S.get("V_Tiling", 1.0))))
			m.set_shader_parameter("uv_distort_strength", float(S.get("UV_Distort_Strength", 0.0)))
			m.set_shader_parameter("uv_distort_contrast", float(S.get("UV_Distort_Contrast", 1.0)))
			m.set_shader_parameter("multy", float(S.get("Multy", 1.0)))
			m.set_shader_parameter("multy_far", float(S.get("MultyFar", 1.0)))
			m.set_shader_parameter("distance_compensation", float(S.get("DistanceCompensation", 1.0)))
			m.set_shader_parameter("power", float(S.get("Power", 1.0)))
			m.set_shader_parameter("colour_contrast", float(S.get("Colour_Contrast", 1.0)))
			m.set_shader_parameter("uses_contact_opacity", W.get("UsesContactOpacity", false))
			m.set_shader_parameter("depth_fade_distance", float(S.get("DepthFade_Distance", 1.0)))
			m.set_shader_parameter("opacity_contrast", float(S.get("Opacity_Contrast", 1.0)))
			m.set_shader_parameter("opacity_strength", float(S.get("Opacity_Strength", 0.0)))
			_exposure(m, S)
		"PSM_Fire_AlphaComposite":
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Spritesheet", "")))
			m.set_shader_parameter("motion_vector", DI2Particles.texture(T.get("Motion_Vector", "")))
			m.set_shader_parameter("sub_images", Vector2(float(S.get("SubImagesU", 1.0)), float(S.get("SubImagesV", 1.0))))
			m.set_shader_parameter("use_motion_vectors", W.get("Motion_Vectors_Switch", false))
			m.set_shader_parameter("offset_magic_number", float(S.get("Offset_Magic_Number", 0.0)))
			m.set_shader_parameter("contrast_color", float(S.get("Contrast_Color", 1.0)))
			m.set_shader_parameter("preblackbody_depthfade", float(S.get("PreBlackbody_DepthFade", 1.0)))
			m.set_shader_parameter("desaturation_fraction", float(S.get("Desaturation_Fraction", 0.0)))
			m.set_shader_parameter("emissive_add_strength", float(S.get("Emissive_Add_Strength", 1.0)))
			m.set_shader_parameter("fade_distance", float(S.get("FadeDistance", 1.0)))
			m.set_shader_parameter("uses_contact_opacity", W.get("UsesContactOpacity", false))
			m.set_shader_parameter("contact_fade_distance", float(S.get("ContactFadeDistance", 1.0)))
			m.set_shader_parameter("contrast_opacity", float(S.get("Contrast_Opacity", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 1.0)))
			_exposure(m, S)
		"PSM_Fire_OpacityMask":
			# PS 6901 (sprite) / 6894 (GPU sprite: no DynamicParameter)
			m.set_shader_parameter("spritesheet", DI2Particles.texture(T.get("Spritesheet", "")))
			m.set_shader_parameter("motion_vector", DI2Particles.texture(T.get("Motion_Vector", "")))
			m.set_shader_parameter("sub_images", Vector2(float(S.get("SubImagesU", 1.0)), float(S.get("SubImagesV", 1.0))))
			m.set_shader_parameter("use_motion_vectors", W.get("Motion_Vectors_Switch", false))
			m.set_shader_parameter("gpu", kind == Kind.GPU)
			m.set_shader_parameter("offset_magic_number", float(S.get("Offset_Magic_Number", 0.0)))
			m.set_shader_parameter("contrast_color", float(S.get("Contrast_Color", 1.0)))
			m.set_shader_parameter("contrast_opacity", float(S.get("Contrast_Opacity", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 1.0)))
			m.set_shader_parameter("blackbody_bias", float(S.get("BlackBodyBias", 1.0)))
			m.set_shader_parameter("desaturation_fraction", float(S.get("Desaturation_Fraction", 0.0)))
			m.set_shader_parameter("emissive_add_strength", float(S.get("Emissive_Add_Strength", 1.0)))
			m.set_shader_parameter("uses_fuel", float(S.get("UsesFuel", 0.0)))
			var fc: Array = V.get("FuelColor", [0, 0, 0, 1])
			m.set_shader_parameter("fuel_color", Vector3(float(fc[0]), float(fc[1]), float(fc[2])))
			m.set_shader_parameter("fuel_height_falloff", float(S.get("FuelHeightFalloff", 1.0)))
			_exposure(m, S)
		"PSM_Whitewater_Foam":
			# VS 12355 / PS 12356 (mesh particles)
			m.set_shader_parameter("linear_noise", DI2Particles.texture("PT_Linear_Noise"))  # graph constant (Texture2D_0)
			m.set_shader_parameter("additional_mask", DI2Particles.texture(T.get("AdditionalMask", "T_WhiteHDR_D")))
			m.set_shader_parameter("noise3d", DI2Particles.texture3d("TV_Global3dNoise"))  # Material.res4 (referenced_textures)
			m.set_shader_parameter("wpo_strength", float(S.get("WPO_Strength", 0.0)))
			m.set_shader_parameter("noise_tile", Vector2(float(S.get("NoiseTileX", 1.0)), float(S.get("NoiseTileY", 1.0))))
			m.set_shader_parameter("noise_speed", float(S.get("NoiseSpeed", 1.0)))
			var pd: Array = V.get("Panner_Direction", [0, 0, 1, 0])
			m.set_shader_parameter("panner_direction", Vector3(float(pd[0]), float(pd[1]), float(pd[2])))
			m.set_shader_parameter("speed", float(S.get("Speed", 1.0)))
			m.set_shader_parameter("noise_scale_3d", float(S.get("3D Noise Scale", 64.0)))
			var vm: Array = V.get("Volume_Mask", [0, 0, 0, 0])
			m.set_shader_parameter("volume_mask", Vector4(float(vm[0]), float(vm[1]), float(vm[2]), float(vm[3])))
			m.set_shader_parameter("softness", float(S.get("Softness", 1.0)))
			m.set_shader_parameter("depthfade_brightness", float(S.get("DepthFade_Brightness", 1.0)))
			m.set_shader_parameter("depthfade_soft_edge", float(S.get("DepthFade_SoftEdgeDistance", 1.0)))
			m.set_shader_parameter("temperature", float(S.get("Temperature", 0.0)))
			m.set_shader_parameter("color_x", float(V.get("Color", [1, 1, 1, 1])[0]))
			m.set_shader_parameter("emissive_add", float(S.get("EmissiveAdd", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 0.0)))
		"PSM_FireDebris":
			# PS 12656 (inline shader map): T_FireDebris_D / _N are graph constants (referenced_textures)
			m.set_shader_parameter("diffuse", DI2Particles.texture("T_FireDebris_D"))
			m.set_shader_parameter("normal_tex", DI2Particles.texture("T_FireDebris_N"))
			var c1: Array = V.get("Color1", [0, 0, 0, 0])
			m.set_shader_parameter("color1", Vector3(float(c1[0]), float(c1[1]), float(c1[2])))
			m.set_shader_parameter("edge", float(S.get("Edge", 0.1)))
		"PSM_Translucent_Bubbles":
			# PS 12574 (inline shader map); Normals defaults to the graph's PT_Caustics_Noise_B_Tiling_N
			var nt: String = T.get("Normals", "PT_Caustics_Noise_B_Tiling_N")
			m.set_shader_parameter("normals", DI2Particles.texture(nt))
			m.set_shader_parameter("normals_flatness", float(S.get("Normals_Flatness", 0.0)))
			m.set_shader_parameter("depth_fade_distance", float(S.get("DepthFade_Distance", 1.0)))
			m.set_shader_parameter("exponent_in", float(S.get("ExponentIn", 1.0)))
			m.set_shader_parameter("base_reflect_fraction", float(S.get("BaseReflectFractionIn", 0.0)))
			m.set_shader_parameter("mask_contrast", float(S.get("Mask_Contrast", 1.0)))
			m.set_shader_parameter("diffuse_reflected_colour", _c3(V.get("Diffuse Reflected Colour", [1, 1, 1, 1])))
			m.set_shader_parameter("roughness", float(S.get("Roughness", 0.5)))
			_transmission(m, S)
		"PSM_Explosion_AlphaComposite":
			# PS 6868 / 7350 / 6787 (Near_Camera_Fade) / 8464 (Fire off); GPU sprites 6841 (no DynamicParameter).
			# Switch defaults from the compiled maps: Fire on (7350, Fire_Burst_02 sets no Fire switch), Near_Camera_Fade off
			# (6868 is shared by MIs without the switch and has no near fade).
			m.set_shader_parameter("smoke_tex", DI2Particles.texture(T.get("Smoke_Spritesheet", "")))
			m.set_shader_parameter("fire_tex", DI2Particles.texture(T.get("Fire_Spritesheet", "")))
			m.set_shader_parameter("normals_tex", DI2Particles.texture(T.get("Normals_Spritesheet", "")))
			m.set_shader_parameter("motion_vector", DI2Particles.texture(T.get("Motion_Vector_SpriteSheet", "")))
			m.set_shader_parameter("sub_images", Vector2(float(S.get("SubImagesU", 1.0)), float(S.get("SubImagesV", 1.0))))
			m.set_shader_parameter("offset_magic_number", float(S.get("Offset_Magic_Number", 0.0)))
			m.set_shader_parameter("gpu", kind == Kind.GPU)
			m.set_shader_parameter("fire", W.get("Fire", true))
			m.set_shader_parameter("normal_flatness", float(S.get("Normal_Flatness", 0.0)))
			m.set_shader_parameter("fade_distance", float(S.get("FadeDistance", 50.0)))
			m.set_shader_parameter("near_camera_fade", W.get("Near_Camera_Fade", false))
			m.set_shader_parameter("near_fade_offset", float(S.get("NearFade_Offset", 0.0)))
			m.set_shader_parameter("near_fade_radius", float(S.get("NearFade_Radius", 1.0)))
			m.set_shader_parameter("contrast_smoke", float(S.get("Contrast_Smoke", 1.0)))
			m.set_shader_parameter("contrast_opacity", float(S.get("Contrast_Opacity", 1.0)))
			m.set_shader_parameter("contrast_fire", float(S.get("Contrast_Fire", 1.0)))
			m.set_shader_parameter("opacity_boost", float(S.get("Opacity_Boost", 1.0)))
			m.set_shader_parameter("desaturation_fraction", float(S.get("Desaturation_Fraction", 0.0)))
			m.set_shader_parameter("emissive_add_strength", float(S.get("Emissive_Add_Strength", 1.0)))
			m.set_shader_parameter("ms_temperature", float(S.get("MultipleScattering_Temperature", 0.0)))
			m.set_shader_parameter("ms_hardness", float(S.get("MultipleScattering_SphereHardness", 0.0)))
			m.set_shader_parameter("ms_contrast", float(S.get("MultipleScattering_Contrast", 1.0)))
			m.set_shader_parameter("ms_zoffset", float(S.get("MultipleScattering_ZOffset", 0.0)))
			_transmission(m, S)
			_exposure(m, S)
		"PSM_Liquid_FluidSprite":
			# PS 11482 (UsesAlphaMask on: the only MI, PSMI_Liquid_FluidSprite_00)
			var st: String = T.get("Spritesheet", "")
			m.set_shader_parameter("spritesheet", DI2Particles.texture(st))
			m.set_shader_parameter("spritesheet_srgb", DI2Particles.db().get("textures", {}).get(st, {}).get("srgb", false))
			m.set_shader_parameter("spritesheet_normal", DI2Particles.texture(T.get("Spritesheet_Normal", "")))
			m.set_shader_parameter("sub_images", Vector2(float(required.get("SubImages_Horizontal", 1)), float(required.get("SubImages_Vertical", 1))))
			m.set_shader_parameter("flatten_normal", float(S.get("FlattenNormal", 0.0)))
			m.set_shader_parameter("low_color_multy", float(S.get("LowColorMulty", 0.1)))
			_transmission(m, S)
		"PSM_Houdini_VertexAnimated_Fluid_Translucent":
			# VS 4576 / PS 4579
			m.set_shader_parameter("position_map", DI2Particles.texture(T.get("PositionMap", "")))
			m.set_shader_parameter("normal_map", DI2Particles.texture(T.get("NormalMap", "")))
			m.set_shader_parameter("color_map", DI2Particles.texture(T.get("ColorMap", "WhiteSquareTexture")))
			m.set_shader_parameter("frames", float(S.get("Frames", 1.0)))
			m.set_shader_parameter("bounding_min", float(S.get("Bounding Min", 0.0)))
			m.set_shader_parameter("bounding_max", float(S.get("Bounding Max", 1.0)))
			m.set_shader_parameter("diffuse_reflected_colour", _c3(V.get("Diffuse Reflected Colour", [1, 1, 1, 1])))
			m.set_shader_parameter("roughness_min", float(S.get("RoughnessMin", 0.5)))
			m.set_shader_parameter("roughness_max", float(S.get("RoughnessMax", 0.5)))
			m.set_shader_parameter("metallic", float(S.get("Metallic", 0.0)))
			m.set_shader_parameter("diffuse_opacity_multiplier", float(S.get("Diffuse Opacity Multiplier", 1.0)))
			m.set_shader_parameter("fresnel_exponent", float(S.get("Fresnel_Exponent", 1.0)))
			m.set_shader_parameter("min_transmission", float(S.get("Min Transmission", 0.0)))
			m.set_shader_parameter("max_transmission", float(S.get("Max Transmission", 0.0)))
			m.set_shader_parameter("absorption_density", float(S.get("Absorption Density", 0.0)))
		"PSM_BurningLiquidSplash", "PSM_BlowMind_Chunks":
			var bc: String = T.get("BC", "")
			m.set_shader_parameter("bc", DI2Particles.texture(bc))
			m.set_shader_parameter("bc_srgb", DI2Particles.db().get("textures", {}).get(bc, {}).get("srgb", false))
			if root == "PSM_BlowMind_Chunks":
				# PS 13532: BC * BC_Detail(uv * DetailTile), no particle rgb, SelectionColor emissive
				var dt: String = T.get("BC_Detail", "")
				m.set_shader_parameter("detail", DI2Particles.texture(dt))
				m.set_shader_parameter("detail_srgb", DI2Particles.db().get("textures", {}).get(dt, {}).get("srgb", false))
				m.set_shader_parameter("detail_tile", Vector2(float(S.get("DetailTileX", 1.0)), float(S.get("DetailTileY", 1.0))))
				m.set_shader_parameter("use_color_rgb", false)
				var sc: Array = V.get("SelectionColor", [0, 0, 0, 0])
				m.set_shader_parameter("emissive", Vector3(sc[0], sc[1], sc[2]) * float(sc[3]))
		"PSM_ParticleNoise_Unlit":
			m.set_shader_parameter("noise_tex", DI2Particles.texture(T.get("Noise_Texture", "PT_Linear_Noise")))
			m.set_shader_parameter("opacity_mask", DI2Particles.texture(T.get("Opacity_Mask", "PT_Circle_Mask")))
			m.set_shader_parameter("detail_mask", DI2Particles.texture(T.get("Detail_Mask", "T_SkinSplatterWoundNoise_H")))
			m.set_shader_parameter("tiling", Vector2(float(S.get("UTiling", 1.0)), float(S.get("VTiling", 1.0))))
			for k in 4:
				var sd: Array = V.get("Speed/Direction%d" % (k + 1), [0, 0, 0, 0])
				m.set_shader_parameter("speed%d" % (k + 1), Vector2(float(sd[0]), float(sd[1])))
			m.set_shader_parameter("noise_strength", float(S.get("Animated_Noise_Strength", 1.0)))
			m.set_shader_parameter("noise_contrast", float(S.get("Animated_Noise_Contrast", 1.0)))
			m.set_shader_parameter("depth_fade_distance", float(S.get("DepthFade_Distance", 1.0)))
			m.set_shader_parameter("temperature", float(S.get("Temperature", 0.0)))
			m.set_shader_parameter("desaturation", float(S.get("Desaturation", 0.0)))
		"PSM_Debris", "PSM_Debris_Dithering":
			m.set_shader_parameter("dithered", root == "PSM_Debris_Dithering")  # PS 16137's dithered mask
			m.set_shader_parameter("gpu_subuv", W.get("GPU_SubUV", false))  # PS 11865 (GPU sprites)
			m.set_shader_parameter("diffuse", DI2Particles.texture(T.get("Diffuse", "")))
			m.set_shader_parameter("mro", DI2Particles.texture(T.get("MRO", "")))
			m.set_shader_parameter("normal_tex", DI2Particles.texture(T.get("Normal", "")))
			m.set_shader_parameter("uv_scale", Vector2(float(S.get("U", 1.0)), float(S.get("V", 1.0))))
			m.set_shader_parameter("uv_tiles", float(S.get("UV_Tiles", 1.0)))
			m.set_shader_parameter("normal_flatness", float(S.get("Normal_Flatness", 0.0)))
			m.set_shader_parameter("roughness_mult", float(S.get("Roughness_Mult", 1.0)))
			m.set_shader_parameter("subsurface_mult", float(S.get("Subsurface_Mult", 1.0)))
			m.set_shader_parameter("metallic", float(S.get("Metallic", 0.0)))
	return m


## DI2's exposure-compensated emissive (Bright / Dark Scene Multiplier): scene_exposure blends the two (0 = bright
## scene: the daylight arena), emissive_exposure_scale is PreExposure / X. On the DI2 test map both come from DI2's
## eye adaptation (DI2Map._process, game/scripts/di2_post.gd); elsewhere 0 / 1 (APPROXIMATED, recon/PARTICLES.md 4.3).
static var scene_exposure := 0.0
static var emissive_exposure_scale := 1.0

static func _exposure(m: ShaderMaterial, S: Dictionary) -> void:
	m.set_shader_parameter("bright_scene_multiplier", float(S.get("Bright Scene Multiplier", 1.0)) * emissive_exposure_scale)
	m.set_shader_parameter("dark_scene_multiplier", float(S.get("Dark Scene Multiplier", 1.0)) * emissive_exposure_scale)
	m.set_shader_parameter("scene_exposure_blend", scene_exposure)


## DI2's fluid compose constants for the drip decals: game/data/fluids.json "compose" (the gore session's
## tools/build_fluids.py: FPostProcessSettings colours, the level's Fuel / FuelEdge overrides in level_colors,
## AFluidParamsUpdateActor's FluidDensity / FluidRoughness, the compose specular and sharpening).
static var _compose: Dictionary = {}

static func _fluid_compose(m: ShaderMaterial) -> void:
	if _compose.is_empty():
		var f := FileAccess.open("res://data/fluids.json", FileAccess.READ)
		if f:
			var j = JSON.parse_string(f.get_as_text())
			if j is Dictionary:
				_compose = j.get("compose", {})
	if _compose.is_empty():
		return
	var cols: Dictionary = _compose.get("colors", {}).duplicate()
	cols.merge(_compose.get("level_colors", {}), true)  # the level's post-process overrides (Fuel, FuelEdge)
	for k in [["Water", "water_colour"], ["Blood", "blood_colour"], ["Fuel", "fuel_colour"], ["FuelEdge", "fuel_edge_colour"],
			["Acid", "acid_colour"], ["AcidEdge", "acid_edge_colour"]]:
		if cols.has(k[0]):
			m.set_shader_parameter(k[1], _c3(cols[k[0]]))
	var fp: Dictionary = _compose.get("fluid_params", {})
	m.set_shader_parameter("fluid_density", float(fp.get("FluidDensity", 10.0)))
	m.set_shader_parameter("fluid_roughness", float(fp.get("FluidRoughness", 0.08)))
	m.set_shader_parameter("fluid_specular", float(_compose.get("specular", 0.35)))
	m.set_shader_parameter("sharpen", float(_compose.get("sharpen", 12.0)))


## The shared translucency tail's parameters (di2_particle_translucent.gdshaderinc).
static func _transmission(m: ShaderMaterial, S: Dictionary) -> void:
	m.set_shader_parameter("opacity_to_transmission", float(S.get("Opacity To Transmission Curve", 1.0)))
	m.set_shader_parameter("min_transmission", float(S.get("Min Transmission", 0.0)))
	m.set_shader_parameter("max_transmission", float(S.get("Max Transmission", 0.0)))
	m.set_shader_parameter("absorption_density", float(S.get("Absorption Density", 0.0)))


static func _c3(a) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


## Fallback for masters not transcribed yet: the first colour-ish texture parameter * particle colour, with the
## master's blend mode and lit / unlit shading model. APPROXIMATED (recon/PARTICLES.md 5).
static func _generic(m: ShaderMaterial, mi: Dictionary, kind: int, required: Dictionary) -> void:
	var T: Dictionary = mi.get("textures", {})
	var base: Dictionary = mi.get("base", {})
	var tex_name := ""
	for k in ["Spritesheet", "Texture", "BC", "Sprite_Mask", "Mask", "Diffuse", "Color", "ColorMap", "Base Color", "Alpha"]:
		for tk: String in T.keys():
			if tk.to_lower().begins_with(k.to_lower()) and T[tk] and T[tk] != "WhiteSquareTexture":
				tex_name = T[tk]
				break
		if tex_name:
			break
	if tex_name == "":
		for tk: String in T.keys():
			var tn = T[tk]
			if tn and not String(tn).ends_with("_N") and tn != "WhiteSquareTexture":
				tex_name = tn
				break
	var tex := DI2Particles.texture(tex_name) if tex_name else null
	var info: Dictionary = DI2Particles.db().get("textures", {}).get(tex_name, {})
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("has_tex", tex != null)
	m.set_shader_parameter("tex_srgb", info.get("srgb", true))
	m.set_shader_parameter("sub_images", Vector2(float(required.get("SubImages_Horizontal", 1)), float(required.get("SubImages_Vertical", 1))))
	var blend: String = base.get("BlendMode", "BLEND_Opaque")
	m.set_shader_parameter("blend", {"BLEND_Opaque": 0, "BLEND_Masked": 1, "BLEND_Translucent": 2, "BLEND_Additive": 3,
		"BLEND_Modulate": 2, "BLEND_AlphaComposite": 4}.get(blend, 2))
	m.set_shader_parameter("is_mesh", kind == Kind.MESH)
