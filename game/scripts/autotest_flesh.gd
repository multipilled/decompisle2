extends Node
## DI2 FLESH check: `godot --path game -- --fleshtest=<out_dir>`
## Hits a Walker through Zombie.take_hit with each DI2 hit family (blunt / sharp / stab / bullet / shotgun / kick /
## counter kill), at full health and near death, and logs what the weapon's HitEffectTree picked, the stamps added
## and the progressive-damage state; a close-up per case (out_dir/flesh.log, <case>.png).

var out_dir := ""
var main: Main
var p: Player
var cam: Camera3D
var log_lines: PackedStringArray = []

## [name, weapon, bone, health fraction before the hit, damage, extra hit facts, view side]
const CASES := [
	["blunt_torso_full", "bat", "spine_03", 1.0, 25.0, {}, 0.0],
	["blunt_torso_neardeath", "bat", "spine_03", 0.3, 25.0, {}, 0.0],
	["blunt_head_heavy", "bat", "head", 1.0, 50.0, {"HeavyAttack": true}, 0.0],
	["sharp_torso_full", "machete", "spine_03", 1.0, 21.0, {}, 0.0],
	["sharp_torso_neardeath", "machete", "spine_03", 0.25, 21.0, {}, 0.0],
	["sharp_head_crit", "machete", "head", 1.0, 27.0, {"CriticalHit": true}, 0.0],
	["stab_torso", "dagger", "spine_03", 0.4, 20.0, {}, 0.0],
	["bullet_torso", "pistol", "spine_03", 1.0, 23.0, {}, 0.0],
	["bullet_head", "pistol", "head", 1.0, 23.0, {}, 0.0],
	["bullet_torso_exit", "pistol", "spine_03", 1.0, 23.0, {}, PI],
	["shotgun_torso", "shotgun", "spine_03", 1.0, 15.0, {}, 0.0],
	["kick_torso", "", "spine_03", 1.0, 10.0, {"tree": "CT_HitEffect_Kick"}, 0.0],
	["counter_kill_machete", "machete", "head", 0.1, 60.0, {"isPaired": true, "CounterKill": true}, 0.0],
	["blunt_fire_mod", "bat", "spine_03", 0.5, 25.0, {"mod": "fire"}, 0.0],
]


func _ready() -> void:
	main = get_parent()
	p = main.player
	DirAccess.make_dir_recursive_absolute(out_dir)
	# Watchdog: never outlive a stuck case.
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		log_lines.append("WATCHDOG: timed out")
		FileAccess.open(out_dir.path_join("flesh.log"), FileAccess.WRITE).store_string("
".join(log_lines))
		get_tree().quit(1))
	main.hud.visible = false
	cam = Camera3D.new()
	cam.fov = 45.0
	main.add_child(cam)
	_spawn_rotation_check()
	await _wait(0.5)
	await _spawn_look()
	await _parts_check()
	await _break_check()
	await _prespawn_check()
	await _explosion_check()
	await _status_check()
	await _accumulate_check()
	await _debuff_check()
	await _particle_dir_check()
	await _fluid_check()
	await _petrol_check()
	await _cut_check()
	await _bisect_check()
	await _corpse_check()
	await load("res://scripts/autotest_archetypes.gd").new().run(self)   # special-archetype bodies (recon/ARCHETYPES.md)
	await _perf_check()
	var first := true
	for c: Array in CASES:
		await _case(c)
		if first:
			first = false
			_dump()
	var f := FileAccess.open(out_dir.path_join("flesh.log"), FileAccess.WRITE)
	f.store_string("\n".join(log_lines))
	get_tree().quit()


func _case(c: Array) -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var maxh := z.gore.get_max_health()
	var dmg: float = c[4]
	z.gore.set_health(maxf(maxh * float(c[3]), dmg * 1.6))
	var b := z.skeleton.find_bone(c[2])
	var bone_pos := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	var from := bone_pos + Vector3(0, 0.05, 1.2)  # the zombie faces +Z (the camera side)
	var into := (bone_pos - from).normalized()
	var swing := Vector3.RIGHT
	var weapon: String = c[1]
	var spec := Flesh.weapon(weapon)
	var kind: String = spec.get("damage_type", "blunt") if weapon != "" else "blunt"
	var hit: Dictionary = (c[5] as Dictionary).duplicate()
	hit["weapon"] = weapon
	if spec.get("kind", "") == "melee":
		hit["align"] = into  # blade pointing at the target: DI2's SourceObjectAlignment for a side swing
	var before := z.gore.stamp_count()
	var res := z.take_hit(c[2], bone_pos, swing, into, dmg, kind, bool(hit.get("HeavyAttack", false)), 1.0, 0.0, Vector3.ZERO, p, hit)
	var fl: Dictionary = z.flesh_log.back() if not z.flesh_log.is_empty() else {}
	var names := []
	for e: Array in fl.get("effects", []):
		names.append("%s(%.1f)" % [e[0], e[1]])
	log_lines.append("%-24s %-8s %-9s tree=%s part=%s health=%.2f dmg=%.2f stamps+%d (total %d) exact=%s particles=%d\n    effects: %s" % [
		c[0], weapon, c[2], fl.get("tree", "-"), fl.get("part", ""), fl.get("state", {}).get("health", -1.0),
		fl.get("state", {}).get("damage", -1.0), z.gore.stamp_count() - before, z.gore.stamp_count(), res.get("exact", false), int(fl.get("particles", 0)), ", ".join(names)])
	await _wait(0.05)
	z.anim.pause()
	await _wait(0.9)  # let the hit particles fall out of the close-up
	var point: Vector3 = res.get("point", bone_pos)
	var side: float = c[6]
	var view := Vector3(sin(side), 0.0, cos(side)) * 0.75 + Vector3(0.12, 0.08, 0.0)
	cam.global_position = point + view
	cam.look_at(point, Vector3.UP)
	cam.current = true
	await _wait(0.15)
	await _shot(c[0])
	var vs := []
	for k in z.viscera_state:
		vs.append("%s=%.1f%s" % [k.get_slice(".", k.get_slice_count(".") - 1), z.viscera_state[k]["damage"], " k%d" % z.viscera_state[k]["k"] if z.viscera_state[k]["k"] > 0 else ""])
	log_lines.append("    viscera: %s" % (", ".join(vs) if not vs.is_empty() else "-"))
	var bs: Dictionary = z.gore.splatter_stats()
	log_lines.append("    bake (%s): %d applications, %.1f ms CPU total, %.2f ms worst, %d target pairs (map %.1f, apply %.1f, dilate %.1f, deform %.1f, per-frame flush %.1f ms)" % ["GPU" if bs.get("gpu", false) else "CPU", bs["applications"], bs["total_ms"], bs["max_ms"], bs["sections"], bs["map_ms"], bs["apply_ms"], bs["dilate_ms"], bs["deform_ms"], bs["flush_ms"]])


## HitEffectSpawn against DI2's point / radial impact rotation (exe 0x1414810b0 / 0x1413d0880): factor 1 faces
## the travel direction with roll 0, factor 0 faces the impact normal with Y perpendicular to the travel (UE Y is
## the Godot basis' z column: DI2Particles.u2g_basis swaps Y / Z), a missing
## travel direction falls back to the normal, and a radial impact faces away from the origin.
func _spawn_rotation_check() -> void:
	var n := Vector3(0, 0, 1)
	var d := Vector3(1, 0, -1).normalized()
	var fails := []
	var b1 := HitEffectSpawn.point_basis(n, d, 1.0)
	if not b1.x.is_equal_approx(d):
		fails.append("factor 1 X %s != travel %s" % [b1.x, d])
	var b0 := HitEffectSpawn.point_basis(n, d, 0.0)
	if not b0.x.is_equal_approx(n) or absf(b0.z.dot(d)) > 1e-4:
		fails.append("factor 0 X %s / Y.travel %.4f" % [b0.x, b0.z.dot(d)])
	var bh := HitEffectSpawn.point_basis(n, d, 0.5)
	var mid := HitEffectSpawn._normalized(HitEffectSpawn._slerp_not_normalized(
		HitEffectSpawn._orient_quat(DI2Particles.g2u_dir(n)), HitEffectSpawn._orient_quat(DI2Particles.g2u_dir(d)), 0.5))
	if not bh.x.is_equal_approx(DI2Particles.u2g_dir(HitEffectSpawn._axis_x(mid))) or absf(bh.z.dot(d)) > 1e-4:
		fails.append("factor 0.5 X %s / Y.travel %.4f" % [bh.x, bh.z.dot(d)])
	if not HitEffectSpawn.point_basis(n, Vector3.ZERO, 0.9).x.is_equal_approx(n):
		fails.append("no travel: not the normal")
	if not HitEffectSpawn.radial_basis(Vector3(2, 1, 0), Vector3(0, 1, 0)).x.is_equal_approx(Vector3.RIGHT):
		fails.append("radial: not away from the origin")
	for b: Basis in [b1, b0, bh]:
		if not b.is_conformal() or absf(b.determinant() - 1.0) > 1e-4:
			fails.append("not a rotation: %s" % b)
	log_lines.append("spawn_rotation_check: %s" % ("ok" if fails.is_empty() else ", ".join(fails)))
	for f: String in fails:
		push_error("SCRIPT ERROR: spawn_rotation_check: " + f)


## DI2's starting look (initial splatter set from the mesh's CharacterInitialState), full body front and back.
func _spawn_look() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var bs: Dictionary = z.gore.splatter_stats()
	log_lines.append("spawn_look: initial splatter %s, stamps %d; bake %d applications %.1f ms total %.2f ms worst, %d target pairs" % [
		z.initial_splatter, z.gore.stamp_count(), bs["applications"], bs["total_ms"], bs["max_ms"], bs["sections"]])
	var mid := z.global_position + Vector3(0, 1.0, 0)
	for side in [0.0, PI]:
		cam.global_position = mid + Vector3(sin(side), 0.0, cos(side)) * 2.4
		cam.look_at(mid, Vector3.UP)
		cam.current = true
		await _wait(0.15)
		await _shot("spawn_look_front" if side == 0.0 else "spawn_look_back")
	# Eye close-ups (M_EyeRefractive + M_EyeOcclusion), straight on and from the side (iris parallax).
	var sk: Skeleton3D = z.skeleton
	var hb := sk.find_bone("head")
	if hb >= 0:
		var eyes := sk.global_transform * (sk.get_bone_global_pose(hb).origin) + Vector3(0, 0.0, 0.08)
		for view in [["eyes_front", Vector3(0, -0.02, 0.32)], ["eyes_side", Vector3(0.22, -0.02, 0.22)]]:
			cam.global_position = eyes + view[1]
			cam.look_at(eyes, Vector3.UP)
			await _wait(0.15)
			await _shot(view[0])


## DI2 viscera / spawnable parts: a counter Action CE culls subsections and spawns / detaches parts on a live zombie.
func _parts_check() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var names := z.gore.subsection_names()
	z.apply_part_effects([["CE_Zombie_Counter_M_1H_Slicing_Action", 0.0]])
	var states := {}
	for slot in z.parts:
		var st: Dictionary = z.parts[slot]
		states[slot] = "spawned=%s detached=%s deleted=%s" % [st.get("spawned"), st.get("detached"), st.get("deleted")]
	log_lines.append("parts_check: %d subsections on the body; after CE_Zombie_Counter_M_1H_Slicing_Action: %s, facts %s" % [names.size(), states, z.part_facts])
	await _wait(0.6)
	var sk: Skeleton3D = z.skeleton
	var hb := sk.find_bone("head")
	if hb >= 0:
		var head := sk.global_transform * (sk.get_bone_global_pose(hb).origin) + Vector3(0, 0.0, 0.08)
		for view in [["parts_front", Vector3(0, -0.02, 0.4)], ["parts_side", Vector3(0.3, -0.02, 0.28)]]:
			cam.global_position = head + view[1]
			cam.look_at(head, Vector3.UP)
			await _wait(0.15)
			await _shot(view[0])
	z.queue_free()


## DI2 bone break: heavy blunt hits on the right forearm until it breaks (GoreBody.di2_break re-skins it).
func _break_check() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var sk: Skeleton3D = z.skeleton
	var b := sk.find_bone("lowerarm_r")
	var p := sk.global_transform * sk.get_bone_global_pose(b).origin
	var spine := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
	var side := Vector3(p.x - spine.x, 0.0, p.z - spine.z).normalized()
	for i in 6:
		if not z.break_points.is_empty() or z.dead:
			break
		var from := p + side * 0.5 + Vector3(0, 0.05, 0)   # from the arm's outer side
		var r := z.take_hit("lowerarm_r", p, Vector3.LEFT, (p - from).normalized(), 25.0, "blunt", true, 1.5, 40.0, Vector3.ZERO, null, {"weapon": "baseball_bat_metal", "HeavyAttack": true})
		log_lines.append("  break hit %d: bone %s outcomes %s" % [i, r.get("bone", "?"), (r.get("outcomes", []) as Array).map(func(o): return o.get("type", "") + ":" + str(o.get("part", "")))])
		await _wait(0.1)
	log_lines.append("break_check: break_points %s, broken %s" % [z.break_points, z.gore.broken_bones()])
	cam.global_position = p + side * 0.55 + Vector3(0, 0.1, 0.2)
	cam.look_at(p, Vector3.UP)
	await _wait(0.3)
	await _shot("break_forearm")
	z.queue_free()


## DI2 pre-spawn missing limbs: Walkers spawned with the spawner's facts (DA_AnimSet_PreSpawnSplatter_Walker) get
## their SplatterSet's Dismember entries cut at spawn (no piece, no hitboxes on the missing limb).
func _prespawn_check() -> void:
	for facts: Dictionary in [{"PreSpawnSplatter_LeftArmMissing": true}, {"PreSpawnSplatter_BothLegsMissing": true}]:
		for n in get_tree().get_nodes_in_group("zombies"):
			n.remove_from_group("zombies")
			n.queue_free()
		var z := Zombie.new()
		z.archetype = "Walker"
		z.spawn_facts = facts
		z.add_to_group("zombies")
		main.add_child(z)
		z.global_position = Vector3(0, 0.1, -2.0)
		z.rotation.y = PI
		z.gore.set_health(3000.0)
		await _wait(0.6)
		var hb := z.hitboxes.map(func(a): return str(a.get_meta("bone")))
		log_lines.append("prespawn %s: cuts %s, crawling %s, arms usable l=%s r=%s, hitboxes %s" % [facts.keys(),
			z.prespawn_cuts.map(func(c: int) -> String: return z.skeleton.get_bone_name(c)), z.gore.is_crawling(),
			z.gore.arm_usable(true), z.gore.arm_usable(false), hb])
		for e in z.flesh_log.filter(func(x): return x.has("limb_cut")):
			log_lines.append("  limb_cut %s: body culled %s" % [e["limb_cut"], e["culled"]["body"]])
		z.anim.pause()
		var sk: Skeleton3D = z.skeleton
		var c := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
		var key := "prespawn_" + str(facts.keys()[0]).trim_prefix("PreSpawnSplatter_").to_lower()
		for view in [["front", Vector3(0, 0.0, 1.6)], ["side", Vector3(1.4, 0.0, 0.6)]]:
			cam.global_position = c + view[1]
			cam.look_at(c, Vector3.UP)
			await _wait(0.15)
			await _shot(key + "_" + view[0])
		z.queue_free()


## DI2 pipe bomb (DA_ExplosionArchetype_PipeBomb through DI2Explosion): Walkers at 1, 2.5 and 3.8 m, normal health.
func _explosion_check() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	p.global_position = Vector3(0, 0.1, 6.0)
	var origin := Vector3(0, 0.15, -2.0)
	var zs: Array[Zombie] = []
	for dx in [1.0, 2.5, 3.8]:
		var z := main.spawn_zombie(origin + Vector3(dx, -0.05, 0), "Walker") as Zombie
		z.target = null
		z.rotation.y = -PI / 2   # facing the bomb
		zs.append(z)
	await _wait(0.6)
	for z in zs:
		z.anim.pause()
	var e := DI2Explosion.spawn(main, "PipeBomb", origin, null, 1.0)
	var hits: Array = await e.finished
	for h: Array in hits:
		log_lines.append("  explosion hit %s: d %.2f m x %.2f damage %.1f stability %.1f impulse %.0f occlusion %.2f" % h)
	await _wait(0.4)
	for z in zs:
		var outs := []
		for o in z.flesh_log:
			if o.has("tree"):
				outs.append([o["tree"], (o["effects"] as Array).map(func(x): return x[0]), o["stamps"]])
		log_lines.append("explosion victim %s: alive %s health %.1f severed %s crawling %s flesh %s" % [z.name, not z.dead,
			z.gore.get_health(), z.flesh_log.filter(func(x): return x.has("di2_cut")).map(func(x): return x["di2_cut"]), z.gore.is_crawling(), outs])
	cam.global_position = origin + Vector3(2.4, 1.2, 3.6)
	cam.look_at(origin + Vector3(2.0, 0.6, 0), Vector3.UP)
	await _wait(0.3)
	await _shot("explosion_pipebomb")
	await _wait(1.2)
	await _shot("explosion_pipebomb_late")
	for z in zs:
		if is_instance_valid(z):
			z.queue_free()
	# DI2's molotov: DA_ExplosionArchetype_Molotov's first Burning 1.0 fills the meter (Burning begins), its second
	# (CanExtendEffectDuration) pauses the drain: "paused" with a full meter.
	var zm := _fresh(origin + Vector3(1.5, -0.05, 0))
	await _wait(0.4)
	var em := DI2Explosion.spawn(main, "Molotov", origin, null, 1.0)
	await em.finished
	var ms: Dictionary = zm.gore.accumulating_state("Burning")
	log_lines.append("molotov: burning %s, health %.1f, statuses %s" % [ms, zm.gore.get_health(), zm.gore.status_states()])
	if ms.get("state", "") != "paused" or float(ms.get("meter", 0.0)) < 0.999:
		push_error("SCRIPT ERROR: molotov did not begin Burning: %s" % ms)
	await _wait(0.6)
	await _shot("explosion_molotov")


## DI2's hit-effect spawn rotation on screen (HitEffectSpawn): a bat swing travelling +X (screen right) plays
## CE_Blunt_Medium_Normal at factor 0.9, so its spray leaves along the swing, mostly to the right; a pistol shot
## (factor 1) sprays along the bullet, away from the camera. Captured 0.12 s after each hit.
func _particle_dir_check() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var b := z.skeleton.find_bone("spine_03")
	var at := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	cam.global_position = at + Vector3(0.0, 0.15, 1.6)
	cam.look_at(at, Vector3.UP)
	cam.current = true
	var swing := Vector3.RIGHT
	z.take_hit("spine_03", at + Vector3(0, 0, 0.15), swing, Vector3(0, 0, -1), 25.0, "blunt", false, 1.0, 0.0, Vector3.ZERO, p,
		{"weapon": "bat", "align": Vector3(0, 0, -1)})
	await _wait(0.12)
	await _shot("particles_bat_swing_right")
	var fl: Dictionary = z.flesh_log.back() if not z.flesh_log.is_empty() else {}
	log_lines.append("particle_dir_check: bat swing +X played %d CEs %s" % [int(fl.get("particles", 0)), fl.get("effects", [])])
	await _wait(1.0)
	var z2 := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z2.anim.pause()
	at = z2.skeleton.global_transform * z2.skeleton.get_bone_global_pose(b).origin
	cam.global_position = at + Vector3(1.4, 0.2, 0.6)
	cam.look_at(at, Vector3.UP)
	z2.take_hit("spine_03", at + Vector3(0, 0, 0.15), Vector3(0, 0, -1), Vector3(0, 0, -1), 20.0, "projectile", false, 1.0, 0.0, Vector3.ZERO, p,
		{"weapon": "pistol"})
	await _wait(0.12)
	await _shot("particles_pistol_side_view")


## DI2's fluids (DI2Fluids, recon/RE_FLUIDS.md §5) for Blood (MinRadius 20, MaxRadius 55, VisualRadiusMultiplier
## 1.75, StartingDecalRadiusMultiplierIfActorIsImpact 0.3, idle 10 s, EvaporationAreaPerSec 50, Curve_FluidConsumption
## 1 at R <= 40): a new puddle, a merge (R = sqrt(R^2 + r^2)), a miss, the MaxRadius cap, evaporation from 10 s idle at
## sqrt(50 / pi) / R per second and the restore an addition triggers, on a detached manager; then a bat hit's CE blood
## (CE_Blunt_Medium_Normal: 225 cm/s x 25 along the swing + one 375 cm/s x 10 in a 15 degree burst) landing as
## puddles on the floor (capture fluids_bat_puddles).
func _fluid_check() -> void:
	var fails := []
	var m := DI2Fluids.new()
	m._payload("Blood", Vector3.ZERO, Vector3.UP, 10.0)
	if m.puddles.size() != 1:
		fails.append("no first puddle")
	else:
		var p0: Dictionary = m.puddles[0]
		if absf(float(p0["radius"]) - 20.0) > 1e-4 or absf(float(p0["visual"]) - 0.3 * 20.0 * 1.75) > 1e-4:
			fails.append("new puddle R %.2f visual %.2f" % [p0["radius"], p0["visual"]])
		m._payload("Blood", Vector3(0.15, 0, 0), Vector3.UP, 15.0)
		if m.puddles.size() != 1 or absf(float(p0["radius"]) - 25.0) > 1e-3:
			fails.append("merge: %d puddles, R %.2f (want 1, 25)" % [m.puddles.size(), p0["radius"]])
		m._payload("Blood", Vector3(0.6, 0, 0), Vector3.UP, 30.0)
		if m.puddles.size() != 2:
			fails.append("out of reach merged (%d puddles)" % m.puddles.size())
		for i in 3:
			m._payload("Blood", Vector3.ZERO, Vector3.UP, 40.0)
		if absf(float(p0["radius"]) - 55.0) > 1e-3:
			fails.append("cap: R %.2f" % p0["radius"])
		var p1: Dictionary = m.puddles[1] if m.puddles.size() > 1 else {}
		var t := 0.0
		var gone1 := -1.0
		var restored := false
		while t < 19.0:
			m._tick_puddles(0.05)
			t += 0.05
			if absf(t - 10.1) < 0.025 and not ((int(p0["evap_flags"]) != 0) and absf(float(p0["rate"]) - sqrt(50.0 / PI) / 55.0) < 1e-5):
				fails.append("evaporation at 10.1 s: %s rate %.5f" % [(int(p0["evap_flags"]) != 0), p0["rate"]])
			if absf(t - 12.0) < 0.025:
				m._payload("Blood", Vector3.ZERO, Vector3.UP, 5.0)
				if (int(p0["evap_flags"]) != 0) or not p0["restoring"]:
					fails.append("addition didn't restore")
			if gone1 < 0.0 and not m.puddles.has(p1):
				gone1 = t
		restored = float(p0["opacity"]) > 0.99 and not (int(p0["evap_flags"]) != 0)
		# p1 (R 30): opacity 1 -> 0 at sqrt(50 / pi) / 30 per second from 10 s.
		var want1 := 10.0 + 30.0 / sqrt(50.0 / PI)
		if absf(gone1 - want1) > 0.2:
			fails.append("R 30 puddle gone at %.2f s (want %.2f)" % [gone1, want1])
		if not restored:
			fails.append("restore: opacity %.3f evaporating %s" % [p0["opacity"], (int(p0["evap_flags"]) != 0)])
		if absf(float(p0["visual"]) - 1.75 * 55.0) > 0.5:
			fails.append("visual radius %.2f (want %.2f)" % [p0["visual"], 1.75 * 55.0])
	m.free()
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	z.anim.pause()
	var fm := DI2Fluids.of(main)
	var b := z.skeleton.find_bone("spine_03")
	var at := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	z.take_hit("spine_03", at + Vector3(0, 0, 0.15), Vector3.RIGHT, Vector3(0, 0, -1), 25.0, "blunt", false, 1.0, 0.0, Vector3.ZERO, p,
		{"weapon": "bat", "align": Vector3(0, 0, -1)})
	var flew := fm.drops.size()
	var first: Vector3 = fm.drops[0]["vel"] if flew > 0 else Vector3.ZERO
	await _wait(2.0)
	var where := []
	for q: Dictionary in fm.puddles:
		where.append("%s R%.0f" % [(q["pos"] as Vector3).snapped(Vector3.ONE * 0.01), q["radius"]])
	if flew != 2 or not first.normalized().is_equal_approx(Vector3.RIGHT) or absf(first.length() - 2.25) > 1e-3:
		fails.append("droplets: %d, first velocity %s (want 2, 2.25 m/s along +X)" % [flew, first])
	if fm.puddles.is_empty() or not fm.drops.is_empty():
		fails.append("%d puddles, %d droplets still flying" % [fm.puddles.size(), fm.drops.size()])
	log_lines.append("fluid_check: bat hit %d droplets -> puddles %s" % [flew, where])
	# The fluid map (DI2's fluid buffer): each puddle's coverage at its centre texel, read back from the viewport.
	if fm._vp:
		await RenderingServer.frame_post_draw
		var img := fm._vp.get_texture().get_image()
		var covs := []
		for q: Dictionary in fm.puddles:
			var qp: Vector3 = q["pos"]
			var px := Vector2i(((Vector2(qp.x, qp.z) - DI2Fluids.map_area.position) / DI2Fluids.MAP_TEXEL).floor())
			covs.append(snappedf(img.get_pixelv(px).a, 0.01) if Rect2i(Vector2i.ZERO, img.get_size()).has_point(px) else -1.0)
		log_lines.append("fluid_check: fluid map %s, centre coverage %s" % [img.get_size(), covs])
		if covs.is_empty() or covs.any(func(c: float) -> bool: return c < 0.3):
			fails.append("fluid map coverage at the puddles %s" % [covs])
	var c := at + Vector3(0.8, -at.y, 0.0)
	cam.global_position = c + Vector3(0.0, 1.6, 1.4)
	cam.look_at(c, Vector3.UP)
	cam.current = true
	await _wait(0.6)
	await _shot("fluids_bat_puddles")
	log_lines.append("fluid_check: %s" % ("ok" if fails.is_empty() else ", ".join(fails)))
	for f: String in fails:
		push_error("SCRIPT ERROR: fluid_check: " + f)


## DI2's status build-up (AccumulatingEffects + GoreBody.accumulate, recon/RE_ACCUMULATING.md): a level-1 fire mod
## adds 0.3 Burning per hit (DA_WeaponModConfig_Default), so the 4th light hit begins Burning; heavy hits add 0.25
## more (2 hits); a zombie 2 levels above the weapon scales it by Curve_AccumulatingEffectsLevelScaling(2) = 0.65.
func _accumulate_check() -> void:
	var fails := []
	var light := AccumulatingEffects.mod_effects("fire", 1, false, {"Hit.HeavyAttack": false})
	var heavy := AccumulatingEffects.mod_effects("fire", 1, false, {"Hit.HeavyAttack": true})
	if light.size() != 1 or absf(float(light[0]["value"]) - 0.3) > 1e-4 or absf(float(heavy[0]["value"]) - 0.55) > 1e-4:
		fails.append("mod values %s / %s" % [light, heavy])
	if absf(AccumulatingEffects.level_scale(3, 1) - 0.65) > 1e-4 or AccumulatingEffects.level_scale(1, 4) != 1.0:
		fails.append("level curve %.3f / %.3f" % [AccumulatingEffects.level_scale(3, 1), AccumulatingEffects.level_scale(1, 4)])
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.3)
	z.gore.set_health(5000.0)
	var began := []
	for i in 4:
		began.append(z.accumulate(light, z.level, true))
	var st: Dictionary = z.gore.accumulating_state("Burning")
	if began.slice(0, 3).any(func(b): return not (b as Array).is_empty()) or began[3] != ["burning"] or st.get("state") != "active":
		fails.append("light hits: began %s, state %s" % [began, st])
	var z2 := _fresh(Vector3(1.5, 0.1, -2.0))
	await _wait(0.3)
	var b2 := [z2.accumulate(heavy, z2.level, true), z2.accumulate(heavy, z2.level, true)]
	if not (b2[0] as Array).is_empty() or b2[1] != ["burning"]:
		fails.append("heavy hits: %s" % [b2])
	z2.level = z2.level + 2
	z2.accumulate([{"type": "Corroded", "value": 0.3}], z2.level - 2, true)
	if absf(float(z2.gore.accumulating_state("Corroded").get("meter", 0.0)) - 0.195) > 1e-3:
		fails.append("level-scaled corroded %s" % z2.gore.accumulating_state("Corroded"))
	log_lines.append("accumulate_check: %s" % ("ok" if fails.is_empty() else ", ".join(fails)))
	for f: String in fails:
		push_error("SCRIPT ERROR: accumulate_check: " + f)


## DI2 elemental statuses on Walkers: burning and corroded spread over the body nodes (DamagePropagation, the
## *_Propagation CEs' splatter); electrocuted gets CE_StatusEffect_Electrocute at spine_01.
func _status_check() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	p.global_position = Vector3(0, 0.1, 6.0)
	var zs: Array[Zombie] = []
	var kinds := ["fire", "acid", "electric"]
	for k in kinds.size():
		var z := main.spawn_zombie(Vector3(-1.4 + k * 1.4, 0.1, -2.0), "Walker") as Zombie
		z.target = null
		z.rotation.y = PI
		zs.append(z)
	await _wait(0.6)
	for k in kinds.size():
		var z := zs[k]
		z.gore.set_health(3000.0)
		z.anim.pause()
		var sk: Skeleton3D = z.skeleton
		var bone := "spine_03" if k != 0 else "thigh_l"
		var at := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin
		var dir := Vector3(0, 0, -1)
		var r := z.take_hit(bone, at, dir, dir, 90.0, kinds[k], false, 1.0, 0.0, Vector3.ZERO, p)
		# DI2's build-up: two Molotov-strength applications (Burning / Corroded / Electrocuted 1.0) fill the meter.
		var began: Array = z.accumulate([{"type": AccumulatingEffects.TYPE_FOR_KIND[kinds[k]], "value": 1.0}], z.level, false, at, bone)
		r["outcomes"] = (r.get("outcomes", []) as Array) + began.map(func(st): return {"type": "status", "status": st})
		log_lines.append("status %s on %s: outcomes %s" % [kinds[k], bone, (r.get("outcomes", []) as Array).map(func(o): return o.get("type", "") + ":" + str(o.get("status", o.get("part", ""))))])
	await _wait(2.5)
	for k in kinds.size():
		var z := zs[k]
		var props := z.flesh_log.filter(func(x): return x.has("propagation"))
		log_lines.append("status %s: %d propagation CEs %s, states %s" % [kinds[k], props.size(),
			props.map(func(x): return "%s@%s(%d)" % [x["node"], x["bone"], x["stamps"]]), z.gore.status_states()])
	var c := Vector3(0, 1.0, -2.0)
	cam.global_position = c + Vector3(0, 0.1, 3.4)
	cam.look_at(c, Vector3.UP)
	await _wait(0.2)
	await _shot("status_front")
	cam.global_position = c + Vector3(0, 0.1, -3.4)
	cam.look_at(c, Vector3.UP)
	await _wait(0.2)
	await _shot("status_back")
	for z in zs:
		z.queue_free()


## A live DI2 limb cut (machete through the left forearm): GoreBody.di2_cut, then UVisceraComponent::LimbCut culling
## the arm's skeleton proxies per CutBias and spawning the straddlers' gibs.
func _cut_check() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	p.global_position = Vector3(0, 0.1, 6.0)
	var z := main.spawn_zombie(Vector3(0, 0.1, -2.0), "Walker") as Zombie
	z.target = null
	z.rotation.y = PI
	await _wait(0.6)
	z.anim.pause()
	var sk: Skeleton3D = z.skeleton
	var b := sk.find_bone("lowerarm_l")
	var at := sk.global_transform * sk.get_bone_global_pose(b).origin
	var fm := DI2Fluids.of(main)
	fm.clear()
	var r := z.take_hit("lowerarm_l", at, Vector3.RIGHT, Vector3(0, 0, -1), 80.0, "sharp", true, 1.5, 40.0, Vector3.ZERO, p,
		{"weapon": "machete", "HeavyAttack": true})
	# DI2's dismember gradual effect (Dismember_AI): PS_Blood_Heavy_Dismemberment at the wound and InitialEffect's 50
	# blood dropped from the hit location with zero velocity (0x14129a8e0).
	var wound_ps := z.skeleton.find_children("*", "DI2Particles", true, false).filter(func(n: Node) -> bool: return (n as DI2Particles).ps_name == "PS_Blood_Heavy_Dismemberment")
	var dropped := fm.drops.filter(func(d: Dictionary) -> bool: return (d["vel"] as Vector3).is_zero_approx() and is_equal_approx(float(d["radius"]), 50.0))
	log_lines.append("cut_check: gradual PS %d, initial wound fluid %d (of %d droplets)" % [wound_ps.size(), dropped.size(), fm.drops.size()])
	if z.flesh_log.any(func(e: Dictionary) -> bool: return e.get("effect", "") == "DA_GradualDamageEffect_Dismember_AI") and (wound_ps.is_empty() or dropped.size() != 1):
		push_error("SCRIPT ERROR: cut_check: Dismember_AI wound PS %d / initial fluid %d (want 1 / 1)" % [wound_ps.size(), dropped.size()])
	log_lines.append("cut_check: outcomes %s" % [(r.get("outcomes", []) as Array).map(func(o): return o.get("type", "") + ":" + str(o.get("bone", o.get("part", ""))))])
	for e in z.flesh_log:
		if e.has("di2_cut") or e.has("gib"):
			log_lines.append("  %s" % [e])
		elif e.has("limb_cut"):
			log_lines.append("  limb_cut %s: body culled %s, limb culled %d proxies" % [e["limb_cut"], e["culled"]["body"], (e["culled"]["limb"] as Array).size()])
	# Debug: the severed piece's materials (the last RigidBody3D under main).
	var rbs := main.get_children().filter(func(x): return x is RigidBody3D)
	if not rbs.is_empty():
		for mi: MeshInstance3D in Util.find_all(rbs.back(), "MeshInstance3D"):
			var parts := []
			for si in mi.get_surface_override_material_count():
				var m := mi.get_surface_override_material(si) as ShaderMaterial
				if m:
					parts.append("%d:lo=%s hi=%s di2=%s piece=%s hid=%s" % [si, m.get_shader_parameter("sub_hidden_lo"), m.get_shader_parameter("sub_hidden_hi"),
						m.get_shader_parameter("di2_cut"), m.get_shader_parameter("is_piece"), m.get_shader_parameter("section_hidden")])
			log_lines.append("  piece mesh %s: %s" % [mi.name, parts])
	await _wait(0.5)
	var c := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("upperarm_l")).origin
	cam.global_position = c + Vector3(-0.9, 0.1, 0.6)
	cam.look_at(c + Vector3(0, -0.3, 0), Vector3.UP)
	await _wait(0.2)
	await _shot("cut_forearm")
	z.queue_free()


## DI2 bisection: a Thug (its MultiPartHealth has Torso_Bisectable) killed by a machete through spine_03 once that
## part is at or below 65% health.
func _bisect_check() -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	p.global_position = Vector3(0, 0.1, 6.0)
	var z := main.spawn_zombie(Vector3(0, 0.1, -2.0), "Thug") as Zombie
	z.target = null
	z.rotation.y = PI
	await _wait(0.6)
	z.anim.pause()
	var sk: Skeleton3D = z.skeleton
	var at := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
	var dir := Vector3(1, 0, 0)
	# Wear the torso part down, then the killing blow.
	var tb: Dictionary = z.gore.part_states().get("Torso_Bisectable", {})
	log_lines.append("bisect_check: Torso_Bisectable %s" % [tb])
	z.take_hit("spine_03", at, dir, Vector3(0, 0, -1), float(tb.get("max", 100.0)) * 0.5, "sharp", false, 1.0, 10.0, Vector3.ZERO, p,
		{"weapon": "machete"})
	z.gore.set_health(1.0)
	var r := z.take_hit("spine_03", at, dir, Vector3(0, 0, -1), 60.0, "sharp", true, 1.0, 40.0, Vector3.ZERO, p,
		{"weapon": "machete", "HeavyAttack": true})
	log_lines.append("bisect_check: outcomes %s, part %s, log %s" % [(r.get("outcomes", []) as Array).map(func(o): return o.get("type", "")),
		z.gore.part_states().get("Torso_Bisectable", {}), z.flesh_log.filter(func(x): return x.has("bisected") or x.has("di2_cut") or x.has("limb_cut")).map(func(x): return x.get("bisected", x.get("di2_cut", "limb_cut:" + str(x.get("limb_cut", "")))))])
	await _wait(1.5)
	cam.global_position = at + Vector3(3.6, 1.6, 2.8)
	cam.look_at(at + Vector3(0, -0.8, 0), Vector3.UP)
	await _wait(0.2)
	await _shot("bisect_thug")
	cam.global_position = at + Vector3(-3.0, 1.2, -2.6)
	cam.look_at(at + Vector3(0, -0.8, 0), Vector3.UP)
	await _wait(0.2)
	await _shot("bisect_thug_back")


## Frame cost with 8 zombies in view: idle, then while every one's hit wounds animate (GPU bake + ticks).
## DI2 keeps processing hits on corpses (gore-core Body::apply_corpse_hit): a ragdolled Walker's forearm still
## dismembers under the machete, its health doesn't change and it gets no second death.
## Weakened (physical damage taken x 1.3, BP_StatusEffectParams_Weakened 0.3 on PhysicalDamageReceivedModifier) and
## Disoriented (stun: StopActions, its duration x U[0.85, 1.15]) through the accumulating meters.
func _debuff_check() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	var sk := z.skeleton
	var at := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
	var h0 := z.gore.get_health()
	z.take_hit("spine_03", at, Vector3.RIGHT, Vector3(0, 0, -1), 20.0, "blunt", false, 1.0, 1.0, Vector3.ZERO, p, {"weapon": "bat"})
	var plain := h0 - z.gore.get_health()
	z.accumulate([{"type": "Weakened", "value": 1.0}], z.level, false)
	var h1 := z.gore.get_health()
	z.take_hit("spine_03", at, Vector3.RIGHT, Vector3(0, 0, -1), 20.0, "blunt", false, 1.0, 1.0, Vector3.ZERO, p, {"weapon": "bat"})
	var weak := h1 - z.gore.get_health()
	z.accumulate([{"type": "Disoriented", "value": 1.0}], z.level, false)
	await _wait(0.3)
	var st: Dictionary = z.gore.status_states()
	var stop: bool = z.reactions.has_kb("StopActions")
	log_lines.append("debuff_check: blunt 20 -> %.2f plain, %.2f weakened (x%.3f); states %s, StopActions %s, clip %s" % [plain, weak,
		weak / maxf(plain, 1e-6), st, stop, z.reactions.clip])
	if absf(weak / maxf(plain, 1e-6) - 1.3) > 0.01 or not z.gore.is_status_active("disoriented") 			or float(st.get("disoriented", 0.0)) < 4.25 - 0.3 or float(st.get("disoriented", 0.0)) > 5.75:
		push_error("SCRIPT ERROR: debuff_check: x%.3f, states %s" % [weak / maxf(plain, 1e-6), st])
	await _wait(6.0)
	log_lines.append("debuff_check: after 6.3 s disoriented %s, StopActions %s" % [z.gore.is_status_active("disoriented"), z.reactions.has_kb("StopActions")])


func _corpse_check() -> void:
	var z := _fresh(Vector3(0, 0.1, -2.0))
	await _wait(0.4)
	var sk := z.skeleton
	var head := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("head")).origin
	z.take_hit("head", head, Vector3.RIGHT, Vector3(0, 0, -1), 5000.0, "blunt", true, 1.0, 20.0, Vector3.ZERO, p, {"weapon": "bat"})
	await _wait(1.5)
	var hp_dead := z.gore.get_health()
	var outs := []
	for i in 6:
		var b := sk.find_bone("lowerarm_l")
		var at := sk.global_transform * sk.get_bone_global_pose(b).origin
		var r := z.take_hit("lowerarm_l", at, Vector3.RIGHT, (at - (at + Vector3(0, 0.8, 0.8))).normalized(), 40.0, "sharp", false, 1.0, 15.0, Vector3.ZERO, p,
			{"weapon": "machete", "align": Vector3(0, -1, 0)})
		outs.append((r.get("outcomes", []) as Array).map(func(o): return str(o.get("type", ""))))
		if outs.back().has("dismembered"):
			break
		await _wait(0.2)
	var cut := outs.any(func(o): return (o as Array).has("dismembered"))
	log_lines.append("corpse_check: dead %s, outcomes %s, health %.1f -> %.1f, stamps %d" % [z.dead, outs, hp_dead, z.gore.get_health(), z.gore.stamp_count()])
	if not z.dead or not cut or z.gore.get_health() != hp_dead or outs.any(func(o): return (o as Array).has("killed")):
		push_error("SCRIPT ERROR: corpse_check: dead %s, outcomes %s" % [z.dead, outs])
	await _wait(0.6)
	var c := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("pelvis")).origin
	cam.global_position = c + Vector3(1.2, 1.6, 1.2)
	cam.look_at(c, Vector3.UP)
	await _wait(0.2)
	await _shot("corpse_dismembered")


func _perf_check() -> void:
	var zs: Array[Zombie] = [_fresh(Vector3(-1.8, 0.1, -3.0))]
	for i in range(1, 8):
		var z := main.spawn_zombie(Vector3((i % 4) * 1.2 - 1.8, 0.1, -3.0 - (i / 4) * 1.5), "Walker") as Zombie
		z.target = null
		z.rotation.y = PI
		z.gore.set_health(3000.0)
		zs.append(z)
	cam.global_position = Vector3(0, 1.6, 2.5)
	cam.look_at(Vector3(0, 1.0, -3.5), Vector3.UP)
	await _wait(1.0)
	var idle := await _measure(2.0)
	var g0 := 0.0
	var k0 := 0.0
	var d0 := 0.0
	for z in zs:
		var st0: Dictionary = z.gore.splatter_stats()
		g0 += float(st0["process_ms"])
		k0 += float(st0["skin_ms"])
		d0 += float(st0["deform_ms"])
	var a0 := Flesh.animator_ms
	for z in zs:
		var sk: Skeleton3D = z.skeleton
		var p := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
		z.take_hit("spine_03", p, Vector3.RIGHT, Vector3.FORWARD, 20.0, "sharp", false, 1.0, 15.0, Vector3.ZERO, null, {"weapon": "machete"})
	var hit := await _measure(2.0)
	var g1 := 0.0
	var k1 := 0.0
	var d1 := 0.0
	for z in zs:
		var st: Dictionary = z.gore.splatter_stats()
		g1 += float(st["process_ms"])
		k1 += float(st["skin_ms"])
		d1 += float(st["deform_ms"])
	var frames: float = float(hit[0]) * 2.0
	log_lines.append("perf_check: GoreBody.process %.2f ms / frame (all 8), animated-wound ticks %.2f ms / frame (of which skinning %.2f, deform %.2f)" % [(g1 - g0) / frames, (Flesh.animator_ms - a0) / frames, (k1 - k0) / frames, (d1 - d0) / frames])
	log_lines.append("perf_check (8 zombies): idle %.1f fps / %.2f ms process / %.2f ms physics; after hits %.1f fps / %.2f ms process / %.2f ms physics" % [idle[0], idle[1], idle[2], hit[0], hit[1], hit[2]])
	# The same hits without DI2 hit particles: what the particle systems cost.
	await _wait(4.0)
	log_lines.append("perf_check: fluids %d droplets / %d puddles" % [DI2Fluids.of(main).drops.size(), DI2Fluids.of(main).puddles.size()])
	Zombie.hit_particles = false
	Zombie.hit_fluids = false
	for z in zs:
		var sk2: Skeleton3D = z.skeleton
		var p2 := sk2.global_transform * sk2.get_bone_global_pose(sk2.find_bone("spine_02")).origin
		z.take_hit("spine_02", p2, Vector3.RIGHT, Vector3.FORWARD, 20.0, "sharp", false, 1.0, 15.0, Vector3.ZERO, null, {"weapon": "machete"})
	var hit_np := await _measure(2.0)
	Zombie.hit_particles = true
	Zombie.hit_fluids = true
	log_lines.append("perf_check (8 zombies): after hits without hit particles / fluids %.1f fps / %.2f ms process" % [hit_np[0], hit_np[1]])
	for z in zs:
		z.queue_free()


func _measure(seconds: float) -> Array:
	var frames := 0
	var proc := 0.0
	var phys := 0.0
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < int(seconds * 1e6):
		await get_tree().process_frame
		frames += 1
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var el := (Time.get_ticks_usec() - t0) / 1e6
	return [frames / el, proc / maxf(frames, 1), phys / maxf(frames, 1)]


## What the zombie's materials actually received (stamp uniforms, the data texture's first stamp, the texture array).
func _dump() -> void:
	var z: Zombie = get_tree().get_nodes_in_group("zombies")[0]
	var seen := 0
	for mi: MeshInstance3D in Util.find_all(z.visual, "MeshInstance3D"):
		for si in mi.get_surface_override_material_count():
			var m := mi.get_surface_override_material(si) as ShaderMaterial
			if m == null or seen > 6:
				continue
			seen += 1
			var data: Variant = m.get_shader_parameter("stamp_data")
			var arr: Variant = m.get_shader_parameter("stamp_tex")
			var line := "DUMP %s/%d layer=%s stamp_count=%s data=%s arr=%s" % [mi.name, si, m.get_shader_parameter("layer"),
				m.get_shader_parameter("stamp_count"), data, arr]
			if data is ImageTexture:
				var img: Image = data.get_image()
				line += " img=%s fmt=%d" % [img.get_size() if img else Vector2i.ZERO, img.get_format() if img else -1]
				if img:
					for r in 7:
						line += "
      row%d %s" % [r, img.get_pixel(r, 0)]
			if arr is Texture2DArray:
				line += " layers=%d %dx%d" % [arr.get_layers(), arr.get_width(), arr.get_height()]
			log_lines.append(line)


## DI2's burning petrol (recon/RE_FLUIDS.md §9): the molotov's two petrol bursts (4 + 1 BP_Fluid_Projectile_Petrol)
## land as Burning puddles with forced evaporation (ForcedEvaporationAreaPerSecond 25); their
## BP_AOE_DamageOverTime_Fluid_Burning gives a zombie standing in them 11 fire damage and Burning 0.3 per 0.5 s, and
## Burning reaches petrol puddles within InitialTransmitRadius 30 + both radii.
func _petrol_check() -> void:
	var fails := []
	var fl := DI2Fluids.of(main)
	var origin := Vector3(0, 0.0, -2.0)
	var down := get_viewport().get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(origin + Vector3.UP, origin + Vector3.DOWN, Util.WORLD))
	if not down.is_empty():
		origin = down["position"]
	var z := _fresh(origin + Vector3(0.2, 0.05, 0.0))
	await _wait(0.4)
	var h0: float = z.gore.get_health()
	cam.global_position = origin + Vector3(0.0, 2.4, 3.4)
	cam.look_at(origin + Vector3(0, 0.3, 0), Vector3.UP)
	var n := DI2Fluids.molotov_burst(main, origin, Vector3.UP, Vector3(0.0, -6.0, -4.0), null)
	if n != 5:
		fails.append("molotov spawned %d petrol projectiles (want 4 + 1)" % n)
	await _wait(1.2)
	await _shot("molotov_petrol")
	await _wait(0.8)
	var burning := fl.burning_puddles()
	if not fl.projs.is_empty():
		fails.append("%d petrol projectiles still flying after 2 s" % fl.projs.size())
	if burning.is_empty():
		fails.append("no burning puddle")
	for b in burning:
		if b["type"] != "Petrol" or not (int(b["evap_flags"]) & DI2Fluids.EVAP_FORCED) or float(b["rate"]) <= 0.0:
			fails.append("burning puddle %s flags %d rate %.4f" % [b["type"], b["evap_flags"], b["rate"]])
	var lost := h0 - float(z.gore.get_health())
	var acc: Dictionary = z.gore.accumulating_state("Burning")
	log_lines.append("petrol: %d puddles (%d burning, R %s), zombie lost %.1f, Burning %s" % [fl.puddles.size(),
		burning.size(), burning.map(func(b): return roundi(float(b["radius"]))), lost, acc])
	if lost < 22.0:
		fails.append("zombie in the fire lost %.1f health in 2 s (want >= 2 ticks of 11)" % lost)
	if float(acc.get("meter", 0.0)) <= 0.0 and str(acc.get("state", "")) in ["", "idle"]:
		fails.append("no Burning build-up from the AOE: %s" % acc)
	await _wait(2.0)
	await _shot("molotov_petrol_late")
	# The ignition spread, on puddles placed by hand away from the zombie.
	fl.clear()
	var at := origin + Vector3(-6.0, 0.0, 0.0)
	var src := fl._payload("Petrol", at, Vector3.UP, 80.0)
	var near := fl._payload("Petrol", at + Vector3(1.2, 0.0, 0.0), Vector3.UP, 20.0)   # 120 cm <= 30 + 80 + 20
	var far := fl._payload("Petrol", at + Vector3(-2.0, 0.0, 0.0), Vector3.UP, 20.0)   # 200 cm > 130
	if fl.puddles.size() != 3:
		fails.append("spread setup merged: %d puddles" % fl.puddles.size())
	fl.activate_state(src, "Burning", null)
	await _wait(0.3)
	if not (near["states"] as Dictionary).has("Burning"):
		fails.append("Burning did not reach a petrol puddle 120 cm away (R 80 + 20)")
	if (far["states"] as Dictionary).has("Burning"):
		fails.append("Burning reached a petrol puddle 200 cm away")
	fl.clear()
	for f in fails:
		push_error("SCRIPT ERROR: petrol_check: " + f)
	if fails.is_empty():
		log_lines.append("petrol_check: ok")


func _fresh(at: Vector3) -> Zombie:
	for n in get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	for n in get_tree().get_nodes_in_group("gore_debris"):
		n.queue_free()   # severed pieces and gibs from earlier checks
	DI2Fluids.of(main).clear()   # and their blood
	p.global_position = Vector3(0, 0.1, 3.0)
	p.set_state("ready")
	var z := main.spawn_zombie(at, "Walker")
	z.target = null
	z.rotation.y = PI
	z.gore.set_health(3000.0)
	return z


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
