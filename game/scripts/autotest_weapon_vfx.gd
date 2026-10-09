extends Node3D
## DI2 weapon / world-impact VFX check (recon/WEAPON_VFX.md). Own scene (scenes/weapon_vfx_test.tscn) so it needs no
## hook in main.gd; run it in the background through tools/run_test.sh:
##   RUN_TEST_ENGINE_ARGS="--fixed-fps 60 res://scenes/weapon_vfx_test.tscn" tools/with_cpu.sh me tools/with_lock.sh me \
##     tools/run_test.sh --weaponvfxtest=game/test_out/weapon_vfx [--only=<case>]
## A small arena (floor and walls with DI2 physical materials as meta) and the real Player: every case fires / swings
## through the real player code, so the player_ranged / player_melee hooks are what is tested. Frames are captured at
## fixed frame counts (--fixed-fps 60 => 1 frame = 1/60 s of game time) from the first-person camera and from side
## cameras; weapon_vfx.log lists what DI2's data picked (muzzle CE, tracer CE, impact CEs, decals, live systems).

const FP_FRAMES := [1, 2, 3, 5, 8, 14, 24, 40]
const CASES := ["pistol_concrete", "pistol_floor", "pistol_wood", "pistol_metal", "shotgun_concrete",
	"bat_concrete", "machete_concrete"]

var out_dir := ""
var only := ""
var p: Player
var side: Camera3D
var log_lines: PackedStringArray = []
var walls := {}


func _init() -> void:
	# The Player reads these actions every frame (main.gd binds them; this scene has no Main).
	for a in ["move_forward", "move_back", "move_left", "move_right", "jump", "sprint", "kick", "dodge", "reload",
			"repair", "weapon_1", "weapon_2", "weapon_3", "weapon_next", "weapon_prev", "attack", "block", "respawn",
			"spawn", "cycle_archetype", "slowmo", "cycle_mod", "throw_weapon", "curveball", "cycle_curveball", "fury",
			"medkit", "interact", "toggle_debug", "toggle_help", "catalog"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weaponvfxtest="):
			out_dir = a.trim_prefix("--weaponvfxtest=")
		elif a.begins_with("--only="):
			only = a.trim_prefix("--only=")
		elif a.begins_with("--decals="):
			WeaponVfx.decal_renderer = a.trim_prefix("--decals=")
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://test_out/weapon_vfx")
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_tree().create_timer(280.0, true, false, true).timeout.connect(func() -> void:
		log_lines.append("WATCHDOG: timed out")
		_save_log()
		get_tree().quit(1))
	DI2Particles.seed_override = 4242
	seed(4242)
	_arena()
	p = Player.new()
	p.name = "Dani"
	p.loadout = ["pistol", "shotgun", "bat", "machete"]
	add_child(p)
	p.global_position = Vector3(0, 0.1, 0)
	side = Camera3D.new()
	side.fov = 60.0
	add_child(side)
	await _frames(10)
	for c in CASES:
		if only != "" and not c.contains(only):
			continue
		await _case(c)
	_save_log()
	get_tree().quit()


# --- Arena ------------------------------------------------------------------------------------------------------

func _arena() -> void:
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
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	add_child(sun)
	# Floor like main.gd's arena (grey, PM_Concrete stand-in) + walls tagged with DI2 physical materials.
	_box("floor", Vector3(0, -0.5, 0), Vector3(40, 1, 40), Color(0.36, 0.34, 0.31), "PM_Concrete")
	_box("concrete", Vector3(0, 1.5, -6), Vector3(4, 3, 0.4), Color(0.5, 0.5, 0.48), "PM_Concrete")
	_box("wood", Vector3(5, 1.5, -6), Vector3(4, 3, 0.4), Color(0.45, 0.33, 0.2), "PM_Wood")
	_box("metal", Vector3(-5, 1.5, -6), Vector3(4, 3, 0.4), Color(0.4, 0.42, 0.45), "PM_Metal")


func _box(n: String, pos: Vector3, size: Vector3, col: Color, pm: String) -> void:
	var b := StaticBody3D.new()
	b.name = n
	b.collision_layer = Util.WORLD
	b.set_meta("di2_physical_material", pm)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.9
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
	walls[n] = b


# --- Cases ------------------------------------------------------------------------------------------------------

func _case(c: String) -> void:
	var wid: String = c.get_slice("_", 0)
	var target: String = c.get_slice("_", 1)
	_clear()
	p.equip(wid, true)
	p.mag = 99
	p.set_state("ready")
	var aim := Vector3(0, 1.5, -5.8)
	var stand := Vector3(0, 0.1, 0)
	match target:
		"floor":
			aim = Vector3(0, 0.0, -3.0)
		"wood":
			aim = Vector3(5, 1.5, -5.8)
			stand = Vector3(5, 0.1, 0)
		"metal":
			aim = Vector3(-5, 1.5, -5.8)
			stand = Vector3(-5, 0.1, 0)
	if wid in ["bat", "machete"]:
		stand = Vector3(aim.x, 0.1, -4.75)
	p.global_position = stand
	await _frames(40)
	_aim(aim)
	await _frames(5)
	var line := "%-18s" % c
	var spawned_before := _alive()
	if p.is_melee():
		WeaponVfx.last_impact = []
		p.melee.start_light()
		var waited := 0
		while WeaponVfx.last_impact.is_empty() and waited < 150:
			await _frames(1)
			waited += 1
		line += " swing->impact %d frames" % waited
		await _capture_fp(c)
	else:
		var item := p.cls().pick("Shoot", p.ranged._facts()) if p.cls() else {}
		line += " muzzleCE=%s tracerCE=%s" % [WeaponVfx.object_set_ce(wid, WeaponVfx.KEY_MUZZLE, WeaponVfx.weapon_facts(p)),
			WeaponVfx.object_set_ce(wid, WeaponVfx.KEY_TRACER, WeaponVfx.weapon_facts(p))]
		line += " spawner=%s" % JSON.stringify(WeaponVfx.spawner(wid))
		line += " weapon_montage=%s" % str(item.get("weapon", {}).get("m", ""))
		WeaponVfx.last_impact = []
		p.ranged.fire()
		await _capture_fp(c)
	line += " impact=%s" % JSON.stringify(WeaponVfx.last_impact)
	line += " decals=%d systems_alive=%d (before %d)" % [_decals().size(), _alive(), spawned_before]
	log_lines.append(line)
	var imp := WeaponVfx.last_impact_at
	var hitp := imp.origin
	var into := -imp.basis.z
	# The impact up close (particles + fresh decal), from in front of the surface.
	_side(hitp - into * 0.7 + Vector3(0.0, 0.25, 0.0), hitp)
	await _shot(c + "_impact")
	if not p.is_melee():
		# A second shot seen from beside the gun: muzzle flare / casings / tracer.
		var sp := WeaponVfx.spawner(wid)
		await _frames(50)
		_aim(aim)
		await _frames(2)
		var mz := WeaponVfx.socket_transform(p, wid, str(sp["MuzzleOriginBoneOrSocketName"]))
		var sk: Skeleton3D = p.weapon_skel.get(wid)
		var so: Dictionary = WeaponVfx.db()["weapons"][wid]["sockets"].get(str(sp["MuzzleOriginBoneOrSocketName"]), {})
		log_lines.append("   muzzle socket %s bone %s idx %d at %s; gun node at %s; skeleton bones %s" % [sp["MuzzleOriginBoneOrSocketName"],
			so.get("bone", "?"), sk.find_bone(str(so.get("bone", ""))) if sk else -2, mz.origin, p.weapon_nodes[wid].global_position,
			str(range(sk.get_bone_count()).map(func(i: int) -> String: return sk.get_bone_name(i))) if sk else "none"])
		var fwd := (aim - mz.origin).normalized()
		var right := fwd.cross(Vector3.UP).normalized()
		_side(mz.origin + right * 0.4 + Vector3.UP * 0.1 + fwd * 0.05, mz.origin + fwd * 0.2)
		p.set_state("ready")
		p.ranged.shot_cd = 0.0
		p.ranged.burst_cd = 0.0
		p.ranged.fire()
		var f := 0
		for target_frame: int in [1, 2, 3, 5, 8, 14]:
			await _frames(target_frame - f)
			f = target_frame
			await _shot("%s_side_%02d" % [c, target_frame])
	if c.begins_with("shotgun"):
		# BP_AnimNotify_SpawnParticleSystemOnWeapon shells at 0.566 s (AM_ShotGun_Shoot_Weapon) after that shot.
		var ej := WeaponVfx.socket_transform(p, wid, "AmmoEject")
		var gfwd := -p.camera.global_basis.z
		var gright := gfwd.cross(Vector3.UP).normalized()
		_side(ej.origin + gright * 0.6 + Vector3.UP * 0.25 + gfwd * 0.2, ej.origin + gright * 0.15)
		await _frames(34 - 14)
		await _shot(c + "_shell_00")
		await _frames(6)
		await _shot(c + "_shell_06")
		await _frames(12)
		await _shot(c + "_shell_18")
	p.camera.current = true
	# The decals 1 s later, up close. On the floor a character-layer capsule lies across the hit: decals must stay off it
	# (Fx.CHARACTER_LAYER; DI2 characters don't receive these decals).
	var dummy: MeshInstance3D = null
	if target == "floor":
		dummy = MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.04
		cap.height = 0.3
		var cm := StandardMaterial3D.new()
		cm.albedo_color = Color(0.85, 0.85, 0.85)
		cap.material = cm
		dummy.mesh = cap
		dummy.layers = Fx.CHARACTER_LAYER
		add_child(dummy)
		dummy.global_transform = Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0), hitp + Vector3(0.0, 0.035, 0.0))
	await _frames(40)
	_side(hitp - into * 0.3 + Vector3(0.0, 0.08, 0.0), hitp)
	await _shot(c + "_decal")
	# Grazing view: the parallax occlusion depth of the decal.
	_side(hitp - into * 0.12 + imp.basis.x * 0.22, hitp)
	await _shot(c + "_decal_oblique")
	if dummy:
		dummy.queue_free()
	log_lines.append("   decal nodes (%s): %s" % [WeaponVfx.decal_renderer, str(_decals().map(func(d: Node3D) -> String: return _decal_desc(d)))])
	p.camera.current = true


func _capture_fp(c: String) -> void:
	p.camera.current = true
	var f := 0
	for target_frame: int in FP_FRAMES:
		await _frames(target_frame - f)
		f = target_frame
		await _shot("%s_fp_%02d" % [c, target_frame])


func _aim(target: Vector3) -> void:
	var d := (target - p.camera.global_position).normalized()
	p.rotation.y = atan2(-d.x, -d.z)
	p.pitch = asin(clampf(d.y, -1.0, 1.0))
	p.head.rotation.x = p.pitch


func _side(from: Vector3, look: Vector3) -> void:
	side.global_position = from
	side.look_at(look, Vector3.UP)
	side.current = true


func _clear() -> void:
	for n in get_children():
		if n is DI2Particles or _is_decal(n):
			n.queue_free()


func _decals() -> Array:
	return get_children().filter(func(n: Node) -> bool: return _is_decal(n))


func _is_decal(n: Node) -> bool:
	return n is Decal or (n is MeshInstance3D and n.material_override is ShaderMaterial and n.mesh is BoxMesh)


func _decal_desc(d: Node3D) -> String:
	if d is Decal:
		return "Decal %.1fx%.1fx%.1f cm %s" % [d.size.x * 100.0, d.size.y * 100.0, d.size.z * 100.0, d.texture_albedo != null]
	return "POM box depth %s, %.2f cm" % [d.material_override.get_shader_parameter("pom_depth"), d.global_basis.x.length() * 100.0]


func _alive() -> int:
	var n := 0
	for c in get_tree().root.find_children("*", "DI2Particles", true, false):
		n += 1
	return n


func _frames(n: int) -> void:
	for i in maxi(n, 0):
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))


func _save_log() -> void:
	var f := FileAccess.open(out_dir.path_join("weapon_vfx.log"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(log_lines) + "\n")
