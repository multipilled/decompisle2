extends Node
## Frame-exact animation captures for the animation-quality work (recon/ANIMATION.md).
## Run through autotest_combat.gd:  --combattest=<dir> --animcap[=scenario,scenario...]
## with RUN_TEST_ENGINE_ARGS="--fixed-fps 60" so every frame advances exactly 1/60 s of game time.
## Per scenario it writes <dir>/anim/<scenario>.jsonl (one record per frame: the visible pose of the watched
## bones, after skeleton modifiers, plus the playing clip / state) and a frame strip <dir>/strips/<scenario>/.
## tools/anim_report.py turns those into pop / slide / blend metrics and contact sheets.

const P_BONES := ["camera_root", "hand_r", "hand_l", "lowerarm_r", "lowerarm_l", "weapon_01_r", "weapon_01_l"]
const Z_BONES := ["pelvis", "spine_03", "head", "hand_l", "hand_r", "foot_l", "foot_r", "ball_l", "ball_r"]
## Face bones recorded in head space for z_face (local look of the face, independent of the body).
const F_BONES := ["lowerJaw", "eye_l", "eye_r", "uplid_01_l", "lowlid_01_l", "upLip_01", "lowLip_01", "mouth_l", "brow_01_l"]

var out_dir := ""
var main: Main
var p: Player
var only: PackedStringArray = []
var scenario := ""
var rec: Array = []
var strip_every := 1
var strip_dir := ""
var strip_n := 0
var watch: Array = []            # zombies whose pose is recorded
var cam3p: Camera3D
var t0 := 0
var notes: PackedStringArray = []


func run() -> void:
	main.hud.visible = false
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	get_tree().process_frame.connect(_on_frame)
	cam3p = Camera3D.new()
	cam3p.fov = 50.0
	main.add_child(cam3p)
	for mi: MeshInstance3D in p.rig.find_children("*", "MeshInstance3D", true, false):
		var cam_aabb := p.camera.global_transform.affine_inverse() * mi.get_global_transform() * mi.get_aabb()
		notes.append("mesh %s visible %s in_tree %s layers %d cast %d skin %s skel %s surfaces %d aabb(cam) %s cull %d" % [mi.name, mi.visible,
			mi.is_visible_in_tree(), mi.layers, mi.cast_shadow, mi.skin != null, mi.skeleton, mi.mesh.get_surface_count() if mi.mesh else -1,
			cam_aabb, p.camera.cull_mask])
	var c := p.cls("bat")
	notes.append("rig: %d clips, bases %s, class %s glb %s exists %s, idle '%s' has %s, current '%s' playing %s" % [
		p.rig_anim.get_animation_list().size(), p.loaded_bases.keys(), c.id if c else "-", c.glb if c else "-",
		ResourceLoader.exists(c.glb) if c else false, c.clip("UpperBodyIdle") if c else "", p.has_clip(c.clip("UpperBodyIdle")) if c else false,
		p.cur_clip(), p.anim.state_key()])
	var all := ["p_locomotion", "p_light_chain", "p_heavy", "p_block_kick_dodge", "p_switch_pistol", "p_pistol_ads",
		"z_walk_chase", "z_turn", "z_hits", "z_knockdown", "z_launch", "z_ko", "z_death_ko", "z_runner", "z_death", "z_face", "z_perf", "z_rootmotion", "z_loco", "z_windup",
		"z_attack_rm", "z_strafe", "z_specials_walk"]
	for s: String in all:
		if not only.is_empty() and s not in only:
			continue
		match s:
			"p_locomotion": await _p_locomotion()
			"p_light_chain": await _p_light_chain()
			"p_heavy": await _p_heavy()
			"p_block_kick_dodge": await _p_block_kick_dodge()
			"p_switch_pistol": await _p_switch_pistol()
			"p_pistol_ads": await _p_pistol_ads()
			"z_walk_chase": await _z_walk_chase()
			"z_turn": await _z_turn()
			"z_hits": await _z_hits()
			"z_knockdown": await _z_knockdown()
			"z_launch": await _z_launch()
			"z_ko": await _z_ko()
			"z_death_ko": await _z_death_ko()
			"z_runner": await _z_runner()
			"z_death": await _z_death()
			"z_face": await _z_face()
			"z_perf": await _z_perf()
			"z_rootmotion": await _z_rootmotion()
			"z_loco": await _z_loco()
			"z_windup": await _z_windup()
			"z_attack_rm": await _z_attack_rm()
			"z_strafe": await _z_strafe()
			"z_specials_walk": await _z_specials_walk()
		_end()
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("anim"))
	var f := FileAccess.open(out_dir.path_join("anim/capture.log"), FileAccess.WRITE)
	f.store_string("\n".join(notes))


# --- recording ---------------------------------------------------------------------------------------------

func _begin(name: String, every := 1) -> void:
	scenario = name
	rec = []
	strip_every = every
	strip_dir = out_dir.path_join("strips").path_join(name)
	DirAccess.make_dir_recursive_absolute(strip_dir)
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("anim"))
	strip_n = 0
	t0 = Engine.get_process_frames()
	notes.append("== %s" % name)


func _end() -> void:
	if scenario == "":
		return
	var f := FileAccess.open(out_dir.path_join("anim").path_join(scenario + ".jsonl"), FileAccess.WRITE)
	for r in rec:
		f.store_line(JSON.stringify(r))
	notes.append("%s: %d frames" % [scenario, rec.size()])
	scenario = ""
	watch = []


func mark(label: String) -> void:
	if scenario != "":
		notes.append("  f%d %s" % [Engine.get_process_frames() - t0, label])
		if not rec.is_empty():
			rec[-1]["mark"] = label


## State at the start of each frame = the pose the previous frame drew (animation, modifiers and nodes updated).
func _on_frame() -> void:
	if scenario == "":
		return
	var r := {"f": Engine.get_process_frames() - t0, "dt": get_process_delta_time()}
	var cam_inv := p.camera.global_transform.affine_inverse()
	var pb := {}
	for b: String in P_BONES:
		var i := p.rig_skel.find_bone(b)
		if i < 0:
			continue
		var g := p.rig_skel.global_transform * p.rig_skel.get_bone_global_pose(i)
		var c := cam_inv * g
		var q := c.basis.get_rotation_quaternion()
		pb[b] = [c.origin.x, c.origin.y, c.origin.z, q.x, q.y, q.z, q.w]
	r["p"] = pb
	r["p_anim"] = p.cur_clip()
	var am := p.anim.active()
	r["p_pos"] = am.pos if am else 0.0
	r["p_mon"] = p.anim.slot.map(func(m): return [m.name, snappedf(m.pos, 0.001), snappedf(m.weight.value, 0.001), m.stopped])
	r["p_base"] = p.anim.states.map(func(e): return [e["key"], snappedf(e["alpha"].value, 0.001)])
	r["p_state"] = p.state
	r["p_phase"] = p.melee.phase
	r["p_vel"] = Vector2(p.velocity.x, p.velocity.z).length()
	r["p_usec"] = p.anim.last_usec
	var cq := p.camera.global_basis.get_rotation_quaternion()
	r["cam"] = [p.camera.global_position.x, p.camera.global_position.y, p.camera.global_position.z, cq.x, cq.y, cq.z, cq.w]
	var zs := []
	for z: Zombie in watch:
		if not is_instance_valid(z):
			zs.append({})
			continue
		var zb := {}
		var sk := z.skeleton
		# A ragdoll draws its bodies' pose; the skeleton's bone poses keep the animation's (ZombieReactions).
		var rp: Array = z.reactions.ragdoll_world_pose() if z.ragdoll != null and z.ragdoll.active else []
		for b: String in Z_BONES:
			var i := sk.find_bone(b)
			if i < 0:
				continue
			var g: Transform3D = rp[i] if not rp.is_empty() else sk.global_transform * sk.get_bone_global_pose(i)
			var q := g.basis.get_rotation_quaternion()
			zb[b] = [g.origin.x, g.origin.y, g.origin.z, q.x, q.y, q.z, q.w]
		zs.append({"b": zb, "node": [z.global_position.x, z.global_position.y, z.global_position.z, z.rotation.y],
			"anim": z.anim_ctl.cur_clip() if not z.dead else "", "apos": (z.anim_ctl.a.active().pos if z.anim_ctl.a.active() else 0.0) if not z.dead else 0.0,
			"speed_scale": 1.0, "react": z.reactions.state, "clip": z.reactions.clip, "dead": z.dead,
			"mon": z.anim_ctl.a.slot.map(func(m): return [m.name, snappedf(m.pos, 0.001), snappedf(m.weight.value, 0.001), m.stopped]),
			"base": z.anim_ctl.a.states.map(func(e): return [e["key"], snappedf(e["alpha"].value, 0.001)]),
			"bs": (Array(z.anim_ctl.a.state_src().weights).map(func(v): return snappedf(v, 0.01)) + [z.anim_ctl.a.state_src().x]) if z.anim_ctl.a.state_src() is DI2Anim.BS else [],
			"vel": Vector2(z.velocity.x, z.velocity.z).length(),
			"wu": [snappedf(z.anim_ctl.wu_amount, 0.001), z.anim_ctl.wu_state, z.anim_ctl.wu_last]})
		if scenario == "z_face" and not z.dead:
			var hb := sk.find_bone("head")
			var hinv := sk.get_bone_global_pose(hb).affine_inverse()
			var fb := {}
			for b: String in F_BONES:
				var i := sk.find_bone(b)
				if i >= 0:
					var g := hinv * sk.get_bone_global_pose(i)
					var q := g.basis.get_rotation_quaternion()
					fb[b] = [g.origin.x, g.origin.y, g.origin.z, q.x, q.y, q.z, q.w]
			zs[-1]["fb"] = fb
			var fl: ZombieAnim.FaceLayer = z.anim_ctl.face
			if fl:
				zs[-1]["face"] = {"w": snappedf(fl.w_facial, 0.001), "combat": fl.combat_state, "db": fl.mouth_db,
					"usec": z.anim_ctl.a.last_usec,
					"states": fl.states.map(func(e): return [e["name"], e["clip"].trim_prefix("face:"), snappedf(e["time"], 0.001), snappedf(e["alpha"].value, 0.001)]),
					"bs": Array(fl.bs_w).map(func(v): return snappedf(v, 0.001))}
	r["z"] = zs
	rec.append(r)


func _on_post_draw() -> void:
	if scenario == "" or strip_every <= 0:
		return
	var f := Engine.get_process_frames() - t0
	if f % strip_every != 0:
		return
	var img := get_viewport().get_texture().get_image()
	img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
	img.save_png(strip_dir.path_join("f%04d.png" % f))
	strip_n += 1


# --- helpers ---------------------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _secs(s: float) -> void:
	await _frames(roundi(s * 60.0))


func _act(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _clear() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()


func _reset_player(at := Vector3(0, 0.1, 0), yaw := 0.0) -> void:
	for a in ["move_forward", "move_back", "move_left", "move_right", "sprint", "attack", "block", "kick"]:
		Input.action_release(a)
	p.global_position = at
	p.rotation.y = yaw
	p.pitch = 0.0
	p.velocity = Vector3.ZERO
	p.health = p.max_health
	p.stamina = p.max_stamina
	p.melee.reset()
	p.set_state("ready")
	p.camera.current = true


func _subject(at: Vector3, archetype := "Walker", passive := true) -> Zombie:
	var z := main.spawn_zombie(at, archetype)
	if passive:
		z.target = null
	z.rotation.y = 0.0
	z.gore.set_health(3000.0)
	return z


func _aim_at(z: Zombie, bone: String) -> void:
	var b := z.skeleton.find_bone(bone)
	var target := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var d := (target - p.camera.global_position).normalized()
	p.rotation.y = atan2(-d.x, -d.z)
	p.pitch = asin(clampf(d.y, -1.0, 1.0))


## Third-person view of a zombie from the side (for zombie strips).
func _frame_zombie(z: Zombie, side := Vector3(3.2, 1.3, 0.0)) -> void:
	cam3p.current = true
	cam3p.global_position = z.global_position + side
	cam3p.look_at(z.global_position + Vector3.UP * 0.9)


func _follow(z: Zombie, side: Vector3, frames: int) -> void:
	for i in frames:
		if is_instance_valid(z):
			cam3p.global_position = z.global_position + side
			cam3p.look_at(z.global_position + Vector3.UP * 0.9)
		await get_tree().process_frame


# --- player scenarios ---------------------------------------------------------------------------------------

## Idle -> walk -> sprint -> walk -> stop with the bat (UpperBody state machine transitions + blend space).
func _p_locomotion() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 10), 0.0)
	p.equip("bat", true)
	await _secs(1.0)
	_begin("p_locomotion", 2)
	await _secs(0.5)
	mark("walk")
	_act("move_forward", true)
	await _secs(1.5)
	mark("sprint")
	_act("sprint", true)
	await _secs(1.5)
	mark("sprint off")
	_act("sprint", false)
	await _secs(1.0)
	mark("stop")
	_act("move_forward", false)
	await _secs(1.5)


## Three chained light swings on a Walker, then the recovery back to idle.
func _p_light_chain() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	var z := _subject(Vector3(0, 0.1, -1.6))
	z.rotation.y = 0.0
	await _secs(0.8)
	_aim_at(z, "spine_03")
	_begin("p_light_chain", 1)
	await _secs(0.2)
	for i in 3:
		mark("press %d" % i)
		_act("attack", true)
		await _frames(3)
		_act("attack", false)
		# Press again inside the recovery like a player chaining swings.
		var n := 0
		while p.melee.phase in ["antic", "attack"] and n < 120:
			await get_tree().process_frame
			n += 1
		await _secs(0.15)
	mark("idle")
	await _secs(2.0)


func _p_heavy() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	var z := _subject(Vector3(0, 0.1, -1.7))
	await _secs(0.8)
	_aim_at(z, "spine_03")
	_begin("p_heavy", 1)
	await _secs(0.2)
	mark("hold")
	_act("attack", true)
	await _secs(1.6)
	mark("release")
	_act("attack", false)
	await _secs(2.2)


func _p_block_kick_dodge() -> void:
	_clear()
	_reset_player()
	p.equip("machete", true)
	var z := _subject(Vector3(0, 0.1, -1.8))
	await _secs(0.8)
	_aim_at(z, "spine_03")
	_begin("p_block_kick_dodge", 2)
	await _secs(0.3)
	mark("block")
	_act("block", true)
	await _secs(1.0)
	_act("block", false)
	mark("unblock")
	await _secs(0.8)
	mark("kick")
	_act("kick", true)
	await _frames(2)
	_act("kick", false)
	await _secs(1.4)
	mark("dodge")
	_act("move_left", true)
	await _frames(1)
	_act("dodge", true)
	await _frames(2)
	_act("dodge", false)
	_act("move_left", false)
	await _secs(1.5)


func _p_switch_pistol() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	await _secs(1.0)
	_begin("p_switch_pistol", 2)
	await _secs(0.3)
	mark("to machete")
	p.equip("machete")
	await _secs(1.2)
	mark("to pistol")
	p.equip("pistol")
	await _secs(1.2)
	for i in 3:
		mark("shoot %d" % i)
		_act("attack", true)
		await _frames(2)
		_act("attack", false)
		await _secs(0.4)
	mark("reload")
	p.ranged.reload()
	await _secs(2.5)


## Pistol: aim down sights, walk while aiming (AdditiveArmLocomotion), three ADS shots (AdditiveArmsCustomState).
func _p_pistol_ads() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 6), 0.0)
	p.equip("pistol", true)
	await _secs(1.0)
	_begin("p_pistol_ads", 2)
	await _secs(0.3)
	mark("aim")
	_act("block", true)
	await _secs(0.8)
	mark("walk aiming")
	_act("move_forward", true)
	await _secs(1.2)
	for i in 3:
		mark("ads shot %d" % i)
		_act("attack", true)
		await _frames(2)
		_act("attack", false)
		await _secs(0.4)
	_act("move_forward", false)
	await _secs(0.6)
	mark("release aim")
	_act("block", false)
	await _secs(1.0)


# --- zombie scenarios ---------------------------------------------------------------------------------------

## A Walker walks/chases Dani from 9 m and attacks.
func _z_walk_chase() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 0), 0.0)
	var z := _subject(Vector3(0, 0.1, -9.0), "Walker", false)
	z.rotation.y = 0.0
	watch = [z]
	_begin("z_walk_chase", 2)
	await _follow(z, Vector3(3.0, 1.2, 0.5), 60 * 7)


## A Walker in reach of Dani attacks: the locomotion-layer wind-up (AnimInterest_Melee) before each swipe.
func _z_windup() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 0), 0.0)
	var z := _subject(Vector3(0, 0.1, -1.6), "Walker", false)
	z.rotation.y = 0.0
	watch = [z]
	_frame_zombie(z, Vector3(2.8, 1.3, 0.6))
	_begin("z_windup", 1)
	await _secs(6.0)


## Dani circles the Walker: turning on the spot and while walking.
func _z_turn() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, -3.0), PI)
	var z := _subject(Vector3(0, 0.1, -6.0), "Walker", false)
	z.rotation.y = 0.0
	watch = [z]
	_frame_zombie(z, Vector3(0.0, 2.2, 4.0))
	_begin("z_turn", 2)
	await _secs(1.0)
	for k in 6:
		var a := PI * 0.5 * (k + 1)
		var at := z.global_position + Vector3(sin(a), 0, cos(a)) * 3.0
		p.global_position = Vector3(at.x, 0.1, at.z)
		mark("dani at %d deg" % roundi(rad_to_deg(a)))
		await _secs(1.0)


## Light / medium / heavy hits on a standing Walker (reactions, physical impacts, blends).
func _z_hits() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	var z := _subject(Vector3(0, 0.1, -1.7))
	z.rotation.y = 0.0
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(2.8, 1.3, 0.6))
	_begin("z_hits", 1)
	await _secs(0.3)
	var hits := [["spine_03", 8.0, 10.0], ["head", 8.0, 15.0], ["upperarm_l", 10.0, 25.0], ["spine_03", 10.0, 40.0]]
	for h in hits:
		mark("hit %s force %d" % [h[0], h[2]])
		var b := z.skeleton.find_bone(h[0])
		var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
		var dir := (pt - p.camera.global_position).normalized()
		z.take_hit(h[0], pt, p.camera.global_basis.x, dir, h[1], "blunt", false, 1.0, h[2], dir, p)
		await _secs(1.4)


func _z_knockdown() -> void:
	_clear()
	_reset_player()
	var z := _subject(Vector3(0, 0.1, -1.7))
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(3.5, 1.5, 0.0))
	_begin("z_knockdown", 2)
	await _secs(0.3)
	mark("knockdown")
	var b := z.skeleton.find_bone("spine_03")
	var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var dir := (pt - p.camera.global_position).normalized()
	z.take_hit("spine_03", pt, dir, dir, 5.0, "blunt", true, 1.0, 120.0, dir, p)
	# DI2's knockdown runs KO montage -> ragdoll -> rest + 0.6 s -> KnockdownDuration (3.5 - 5 s) -> stand-up montage.
	await _wait_standing(z, 16.0)


## A heavy bat hit at zero stability: DI2's CT_HitReact_Knockdown_Zombie -> #LaunchRequirements -> Launch_Zombie ->
## LaunchingImpactResponse with the bat's impact-provided DA_LaunchSettings_MeleeDefault_CrowdControl_Medium -> the
## Ragdoll action with the launch impulses -> rest -> stand-up (zombie_reactions.gd, launch_math.gd).
func _z_launch() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	var z := _subject(Vector3(0, 0.1, -1.7))
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(4.5, 1.8, 0.0))
	_begin("z_launch", 2)
	await _secs(0.3)
	mark("launch")
	var b := z.skeleton.find_bone("spine_03")
	var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var dir := (pt - p.camera.global_position).normalized()
	z.take_hit("spine_03", pt, dir, dir, 5.0, "blunt", true, 1.0, 120.0, dir, p, {"weapon": "bat", "HeavyAttack": true})
	await _wait_standing(z, 16.0)


## Two hits: Force 30 then Force 20 zeroes stability with #SmallStabilityDamage -> CT_HitReact_Knockdown_Zombie's
## KnockdownAction HitReactions.KOMedium: KO montage -> HitReactRagdoll notify -> Ragdoll action -> stand-up.
func _z_ko() -> void:
	_clear()
	_reset_player()
	p.equip("bat", true)
	var z := _subject(Vector3(0, 0.1, -1.7))
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(3.5, 1.5, 0.0))
	_begin("z_ko", 2)
	await _secs(0.3)
	for f in [30.0, 20.0]:
		mark("hit force %d" % f)
		var b := z.skeleton.find_bone("spine_03")
		var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
		var dir := (pt - p.camera.global_position).normalized()
		z.take_hit("spine_03", pt, dir, dir, 5.0, "blunt", false, 1.0, f, dir, p, {"weapon": "machete"})
		if f == 30.0:
			await _secs(1.2)
	await _wait_standing(z, 16.0)


## A kill with Force 20: CT_HitReact_Death_Zombie's DeathAction HitReactions.KOMedium -> death montage -> ragdoll at
## its HitReactRagdoll notify.
func _z_death_ko() -> void:
	_clear()
	_reset_player()
	var z := _subject(Vector3(0, 0.1, -1.8))
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(3.2, 1.4, 0.3))
	_begin("z_death_ko", 1)
	await _secs(0.3)
	mark("kill force 20")
	z.gore.set_health(1.0)
	var b := z.skeleton.find_bone("spine_03")
	var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var dir := (pt - p.camera.global_position).normalized()
	z.take_hit("spine_03", pt, dir, dir, 50.0, "blunt", false, 1.0, 20.0, dir, p, {"weapon": "machete"})
	await _secs(3.0)


## Waits until the zombie's reaction is over (standing again) plus 1 s, at most `limit` seconds; marks the phases.
func _wait_standing(z: Zombie, limit: float) -> void:
	var last := ""
	var t := 0.0
	var done := -1.0
	while t < limit:
		await _frames(1)
		t += 1.0 / 60.0
		if not is_instance_valid(z):
			return
		var st: String = z.reactions.state + ("/" + z.reactions.rag_phase if z.reactions.state == "ragdoll" else "")
		if st != last:
			mark("react " + (st if st != "" else "none"))
			last = st
		if st == "" and t > 0.5 and done < 0.0:
			done = t
		if done >= 0.0 and t > done + 1.0:
			return


func _z_runner() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 0), 0.0)
	var z := _subject(Vector3(0, 0.1, -12.0), "Runner", false)
	watch = [z]
	_begin("z_runner", 2)
	await _follow(z, Vector3(3.0, 1.2, 0.5), 60 * 5)


func _z_death() -> void:
	_clear()
	_reset_player()
	var z := _subject(Vector3(0, 0.1, -1.8))
	watch = [z]
	await _secs(0.8)
	_frame_zombie(z, Vector3(3.2, 1.4, 0.3))
	_begin("z_death", 1)
	await _secs(0.3)
	mark("kill")
	z.gore.set_health(1.0)
	var b := z.skeleton.find_bone("head")
	var pt := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var dir := (pt - p.camera.global_position).normalized()
	z.take_hit("head", pt, dir, dir, 50.0, "blunt", true, 1.0, 30.0, dir, p)
	await _secs(2.5)


## Face close-ups per body (recon/ANIMATION.md 7): 1 s with the facial layer off (the port before), the calm face
## (Idle facial state), the combat face (target set: Idle -> Combat crossfade), then a diagnostic sweep of the voice
## level RTPC_Zombie_Mouth_Volume from the -48 dB floor to 0 dB and back (what a vocalising zombie's mouth does in DI2;
## the port has no zombie voice audio, so in play it stays at the floor).
func _z_face() -> void:
	_begin("z_face", 3)
	await _frames(1)
	for arch in ["Walker", "Runner", "Shambler", "Thug"]:
		_clear()
		_reset_player(Vector3(0, 0.1, 6.0), 0.0)
		var z := _subject(Vector3(0, 0.1, 0.0), arch)
		watch = [z]
		var fl: ZombieAnim.FaceLayer = z.anim_ctl.face
		notes.append("  %s face layer ok %s, bones %d, clips %s" % [arch, fl.ok if fl else false, fl.bones.size() if fl else 0,
			fl.sets if fl else {}])
		if fl:
			fl.w_facial = 0.0
			fl.facial_target = 0.0
		mark("%s: facial layer off (before)" % arch)
		await _face_cam(z, 60)
		if fl:
			fl.w_facial = 1.0
			fl.facial_target = 1.0
		mark("%s: DI2 face, calm" % arch)
		await _face_cam(z, 150)
		z.target = p
		mark("%s: combat (target set)" % arch)
		await _face_cam(z, 150)
		if fl:
			mark("%s: voice level sweep -48 -> 0 -> -48 dB (diagnostic)" % arch)
			for i in 120:
				fl.mouth_db = -48.0 + 48.0 * sin(PI * i / 120.0)
				await _face_cam(z, 1)
			fl.mouth_db = -48.0
		z.target = null


## Camera 0.55 m in front of the zombie's head, looking at it.
func _face_cam(z: Zombie, frames: int) -> void:
	for i in frames:
		if is_instance_valid(z):
			var sk := z.skeleton
			var hb := sk.find_bone("head")
			var hp := sk.global_transform * sk.get_bone_global_pose(hb).origin
			var fwd := -z.global_basis.z
			cam3p.current = true
			cam3p.global_position = hp + fwd * 0.6 - Vector3.UP * 0.04
			cam3p.look_at(hp + fwd * 0.08 + Vector3.UP * 0.02)
		await get_tree().process_frame


# --- performance ----------------------------------------------------------------------------------------------

## Where an idle zombie's frame goes: the scene alone, then 8 idle Walkers (the flesh suite's perf_check layout)
## with each per-zombie part switched off in turn (cumulative), then the scene's other per-frame systems.
func _z_perf() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 2.5), 0.0)
	cam3p.current = true
	cam3p.global_position = Vector3(0, 1.6, 2.5)
	cam3p.look_at(Vector3(0, 1.0, -3.5), Vector3.UP)
	await _wait_s(1.0)
	var m0 := await _measure(2.0, [])
	notes.append("== z_perf")
	notes.append("  %-50s %6.1f fps  process %6.2f ms  physics %6.2f ms" % ["no zombies", m0[0], m0[1], m0[2]])
	var zs: Array[Zombie] = []
	for i in 8:
		var z := main.spawn_zombie(Vector3((i % 4) * 1.2 - 1.8, 0.1, -3.0 - (i / 4) * 1.5), "Walker") as Zombie
		z.target = null
		z.rotation.y = PI
		z.gore.set_health(3000.0)
		zs.append(z)
	await _wait_s(1.5)
	var z0 := zs[0]
	var kinds := {}
	for n in Util.find_all(z0, "Node"):
		var c: String = n.get_class()
		kinds[c] = kinds.get(c, 0) + 1
	notes.append("  nodes per zombie %d: %s" % [Util.find_all(z0, "Node").size(), JSON.stringify(kinds)])
	# Equivalence: each zombie's pose evaluated in the same frame without and with the optimisations.
	var worst := 0.0
	var worst_p := 0.0
	var worst_a := 0.0
	var worst_b := ""
	var repeat_a := 0.0
	var repeat_b := ""
	for z in zs:
		var an: DI2Anim = z.anim_ctl.a
		var sk := z.skeleton
		DI2Anim.direct_enabled = false
		an.set_covered(PackedByteArray())
		an.evaluate()
		var ref0: Array = []
		for b in sk.get_bone_count():
			ref0.append(sk.get_bone_pose(b))
		an.evaluate()
		var ref: Array = []
		for b in sk.get_bone_count():
			ref.append(sk.get_bone_pose(b))
			var r0: Transform3D = ref0[b]
			var ra := rad_to_deg(r0.basis.get_rotation_quaternion().angle_to(ref[b].basis.get_rotation_quaternion()))
			if ra > repeat_a:
				repeat_a = ra
				repeat_b = "%s: %s -> %s, rest %s" % [sk.get_bone_name(b), r0.basis.get_rotation_quaternion(), ref[b].basis.get_rotation_quaternion(), sk.get_bone_rest(b).basis.get_rotation_quaternion()]
		DI2Anim.direct_enabled = true
		for fb in z.anim_ctl.face.bones:   # stale skeleton values: the optimised path must rewrite every face bone
			sk.set_bone_pose_rotation(fb, Quaternion(Vector3.UP, 1.0))
			sk.set_bone_pose_position(fb, Vector3.ONE)
		an.set_covered(z.anim_ctl.face.cover_mask)
		an.evaluate()
		an.evaluate()   # a second frame: the covered bones now rely on the values kept from the first
		for b in sk.get_bone_count():
			var t0: Transform3D = ref[b]
			var t1 := sk.get_bone_pose(b)
			var dp := t0.origin.distance_to(t1.origin)
			var da := rad_to_deg(t0.basis.get_rotation_quaternion().angle_to(t1.basis.get_rotation_quaternion()))
			if dp > worst_p or da > worst_a:
				worst_b = "%s (%s) states %s slot %s src %s" % [sk.get_bone_name(b), "face" if z.anim_ctl.face.cover_mask[b] == 1 else "body",
					an.states.map(func(e): return [e["key"], snappedf(e["alpha"].value, 0.0001)]),
					an.slot.map(func(m): return [m.name, snappedf(m.weight.value, 0.000001), m.additive]),
					an.states[-1]["src"].get_script().resource_path if an.states[-1]["src"].get_script() else "?"]
			worst_p = maxf(worst_p, dp)
			worst_a = maxf(worst_a, da)
	var an0: DI2Anim = zs[0].anim_ctl.a
	var src0 = an0.states[-1]["src"]
	if src0 is DI2Anim.Seq:
		var anim0 := an0.clip(src0.clip)
		var per := {}
		var dup := []
		for i in anim0.get_track_count():
			var key := "%s %d" % [anim0.track_get_path(i).get_concatenated_subnames(), anim0.track_get_type(i)]
			per[key] = per.get(key, 0) + 1
			if per[key] == 2:
				dup.append(key)
		notes.append("  clip %s: %d tracks, bones with 2+ tracks of one type: %d %s" % [src0.clip, anim0.get_track_count(), dup.size(), dup.slice(0, 8)])
	notes.append("  general path evaluated twice: worst rotation difference %.4f deg (%s)" % [repeat_a, repeat_b])
	notes.append("  optimisation equivalence: worst position %.6f m, rotation %.4f deg (last worst bone %s) over 8 zombies x %d bones" % [worst_p, worst_a, worst_b, zs[0].skeleton.get_bone_count()])
	# A/B of DI2Anim's covered-bones skip (same run, alternating, ZombieAnim update time per zombie).
	for rep in 3:
		for on in [true, false]:
			DI2Anim.cover_enabled = on
			await _wait_s(0.3)
			var mab := await _measure(1.5, zs)
			notes.append("  A/B face-bone skip %-5s %6.1f fps  process %6.2f ms  ZombieAnim update %.0f us / zombie" % [on, mab[0], mab[1], mab[3]])
	DI2Anim.cover_enabled = true
	for k in DI2Anim.prof:
		DI2Anim.prof[k] = 0
	DI2Anim.profile = true
	await _measure(1.5, zs)
	DI2Anim.profile = false
	var n := maxf(float(DI2Anim.prof["n"]), 1.0)
	notes.append("  DI2Anim.update per call (us): advance %.1f, accumulate %.1f, compose %.1f, post layers (face) %.1f, write %.1f" % [
		DI2Anim.prof["advance"] / n, DI2Anim.prof["accumulate"] / n, DI2Anim.prof["compose"] / n, DI2Anim.prof["post"] / n,
		DI2Anim.prof["write"] / n])
	var steps := ["8 idle Walkers, all on", "- ZombieAnim tick (pose frozen)", "- PhysicalReaction modifier",
		"- DanglingLimbs modifier", "- DamagePropagation", "- GoreBody process", "- zombie _physics_process (AI, move)",
		"- BoneAttachment3D nodes (hitboxes, parts) removed", "- visual hidden"]
	for k in steps.size():
		for z in zs:
			_perf_off(z, k)
		await _wait_s(0.5)
		var m := await _measure(2.0, zs if k == 0 else [])
		notes.append("  %-50s %6.1f fps  process %6.2f ms  physics %6.2f ms%s" % [steps[k], m[0], m[1], m[2],
			("  (ZombieAnim update %.0f us / zombie)" % m[3]) if k == 0 else ""])
	for z in zs:
		z.queue_free()
	await _wait_s(0.5)
	var others := ["zombies freed", "- player _process", "- player _physics_process", "- DaniVisual _process",
		"- HUD _process", "- main _process"]
	for k in others.size():
		match k:
			1:
				p.set_process(false)
			2:
				p.set_physics_process(false)
			3:
				for dv in Util.find_all(p, "DaniVisual"):
					dv.set_process(false)
			4:
				main.hud.set_process(false)
			5:
				main.set_process(false)
		await _wait_s(0.5)
		var m := await _measure(2.0, [])
		notes.append("  %-50s %6.1f fps  process %6.2f ms  physics %6.2f ms" % [others[k], m[0], m[1], m[2]])
	p.set_process(true)
	p.set_physics_process(true)
	for dv in Util.find_all(p, "DaniVisual"):
		dv.set_process(true)
	main.hud.set_process(true)
	main.set_process(true)


func _perf_off(z: Zombie, k: int) -> void:
	match k:
		1:
			z.anim_ctl.set_process(false)
		2:
			z.phys.active = false
		3:
			z.dangling.active = false
		4:
			z.propagation.set_process(false)
		5:
			z.gore.set_process(false)
			z.gore.set_physics_process(false)
		6:
			z.set_physics_process(false)
		7:
			for att in Util.find_all(z, "BoneAttachment3D"):
				att.get_parent().remove_child(att)
		8:
			z.visual.visible = false


func _wait_s(s: float) -> void:
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < int(s * 1e6):
		await get_tree().process_frame


func _measure(seconds: float, zs: Array) -> Array:
	var frames := 0
	var proc := 0.0
	var phys := 0.0
	var anim_us := 0.0
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < int(seconds * 1e6):
		await get_tree().process_frame
		frames += 1
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		for z: Zombie in zs:
			anim_us += z.anim_ctl.a.last_usec
	var el := (Time.get_ticks_usec() - t0) / 1e6
	return [frames / el, proc / maxf(frames, 1), phys / maxf(frames, 1), anim_us / maxf(frames * maxi(zs.size(), 1), 1)]


## Root-motion locomotion test (recon/ANIMATION.md 3.6): the zombie's own physics is off and the node moves only by
## ZombieAnim.root_motion(); first the brain-driven baseline (z_walk_chase measures that), then a chase walk at the
## Walker's walk speed, then DI2's TurnOnSpot L90 clip in place.
func _z_rootmotion() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 8.0), 0.0)
	var z := _subject(Vector3(0, 0.1, 0.0), "Walker")
	z.rotation.y = 0.0
	watch = [z]
	await _secs(0.5)
	z.set_physics_process(false)
	z.anim_ctl.rm_locomotion = true
	_begin("z_rootmotion", 2)
	await _frames(1)
	mark("walk by root motion at 1.5 m/s")
	for i in 60 * 4:
		z.anim_ctl.drive("Chase", 1.5, false)
		await _rm_step(z)
	mark("walk by root motion at 1.6 m/s (Walk_Med alone)")
	for i in 60 * 4:
		z.anim_ctl.drive("Chase", 1.6, false)
		await _rm_step(z)
	mark("idle")
	for i in 60:
		z.anim_ctl.drive("Idle", 0.0, false)
		await _rm_step(z)
	var yaw0 := z.rotation.y
	var c := "x:A_ZMB_Walker_Calm_TurnOnSpot_Slow_L90"
	mark("TurnOnSpot L90 by root motion (yaw before %.1f deg)" % rad_to_deg(yaw0))
	z.anim_ctl.a.set_state("TurnOnSpot:test", DI2Anim.Seq.new(c, z.anim_ctl.a.clip_len(c), false), 0.2, "HermiteCubic")
	for i in roundi(z.anim_ctl.a.clip_len(c) * 60.0) + 30:
		await _rm_step(z)
	notes.append("  TurnOnSpot L90: node yaw %.1f -> %.1f deg (DI2 clip turns 90 deg left)" % [rad_to_deg(yaw0), rad_to_deg(z.rotation.y)])
	z.set_physics_process(true)


func _rm_step(z: Zombie) -> void:
	await get_tree().process_frame
	var dt := get_process_delta_time()
	var rm: Dictionary = z.anim_ctl.root_motion(dt)
	z.global_position += Vector3(rm["velocity"].x, 0.0, rm["velocity"].z) * dt
	z.rotate_y(rm["yaw"])
	cam3p.current = true
	cam3p.global_position = z.global_position + Vector3(3.0, 1.4, 0.8)
	cam3p.look_at(z.global_position + Vector3.UP * 0.9)


## DI2's root-motion locomotion states (zombie_anim.gd _drive_rm) on a Walker moved only by root_motion(): an idle
## turn-in-place to a target 90 deg right, a Start toward a target 90 deg left at walk speed, a walk, then a Stop.
func _z_loco() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, 8.0), 0.0)
	var z := _subject(Vector3(0, 0.1, 0.0), "Walker")
	z.rotation.y = 0.0
	watch = [z]
	await _secs(0.5)
	z.set_physics_process(false)
	z.anim_ctl.rm_locomotion = true
	_begin("z_loco", 2)
	var log0: int = z.anim_ctl.loco_log.size()
	var yaw0 := z.rotation.y
	mark("idle, target 90 deg right")
	for i in 60 * 3:
		z.anim_ctl.drive("Alert", 0.0, false, Vector3(1, 0, 0), INF)
		await _rm_step(z)
	notes.append("  turn: node yaw %.1f -> %.1f deg (want -90)" % [rad_to_deg(yaw0), rad_to_deg(z.rotation.y)])
	mark("chase 1.5 m/s, target 90 deg left")
	var p0 := z.global_position
	for i in 60 * 4:
		z.anim_ctl.drive("Chase", 1.5, false, Vector3(0, 0, -1), INF)
		await _rm_step(z)
	notes.append("  start+walk: moved %s, yaw %.1f deg (want 0)" % [z.global_position - p0, rad_to_deg(z.rotation.y)])
	mark("stop")
	p0 = z.global_position
	for i in 60 * 3:
		z.anim_ctl.drive("Chase", 0.0, false, Vector3(0, 0, -1), 0.0)
		await _rm_step(z)
	notes.append("  stop: moved %.2f m after the stop command" % (z.global_position - p0).length())
	for e: Array in z.anim_ctl.loco_log.slice(log0):
		notes.append("  loco %s" % [e])
	z.set_physics_process(true)


## Attack-montage root motion (recon/ANIMATION.md 13): a Walker moved only by root_motion() plays
## AM_ZMB_Walker_SwipeR_Vert_Med (IntoStatic lead-in -> attack segment); the capsule should travel with the montage's
## root motion and the pose should not jump at the segment boundary.
func _z_attack_rm() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, -1.6), PI)
	var z := _subject(Vector3(0, 0.1, 0.0), "Walker")
	watch = [z]
	await _secs(0.5)
	z.set_physics_process(false)
	z.anim_ctl.rm_locomotion = true
	for i in 30:
		z.anim_ctl.drive("Alert", 0.0, false, Vector3(0, 0, -1), INF)
		await _rm_step(z)
	_begin("z_attack_rm", 1)
	mark("AM_ZMB_Walker_SwipeR_Vert_Med")
	var p0 := z.global_position
	z.anim_ctl.play("AM_ZMB_Walker_SwipeR_Vert_Med")
	for i in 60 * 3:
		z.anim_ctl.drive("Attack", 0.0, false, Vector3(0, 0, -1), 0.0)
		await _rm_step(z)
	notes.append("  attack: capsule moved %s" % [z.global_position - p0])
	z.set_physics_process(true)
	_end()


## Strafing Move (recon/ANIMATION.md 14): a Walker facing its target (-Z) walks forward, then strafes right, then left
## (a 180 deg jump: the primary / secondary swap), moved only by root_motion(). move_dir is what zombie.gd passes from a
## strafe card (cmd move_dir); 1.0 m/s is a test input.
func _z_strafe() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, -8.0), PI)
	var z := _subject(Vector3(0, 0.1, 0.0), "Walker")
	watch = [z]
	await _secs(0.5)
	z.set_physics_process(false)
	z.anim_ctl.rm_locomotion = true
	_begin("z_strafe", 2)
	var log0: int = z.anim_ctl.loco_log.size()
	var face := Vector3(0, 0, -1)
	mark("walk forward 1.0 m/s")
	for i in 60 * 3:
		z.anim_ctl.drive("Chase", 1.0, false, face, INF)
		await _rm_step(z)
	for leg: Array in [["strafe right", Vector3(1, 0, 0)], ["strafe left", Vector3(-1, 0, 0)]]:
		mark(leg[0])
		var p0 := z.global_position
		z.anim_ctl.move_dir = leg[1]
		for i in 60 * 3:
			z.anim_ctl.drive("Chase", 1.0, false, face, INF)
			await _rm_step(z)
		notes.append("  %s: moved %s, yaw %.1f deg (want 0), angle %.1f, back %.2f" % [leg[0], z.global_position - p0,
			rad_to_deg(z.rotation.y), z.anim_ctl._mv_angle, (z.anim_ctl._loco_src as ZombieAnim.MoveBS).back if z.anim_ctl._loco_src is ZombieAnim.MoveBS else -1.0])
	z.anim_ctl.move_dir = Vector3.ZERO
	for e: Array in z.anim_ctl.loco_log.slice(log0):
		notes.append("  loco %s" % [e])
	z.set_physics_process(true)
	_end()


## The special bodies' own locomotion sets (zombie_anim.gd LOCO_SETS): Screamer, Slobber, Suicider and Butcher start,
## walk and stop side by side, moved only by root_motion().
func _z_specials_walk() -> void:
	_clear()
	_reset_player(Vector3(0, 0.1, -12.0), PI)
	var zs: Array[Zombie] = []
	var x := -3.0
	for arch: String in ["Screamer", "Slobber", "Suicider", "Butcher"]:
		var z := _subject(Vector3(x, 0.1, 0.0), arch)
		zs.append(z)
		x += 2.0
	watch = zs
	await _secs(0.5)
	var p0: Array[Vector3] = []
	var log0: Array[int] = []
	for z in zs:
		z.set_physics_process(false)
		z.anim_ctl.rm_locomotion = true
		p0.append(z.global_position)
		log0.append(z.anim_ctl.loco_log.size())
	_begin("z_specials_walk", 2)
	for phase: Array in [["walk 1.2 m/s", 1.2, 60 * 4], ["stop", 0.0, 60 * 2]]:
		mark(phase[0])
		for i in int(phase[2]):
			for z in zs:
				z.anim_ctl.drive("Chase", float(phase[1]), false, Vector3(0, 0, -1), INF if float(phase[1]) > 0.0 else 0.0)
			await get_tree().process_frame
			var dt := get_process_delta_time()
			for z in zs:
				var rm: Dictionary = z.anim_ctl.root_motion(dt)
				z.global_position += Vector3(rm["velocity"].x, 0.0, rm["velocity"].z) * dt
				z.rotate_y(rm["yaw"])
			cam3p.current = true
			cam3p.global_position = zs[1].global_position + Vector3(6.0, 2.0, 2.0)
			cam3p.look_at(zs[1].global_position + Vector3(1.0, 0.9, 0.0))
	for k in zs.size():
		var z := zs[k]
		notes.append("  %s (%s): moved %s, rm %s, clips %s" % [z.archetype if "archetype" in z else "?", z.anim_ctl.body,
			z.global_position - p0[k], z.anim_ctl.rm_locomotion, z.anim_ctl.loco_log.slice(log0[k]).map(func(e): return e[1])])
		z.set_physics_process(true)
	_end()
