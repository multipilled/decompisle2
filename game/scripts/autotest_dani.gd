extends Node
## Dani look check: `godot --path game -- --danitest=<out_dir>` (run through tools/run_test.sh).
## Verifies every SK_FemBerserkerFP section against game/data/dani_materials.json (shader variant, textures, scalars)
## and captures: the old prop.gdshader look vs player.gdshader (idle + hand close-up), a bat swing, the pistol, the
## four DI2 hand-blood stages after their flow animation, Fury veins, looking down (FP lower body) and the hidden
## third-person shadow body. Log: out_dir/dani.log.

var out_dir := ""
var main: Main
var p: Player
var dv: DaniVisual
var log_lines: PackedStringArray = []
var cam: Camera3D


func _ready() -> void:
	main = get_parent()
	p = main.player
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_tree().create_timer(170.0).timeout.connect(func() -> void:
		log_lines.append("WATCHDOG: timed out")
		_save_log()
		get_tree().quit(1))
	main.hud.visible = false
	await _wait(0.6)
	_clear()
	dv = DaniVisual.of(p)
	if dv == null:
		log_lines.append("FAIL: no DaniVisual on the player (player.gd hook-up missing)")
		_save_log()
		get_tree().quit(1)
		return
	_verify()
	p.global_position = Vector3(0, 0.1, 0)
	p.rotation.y = 0.0
	p.pitch = 0.0
	p.equip("bat", true)
	await _wait(1.0)
	await _shot("01_idle_bat")
	await _closeup("02_hands_closeup")
	await _closeup("02b_left_hand_closeup", "hand_l")
	await _before_after()
	# swing: DI2 light attack mid-arc
	p.lmb_held = false
	p.melee.start_light()
	for k in 4:
		await _wait(0.12)
		await _shot("05_swing_bat_%d" % k)
	await _wait(1.0)
	p.equip("pistol", true)
	await _wait(1.4)
	await _shot("06_pistol")
	await _closeup("06b_pistol_hands_closeup")
	p.ranged.shot_cd = 0.0
	p.ranged.fire()
	await _wait(0.05)
	await _shot("07_pistol_fire")
	await _wait(0.8)
	p.equip("bat", true)
	await _wait(1.2)
	await _blood_stages()
	await _veins()
	await _look_down()
	await _shadow()
	_save_log()
	get_tree().quit()


## Every FP surface: player.gdshader, the variant of its decompiled PS, all used textures loaded, scalars as resolved.
func _verify() -> void:
	log_lines.append(dv.skin8_note)
	var mi: MeshInstance3D = Util.find_first(p.rig, "MeshInstance3D")
	var bad := 0
	log_lines.append("FP mesh: %d surfaces, cast_shadow %d (DI2 MeshFirstPerson CastShadow false)" % [mi.mesh.get_surface_count(), mi.cast_shadow])
	if mi.mesh.get_surface_count() != dv.data["fp_mesh"]["sections"].size():
		log_lines.append("FAIL: FP mesh has %d surfaces, SK_FemBerserkerFP has %d sections" % [mi.mesh.get_surface_count(), dv.data["fp_mesh"]["sections"].size()])
		bad += 1
	for s in mi.mesh.get_surface_count():
		var mat := mi.get_surface_override_material(s) as ShaderMaterial
		var name := mi.mesh.surface_get_material(s).resource_name if mi.mesh.surface_get_material(s) else "?"
		var e: Dictionary = dv.data["materials"].get(name, {})
		if mat == null or e.is_empty() or not mat.shader.code.begins_with("// Dani"):
			log_lines.append("FAIL surface %d %s: not a player.gdshader material" % [s, name])
			bad += 1
			continue
		var want: int = DaniVisual.VARIANTS[e["shader_variant"]]
		var miss: PackedStringArray = []
		for n: String in e["params"]["textures"]:
			var t: Dictionary = e["params"]["textures"][n]
			if t["used"] and t["value"] and DaniVisual.TEX_UNIFORMS.has(n) and mat.get_shader_parameter(DaniVisual.TEX_UNIFORMS[n]) == null:
				miss.append(n)
		var wrong: PackedStringArray = []
		for n: String in e["params"]["scalars"]:
			var sv = e["params"]["scalars"][n]["value"]
			if sv != null and DaniVisual.SCALAR_UNIFORMS.has(n) and n != "Splatter Animation Phase":
				if absf(float(mat.get_shader_parameter(DaniVisual.SCALAR_UNIFORMS[n])) - float(sv)) > 1e-5:
					wrong.append("%s=%s" % [n, mat.get_shader_parameter(DaniVisual.SCALAR_UNIFORMS[n])])
		var ok: bool = mat.get_shader_parameter("variant") == want and miss.is_empty() and wrong.is_empty()
		bad += 0 if ok else 1
		log_lines.append("%s surface %d %s: variant %s (PS %d), two-sided %s, clip %.4f, SSS %s%s%s" % [
			"ok  " if ok else "FAIL", s, name, e["shader_variant"], int(e["base_pass_ps"]["index"]),
			e["render"]["TwoSided"]["value"], float(mat.get_shader_parameter("clip_value")),
			e.get("subsurface_profile", {}).get("value", "-") if e.get("subsurface_profile") else "-",
			("  missing textures " + ", ".join(miss)) if miss else "", ("  wrong " + ", ".join(wrong)) if wrong else ""])
	log_lines.append("materials verified: %d bad" % bad)
	var t_ok := 0
	for n: String in dv.textures:
		t_ok += 1 if dv.textures[n] != null else 0
	log_lines.append("textures loaded: %d / %d" % [t_ok, dv.textures.size()])
	for n: String in dv.textures:
		var t = dv.textures[n]
		if t is ImageTexture:
			var img: Image = t.get_image()
			log_lines.append("  %s %dx%d format %d mipmaps %s" % [n, img.get_width(), img.get_height(), img.get_format(), img.has_mipmaps()])
		elif t == null:
			log_lines.append("  FAIL %s not loaded" % n)
	log_lines.append("shadow body: %s, %d bones mapped" % ["yes" if dv.shadow_root else "NO",
		Array(dv.shadow_bone_map).filter(func(x): return x >= 0).size()])


## The old Util.apply_prop_materials look vs the DI2 transcription, same frame.
func _before_after() -> void:
	var arms: MeshInstance3D = Util.find_first(p.rig, "MeshInstance3D")
	var saved := {}
	for mi: MeshInstance3D in Util.find_all(p.rig, "MeshInstance3D"):
		var list: Array = []
		for s in mi.mesh.get_surface_count():
			list.append(mi.get_surface_override_material(s))
		saved[mi] = list
	Util.apply_prop_materials(arms, "res://assets/di2/dani/dani_fp.materials.json")   # the arms only, as player.gd did
	await _shot("03_before_prop_shader")
	await _closeup("04_before_prop_closeup")
	for mi: MeshInstance3D in saved:
		for s in saved[mi].size():
			mi.set_surface_override_material(s, saved[mi][s])
	await _wait(0.2)


## DI2 PlayerHandsMaterialComponent: the stage textures at bloodiness 0.1 / 0.5 / 0.75 / 1.0 after the flow animation
## (RequiredOnScreenTimeBeforeAnimation + FlowAnimationDuration), via the same entry point melee hits use.
func _blood_stages() -> void:
	var steps := [[1, false], [3, false], [1, true], [1, false]]   # hits (x0.1), critical (x3) -> 0.1, 0.4, 0.7, 0.8
	var i := 0
	for st: Array in steps:
		for k in int(st[0]):
			dv.on_melee_hit(st[1])
		await _wait(0.1)
		var phases := []
		for s: Dictionary in dv.blood_sections:
			phases.append("%s:%s@%.2f" % [s["name"].trim_prefix("MI_FemBerserker"), s["tex"], s["phase"]])
		log_lines.append("blood %.2f right after hit: %s" % [dv.bloodiness, ", ".join(phases)])
		await _wait(3.4)
		phases.clear()
		for s: Dictionary in dv.blood_sections:
			phases.append("%s@%.2f" % [s["name"].trim_prefix("MI_FemBerserker"), s["phase"]])
		log_lines.append("blood %.2f after flow: %s" % [dv.bloodiness, ", ".join(phases)])
		await _closeup("08_blood_%d_%02d" % [i, roundi(dv.bloodiness * 100)])
		i += 1
	dv.add_bloodiness(1.0)
	await _wait(3.4)
	await _shot("09_blood_full_fp")
	dv.clean_hands()
	await _wait(3.4)
	log_lines.append("after clean: %.2f, %s" % [dv.bloodiness, ", ".join(dv.blood_sections.map(func(s): return "%s@%.2f" % [s["tex"], s["phase"]]))])


func _veins() -> void:
	for m in dv.vein_materials:
		m.set_shader_parameter("zombie_vein_blend_weight", 1.0)
	dv.set_process(false)   # keep the weight (the Autophage driver would reset it outside Fury)
	await _wait(0.3)
	await _closeup("10_fury_veins_closeup")
	log_lines.append("veins at 1.0 on %d materials; Autophage curve at 0.25/0.5/0.75: %.3f %.3f %.3f" % [
		dv.vein_materials.size(), DaniVisual._curve(dv.autophage_keys, 0.25), DaniVisual._curve(dv.autophage_keys, 0.5),
		DaniVisual._curve(dv.autophage_keys, 0.75)])
	for m in dv.vein_materials:
		m.set_shader_parameter("zombie_vein_blend_weight", 0.0)
	dv.set_process(true)


func _look_down() -> void:
	p.pitch = deg_to_rad(-80.0)
	await _wait(0.4)
	await _shot("11_look_down")
	p.pitch = 0.0
	await _wait(0.3)


## A low sun from behind-left: the hidden SK_FemBerserker body should throw Dani's shadow ahead (the FP mesh casts none).
func _shadow() -> void:
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.light_energy = 1.5
	main.add_child(sun)
	sun.global_transform = Transform3D(Basis.looking_at(Vector3(0.3, -0.6, -1.0).normalized()), Vector3.ZERO)
	cam = Camera3D.new()
	main.add_child(cam)
	cam.global_position = p.global_position + Vector3(1.6, 2.4, -2.8)
	cam.look_at(p.global_position + Vector3(0, 0.2, -1.4))
	cam.current = true
	await _wait(0.4)
	await _shot("12_shadow_external")
	cam.current = false
	p.camera.current = true
	await _shot("13_shadow_fp")
	sun.queue_free()


func _closeup(name: String, bone := "hand_r") -> void:
	var b := p.rig_skel.find_bone(bone)
	var hand := p.rig_skel.global_transform * p.rig_skel.get_bone_global_pose(b).origin
	var c := Camera3D.new()
	c.near = 0.005
	c.fov = 40.0
	main.add_child(c)
	var eye := p.camera.global_position
	c.global_position = eye + (hand - eye) * 0.55 + p.camera.global_basis.x * 0.04
	c.look_at(hand, Vector3.UP)
	c.current = true
	await _wait(0.15)
	await _shot(name)
	c.current = false
	p.camera.current = true
	c.queue_free()


func _clear() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	log_lines.append("shot " + name)


func _save_log() -> void:
	FileAccess.open(out_dir.path_join("dani.log"), FileAccess.WRITE).store_string("\n".join(log_lines))
