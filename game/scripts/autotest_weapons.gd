extends Node
## Every DI2 weapon class, one weapon each: `godot --path game -- --weapontest=<out_dir> [--only=<class_id>]`
## Equips it, runs its DI2 actions through the real player code and logs the clip each action played, whether
## the hit landed and the damage, plus a screenshot per weapon (out_dir/weapons.log, <class>.png).

var out_dir := ""
var only := ""
var main: Main
var p: Player
var log_lines: PackedStringArray = []


func _ready() -> void:
	main = get_parent()
	p = main.player
	DirAccess.make_dir_recursive_absolute(out_dir)
	await _wait(0.6)
	var seen := {}
	var picks := []
	for wid: String in p.catalog_ids:
		var cid: String = p.data[wid].get("class_id", "")
		if cid == "" or seen.has(cid) or (only != "" and cid != only):
			continue
		seen[cid] = true
		picks.append(wid)
	log_lines.append("%d classes" % picks.size())
	for wid: String in picks:
		await _test_weapon(wid)
	var f := FileAccess.open(out_dir.path_join("weapons.log"), FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
	get_tree().quit()


func _test_weapon(wid: String) -> void:
	var spec: Dictionary = p.data[wid]
	var z := _fresh(Vector3(0, 0.1, -1.5))
	if not p.loadout.has(wid):
		p.loadout[0] = wid
	p.equip(wid, true)
	await _wait(0.6)
	var line := "%-30s %-38s" % [wid, spec.get("class_id", "")]
	if not p.weapon_nodes.has(wid):
		log_lines.append(line + " NO MESH")
		return
	line += " idle=%s" % p.cur_clip()
	_aim(z, "spine_03")
	if spec["kind"] == "melee":
		var hp := z.gore.get_health()
		p.melee.start_light()
		var light_clip := p.cur_clip()
		await _until_idle(2.5)
		line += " | light %s (%s) dmg %.0f" % [p.melee.key.trim_prefix("AM_"), light_clip, hp - z.gore.get_health()]
		await _shot(spec.get("class_id", wid))
		z = _fresh(Vector3(0, 0.1, -1.5))
		await _wait(0.2)
		_aim(z, "spine_03")
		hp = z.gore.get_health()
		p.melee._start_charge()
		var charge_clip := p.cur_clip()
		await _wait(0.4)
		p.melee.charge = 1.0
		p.melee._release_heavy()
		var heavy_clip := p.cur_clip()
		await _until_idle(3.0)
		line += " | heavy %s->%s dmg %.0f" % [charge_clip, heavy_clip, hp - z.gore.get_health()]
		z = _fresh(Vector3(0, 0.1, -1.2))
		await _wait(0.2)
		_aim(z, "spine_03")
		p.moves.kick()
		line += " | kick %s" % p.moves.kick_clip
		await _until_idle(2.0)
		p.moves.block_pressed()
		p.rmb_held = true
		var block_in := p.cur_clip()
		await _wait(0.4)
		p.rmb_held = false
		await _wait(0.4)
		line += " | block %s" % block_in
		p.set_state("ready")
		p.moves.dodge()
		line += " | dodge %s" % p.cur_clip()
		await _until_idle(2.0)
	else:
		z.global_position = Vector3(0, 0.1, -5.0)
		await _wait(0.2)
		_aim(z, "spine_03")
		var hp := z.gore.get_health()
		p.set_state("ready")
		p.ranged.shot_cd = 0.0
		p.ranged.fire()
		var shoot_clip := p.cur_clip()
		var gun := p.weapon_anim()
		var gun_clip: String = gun.current_animation if gun else "(no gun anims)"
		await _wait(0.6)
		line += " | shoot %s gun %s mag %d dmg %.0f" % [shoot_clip, gun_clip, p.mag, hp - z.gore.get_health()]
		await _shot(spec.get("class_id", wid))
		p.set_state("ready")
		p.ranged.reload()
		line += " | reload %s (%s)" % [p.cur_clip(), p.ranged.config().get("ReloadHandler", {}).get("_type", "")]
		await _wait(3.5)
		line += " -> mag %d state %s" % [p.mag, p.state]
	log_lines.append(line)


func _until_idle(limit: float) -> void:
	var t := 0.0
	while p.state not in ["ready", "switch"] and t < limit:
		await get_tree().process_frame
		t += get_process_delta_time()
	await _wait(0.2)


func _fresh(at: Vector3) -> Zombie:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	p.global_position = Vector3(0, 0.1, 0)
	p.rotation.y = 0.0
	p.health = p.max_health
	p.stamina = p.max_stamina
	p.set_state("ready")
	var z := main.spawn_zombie(at, "Walker")
	z.target = null
	z.rotation.y = PI
	z.gore.set_health(3000.0)
	return z


func _aim(z: Zombie, bone: String) -> void:
	var b := z.skeleton.find_bone(bone)
	var target := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var d := (target - p.camera.global_position).normalized()
	p.rotation.y = atan2(-d.x, -d.z)
	p.pitch = asin(clampf(d.y, -1.0, 1.0))
	p.head.rotation.x = p.pitch


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
