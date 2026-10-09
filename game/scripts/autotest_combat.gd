extends Node
## Combat oracle for Dani's full DI2 kit: `godot --path game -- --combattest=<out_dir>`
## Every step drives the real player code paths, logs what the core reported and saves a screenshot.

var out_dir := ""
var main: Main
var p: Player
var log_lines: PackedStringArray = []


func _ready() -> void:
	main = get_parent()
	p = main.player
	DirAccess.make_dir_recursive_absolute(out_dir)
	await _wait(0.6)
	# --animcap[=a,b]: frame-exact animation captures instead of the combat oracle (scripts/anim_capture.gd).
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--animcap"):
			var cap: Node = load("res://scripts/anim_capture.gd").new()
			cap.out_dir = out_dir
			cap.main = main
			cap.p = p
			if arg.contains("="):
				cap.only = arg.split("=")[1].split(",")
			add_child(cap)
			await cap.run()
			get_tree().quit()
			return
	# --zombieai: only the zombie AI scenarios (log + captures in <test_out>/zombie_ai), not the whole combat oracle.
	if "--zombieai" in OS.get_cmdline_user_args():
		var zt0: Node = load("res://scripts/autotest_zombie_ai.gd").new()
		zt0.main = main
		zt0.p = p
		zt0.out_dir = out_dir.get_base_dir().path_join("zombie_ai")
		add_child(zt0)
		await zt0.run()
		get_tree().quit()
		return
	_clear()
	_log_rig("idle")

	# 1. Bat light chain on a Walker (context-picked swings, impacts, reactions, chain-damage perk).
	var z := _fresh(Vector3(0, 0.1, -1.7))
	p.equip("bat", true)
	await _wait(0.5)
	await _shot("00_bat_idle")
	_aim(z, "spine_03")
	for i in 3:
		_close_in(z, 1.5)
		_aim(z, "spine_03")
		await _light()
		if i == 0:
			_log_rig("after light")
			await _shot("01_bat_light_impact", 0.0)
	_log_z(z, "bat light x3")
	await _wait(1.0)
	await _shot("02_bat_after_chain")

	# 2. Head up close -> DI2 ScalpContext overhead strike.
	z = _fresh(Vector3(0, 0.1, -1.4))
	_aim(z, "head")
	await _light()
	log_lines.append("scalp context attack key: %s" % p.melee.key)
	_log_z(z, "scalp strike")
	await _wait(1.2)

	# 3. Fully charged bat heavy -> knockdown, then head stomp on the downed zombie.
	z = _fresh(Vector3(0, 0.1, -1.7))
	_aim(z, "spine_03")
	await _heavy(1.0)
	await _wait(0.4)
	await _shot("03_bat_heavy_knockdown")
	_log_z(z, "after heavy")
	await _wait(0.6)
	log_lines.append("downed before stomp: %s" % z.is_down())
	if z.is_down() and not z.dead:
		# Walk up to the body like a player would before stomping.
		var flat := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone("head")).origin
		var away := p.global_position - Vector3(flat.x, p.global_position.y, flat.z)
		p.global_position = Vector3(flat.x, p.global_position.y, flat.z) + away.normalized() * 1.0
		await _wait(0.05)
		_aim(z, "head")
		var sf := p.combat_facts(false)
		var ai := p.aim_info(3.0)
		log_lines.append("stomp facts: aim bone %s context %s pitch %.0f" % [ai.get("bone", "-"), sf.get("Self.TargetBodyContextName"), sf["Self.CameraPitch"]])
		p.moves.kick()
		log_lines.append("stomp clip: %s" % p.moves.kick_clip)
		await _wait(0.9)
		await _shot("04_stomp")
		_log_z(z, "after stomp")
	await _wait(1.0)

	# 4. Machete: slash an arm off, then a charged head strike.
	z = _fresh(Vector3(0, 0.1, -1.6))
	p.equip("machete", true)
	await _wait(0.5)
	for i in 3:
		_close_in(z, 1.4)
		_aim(z, "lowerarm_r" if i < 2 else "upperarm_l")
		await _light()
	_log_z(z, "machete arm slashes")
	await _shot("05_machete_arm")
	await _wait(1.0)

	# 5. Kicks: DI2 KickForce 30 vs stability 500 -> stumble, then knockdown.
	z = _fresh(Vector3(0, 0.1, -1.3))
	p.equip("bat", true)
	await _wait(0.4)
	_aim(z, "spine_03")
	for i in 2:
		_close_in(z, 1.1)
		_aim(z, "spine_03")
		p.moves.kick()
		await _wait(0.9)
		log_lines.append("kick %d: stability %.2f down=%s reaction=%s" % [i + 1, z.gore.get_stability(), z.is_down(), z.reactions.clip])
	await _shot("06_kicks")
	await _wait(2.5)

	# 6. Block -> perfect block -> counter (paired clips).
	z = _fresh(Vector3(0, 0.1, -1.4))
	_aim(z, "head")
	p.moves.block_pressed()
	p.rmb_held = true
	await _wait(0.1)
	p.take_zombie_hit(15.0, z)
	log_lines.append("perfect block: counter window %.2f, health %.0f" % [p.moves.counter_window, p.health])
	await _shot("07_perfect_block", 0.05)
	p.rmb_held = false
	await _wait(0.3)
	p.moves.on_attack_pressed()
	log_lines.append("counter state: %s zombie clip: %s" % [p.state, z.reactions.clip])
	await _wait(0.6)
	await _shot("08_counter")
	await _wait(2.0)
	_log_z(z, "after counter")
	# Regular block (outside the perfect window) drains stamina instead of health.
	z = _fresh(Vector3(0, 0.1, -1.4))
	p.moves.block_pressed()
	p.rmb_held = true
	await _wait(0.5)
	var hp := p.health
	var st := p.stamina
	p.take_zombie_hit(15.0, z)
	log_lines.append("regular block: health %.0f->%.0f stamina %.0f->%.0f" % [hp, p.health, st, p.stamina])
	p.rmb_held = false
	await _wait(0.6)

	# 7. Perfect dodge.
	p.moves.dodge()
	await _wait(0.1)
	p.take_zombie_hit(15.0, z)
	log_lines.append("dodge: state %s health %.0f" % [p.state, p.health])
	await _wait(1.0)

	# 8. Drop kick into a group.
	_clear()
	p.global_position = Vector3(0, 0.1, 2.0)
	for x in [-0.5, 0.5]:
		main.spawn_zombie(Vector3(x, 0.1, 0.0), "Walker").target = null
	await _wait(0.5)
	p.rotation.y = 0.0
	p.moves._start_dropkick()
	await _wait(0.45)
	await _shot("09_dropkick")
	await _wait(1.2)
	for zz: Zombie in get_tree().get_nodes_in_group("zombies"):
		_log_z(zz, "after dropkick")

	# 9. Ground pound.
	p.global_position = Vector3(0, 2.5, 1.0)
	p.velocity = Vector3.ZERO
	await _wait(0.2)
	p.air_t = 0.3
	p.moves.on_attack_pressed()
	await _wait(0.8)
	await _shot("10_ground_pound")
	for zz: Zombie in get_tree().get_nodes_in_group("zombies"):
		_log_z(zz, "after ground pound")
	await _wait(1.0)

	# 10. Weapon throw + pickup.
	_clear()
	p.global_position = Vector3(0, 0.1, 0)
	z = _fresh(Vector3(0, 0.1, -4.0))
	p.equip("machete", true)
	await _wait(0.4)
	_aim(z, "spine_03")
	p.moves.throw_pressed()
	await _wait(0.4)
	p.moves.throw_released()
	await _wait(0.6)
	await _shot("11_weapon_throw")
	_log_z(z, "after thrown machete")
	await _wait(1.0)
	var tw = p.moves.thrown[0] if not p.moves.thrown.is_empty() else null
	if tw:
		p.global_position = tw.global_position + Vector3(0.5, 0, 0.5)
		await _wait(0.1)
		p.moves.pickup()
	log_lines.append("after pickup: weapon %s away=%s" % [p.weapon, p.weapon_away])
	await _wait(0.5)

	# 11. Curveballs: pipe bomb, Molotov, shuriken.
	for kind_i in 3:
		_clear()
		p.global_position = Vector3(0, 0.1, 0)
		p.rotation.y = 0.0
		p.pitch = deg_to_rad(-10)
		for x in [-0.6, 0.6]:
			main.spawn_zombie(Vector3(x, 0.1, -6.0), "Walker").target = null
		await _wait(0.4)
		p.moves.curveball_i = kind_i
		p.moves.curveball_cd = 0.0
		log_lines.append("curveball %s: state before %s" % [PlayerMoves.CURVEBALLS[kind_i], p.state])
		p.moves.curveball()
		await _wait(3.2 if kind_i == 0 else 2.0)
		await _shot("12_curveball_%s" % PlayerMoves.CURVEBALLS[kind_i])
		for zz: Zombie in get_tree().get_nodes_in_group("zombies"):
			_log_z(zz, "after " + PlayerMoves.CURVEBALLS[kind_i])

	# 12. Fury: scream, claws, overhead smash.
	_clear()
	p.global_position = Vector3(0, 0.1, 0)
	z = _fresh(Vector3(0, 0.1, -1.5))
	p.fury = 1.0
	p.moves.start_fury()
	await _wait(1.6)
	_aim(z, "spine_03")
	_close_in(z, 1.3)
	_aim(z, "spine_03")
	var hp_fury := z.gore.get_health()
	await _light()
	log_lines.append("fury claw: key %s hits %d, hp %.0f -> %.0f" % [p.melee.key, p.melee.hits.size(), hp_fury, z.gore.get_health()])
	await _shot("13_fury_claws")
	_log_z(z, "fury claws")
	p.set_state("ready")
	p.moves.fury_smash()
	await _wait(1.0)
	await _shot("14_fury_smash")
	_log_z(z, "fury")
	p.moves.end_fury()
	await _wait(0.5)

	# 13. Grapple struggle.
	z = _fresh(Vector3(0, 0.1, -1.2))
	var started := p.start_grapple(z)
	await _wait(1.0)
	_log_paired(z, "grapple loop")
	await _shot("15_grapple")
	for i in 5:
		p.moves._mash()
		await _wait(0.15)
	await _wait(1.2)
	log_lines.append("grapple started=%s bar=%.2f phase=%s state=%s" % [started, p.moves.grapple_bar, p.moves.grapple_phase, p.state])
	await _wait(1.5)
	await _shot("15b_grapple_exit")
	_log_paired(z, "after grapple exit")

	# 14. Pistol: shots, headshot, reload.
	_clear()
	p.global_position = Vector3(0, 0.1, 0)
	z = _fresh(Vector3(0, 0.1, -5.0))
	p.equip("pistol", true)
	await _wait(0.5)
	for bone in ["thigh_l", "head"]:
		_aim(z, bone)
		p.ranged.shot_cd = 0.0
		p.ranged.spread = 0.0
		p.ranged.recoil = Vector2.ZERO
		p.set_state("ready")
		p.ranged.fire()
		await _wait(0.35)
	await _shot("16_pistol")
	_log_z(z, "after pistol")
	p.set_state("ready")
	p.ranged.reload()
	await _wait(2.0)
	log_lines.append("pistol mag %d reserve %d" % [p.mag, p.reserve])

	# 15. XP and level up: a real kill pays the archetype's XP, then top up to level 2 (1500 XP).
	log_lines.append("XP %d level %d" % [main.progression.xp, main.progression.level])
	z = _fresh(Vector3(0, 0.1, -1.6))
	z.gore.set_health(5.0)
	p.equip("bat", true)
	await _wait(0.4)
	_aim(z, "head")
	await _light()
	await _wait(0.3)
	log_lines.append("after kill: dead=%s XP %d" % [z.dead if is_instance_valid(z) else true, main.progression.xp])
	await _wait(1.5)
	if is_instance_valid(z):
		# Look at the body from 1.6 m.
		var pel := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone("pelvis")).origin
		log_lines.append("ragdoll pelvis %.2f m from where it died" % Vector2(pel.x, pel.z).distance_to(Vector2(0, -1.6)))
		p.global_position = Vector3(pel.x + 1.2, 0.1, pel.z + 1.0)
		var to := pel - p.camera.global_position
		p.rotation.y = atan2(-to.x, -to.z)
		p.pitch = deg_to_rad(-35)
		await _wait(0.1)
	await _shot("18_ragdoll")
	if is_instance_valid(z):
		var sk := z.skeleton
		for pair in [["head", "neck_01"], ["neck_01", "spine_03"], ["upperarm_l", "clavicle_l"], ["calf_r", "thigh_r"]]:
			var a := sk.find_bone(pair[0])
			var b := sk.find_bone(pair[1])
			var now := sk.get_bone_global_pose(a).origin.distance_to(sk.get_bone_global_pose(b).origin)
			var rest := sk.get_bone_global_rest(a).origin.distance_to(sk.get_bone_global_rest(b).origin)
			log_lines.append("ragdoll %s-%s length %.3f (rest %.3f) stretch x%.2f" % [pair[0], pair[1], now, rest, now / maxf(rest, 1e-4)])
	main.progression.add(1500 - main.progression.xp)
	p.set_level(main.progression.level)
	await _wait(0.3)
	await _shot("17_level_up")
	log_lines.append("after XP: level %d max health %.0f" % [main.progression.level, p.max_health])

	# Zombie AI scenarios (DI2 card dealer, zombie_ai.gd): own log + captures in <test_out>/zombie_ai.
	var zt: Node = load("res://scripts/autotest_zombie_ai.gd").new()
	zt.main = main
	zt.p = p
	zt.out_dir = out_dir.get_base_dir().path_join("zombie_ai")
	add_child(zt)
	await zt.run()
	log_lines.append_array(zt.summary)

	var f := FileAccess.open(out_dir.path_join("combat.log"), FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
	get_tree().quit()


# --- helpers -------------------------------------------------------------------------------------

func _clear() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()


func _subject(at: Vector3) -> Zombie:
	var z := main.spawn_zombie(at, "Walker")
	z.target = null
	z.rotation.y = PI
	z.gore.set_health(3000.0)
	return z


func _fresh(at: Vector3) -> Zombie:
	_clear()
	p.global_position = Vector3(0, 0.1, 0)
	p.rotation.y = 0.0
	p.health = p.max_health
	p.stamina = p.max_stamina
	p.set_state("ready")
	return _subject(at)


## Walk up to `dist` from the zombie (as a player would between swings).
func _close_in(z: Zombie, dist: float) -> void:
	if not is_instance_valid(z):
		return
	var flat := Vector3(z.global_position.x, p.global_position.y, z.global_position.z)
	var away := p.global_position - flat
	away.y = 0.0
	if away.length() > dist:
		p.global_position = flat + away.normalized() * dist


func _aim(z: Zombie, bone: String) -> void:
	var b := z.skeleton.find_bone(bone)
	# The final pose cached at skeleton_updated (after the SkeletonModifier3Ds); a plain get_bone_global_pose here
	# returns the pre-modifier pose (~30 cm off at the arm). Bones without a hitbox fall back to it.
	var pose: Transform3D = z._hitbox_poses[b] if z._hitbox_poses.has(b) else z.skeleton.get_bone_global_pose(b)
	var target := z.skeleton.global_transform * pose.origin
	var eye := p.camera.global_position
	var d := (target - eye).normalized()
	p.rotation.y = atan2(-d.x, -d.z)
	p.pitch = asin(clampf(d.y, -1.0, 1.0))
	p.head.rotation.x = p.pitch


func _light() -> void:
	p.lmb_held = false
	p.melee.start_light()
	var t := 0.0
	while p.melee.phase in ["antic", "attack"] and t < 2.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	await _wait(0.25)


func _heavy(charge: float) -> void:
	p.lmb_held = true
	p.lmb_t = 0.3
	await _wait(0.05)
	await _wait(p.melee._charge_time() * charge + 0.3)
	p.lmb_held = false
	p.melee.on_attack_released()
	await _wait(0.5)


func _log_z(z: Zombie, label: String) -> void:
	if not is_instance_valid(z):
		log_lines.append("%s: (gone)" % label)
		return
	var parts: Dictionary = z.gore.part_states()
	var bits := []
	for k in parts:
		if parts[k]["state"] != "intact":
			bits.append("%s=%s" % [k, parts[k]["state"]])
	var jolt := z.phys.peak
	z.phys.peak = 0.0
	log_lines.append("%s: hp=%.0f stab=%.2f dead=%s down=%s crawl=%s reaction=%s wounds=%d peak jolt=%.0fdeg %s" % [label, z.gore.get_health(), z.gore.get_stability(), z.dead, z.is_down(), z.gore.is_crawling(), z.reactions.clip, z.gore.wound_count(), rad_to_deg(jolt), " ".join(bits)])


## Paired placement: the zombie's head in camera space (should be ~0.4-0.7 m ahead, -Z) and its node vs Dani.
func _log_paired(z: Zombie, label: String) -> void:
	if not is_instance_valid(z):
		log_lines.append("%s: (gone)" % label)
		return
	var head := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone("head")).origin
	var c := p.camera.global_transform.affine_inverse() * head
	var rel := z.global_position - p.global_position
	log_lines.append("%s: zombie head in camera (%.2f, %.2f, %.2f), node offset (%.2f, %.2f) dist %.2f, reaction %s" % [label, c.x, c.y, c.z, rel.x, rel.z, Vector2(rel.x, rel.z).length(), z.reactions.clip])


## Where the first-person rig sits in camera space (hands should be ~0.2-0.6 m in front, -Z).
func _log_rig(label: String) -> void:
	var cam_inv := p.camera.global_transform.affine_inverse()
	var bits := []
	for b in ["camera_root", "hand_r", "hand_l", "weapon_01_r"]:
		var i := p.rig_skel.find_bone(b)
		if i < 0:
			bits.append("%s=missing" % b)
			continue
		var at := cam_inv * (p.rig_skel.global_transform * p.rig_skel.get_bone_global_pose(i).origin)
		bits.append("%s=(%.2f,%.2f,%.2f)" % [b, at.x, at.y, at.z])
	var meshes := 0
	var shown := 0
	for m in p.rig.find_children("*", "MeshInstance3D", true, false):
		meshes += 1
		if m.is_visible_in_tree():
			shown += 1
	log_lines.append("rig %s: anim=%s meshes %d/%d visible, %s" % [label, p.cur_clip(), shown, meshes, " ".join(bits)])


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _shot(name: String, delay := 0.0) -> void:
	if delay > 0.0:
		await _wait(delay)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	log_lines.append("shot " + name)
