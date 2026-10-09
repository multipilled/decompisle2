class_name DI2Map
extends Node3D
## A DI2 level section as the recreation's test environment (main.gd --map=<name>).
## Built at load from tools/build_test_map.py's output in res://assets/di2/maps/<name>/ (.gdignore'd, read raw):
##   map.json  meshes, materials, instance groups, collision, lights and the level settings DI2 places in it;
##   map.bin   Godot-encoded arrays (var_to_bytes layout) the json points at as [offset, length];
##   textures/ the cooked DI2 textures as DDS (same BC format and mips as shipped, top mips above the builder's cap
##             dropped).
## The map's spawn origin (an open floor area picked by tools/test_map/find_open.py) is this node's origin, so the
## tests' fixed positions (player at +Z 6, zombies around -Z 2..6) land on DI2 floor. Collision is on Util.WORLD.
## Notes, sources and what is approximate: recon/TEST_MAP.md.

const ROOT := "res://assets/di2/maps/"
const SHADERS := {"opaque": "res://shaders/di2_env.gdshader", "two_sided": "res://shaders/di2_env_2s.gdshader",
	"glass": "res://shaders/di2_env_glass.gdshader", "landscape": "res://shaders/di2_landscape.gdshader"}

var data: Dictionary = {}
var blob := PackedByteArray()
var dir := ""
var textures := {}
var materials: Array[Material] = []
var meshes: Array = []
var stats := {}
var _sky_mean := Color(0, 0, 0)
var post = null  ## di2_post.gd compositor effect (DI2's eye adaptation / tonemap), when the map has post data


static func exists(map_name: String) -> bool:
	return FileAccess.file_exists(ROOT + map_name + "/map.json")


static func create(map_name: String) -> Node3D:
	var m = (load("res://scripts/di2_map.gd") as GDScript).new()
	m.name = "DI2Map_" + map_name
	m.dir = ROOT + map_name
	var t0 := Time.get_ticks_usec()
	m._build()
	m.stats["build_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	print("DI2Map %s: %s" % [map_name, m.stats])
	return m


func _seg(s: Array) -> Variant:
	return bytes_to_var(blob.slice(int(s[0]), int(s[0]) + int(s[1])))


func _build() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(dir + "/map.json"))
	# DI2Fluids' fluid map must cover the test area before the first puddle exists (the map loads in _build_arena,
	# before any zombie): the builder's "fluid_area" (tools/build_test_map.py).
	var fa: Dictionary = data.get("fluid_area", {})
	if fa.has("rect"):
		var r: Array = fa["rect"]
		DI2Fluids.map_area = Rect2(r[0], r[1], r[2], r[3])
	if fa.has("heights"):
		DI2Fluids.map_heights = Vector2(fa["heights"][0], fa["heights"][1])
	blob = FileAccess.get_file_as_bytes(dir + "/" + String(data.get("blob", "map.bin")))
	var t0 := Time.get_ticks_msec()
	for md: Dictionary in data["materials"]:
		materials.append(_material(md))
	stats["ms_materials"] = Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	for me: Dictionary in data["meshes"]:
		meshes.append(_mesh_arrays(me))
	stats["ms_meshes"] = Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	var shared := {}
	var instances := 0
	var mmis: Array[MultiMeshInstance3D] = []
	for g: Dictionary in data["groups"]:
		var key := "%d:%s" % [g["mesh"], str(g["materials"])]
		if not shared.has(key):
			shared[key] = _mesh(int(g["mesh"]), g["materials"])
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = shared[key]
		var buf: PackedFloat32Array = _seg(g["xforms"])
		mm.instance_count = buf.size() / 12
		mm.buffer = buf
		instances += mm.instance_count
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g.get("shadow", true) \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# DI2's HLOD (tools/build_test_map.py "hlod"): a proxy shows beyond its LODActor's LODDrawDistance and hides
		# the components it replaces (their visibility_parent); foliage ends at its InstanceEndCullDistance
		if g.has("vis_begin"):
			mmi.visibility_range_begin = float(g["vis_begin"])
		if g.has("vis_end"):
			mmi.visibility_range_end = float(g["vis_end"])
		add_child(mmi)
		mmis.append(mmi)
	var hlod := 0
	for gi in data["groups"].size():
		var g: Dictionary = data["groups"][gi]
		if g.has("vis_parent"):
			mmis[gi].visibility_parent = mmis[gi].get_path_to(mmis[int(g["vis_parent"])])
			hlod += 1
	stats["hlod_children"] = hlod
	stats["meshes"] = meshes.size()
	stats["materials"] = materials.size()
	stats["groups"] = data["groups"].size()
	stats["instances"] = instances
	stats["ms_groups"] = Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	_collision(data.get("collision", {}))
	stats["ms_collision"] = Time.get_ticks_msec() - t0
	_environment(data.get("environment", {}))
	_lights(data.get("lights", []))
	_decals(data.get("decals", []))
	blob = PackedByteArray()


# --- geometry ----------------------------------------------------------------------------------------------------

func _mesh_arrays(me: Dictionary) -> Array:
	var surfaces := []
	for s: Dictionary in me["surfaces"]:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		var src: Dictionary = s["arrays"]
		a[Mesh.ARRAY_VERTEX] = _seg(src["vertex"])
		a[Mesh.ARRAY_NORMAL] = _seg(src["normal"])
		if src.has("tangent"):
			a[Mesh.ARRAY_TANGENT] = _seg(src["tangent"])
		if src.has("uv"):
			a[Mesh.ARRAY_TEX_UV] = _seg(src["uv"])
		if src.has("uv2"):
			a[Mesh.ARRAY_TEX_UV2] = _seg(src["uv2"])
		if src.has("color"):
			a[Mesh.ARRAY_COLOR] = _seg(src["color"])
		a[Mesh.ARRAY_INDEX] = _seg(src["index"])
		surfaces.append(a)
	return surfaces


## ArrayMesh of mesh `i` with one material per surface (indices into `materials`, -1 = default grey).
func _mesh(i: int, mats: Array) -> ArrayMesh:
	var am := ArrayMesh.new()
	var surfaces: Array = meshes[i]
	for k in surfaces.size():
		var mi := int(mats[k]) if k < mats.size() else -1
		# masters the port leaves out (mesh decals, cobwebs: tools/build_test_map.py SKIP_MASTERS)
		if mi >= 0 and String(data["materials"][mi].get("shader", "")) == "none":
			continue
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surfaces[k])
		if mi >= 0:
			am.surface_set_material(am.get_surface_count() - 1, materials[mi])
	am.resource_name = data["meshes"][i]["name"]
	return am


## Jolt builds one static compound per body and runs out of sub-shape ID bits past a few thousand shapes, so the
## shapes are spread over bodies of at most BODY_SHAPES each.
const BODY_SHAPES := 200
var _bodies: Array[StaticBody3D] = []


func _add_shape(sh: Shape3D, xf := Transform3D.IDENTITY) -> void:
	if _bodies.is_empty() or _bodies[-1].get_child_count() >= BODY_SHAPES:
		var body := StaticBody3D.new()
		body.name = "Collision%d" % _bodies.size()
		body.collision_layer = Util.WORLD
		body.collision_mask = 0
		add_child(body)
		_bodies.append(body)
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.transform = xf
	_bodies[-1].add_child(cs)


func _collision(c: Dictionary) -> void:
	var shapes := 0
	if c.has("trimesh"):
		# one face array, or (whole maps, tools/build_test_map.py "cell") one face array per map cell
		var seg = _seg(c["trimesh"])
		var parts: Array = seg if seg is Array else [seg]
		var tris := 0
		for faces: PackedVector3Array in parts:
			if faces.size() == 0:
				continue
			var sh := ConcavePolygonShape3D.new()
			sh.set_faces(faces)
			sh.backface_collision = true
			_add_shape(sh)
			shapes += 1
			tris += faces.size() / 3
		stats["trimesh_tris"] = tris
	if c.has("convex"):
		var hulls: Array = _seg(c["convex"])
		for pts: PackedVector3Array in hulls:
			var sh := ConvexPolygonShape3D.new()
			sh.points = pts
			_add_shape(sh)
			shapes += 1
	for s: Array in c.get("spheres", []):
		var sh := SphereShape3D.new()
		sh.radius = s[3]
		_add_shape(sh, Transform3D(Basis.IDENTITY, Vector3(s[0], s[1], s[2])))
		shapes += 1
	for s: Array in c.get("capsules", []):
		# [basis x, y, z (capsule axis = y), origin, radius, height (tip to tip)]
		var sh := CapsuleShape3D.new()
		sh.radius = s[12]
		sh.height = s[13]
		_add_shape(sh, Transform3D(Basis(Vector3(s[0], s[1], s[2]), Vector3(s[3], s[4], s[5]), Vector3(s[6], s[7], s[8])),
			Vector3(s[9], s[10], s[11])))
		shapes += 1
	stats["collision_shapes"] = shapes
	stats["collision_bodies"] = _bodies.size()


# --- materials ----------------------------------------------------------------------------------------------------

func _material(md: Dictionary) -> Material:
	if String(md.get("shader", "")) == "landscape":
		return _landscape_material(md)
	var mat := ShaderMaterial.new()
	mat.resource_name = md["name"]
	mat.shader = load(SHADERS.get(md.get("shader", "opaque"), SHADERS["opaque"]))
	var tex: Dictionary = md.get("textures", {})
	for slot in ["albedo", "normal", "mro"]:
		if tex.has(slot):
			var t = _texture(tex[slot])
			if t:
				mat.set_shader_parameter(slot + "_tex", t)
				mat.set_shader_parameter("has_" + slot, true)
	if md.get("tint") != null:
		var c: Array = md["tint"]
		mat.set_shader_parameter("tint", Color(c[0], c[1], c[2], c[3]))
	if md.get("base_color") != null:
		var b: Array = md["base_color"]
		mat.set_shader_parameter("base_color", Color(b[0], b[1], b[2], b[3]))
	mat.set_shader_parameter("use_alpha_clip", md.get("masked", false))
	mat.set_shader_parameter("alpha_clip", md.get("clip", 0.3333))
	if md.has("opacity"):
		mat.set_shader_parameter("opacity", md["opacity"])
	return mat


## DI2's landscape material (M_LandscapeLite, game/shaders/di2_landscape.gdshader): per layer k = 1..5 the diffuse /
## normal / MRO / heightmap (AHA) textures and the MI's tint, height-blend influence and roughness adjustment.
func _landscape_material(md: Dictionary) -> Material:
	var mat := ShaderMaterial.new()
	mat.resource_name = md["name"]
	mat.shader = load(SHADERS["landscape"])
	var slots := {"albedo": [], "normal": [], "mro": [], "height": []}
	var tints: Array[Vector4] = []
	var hb := PackedFloat32Array()
	var ra := PackedFloat32Array()
	var layers: Array = md.get("layers", [])
	for k in 5:
		var lay: Dictionary = layers[k] if k < layers.size() else {}
		var tex: Dictionary = lay.get("textures", {})
		for s in slots:
			slots[s].append(_texture(tex[s]) if tex.has(s) else null)
		var t = lay.get("Diffuse Colour Tint")
		tints.append(Vector4(t[0], t[1], t[2], t[3]) if t is Array else Vector4.ONE)
		var h = lay.get("Height Blend Influence")
		hb.append(float(h) if h != null else 1.0)
		var r = lay.get("Roughness Adjustment")
		ra.append(float(r) if r != null else 0.0)
	for s in slots:
		mat.set_shader_parameter("layer_" + s, slots[s])
	mat.set_shader_parameter("layer_tint", tints)
	mat.set_shader_parameter("layer_height_blend", hb)
	mat.set_shader_parameter("layer_roughness_adj", ra)
	mat.set_shader_parameter("tiling_cm", float(md.get("tiling_cm", 400.0)) if md.get("tiling_cm") != null else 400.0)
	return mat


func _texture(rel: String) -> Texture2D:
	if textures.has(rel):
		return textures[rel]
	var tex: Texture2D = null
	var bytes := FileAccess.get_file_as_bytes(dir + "/" + rel)
	var img := Image.new()
	if bytes.is_empty():
		push_warning("DI2Map: missing %s" % rel)
	elif img.load_dds_from_buffer(bytes) == OK:
		tex = ImageTexture.create_from_image(img)
	else:
		push_warning("DI2Map: cannot decode %s" % rel)
	textures[rel] = tex
	return tex


# --- lights / environment / decals ---------------------------------------------------------------------------------

## WorldEnvironment from the level's time-of-day actor: its HDRI (BP_BasicTimeOfDay SkyTexture) as the sky, also the
## ambient and reflection source, scaled by Sky Brightness x the level's exposure (tools/build_test_map.py sun_and_sky).
## DI2's sky HDRIs are 4:1 domes (zenith at the top row, horizon at the bottom: T_VeniceBeach_HDR 4096 x 1024) on the
## M_Sky dome mesh; Godot's panorama is a full 2:1 sphere, so the dome becomes its upper half and the lower half stays
## black (below the horizon DI2 has level geometry, not sky). The dome's azimuth offset is not ported.
## Exposure and tone mapping are DI2's (game/scripts/di2_post.gd, a compositor effect: eye adaptation from a scene
## histogram + DI2's LUT / tonemap passes, recon/TEST_MAP.md "Exposure and tone mapping"); lights and sky are
## pre-exposed by environment.pre_exposure, and Godot's own tonemap is linear (white 1) so DI2's display values pass
## through. Godot's glow is off: DI2's bloom (BloomIntensity 0.35, tinted gaussian chain, dirt mask) is not ported yet.
func _environment(env: Dictionary) -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sky_tex: Texture2D = _sky_panorama(env["sky_file"]) if env.has("sky_file") else null
	if sky_tex:
		var pm := PanoramaSkyMaterial.new()
		pm.panorama = sky_tex
		pm.energy_multiplier = env.get("sky_energy", 1.0)
		sky.sky_material = pm
	else:
		sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = true
	if env.has("post"):
		e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		e.tonemap_exposure = 1.0
		e.tonemap_white = 1.0
		e.glow_enabled = false
		post = (load("res://scripts/di2_post.gd") as GDScript).new()
		post.post = env["post"]
		post.pre_exposure = float(env.get("pre_exposure", 1.0))
		post.map_dir = dir
		if env.has("fog"):
			# UE height fog inscattering: InscatteringTextureTint * the sky cubemap's non-directional (lowest mip)
			# colour. The cubemap (TC_VeniceBeach_Cube_HDR) is not exported; the mean of the same HDRI's dome stands in
			# (UNVERIFIED #57).
			post.fog = env["fog"]
			post.fog_inscatter = _sky_mean * float(env["fog"]["tint"]) * float(env.get("pre_exposure", 1.0))
		var comp := Compositor.new()
		comp.compositor_effects = [post]
		we.compositor = comp
	else:
		e.tonemap_mode = Environment.TONE_MAPPER_AGX
		e.glow_enabled = true
	we.environment = e
	we.name = "Environment"
	add_child(we)


## DI2's exposure-compensated particle emissive (recon/PARTICLES.md 4.3): lerp(Bright, Dark Scene Multiplier,
## sat((X - Tb) / (Td - Tb))) / X * PreExposure, X = View.CurrentEyeAdaption.y (the eye adaptation's target exposure),
## Tb / Td = MPC_Postprocess_Player AdvExpCompThresholdBright 5e-5 / AdvExpCompThresholdDark 0.005. The port's
## particle shaders output lerp(...) unscaled, so DI2ParticleMaterials gets the blend and PreExposure / X (in this
## map's units: pre_exposure / exposure); new particle materials pick them up.
func _process(_delta: float) -> void:
	if post == null or post.target_exposure <= 0.0:
		return
	var x: float = post.target_exposure
	DI2ParticleMaterials.scene_exposure = clampf((x - 5e-5) / (0.005 - 5e-5), 0.0, 1.0)
	DI2ParticleMaterials.emissive_exposure_scale = post.pre_exposure / x


func _sky_panorama(rel: String) -> Texture2D:
	var bytes := FileAccess.get_file_as_bytes(dir + "/" + rel)
	var img := Image.new()
	if bytes.is_empty() or img.load_dds_from_buffer(bytes) != OK:
		push_warning("DI2Map: cannot load sky %s" % rel)
		return null
	if img.get_width() != 4 * img.get_height():
		return ImageTexture.create_from_image(img)
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBAH)
	var small := img.duplicate() as Image
	small.resize(64, 16, Image.INTERPOLATE_BILINEAR)
	var sum := Color(0, 0, 0)
	for y in 16:
		for x in 64:
			sum += small.get_pixel(x, y)
	_sky_mean = Color(sum.r / 1024.0, sum.g / 1024.0, sum.b / 1024.0)
	var pano := Image.create_empty(img.get_width(), img.get_height() * 2, false, Image.FORMAT_RGBAH)
	pano.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i.ZERO)
	return ImageTexture.create_from_image(pano)


func _lights(lights: Array) -> void:
	for l: Dictionary in lights:
		var node: Light3D
		match String(l["kind"]):
			"directional":
				var d := DirectionalLight3D.new()
				d.directional_shadow_max_distance = l.get("shadow_distance", 100.0)
				# DI2's cascades (tools/test_map/post.py sun_shadows): count, UE exponent-3 splits, fade-out fraction
				if int(l.get("shadow_cascades", 4)) >= 4:
					d.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
				var sp: Array = l.get("shadow_splits", [])
				if sp.size() >= 3:
					d.directional_shadow_split_1 = sp[0]
					d.directional_shadow_split_2 = sp[1]
					d.directional_shadow_split_3 = sp[2]
				d.directional_shadow_fade_start = 1.0 - float(l.get("shadow_fade", 0.2))
				d.directional_shadow_blend_splits = bool(l.get("shadow_blend", false))
				node = d
			"point":
				var p := OmniLight3D.new()
				p.omni_range = l["range"]
				p.omni_attenuation = l.get("attenuation", 1.0)
				node = p
			"spot":
				var s := SpotLight3D.new()
				s.spot_range = l["range"]
				s.spot_angle = l["angle"]
				s.spot_attenuation = l.get("attenuation", 1.0)
				node = s
			_:
				continue
		var c: Array = l["color"]
		node.light_color = Color(c[0], c[1], c[2])
		node.light_energy = l["energy"]
		node.shadow_enabled = l.get("shadow", false)
		var x: Array = l["xform"]
		node.transform = Transform3D(Basis(Vector3(x[0], x[1], x[2]), Vector3(x[3], x[4], x[5]), Vector3(x[6], x[7], x[8])),
			Vector3(x[9], x[10], x[11]))
		node.name = String(l.get("name", node.name))
		add_child(node)


func _decals(decals: Array) -> void:
	var n := 0
	for dd: Dictionary in decals:
		var mi := int(dd["material"])
		if mi < 0:
			continue
		var md: Dictionary = data["materials"][mi]
		var tex: Dictionary = md.get("textures", {})
		if not tex.has("albedo"):
			continue
		var dec := Decal.new()
		dec.texture_albedo = _texture(tex["albedo"])
		if tex.has("normal"):
			dec.texture_normal = _texture(tex["normal"])
		var s: Array = dd["size"]
		dec.size = Vector3(s[0], s[1], s[2])
		var x: Array = dd["xform"]
		dec.transform = Transform3D(Basis(Vector3(x[0], x[1], x[2]), Vector3(x[3], x[4], x[5]), Vector3(x[6], x[7], x[8])),
			Vector3(x[9], x[10], x[11]))
		dec.cull_mask = 0xFFFFF & ~Fx.CHARACTER_LAYER
		if md.get("tint") != null:
			var c: Array = md["tint"]
			dec.modulate = Color(c[0], c[1], c[2], c[3])
		add_child(dec)
		n += 1
	stats["decals"] = n
