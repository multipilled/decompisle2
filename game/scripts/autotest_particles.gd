extends Node
## DI2 hit particle check: `godot --path game -- --particletest=<out_dir>` (run through tools/run_test.sh).
## Plays the main DI2 zombie-hit cosmetic effects with DI2Particles.play_ce at a fixed hit (chest height, surface
## normal toward the attacker, hit travelling away from the camera side) and steps them at a fixed 60 Hz, so every
## capture is at the same effect time. Writes one frame strip per effect (<label>.png: 8 frames at TIMES) and a
## log (particles.log) with the live particle count of every emitter at each captured frame, plus the frame at
## TIMES[FULL_FRAME] at full resolution (<label>_full.png) and the last frame (<label>_end.png).

const TIMES := [0.0333, 0.0667, 0.1, 0.1667, 0.25, 0.4, 0.7, 1.5]
const DT := 1.0 / 60.0
const FRAME_W := 480
const FRAME_H := 270
const FULL_FRAME := 3  # also saved at full resolution (<label>_full.png)
## [label, CE, DirectionInterpolationFactor (the value the hit tree uses for that CE)]
const EFFECTS := [
	["blunt_medium", "CE_Blunt_Medium_Normal", 1.0],
	["blunt_crit", "CE_Blunt_Crit_Normal", 1.0],
	["sharp_medium", "CE_Sharp_Medium_Normal", 1.0],
	["sharp_crit", "CE_Sharp_Crit_Normal", 1.0],
	["stab_medium", "CE_Stab_Medium", 0.0],
	["bullet_pistol", "CE_Bullet_Pistol_Normal", 1.0],
	["headshot_pistol", "CE_Bullet_Pistol_Head_Normal", 1.0],
	["headshot_shotgun", "CE_Bullet_Shotgun_Head_Normal", 1.0],
	["blunt_fire", "CE_Blunt_Fire", 1.0],
	["blunt_shock", "CE_Blunt_Shock", 1.0],
	["blunt_acid", "CE_Blunt_Acid", 1.0],
	["bleed_lingering", "CE_Bleed_Lingering", 0.0],
	["fist_kill_chunks", "CE_Zombie_Counter_Fist_Kill", -1.0],  # viscera chunks (PSM_Debris); -1 = the CE's own factor
	# floor effects (4th element true: played on the floor 1 m in front of the body, normal up): the gore session's
	# burning-puddle port plays these on the fluid puddles (game/data/fluids.json)
	# 6th element: PS instance parameters. The fluid states get the transmitter's (di2_fluids.gd _state_params):
	# Radius = VisualRadiusMultiplier 1.75 x R 128 (fluids.json Petrol: MaxRadius, the merged molotov puddle), Opacity 1
	["burning_petrol", "CE_Fluid_State_Flammable", 0.0, true, 2.0, {"Radius": 224.0, "Opacity": Vector3.ONE}],
	["extinguished_fire", "CE_Extinguished_Fire", 0.0, true, 2.0, {"Radius": 224.0, "Opacity": Vector3.ONE}],
	["acid_lingering", "CE_Acid_Lingering", 0.0, true],  # acid bubbles (PSM_Translucent_Bubbles)
	["bullet_acid_world", "CE_Collision_Bullet_Pistol_Acid", 0.0, true],  # translucent VAT splash
	# explosions (PSM_Explosion_AlphaComposite), 5th element: camera distance scale
	["molotov", "CE_Explosions_Molotov", 0.0, true, 3.0],
	["pipe_bomb", "CE_Explosions_PipeBomb", 0.0, true, 3.0],
]

var out_dir := ""
var only := ""   # --only=<label substring> limits the run (iteration aid)
var main: Main
var cam: Camera3D
var log_lines: PackedStringArray = []
var hit_pos := Vector3(0.0, 1.4, 0.0)
var hit_normal := Vector3(0.0, 0.0, 1.0)
var hit_dir := Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	main = get_parent()
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_tree().create_timer(280.0).timeout.connect(func() -> void:
		log_lines.append("WATCHDOG: timed out")
		_save_log()
		get_tree().quit(1))
	main.hud.visible = false
	await _frames(3)
	for z in get_tree().get_nodes_in_group("zombies"):
		z.queue_free()
	main.player.process_mode = Node.PROCESS_MODE_DISABLED
	main.player.visible = false
	# Body stand-in behind the hit (visual only: no collision, DI2's particle collision traces statics): gives the
	# contact / soft-particle depth fades a surface like a zombie torso would.
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.18
	cap.height = 0.9
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.42, 0.36, 0.33)
	bm.roughness = 0.8
	cap.material = bm
	body.mesh = cap
	main.add_child(body)
	body.global_position = hit_pos - hit_normal * 0.18
	cam = Camera3D.new()
	cam.fov = 70.0
	main.add_child(cam)
	# side view: DI2's point-impact rotation (HitEffectSpawn.point_basis) sends factor-1 effects along the hit's
	# travel (-Z, through the body) and factor-0 ones out of the surface (+Z); both sides stay in frame
	cam.global_position = hit_pos + Vector3(1.6, 0.25, 0.0)
	cam.look_at(hit_pos + Vector3(0.0, -0.15, 0.0), Vector3.UP)
	cam.make_current()
	await _frames(3)
	var t0 := Time.get_ticks_msec()
	var d := DI2Particles.db()
	log_lines.append("particles.json: %d CEs, %d systems (loaded in %d ms)" % [d.get("ce", {}).size(), d.get("ps", {}).size(), Time.get_ticks_msec() - t0])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	if OS.get_cmdline_user_args().has("--perf"):
		await _perf()
		_save_log()
		get_tree().quit()
		return
	for e in EFFECTS:
		if only == "" or String(e[0]).contains(only):
			await _run(e[0], e[1], e[2], e.size() > 3 and e[3], e[4] if e.size() > 4 else 1.0, e[5] if e.size() > 5 else {})
	_save_log()
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run(label: String, ce: String, factor: float, on_floor := false, cam_scale := 1.0, ps_params := {}) -> void:
	var t_start := Time.get_ticks_usec()
	var saved := [hit_pos, hit_normal, cam.global_transform]
	if on_floor:
		hit_pos = Vector3(0.0, 0.0, 1.0)
		hit_normal = Vector3.UP
		cam.global_position = hit_pos + Vector3(1.8, 0.9, 0.0) * cam_scale
		cam.look_at(hit_pos + Vector3(0.0, 0.4, 0.0) * cam_scale, Vector3.UP)
		hit_pos.y += 0.5 * cam_scale  # crop centre (the crop looks 0.1 m below hit_pos)
	DI2Particles.play_ce(main, ce, hit_pos - (Vector3(0.0, 0.5 * cam_scale, 0.0) if on_floor else Vector3.ZERO), hit_normal, hit_dir, factor, ps_params)
	var nodes: Array = DI2Particles.last_spawned.duplicate()
	log_lines.append("== %s (%s, factor %.2f): %s" % [label, ce, factor, ", ".join(nodes.map(func(p): return p.ps_name))])
	if nodes.is_empty():
		log_lines.append("  FAIL: no particle system spawned")
		hit_pos = saved[0]
		hit_normal = saved[1]
		cam.global_transform = saved[2]
		return
	for p: DI2Particles in nodes:
		p.set_process(false)
		if OS.get_cmdline_user_args().has("--debugvat"):
			for e in p.emitters:
				if e.mat is ShaderMaterial and e.kind == DI2Particles.Emitter.Kind.MESH:
					e.mat.set_shader_parameter("debug_mode", 1)
	var t := 0.0
	var strip := Image.create(FRAME_W * TIMES.size(), FRAME_H, false, Image.FORMAT_RGBA8)
	var sim_us := 0
	for k in TIMES.size():
		while t < TIMES[k] * (2.0 if on_floor else 1.0) - 1e-4:  # floor effects: 0.067 .. 3 s
			var s := Time.get_ticks_usec()
			for p in nodes:
				if is_instance_valid(p):
					p.advance(DT)
			sim_us += Time.get_ticks_usec() - s
			t += DT
		var last := k == TIMES.size() - 1 and not on_floor  # floor effects keep their camera
		var cam_xf := cam.global_transform
		if last:
			# the end frame also looks down at the floor where the droplets land (up to ~3 m out along the normal)
			cam.global_position = Vector3(hit_pos.x + 2.6, 2.6, hit_pos.z)
			cam.look_at(Vector3(hit_pos.x, 0.0, hit_pos.z), Vector3.UP)
			for p in nodes:
				if is_instance_valid(p):
					p.render_now(cam)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if k == (TIMES.size() - 1 if on_floor else FULL_FRAME):  # floor effects build up: t = 3 s
			img.save_png(out_dir.path_join(label + "_full.png"))
		elif last:
			img.save_png(out_dir.path_join(label + "_end.png"))  # landed drips / environment decals
			cam.global_transform = cam_xf
		# crop 640x360 around the hit (so the strip keeps detail), then fit the strip cell
		var c := cam.unproject_position(hit_pos + Vector3(0.0, -0.1, 0.0))
		var cw := mini(640, img.get_width()); var ch := mini(360, img.get_height())
		var ox := clampi(int(c.x) - cw / 2, 0, img.get_width() - cw)
		var oy := clampi(int(c.y) - ch / 2, 0, img.get_height() - ch)
		img = img.get_region(Rect2i(ox, oy, cw, ch))
		img.resize(FRAME_W, FRAME_H, Image.INTERPOLATE_BILINEAR)
		img.convert(Image.FORMAT_RGBA8)
		strip.blit_rect(img, Rect2i(0, 0, FRAME_W, FRAME_H), Vector2i(FRAME_W * k, 0))
		if only != "" and (k == FULL_FRAME or k == TIMES.size() - 1):
			for p in nodes:
				for ei in p.emitters.size():
					var e = p.emitters[ei]
					if e.mm and e.n > 0 and e.kind == DI2Particles.Emitter.Kind.MESH:
						var xf: Transform3D = e.mm.get_instance_transform(0)
						var ps: Dictionary = p.particle_state(ei, 0)
						log_lines.append("  dbg %s: n=%d vis=%d origin=%s scale=%s dyn=%s col=%s rel=%.2f size=%s loc=%s" % [e.name, e.n,
							e.mm.visible_instance_count, xf.origin, xf.basis.get_scale(), ps.get("dyn"), ps.get("col"), ps.get("rel", 0.0), ps.get("size"), ps.get("loc")])
		var counts := []
		for p in nodes:
			if is_instance_valid(p):
				for e in p.emitters:
					if e.n > 0:
						counts.append("%s/%s:%d" % [p.ps_name.trim_prefix("PS_"), e.name, e.n])
		log_lines.append("  t=%.3f  %s" % [t, " ".join(counts)])
	strip.save_png(out_dir.path_join(label + ".png"))
	log_lines.append("  sim %.2f ms total for %d steps; wall %.0f ms" % [sim_us / 1000.0, int(round(TIMES[-1] / DT)), (Time.get_ticks_usec() - t_start) / 1000.0])
	for p in nodes:
		if is_instance_valid(p):
			p.queue_free()
	await _frames(2)
	hit_pos = saved[0]
	hit_normal = saved[1]
	cam.global_transform = saved[2]


## --perf: 8 hits (1.2 m apart) x PERF_CES, deterministic seeds, 120 fixed 60 Hz steps; logs the GDScript cost per
## frame by phase (DI2Particles.prof), the live particle count and state / draw checksums (equal before and after a
## behaviour-preserving optimisation).
const PERF_CES := ["CE_Sharp_Medium_Normal", "CE_Sharp_Crit_Normal", "CE_Stab_Medium"]

func _perf() -> void:
	if OS.get_cmdline_user_args().has("--gd"):
		DI2Particles.use_rust = false  # A/B: the GDScript simulation
	log_lines.append("perf: simulation %s" % ("Rust (DI2ParticleSim)" if DI2Particles.use_rust and ClassDB.class_exists("DI2ParticleSim") else "GDScript"))
	if ClassDB.class_exists("DI2ParticleSim"):
		# the Rust PCG port must draw Godot's RandomNumberGenerator.randf() sequence exactly
		var g := RandomNumberGenerator.new()
		g.seed = 987654321
		var rs: PackedFloat64Array = ClassDB.instantiate("DI2ParticleSim").rng_test(987654321, 64)
		var same := 0
		for k in 64:
			if g.randf() == rs[k]:
				same += 1
		log_lines.append("perf: RNG port %d / 64 randf() values identical" % same)
		var g2 := RandomNumberGenerator.new()
		g2.seed = 987654321
		var line := "perf: rng godot / rust:"
		for k in 8:
			line += " %.9f/%.9f" % [g2.randf(), rs[k]]
		log_lines.append(line)
		var g3 := RandomNumberGenerator.new()
		g3.seed = 987654321
		var ints := "perf: rng godot randi:"
		for k in 6:
			ints += " %d" % g3.randi()
		log_lines.append(ints)
	DI2Particles.seed_override = 1000
	DI2Particles._seed_count = 0
	if OS.get_cmdline_user_args().has("--prewarm"):
		var pw0 := Time.get_ticks_usec()
		DI2Particles.prewarm(PERF_CES)
		log_lines.append("perf: prewarm of the 3 CEs took %.2f ms" % ((Time.get_ticks_usec() - pw0) / 1000.0))
	var nodes: Array = []
	var sp0 := Time.get_ticks_usec()
	for h in 8:
		var at := Vector3(-4.2 + h * 1.2, 1.4, -1.0)
		for ce in PERF_CES:
			DI2Particles.play_ce(main, ce, at, hit_normal, hit_dir)
			nodes.append_array(DI2Particles.last_spawned)
	log_lines.append("perf: spawning %d systems (24 CEs) took %.2f ms (cold: first use)" % [nodes.size(), (Time.get_ticks_usec() - sp0) / 1000.0])
	# the same 24 CEs again (warm: data, materials, textures cached), timed and freed (seeds continue, so the
	# checksummed set above is unchanged)
	var warm: Array = []
	var sp1 := Time.get_ticks_usec()
	for h in 8:
		for ce in PERF_CES:
			DI2Particles.play_ce(main, ce, Vector3(-4.2 + h * 1.2, 1.4, -3.0), hit_normal, hit_dir)
			warm.append_array(DI2Particles.last_spawned)
	log_lines.append("perf: spawning them again took %.2f ms (warm)" % ((Time.get_ticks_usec() - sp1) / 1000.0))
	for p in warm:
		p.queue_free()
	for p: DI2Particles in nodes:
		p.set_process(false)
	DI2Particles.prof = {"tick": 0, "events": 0, "render": 0}
	DI2Particles.prof_on = true
	DI2Particles.prof_fine = OS.get_cmdline_user_args().has("--perf-fine")
	var steps := 120
	var total := 0
	var peak := 0
	var parts := 0
	for k in steps:
		var s := Time.get_ticks_usec()
		for p in nodes:
			if is_instance_valid(p):
				p.advance(DT)
		var us := Time.get_ticks_usec() - s
		total += us
		peak = maxi(peak, us)
		for p in nodes:
			if is_instance_valid(p):
				for e in p.emitters:
					parts += e.n
		if k % 30 == 0:
			await RenderingServer.frame_post_draw
	DI2Particles.prof_on = false
	DI2Particles.prof_fine = false
	var cs := 0.0
	var rs := 0.0
	for p in nodes:
		if is_instance_valid(p):
			cs += p.checksum()
			rs += p.render_checksum()
	log_lines.append("perf: %d systems, %d steps: %.2f ms / frame (peak %.2f): tick %.2f, events %.2f, render %.2f; avg %d live particles" % [
		nodes.size(), steps, total / 1000.0 / steps, peak / 1000.0, DI2Particles.prof["tick"] / 1000.0 / steps,
		DI2Particles.prof["events"] / 1000.0 / steps, DI2Particles.prof["render"] / 1000.0 / steps, parts / steps])
	log_lines.append("perf: state checksum %.6f, draw checksum %.4f" % [cs, rs])
	var keys := DI2Particles.prof.keys()
	keys.sort_custom(func(a, b): return DI2Particles.prof[a] > DI2Particles.prof[b])
	for k in keys:
		log_lines.append("  %-28s %.3f ms / frame" % [k, DI2Particles.prof[k] / 1000.0 / steps])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("perf.png"))


func _save_log() -> void:
	FileAccess.open(out_dir.path_join("particles.log"), FileAccess.WRITE).store_string("\n".join(log_lines))
