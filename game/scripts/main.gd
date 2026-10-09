class_name Main
extends Node3D
## Test arena: Dani vs DI2 walkers, recreated gore running on the Rust core.

static var time_scale := 1.0

var player: Player
var hud: Hud
var archetypes: Array = []
var archetype_i := 0
var progression: Progression


func _init() -> void:
	_bind("move_forward", [KEY_W])
	_bind("move_back", [KEY_S])
	_bind("move_left", [KEY_A])
	_bind("move_right", [KEY_D])
	_bind("jump", [KEY_SPACE])
	_bind("sprint", [KEY_SHIFT])
	_bind("kick", [KEY_F], [MOUSE_BUTTON_MIDDLE])
	_bind("dodge", [KEY_ALT, KEY_C])
	_bind("reload", [KEY_R])
	_bind("repair", [KEY_T])
	_bind("weapon_1", [KEY_1])
	_bind("weapon_2", [KEY_2])
	_bind("weapon_3", [KEY_3])
	_bind("weapon_next", [], [MOUSE_BUTTON_WHEEL_DOWN])
	_bind("weapon_prev", [], [MOUSE_BUTTON_WHEEL_UP])
	_bind("attack", [], [MOUSE_BUTTON_LEFT])
	_bind("block", [], [MOUSE_BUTTON_RIGHT])
	_bind("respawn", [KEY_ENTER])
	_bind("spawn", [KEY_K])
	_bind("cycle_archetype", [KEY_J])
	_bind("slowmo", [KEY_Z])
	_bind("cycle_mod", [KEY_M])
	_bind("throw_weapon", [KEY_G])
	_bind("curveball", [KEY_Q])
	_bind("cycle_curveball", [KEY_TAB])
	_bind("fury", [KEY_V])
	_bind("medkit", [KEY_H])
	_bind("interact", [KEY_E])
	_bind("toggle_debug", [KEY_F2])
	_bind("toggle_help", [KEY_F1])
	_bind("catalog", [KEY_F3])


func _bind(action: String, keys: Array, buttons: Array = []) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	for b in buttons:
		var m := InputEventMouseButton.new()
		m.button_index = b
		InputMap.action_add_event(action, m)


func _ready() -> void:
	archetypes = (Util.load_json("res://data/archetypes.json") as Array).map(func(a): return a["name"])
	archetype_i = max(0, archetypes.find("Walker"))
	_build_arena()
	# A system's first use loads its materials (~0.8 s, recon/PARTICLES.md hand-off): prewarm every CE a zombie hit can
	# play (game/data/hit_effects.json) and the molotov's burning petrol (CE_Fluid_State_Flammable) at load.
	var ces := {}
	var rx := RegEx.create_from_string("\"(CE_[A-Za-z0-9_]+)\"")
	# Also the statuses' CEs a zombie plays: body_proxies.json's propagation CEs (damage_propagation.gd) and the
	# electrocute look (zombie.gd _electrocute_look). prewarm skips names the particle port doesn't have.
	for path in ["res://data/hit_effects.json", "res://data/body_proxies.json"]:
		for m in rx.search_all(FileAccess.get_file_as_string(path)):
			ces[m.get_string(1)] = true
	ces["CE_StatusEffect_Electrocute"] = true
	ces["CE_Fluid_State_Flammable"] = true
	DI2Particles.prewarm(ces.keys())
	player = Player.new()
	player.name = "Dani"
	add_child(player)
	player.global_position = Vector3(0, 0.1, 6)
	player.spawn_point = player.global_position
	var layer := CanvasLayer.new()
	add_child(layer)
	progression = Progression.new(player.combat)
	hud = Hud.new()
	hud.player = player
	hud.progression = progression
	layer.add_child(hud)
	for i in 5:
		var a := TAU * i / 5.0
		spawn_zombie(Vector3(cos(a) * 5.0, 0.1, sin(a) * 5.0 - 4.0), archetypes[archetype_i])
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--weapontest="):
			var wt: Node = load("res://scripts/autotest_weapons.gd").new()
			wt.out_dir = arg.trim_prefix("--weapontest=")
			for a2 in OS.get_cmdline_user_args():
				if a2.begins_with("--only="):
					wt.only = a2.trim_prefix("--only=")
			hud.show_help = false
			add_child(wt)
			return
		if arg.begins_with("--fleshtest="):
			var ft: Node = load("res://scripts/autotest_flesh.gd").new()
			ft.out_dir = arg.trim_prefix("--fleshtest=")
			hud.show_help = false
			add_child(ft)
			return
		if arg.begins_with("--combattest="):
			var ct: Node = load("res://scripts/autotest_combat.gd").new()
			ct.out_dir = arg.trim_prefix("--combattest=")
			hud.show_help = false
			add_child(ct)
			return
		if arg.begins_with("--autotest="):
			var t: Node = load("res://scripts/autotest.gd").new()
			t.out_dir = arg.trim_prefix("--autotest=")
			hud.show_help = false
			add_child(t)
			return
		if arg.begins_with("--danitest="):
			var dt: Node = load("res://scripts/autotest_dani.gd").new()
			dt.out_dir = arg.trim_prefix("--danitest=")
			hud.show_help = false
			add_child(dt)
			return
		if arg.begins_with("--particletest="):
			var pt: Node = load("res://scripts/autotest_particles.gd").new()
			pt.out_dir = arg.trim_prefix("--particletest=")
			hud.show_help = false
			add_child(pt)
			return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_arena() -> void:
	# --map=<name>: a DI2 level section (game/scripts/di2_map.gd, built by tools/build_test_map.py) instead of the
	# procedural arena. Its spawn origin is an open DI2 floor area, so every fixed test position stays valid.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			var map_name := arg.trim_prefix("--map=")
			var di2_map: Script = load("res://scripts/di2_map.gd")
			if di2_map.call("exists", map_name):
				add_child(di2_map.call("create", map_name))
				return
			push_error("--map=%s: no res://assets/di2/maps/%s/map.json (run tools/build_test_map.py %s)" % [map_name, map_name, map_name])
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.45, 0.62)
	sm.sky_horizon_color = Color(0.75, 0.68, 0.6)
	sm.ground_bottom_color = Color(0.2, 0.18, 0.16)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.ssao_enabled = true
	e.glow_enabled = true
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.shadow_enabled = true
	add_child(sun)

	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = Util.WORLD
	var fm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	# The floor composes DI2's fluid buffer (blood puddles, DI2Fluids / di2_fluid.gdshaderinc).
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/arena_floor.gdshader")
	var noise := NoiseTexture2D.new()
	noise.noise = FastNoiseLite.new()
	noise.seamless = true
	mat.set_shader_parameter("albedo_texture", noise)
	plane.material = mat
	fm.mesh = plane
	floor_body.add_child(fm)
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	fs.shape = box
	fs.position.y = -0.5
	floor_body.add_child(fs)
	add_child(floor_body)

	# Some cover: crates and a low wall to test sweeps hitting the world.
	var crate_mat := StandardMaterial3D.new()
	crate_mat.albedo_color = Color(0.45, 0.33, 0.2)
	for i in 8:
		var a := TAU * i / 8.0 + 0.3
		_box(Vector3(cos(a) * 14.0, 0.6, sin(a) * 14.0), Vector3(1.2, 1.2, 1.2), crate_mat)
	_box(Vector3(0, 0.5, -14), Vector3(10, 1.0, 0.4), crate_mat)


func _box(pos: Vector3, size: Vector3, mat: Material) -> void:
	var b := StaticBody3D.new()
	b.collision_layer = Util.WORLD
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	m.material = mat
	mi.mesh = m
	b.add_child(mi)
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = size
	cs.shape = s
	b.add_child(cs)
	add_child(b)
	b.position = pos


func spawn_zombie(at: Vector3, archetype: String) -> Zombie:
	var z := Zombie.new()
	z.archetype = archetype
	# DI2 spawns enemies around the player's level.
	z.level = maxi(1, progression.level + randi_range(-1, 1)) if progression else 1
	z.target = player
	z.died.connect(_on_zombie_died)
	z.add_to_group("zombies")
	add_child(z)
	z.global_position = at
	z.rotation.y = randf() * TAU
	return z


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("spawn"):
		var cam := player.camera.global_transform
		var at := cam.origin - cam.basis.z * 6.0
		spawn_zombie(Vector3(at.x, 0.1, at.z), archetypes[archetype_i])
	elif event.is_action_pressed("cycle_archetype"):
		archetype_i = (archetype_i + 1) % archetypes.size()
		player.say("Spawning: %s (%s body)" % [archetypes[archetype_i], Zombie.body_for(archetypes[archetype_i])[0]])
	elif event.is_action_pressed("slowmo"):
		time_scale = 0.25 if time_scale > 0.5 else 1.0
		Engine.time_scale = time_scale
	elif event.is_action_pressed("toggle_debug"):
		hud.show_debug = not hud.show_debug
	elif event.is_action_pressed("toggle_help"):
		hud.show_help = not hud.show_help
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if progression:
		progression.tick(delta)


func _on_zombie_died(z: Zombie) -> void:
	if progression == null or not (z.last_attacker is Player):
		return
	var gained := progression.add(progression.reward_for(z))
	player.popup(z.global_position + Vector3.UP * 2.2, "+%d XP" % progression.last_gain, "perk")
	if gained > 0:
		player.set_level(progression.level)
		player.health = player.max_health
