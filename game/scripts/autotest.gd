extends Node
## Scripted oracle: `godot --path game -- --autotest=<out_dir>`
## Part A drives the real weapon code (aim, swing, charge, fire). Part B stages close-ups of each
## damage type with the view model hidden. Part D shows one of each DI2 body (Walker, Runner, Shambler,
## Thug) walking and losing limbs; add `--bodies-only` after the autotest arg to run just that part.
## Screenshots + an outcome log go to out_dir.

var out_dir := ""
var main: Main
var player: Player
var log_lines: PackedStringArray = []


func _ready() -> void:
	main = get_parent()
	player = main.player
	DirAccess.make_dir_recursive_absolute(out_dir)
	await get_tree().create_timer(0.5).timeout
	for z in get_tree().get_nodes_in_group("zombies"):
		z.queue_free()
	await get_tree().process_frame
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation.y = 0.0
	if "--bodies-only" in OS.get_cmdline_user_args():
		await _bodies()
		_write_log()
		get_tree().quit()
		return
	if "--severing-only" in OS.get_cmdline_user_args():
		await _severing()
		await _moving_hits()
		_write_log()
		get_tree().quit()
		return

	# --- A: weapons through the player code -------------------------------------------------------
	var z := _subject(Vector3(0, 0.1, -1.7), PI)
	await _settle(0.6)
	player.equip("machete")
	await _settle(0.6)
	_aim_at(z, "spine_03")
	await _shot("a00_machete_ready")
	player.lmb_t = 0.0
	player.melee.start_light()
	await _settle(0.45)
	await _shot("a01_machete_swing")
	await _settle(1.4)
	# Swing at the right forearm until it comes off (the first swing may land on the other arm).
	for swing in 4:
		if z.gore.part_states()["arm_right"]["state"] == "severed":
			break
		while player.state != "ready":
			await _settle(0.1)
		player.stamina = 100.0
		_aim_at(z, "lowerarm_r")
		player.melee.start_light()
		await _settle(1.2)
	await _settle(0.8)
	_log_parts(z, "after machete swings")
	_log_caps(z, "after machete")
	_aim_at(z, "spine_01")
	await _shot("a02_after_machete")

	player.equip("bat")
	await _settle(0.6)
	_aim_at(z, "upperarm_l")
	player.melee._start_charge()
	player.melee.charge = 1.0
	player.melee._release_heavy()
	await _settle(1.6)
	_log_parts(z, "after bat heavy")
	await _shot("a03_after_bat_heavy")

	while player.state != "ready":
		await _settle(0.1)
	player.equip("pistol")
	await _settle(0.6)
	for bone in ["thigh_l", "thigh_l", "calf_r"]:
		_aim_at(z, bone)
		await _settle(0.05)
		player.ranged.shot_cd = 0.0
		player.ranged.spread = 0.0
		player.ranged.recoil = Vector2.ZERO
		player.set_state("ready")
		player.ranged.fire()
		await _settle(0.3)
	_log_parts(z, "after pistol")
	await _settle(1.2)
	await _shot("a04_after_pistol")
	log_lines.append("pistol mag %d reserve %d" % [player.mag, player.reserve])

	# --- B: close-ups of every wound channel -------------------------------------------------------
	for n in get_tree().get_nodes_in_group("zombies"):
		n.queue_free()
	player.rig.visible = false
	player.global_position = Vector3(0, 0.1, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.pitch = deg_to_rad(-12)
	var c := _subject(Vector3(0, 0.1, -1.35), PI)
	await _settle(0.8)
	await _shot("b00_closeup_clean")
	await _hit(c, "spine_03", "sharp", 30.0, Vector3.RIGHT)
	await _hit(c, "spine_03", "sharp", 30.0, Vector3.RIGHT)
	await _hit(c, "upperarm_l", "blunt", 22.0, Vector3.LEFT)
	await _hit(c, "head", "blunt", 18.0, Vector3.LEFT)
	await _settle(0.8)
	await _shot("b01_cuts_bruises")
	await _hit(c, "spine_01", "acid", 20.0, Vector3.FORWARD)
	await _hit(c, "thigh_r", "fire", 20.0, Vector3.FORWARD)
	await _hit(c, "upperarm_r", "electric", 20.0, Vector3.FORWARD)
	await _settle(2.5)
	await _shot("b02_acid_fire_shock")
	await _severing(c)
	await _moving_hits()

	# --- C: live AI - zombies chase and attack Dani; she blocks part of the time ----------------------
	for n in get_tree().get_nodes_in_group("zombies"):
		n.queue_free()
	player.rig.visible = true
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation.y = 0.0
	player.pitch = deg_to_rad(-5)
	player.health = player.max_health
	player.equip("bat", true)
	for i in 3:
		var zz := main.spawn_zombie(Vector3(-1.2 + i * 1.2, 0.1, -3.5), "Walker")
		zz.target = player
	await _settle(4.0)
	await _shot("c00_horde_closing")
	# Each window starts at full health: two Walkers at DI2's attack cadence take ~70 HP in 3 s, and a
	# dead Dani would make the blocking window measure nothing.
	player.health = player.max_health
	var hp_before := player.health
	await _settle(3.0)
	log_lines.append("unblocked: health %.0f -> %.0f" % [hp_before, player.health])
	player.dead = false
	player.health = player.max_health
	Input.action_press("block")
	await _settle(0.3)
	var hp_block := player.health
	var st_block := player.stamina
	await _settle(3.0)
	Input.action_release("block")
	log_lines.append("blocking: health %.0f -> %.0f, stamina %.0f -> %.0f" % [hp_block, player.health, st_block, player.stamina])
	await _shot("c01_blocking")

	# --- D: one of each DI2 body --------------------------------------------------------------------
	await _bodies()

	_write_log()
	get_tree().quit()


## Walker, Runner, Shambler and Thug side by side, then each one close up: its own walk clip, an arm
## cut off, then a leg (DI2's rules decide whether it crawls on or dies).
func _bodies() -> void:
	await _clear_arena()
	if player.dead:
		player.respawn()
	player.rig.visible = false
	player.global_position = Vector3(0, 0.1, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.pitch = deg_to_rad(-8)
	var types := ["Walker", "Runner", "Shambler", "Thug"]
	var lineup: Array[Zombie] = []
	for i in types.size():
		lineup.append(_subject(Vector3(-2.4 + i * 1.6, 0.1, -4.6), PI, types[i]))
	await _settle(1.2)
	for z in lineup:
		log_lines.append("%s: body=%s scale=%.2f bones=%d clips=%d meshes=%d" % [z.archetype, z.body, z.body_scale,
			z.skeleton.get_bone_count(), z.anim.get_animation_list().size(), Util.find_all(z.visual, "MeshInstance3D").size()])
	await _body_shot("d00_bodies_lineup")

	var data: Array = Util.load_json("res://data/archetypes.json")
	for i in types.size():
		await _clear_arena()
		var z := _subject(Vector3(0, 0.1, -2.9), PI, types[i])
		z._play_once("walk", 5.0)
		await _settle(0.9)
		var loco: Dictionary = data.filter(func(a): return a["name"] == types[i])[0]["locomotion"]
		log_lines.append("%s walk clip %.2f m/s, archetype walk/chase %.2f/%.2f m/s" % [types[i], z.clip_speed.get("walk", 0.0),
			loco["walk_speed"], loco["chase_speed"]])
		await _body_shot("d%d1_%s_walk" % [i + 1, types[i].to_lower()])
		z.lock_time = 0.0
		# A medium blunt hit from the front: DI2's shared Base reaction clips, played on this body.
		await _hit(z, "spine_03", "blunt", 25.0, Vector3.FORWARD)
		await _settle(0.35)
		log_lines.append("%s reaction: %s" % [types[i], z.anim.current_animation])
		await _body_shot("d%d4_%s_reaction" % [i + 1, types[i].to_lower()])
		await _settle(1.5)
		await _hit(z, "lowerarm_l", "sharp", 400.0, Vector3.RIGHT)
		await _settle(1.0)
		await _body_shot("d%d2_%s_arm_cut" % [i + 1, types[i].to_lower()])
		# A fresh one loses a leg: Walkers and Runners crawl on, Shamblers and Thugs die of it (DI2 data).
		await _clear_arena()
		z = _subject(Vector3(0, 0.1, -4.0), PI, types[i])
		await _settle(0.5)
		await _hit(z, "calf_r", "sharp", 400.0, Vector3.RIGHT)
		await _settle(3.5)
		_log_parts(z, types[i] + " after leg cut")
		log_lines.append("%s: dead=%s anim=%s" % [types[i], z.dead, z.anim.current_animation])
		await _body_shot("d%d3_%s_leg_cut" % [i + 1, types[i].to_lower()])

	# Live AI: one of each closes in on Dani at its own measured speed and attacks with its own clips.
	await _clear_arena()
	player.rig.visible = true
	player.health = player.max_health
	player.pitch = deg_to_rad(-4)
	var racers: Array[Zombie] = []
	for i in types.size():
		var z := main.spawn_zombie(Vector3(-2.7 + i * 1.8, 0.1, -9.0), types[i])
		z.rotation.y = 0.0
		racers.append(z)
	await _settle(2.2)
	await _body_shot("d51_live_chase")
	for z in racers:
		log_lines.append("%s live: %.1f m away, anim %s x%.2f" % [z.archetype, z.global_position.distance_to(player.global_position),
			z.anim.current_animation, z.anim.speed_scale])
	await _settle(3.0)
	await _body_shot("d52_live_attack")
	for z in racers:
		log_lines.append("%s live: %.1f m away, anim %s" % [z.archetype, z.global_position.distance_to(player.global_position), z.anim.current_animation])
	log_lines.append("Dani health after the mixed horde: %.0f" % player.health)


## Part D screenshots go to <out_dir>/bodies/.
func _body_shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("bodies"))
	await _shot("bodies/" + name)


## Severing close-ups: a leg comes off (a Walker crawls on), then an arm (which kills it). Each shot frames
## the capped stump together with the capped piece that flew off.
func _severing(c: Zombie = null) -> void:
	if c == null:
		await _clear_arena()
		player.rig.visible = false
		player.global_position = Vector3(0, 0.1, 0)
		player.velocity = Vector3.ZERO
		player.rotation.y = 0.0
		player.pitch = deg_to_rad(-12)
		c = _subject(Vector3(0, 0.1, -1.35), PI)
		await _settle(0.8)
	var home := player.global_position
	await _hit(c, "calf_l", "sharp", 80.0, Vector3.RIGHT)
	await _settle(2.5)
	_log_parts(c, "after leg cut")
	_log_caps(c, "after leg cut")
	var eye := player.head.position.y
	_frame_cut(c, "thigh_l", "calf_l")
	await _shot("b03_severed_crawler")
	player.head.position.y = eye
	# Straight-on close-ups of the leg's two caps: the hip stump and the top of the severed thigh.
	await _cap_shot(c.skeleton, "thigh_l", "calf_l", 1.0, "b04_cap_stump")
	var leg := _pieces().filter(func(p): return Util.find_first(p, "Skeleton3D").get_children().any(func(n): return n.name == "Cap_thigh_l"))
	if not leg.is_empty():
		await _cap_shot(Util.find_first(leg[0], "Skeleton3D"), "thigh_l", "calf_l", -1.0, "b05_cap_piece")
	player.global_position = home
	_aim_at(c, "lowerarm_l")
	await _hit(c, "lowerarm_l", "sharp", 80.0, Vector3.RIGHT)
	await _settle(2.5)
	_log_caps(c, "after arm cut")
	_frame_cut(c, "upperarm_l", "lowerarm_l")
	await _shot("b06_severed_arm")
	player.head.position.y = eye


## Hits on a walking zombie land where they hit. GoreBody refines each hitbox impact against the posed
## mesh, so the damaged bone is the one under the impact and its wound sits on that spot of the moving body
## (two walk phases are shot to show the wounds travel with it). A sharp hit mid-forearm cuts the forearm
## there, at DI2's nearest cut position, not at the elbow.
func _moving_hits() -> void:
	await _clear_arena()
	player.rig.visible = false
	player.global_position = Vector3(0, 0.1, 0)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.pitch = deg_to_rad(-10)
	player.head.rotation.x = player.pitch
	var z := _subject(Vector3(0, 0.1, -1.6), PI)
	z._play_once("walk", 30.0)
	await _settle(0.7)
	for spec in [["head", "blunt", 0.6], ["spine_03", "sharp", 0.5], ["upperarm_r", "blunt", 0.5],
			["lowerarm_l", "sharp", 0.5], ["thigh_r", "sharp", 0.5], ["calf_l", "blunt", 0.5]]:
		await _exact_hit(z, spec[0], spec[1], 14.0, spec[2])
	await _settle(0.3)
	await _shot("e00_walking_hits")
	await _settle(0.55)
	await _shot("e01_walking_hits_later")
	await _exact_hit(z, "lowerarm_r", "sharp", 200.0, 0.55)
	log_lines.append("forearm cut at %.2f of lowerarm_r (DI2 LowerArmR1-3: 0.22 / 0.57 / 0.89)" % z.gore.cut_fraction("lowerarm_r"))
	_log_caps(z, "after forearm cut")
	await _settle(1.0)
	await _cap_shot(z.skeleton, "lowerarm_r", "hand_r", 1.0, "e02_forearm_cut_stump")


## Like a weapon hit, aimed at a point `along` the bone's hitbox segment of the zombie as it is posed now.
## Logs the bone aimed at, the hitbox the ray met and the bone GoreBody found under the impact.
func _exact_hit(z: Zombie, bone: String, kind: String, dmg: float, along: float) -> void:
	var b := z.skeleton.find_bone(bone)
	var spec: Array = Zombie.HITBOXES[bone]
	var target_p := _bone_pos(z, bone)
	if spec[0] != "":
		target_p = target_p.lerp(_bone_pos(z, spec[0]), along)
	else:
		var up := target_p - _bone_pos(z, z.skeleton.get_bone_name(z.skeleton.get_bone_parent(b)))
		target_p += up.normalized() * float(spec[2]) * along
	var eye := player.camera.global_position
	var ray := (target_p - eye).normalized()
	Zombie.sync_hitboxes()
	var q := PhysicsRayQueryParameters3D.create(eye, eye + ray * 4.0, Util.HITBOX)
	q.collide_with_areas = true
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		log_lines.append("%s: aimed ray missed every hitbox" % bone)
		return
	var hitbox: String = hit["collider"].get_meta("bone")
	var res := z.take_hit(hitbox, hit["position"], Vector3.RIGHT, ray, dmg, kind, false, 1.0, 0.0)
	var on_ray: Vector3 = res.get("point", hit["position"])
	var miss := (on_ray - eye).cross(ray).length()
	log_lines.append("%s %s: hitbox %s -> exact %s (%s), impact %.1f cm from the aimed ray, %.0f cm in front of the aim point -> %s" % [
		bone, kind, hitbox, res.get("bone", "?"), "mesh" if res.get("exact", false) else "hitbox fallback", miss * 100.0,
		(target_p - on_ray).dot(ray) * 100.0, JSON.stringify(res.get("outcomes", []).map(func(o): return o["type"]))])
	await get_tree().create_timer(0.15).timeout


## Severed pieces lying in the arena (rigid bodies carrying a copy of a zombie skeleton).
func _pieces() -> Array:
	return main.get_children().filter(func(n): return n is RigidBody3D and Util.find_first(n, "Skeleton3D") != null)


func _log_caps(z: Zombie, label: String) -> void:
	var body_caps := z.skeleton.get_children().filter(func(n): return n.name.begins_with("Cap_")).size()
	var piece_caps := 0
	for p in _pieces():
		piece_caps += Util.find_first(p, "Skeleton3D").get_children().filter(func(n): return n.name.begins_with("Cap_")).size()
	log_lines.append("%s: cut caps on body %d, on pieces %d (%d pieces)" % [label, body_caps, piece_caps, _pieces().size()])


## Puts the camera low and about a metre out along the cut bone's axis (where the stump faces), looking at
## the stump with the nearest severed piece pulled into view. `_severing` restores the eye height.
func _frame_cut(z: Zombie, bone: String, child: String, eye := 0.8) -> void:
	var stump := _bone_pos(z, bone)
	var axis := _bone_pos(z, child) - stump
	var flat := Vector3(axis.x, 0.0, axis.z)
	flat = flat.normalized() if flat.length() > 0.05 else Vector3.BACK
	var focus := stump
	var nearest := INF
	for p: RigidBody3D in _pieces():
		var d := p.global_position.distance_to(stump)
		if d < nearest and d < 1.8:
			nearest = d
			focus = stump.lerp(p.global_position, 0.35)
			flat = flat.slerp(Vector3(p.global_position.x - stump.x, 0.0, p.global_position.z - stump.z).normalized(), 0.3)
	player.velocity = Vector3.ZERO
	player.head.position.y = eye
	player.global_position = Vector3(stump.x, 0.1, stump.z) + flat * 1.05
	var d := (focus - player.camera.global_position).normalized()
	player.rotation.y = atan2(-d.x, -d.z)
	player.pitch = asin(clamp(d.y, -1.0, 1.0))
	player.head.rotation.x = player.pitch


## Shot from a free camera 0.4 m in front of the cap at `bone`: `facing` +1 for the body's cap (faces
## down the limb), -1 for the piece's cap (faces back up it).
func _cap_shot(skel: Skeleton3D, bone: String, child: String, facing: float, name: String) -> void:
	var at := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(bone)).origin
	var tip := skel.global_transform * skel.get_bone_global_pose(skel.find_bone(child)).origin
	var eye := at + (tip - at).normalized() * facing * 0.4 + Vector3.UP * 0.12
	eye.y = maxf(eye.y, 0.25)
	var cam := Camera3D.new()
	cam.near = 0.02
	cam.fov = 50.0
	main.add_child(cam)
	cam.global_position = eye
	cam.look_at(at, Vector3.UP if absf((at - eye).normalized().y) < 0.98 else Vector3.FORWARD)
	cam.current = true
	await _shot(name)
	cam.queue_free()
	player.camera.current = true


func _bone_pos(z: Zombie, bone: String) -> Vector3:
	return z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone(bone)).origin


## Removes zombies, ragdolls and severed pieces so the next shot starts clean.
func _clear_arena() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.queue_free()
	for n in main.get_children():
		if n is RigidBody3D:
			n.queue_free()
	await get_tree().process_frame


func _subject(at: Vector3, yaw: float, archetype := "Walker") -> Zombie:
	var z := main.spawn_zombie(at, archetype)
	z.target = null
	z.rotation.y = yaw
	z.gore.set_health(5000.0)
	return z


func _aim_at(z: Zombie, bone: String) -> void:
	var b := z.skeleton.find_bone(bone)
	var p := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var eye := player.camera.global_position
	var d := (p - eye).normalized()
	player.rotation.y = atan2(-d.x, -d.z)
	player.pitch = asin(clamp(d.y, -1.0, 1.0))
	player.head.rotation.x = player.pitch


func _hit(z: Zombie, bone: String, kind: String, dmg: float, dir: Vector3) -> void:
	# Like a weapon: ray from the eye to the bone, impact on the hitbox surface.
	var b := z.skeleton.find_bone(bone)
	var target_p := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var eye := player.camera.global_position
	Zombie.sync_hitboxes()
	var q := PhysicsRayQueryParameters3D.create(eye, eye + (target_p - eye) * 1.5, Util.HITBOX)
	q.collide_with_areas = true
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	var p: Vector3 = hit["position"] if hit else target_p
	var hit_bone: String = hit["collider"].get_meta("bone") if hit else bone
	var res := z.take_hit(hit_bone, p, dir, (target_p - eye).normalized(), dmg, kind, false, 1.0, 0.0)
	if AccumulatingEffects.TYPE_FOR_KIND.has(kind):
		# An elemental hit's status: fill the meter (DI2 bApplyMaxValue) so the status begins.
		z.accumulate([{"type": AccumulatingEffects.TYPE_FOR_KIND[kind], "value": 1.0, "apply_max": true}], z.level, false, p, hit_bone)
	log_lines.append("%s(%s) %s dmg=%.0f -> %s" % [bone, hit_bone, kind, dmg, JSON.stringify(res.get("outcomes", []))])
	await get_tree().create_timer(0.2).timeout


func _log_parts(z: Zombie, label: String) -> void:
	var parts: Dictionary = z.gore.part_states()
	var bits := []
	for k in parts:
		bits.append("%s=%s(%.0f)" % [k, parts[k]["state"], parts[k]["health"]])
	log_lines.append("%s: hp=%.0f crawling=%s %s" % [label, z.gore.get_health(), z.gore.is_crawling(), " ".join(bits)])


func _settle(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	log_lines.append("shot " + name)


func _write_log() -> void:
	var f := FileAccess.open(out_dir.path_join("autotest.log"), FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
