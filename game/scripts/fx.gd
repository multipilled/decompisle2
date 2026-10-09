class_name Fx
## Blood bursts, floor splats, gibs (DI2's breakage, viscera and blood-gib meshes) and floating damage numbers.

static var _blood_mat: StandardMaterial3D
static var _decal_tex: Texture2D


static func _mats() -> void:
	if _blood_mat:
		return
	_blood_mat = StandardMaterial3D.new()
	_blood_mat.albedo_color = Color(0.32, 0.01, 0.01)
	_blood_mat.roughness = 0.15
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.55, Color(1, 1, 1, 0.9))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 128
	gt.height = 128
	_decal_tex = gt


static func blood_burst(parent: Node, at: Vector3, dir: Vector3, amount: int = 24, speed: float = 3.0) -> void:
	_mats()
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = amount
	p.lifetime = 0.9
	p.explosiveness = 0.95
	p.direction = dir.normalized() if dir.length() > 0.01 else Vector3.UP
	p.spread = 35.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.004
	p.scale_amount_max = 0.014
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = 6
	m.rings = 3
	m.material = _blood_mat
	p.mesh = m
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(2.0).timeout.connect(p.queue_free)
	if amount > 0:
		floor_splat(parent, at, clampf(0.2 + amount * 0.008, 0.2, 0.9))


## Render layer for characters, so floor decals never stain them.
const CHARACTER_LAYER := 2


static func floor_splat(parent: Node, at: Vector3, size: float) -> void:
	_mats()
	var from := Vector3(at.x + randf_range(-0.3, 0.3), at.y + 0.1, at.z + randf_range(-0.3, 0.3))
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 4.0, Util.WORLD)
	var hit := (parent as Node3D).get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var d := Decal.new()
	d.texture_albedo = _decal_tex
	d.modulate = Color(0.3, 0.0, 0.0, 0.9)
	d.size = Vector3(size, 0.3, size)
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	d.cull_mask = 1
	parent.add_child(d)
	d.global_position = hit["position"]
	d.rotate_y(randf() * TAU)
	parent.get_tree().create_timer(90.0).timeout.connect(d.queue_free)


const GORE_DIR := "res://assets/di2/gore"
## Viscera bigger than this (m, largest side) stay in the body: whole lungs, the intestine mass.
const MAX_GIB_SIZE := 0.2

## DI2 gore meshes (tools/pack_gore.py): {"shards": [...], "splats": [...], "viscera": {group: [...]}},
## each entry {mesh, mat, centre (bind pose), half (AABB half size)}.
static var _gore: Dictionary


static func _gore_set(file: String) -> Array:
	var scene: PackedScene = load(GORE_DIR.path_join(file + ".glb"))
	if scene == null:
		push_error("Fx: missing %s/%s.glb (run tools/pack_gore.py)" % [GORE_DIR, file])
		return []
	var root := scene.instantiate()
	var mats := Util.apply_prop_materials(root, GORE_DIR.path_join(file + ".materials.json"))
	for m in mats:
		m.set_shader_parameter("blood_amount", 0.45)
	var out := []
	for mi: MeshInstance3D in Util.find_all(root, "MeshInstance3D"):
		var aabb := mi.mesh.get_aabb()
		out.append({"name": String(mi.name), "mesh": mi.mesh, "mat": mi.get_surface_override_material(0),
			"centre": mi.position, "half": aabb.size * 0.5, "offset": aabb.get_center()})
	root.free()
	return out


static func _load_gore() -> void:
	if not _gore.is_empty():
		return
	_gore = {"shards": _gore_set("breakage"), "splats": _gore_set("blood_gibs"), "viscera": {}}
	var info: Dictionary = Util.load_json(GORE_DIR.path_join("viscera.json"))
	for file in ["head_viscera", "organs"]:
		for e: Dictionary in _gore_set(file):
			var meta: Dictionary = info.get(e["name"], {})
			e["bone"] = meta.get("bone", "")
			var group: String = meta.get("group", "Loose")
			if not _gore["viscera"].has(group):
				_gore["viscera"][group] = []
			_gore["viscera"][group].append(e)


## Flying gore from DI2's meshes: viscera pieces of `group` (gore/viscera.json: "Head" for a burst head,
## "Guts"/"Loose" for the torso) plus `count` breakage shards, landing in DI2's blood-gib splats.
## `from_rest` maps the body's bind pose to world, so viscera start where they sat in the body.
static func gibs(parent: Node, at: Vector3, dir: Vector3, count: int = 10, group: String = "", from_rest := Transform3D.IDENTITY) -> void:
	_load_gore()
	var placed := from_rest != Transform3D.IDENTITY
	var pieces := []
	for e: Dictionary in _gore["viscera"].get(group, []):
		var half: Vector3 = e["half"]
		if maxf(half.x, maxf(half.y, half.z)) * 2.0 <= MAX_GIB_SIZE:
			pieces.append([e, 1.0])
	for i in count:
		if not _gore["shards"].is_empty():
			pieces.append([_gore["shards"].pick_random(), randf_range(0.45, 0.85)])
	for p in pieces:
		var e: Dictionary = p[0]
		var scale: float = p[1]
		var rb := RigidBody3D.new()
		rb.collision_layer = Util.DEBRIS
		rb.collision_mask = Util.WORLD | Util.DEBRIS
		var half: Vector3 = e["half"] * scale
		rb.mass = clampf(half.x * half.y * half.z * 8.0 * 1000.0, 0.05, 1.5)
		var mi := MeshInstance3D.new()
		mi.mesh = e["mesh"]
		mi.material_override = e["mat"]
		mi.scale = Vector3.ONE * scale
		rb.add_child(mi)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = (half * 2.0).max(Vector3.ONE * 0.02)
		cs.shape = box
		cs.position = e["offset"] * scale
		rb.add_child(cs)
		parent.add_child(rb)
		var start := at + Vector3(randf_range(-0.05, 0.05), randf_range(-0.05, 0.05), randf_range(-0.05, 0.05))
		var basis := Basis(Quaternion.from_euler(Vector3(randf(), randf(), randf()) * TAU))
		if placed and e["centre"] != Vector3.ZERO:
			start = from_rest * e["centre"]
			basis = from_rest.basis.orthonormalized()
		rb.global_transform = Transform3D(basis, start)
		var out := (start - at).normalized() if start.distance_to(at) > 0.01 else Vector3.UP
		rb.linear_velocity = dir.normalized() * randf_range(1.0, 3.5) + out * randf_range(1.0, 2.5) + Vector3(randf_range(-1, 1), randf_range(1.5, 3.5), randf_range(-1, 1))
		rb.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 9.0
		parent.get_tree().create_timer(20.0).timeout.connect(rb.queue_free)
	for i in 1 + int(count / 5.0):
		blood_gib_splat(parent, at + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6)) + dir.normalized() * randf_range(0.2, 1.0))


## One of DI2's flat gore splats (alpha-masked chunks and blood) lying on the floor under `at`.
static func blood_gib_splat(parent: Node, at: Vector3, size := 1.0) -> void:
	_load_gore()
	if _gore["splats"].is_empty():
		return
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 4.0, Util.WORLD)
	var hit := (parent as Node3D).get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var e: Dictionary = _gore["splats"].pick_random()
	var mi := MeshInstance3D.new()
	mi.mesh = e["mesh"]
	mi.material_override = e["mat"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = hit["position"] + Vector3.UP * 0.003
	mi.rotate_y(randf() * TAU)
	mi.scale = Vector3.ONE * size * randf_range(0.6, 1.1)
	parent.get_tree().create_timer(90.0).timeout.connect(mi.queue_free)


static func damage_number(parent: Node, at: Vector3, value: float, crit: bool) -> void:
	var l := Label3D.new()
	l.text = str(roundi(value))
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 48 if crit else 34
	l.modulate = Color(1, 0.85, 0.2) if crit else Color(1, 1, 1)
	l.outline_size = 8
	l.pixel_size = 0.004
	parent.add_child(l)
	l.global_position = at + Vector3(0, 0.15, 0)
	var t := l.create_tween()
	t.tween_property(l, "global_position", at + Vector3(randf_range(-0.2, 0.2), 0.7, 0), 0.8)
	t.parallel().tween_property(l, "modulate:a", 0.0, 0.8)
	t.tween_callback(l.queue_free)


# --- Combat effects (combat session) ----------------------------------------------------------------

static func _quick_particles(parent: Node, at: Vector3, color: Color, amount: int, speed: float, size: float, lifetime := 0.6, dir := Vector3.UP, spread := 60.0, gravity := -9.8) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 0.95
	p.direction = dir
	p.spread = spread
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity, 0)
	p.scale_amount_min = size * 0.5
	p.scale_amount_max = size
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = 6
	m.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = color.v > 0.8
	mat.emission = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if color.v > 0.8 else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.material = mat
	p.mesh = m
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(lifetime + 1.0).timeout.connect(p.queue_free)
	return p


static func status_burst(target: Node3D, status: String) -> void:
	var at := target.global_position + Vector3.UP * 1.1
	match status:
		"burning":
			_quick_particles(target.get_parent(), at, Color(1.0, 0.55, 0.15), 40, 2.0, 0.05, 0.8, Vector3.UP, 30.0, 2.0)
		"electrified":
			_quick_particles(target.get_parent(), at, Color(0.6, 0.85, 1.0), 30, 4.0, 0.02, 0.3)
		"caustic":
			_quick_particles(target.get_parent(), at, Color(0.55, 0.75, 0.1), 30, 1.5, 0.04, 1.0)
		"bleeding":
			blood_burst(target.get_parent(), at, Vector3.UP, 30, 2.0)


## Placeholder (not DI2). World hits use WeaponVfx.world_impact / melee_world_hit (DI2's environment hit-effect trees).
static func sparks(parent: Node, at: Vector3, normal: Vector3) -> void:
	_quick_particles(parent, at, Color(1.0, 0.85, 0.5), 14, 4.0, 0.012, 0.35, normal, 40.0)


static func explosion(parent: Node, at: Vector3) -> void:
	_quick_particles(parent, at + Vector3.UP * 0.3, Color(1.0, 0.6, 0.2), 60, 9.0, 0.15, 0.5, Vector3.UP, 180.0, -2.0)
	_quick_particles(parent, at + Vector3.UP * 0.3, Color(0.15, 0.13, 0.12), 40, 3.0, 0.35, 1.6, Vector3.UP, 90.0, 1.0)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.6, 0.3)
	l.light_energy = 12.0
	l.omni_range = 9.0
	parent.add_child(l)
	l.global_position = at + Vector3.UP
	var t := l.create_tween()
	t.tween_property(l, "light_energy", 0.0, 0.5)
	t.tween_callback(l.queue_free)
	floor_splat(parent, at + Vector3.UP * 0.5, 2.5)


static func shockwave(parent: Node, at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var m := TorusMesh.new()
	m.inner_radius = 0.9
	m.outer_radius = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	mi.mesh = m
	parent.add_child(mi)
	mi.global_position = at + Vector3.UP * 0.1
	var t := mi.create_tween()
	t.tween_property(mi, "scale", Vector3(4, 1, 4), 0.35)
	t.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.35)
	t.tween_callback(mi.queue_free)


## Placeholder (not DI2). Guns use WeaponVfx.on_shot (DI2's muzzle flare CEs / MuzzleFlashEffectType).
static func muzzle_flash(camera: Camera3D, local: Vector3) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.75, 0.4)
	l.light_energy = 6.0
	l.omni_range = 4.0
	camera.add_child(l)
	l.position = local
	camera.get_tree().create_timer(0.05).timeout.connect(l.queue_free)


## Placeholder (not DI2). Guns use WeaponVfx.on_projectile / tracer (DI2's PS_Ranged_Tracer_Single with its params).
static func tracer(parent: Node, from: Vector3, to: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.004
	m.bottom_radius = 0.004
	m.height = from.distance_to(to)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.6, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	mi.mesh = m
	parent.add_child(mi)
	mi.global_position = (from + to) * 0.5
	var axis := (to - from).normalized()
	if absf(axis.dot(Vector3.UP)) < 0.999:
		mi.global_basis = Basis(Quaternion(Vector3.UP, axis))
	parent.get_tree().create_timer(0.05).timeout.connect(mi.queue_free)
