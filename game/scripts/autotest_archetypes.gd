extends RefCounted
## DI2 special-archetype bodies in the flesh suite (recon/ARCHETYPES.md): per archetype a front / back look capture
## and one gore case (a heavy machete hit on a severable limb: FLESH stamp + dismemberment), saved to
## <test_out>/archetypes/<archetype>_*.png, with a log line per body. Called from autotest_flesh.gd:
##   await load("res://scripts/autotest_archetypes.gd").new().run(self)
## The hit is the flesh suite's own cut_check hit (autotest_flesh.gd _cut_check), so the result compares 1:1 with the
## Walker's.

## Archetypes with their own DI2 body (zombie.gd BODIES, beyond the four the rest of the suite covers).
const ARCHETYPES := ["Screamer", "Slobber", "Butcher", "Suicider"]


## P2 variant bodies (tools/archetype_bodies.py VARIANTS): every archetypes.json row with "variant_of" (mesh swaps on
## their class's clips, scripts/body_variant.gd). Captures go to <test_out>/di2-arch-meshes/.
## A row is spawned only once its body is built and imported (its glb resource exists) and zombie.gd BODIES maps the
## archetype to it; the rest are logged as skipped, so the suite stays green while bodies are being built.
static func variants(log_lines: Array = []) -> Array:
	var out := []
	for a: Dictionary in Util.load_json("res://data/archetypes.json"):
		if not a.has("variant_of"):
			continue
		var b := str(a.get("body", ""))
		var glb := "res://assets/di2/%s/%s.glb" % [b, b]
		if not ResourceLoader.exists(glb) or str(Zombie.body_for(str(a["name"]))[0]) != b:
			log_lines.append("archetypes: %s skipped (body %s not built / imported or not in zombie.gd BODIES)" % [a["name"], b])
			continue
		out.append(str(a["name"]))
	return out


func run(t: Node) -> void:
	var main: Main = t.main
	var cam: Camera3D = t.cam
	var out_special := (t.out_dir as String).get_base_dir().path_join("archetypes")
	var out_variant := (t.out_dir as String).get_base_dir().path_join("di2-arch-meshes")
	DirAccess.make_dir_recursive_absolute(out_special)
	DirAccess.make_dir_recursive_absolute(out_variant)
	var vars := variants(t.log_lines)
	# The flesh suite runs near its 300 s limit: by default one variant (smoke test of the mesh-only path); every variant
	# with --archetype-variants (run it alone with RUN_TEST_LIMIT raised, ~5 s per variant).
	var all_vars := "--archetype-variants" in OS.get_cmdline_user_args()
	if not all_vars and vars.size() > 1:
		t.log_lines.append("archetypes: %d variants, capturing %s only (--archetype-variants for all)" % [vars.size(), vars[0]])
		vars = vars.slice(0, 1)
	for arch: String in (([] as Array) if all_vars else ARCHETYPES) + vars:
		var out := out_variant if arch in vars else out_special
		for n in t.get_tree().get_nodes_in_group("zombies"):
			n.remove_from_group("zombies")
			n.queue_free()
		for n in t.get_tree().get_nodes_in_group("gore_debris"):
			n.queue_free()
		DI2Fluids.of(main).clear()
		t.p.global_position = Vector3(0, 0.1, 6.0)
		var z := main.spawn_zombie(Vector3(0, 0.1, -2.0), arch) as Zombie
		z.target = null
		z.rotation.y = PI
		await t._wait(0.6)
		z.anim.pause()
		var sk: Skeleton3D = z.skeleton
		t.log_lines.append("archetypes: %s body=%s mesh=%s scale=%.2f bones=%d clips=%d meshes=%d initial splatter %s" % [arch,
			z.body, z.get("mesh_body"), z.body_scale, sk.get_bone_count(), z.anim.get_animation_list().size(), Util.find_all(z.visual, "MeshInstance3D").size(),
			z.initial_splatter])
		var mid := z.global_position + Vector3(0, 1.0 * z.body_scale, 0)
		for side in [0.0, PI]:
			cam.global_position = mid + Vector3(sin(side), 0.0, cos(side)) * 2.4 * z.body_scale
			cam.look_at(mid, Vector3.UP)
			cam.current = true
			await t._wait(0.15)
			await _shot(t, out, "%s_look_%s" % [arch.to_lower(), "front" if side == 0.0 else "back"])
		# The first part DI2's MultiPartHealth lets this archetype lose (arm, then leg, then head; bCanBeDismembered), hit
		# for just over its health (MaxHealth x MaxHealthFraction), so it is cut in one blow. The Butcher's legs and every
		# Suicider part are not dismemberable in DI2: the Suicider gets the stamp only.
		var pick := _severable(arch)
		var bone: String = {"arm_left": "lowerarm_l", "leg_left": "calf_l", "head": "head"}[pick[0]]
		var b := sk.find_bone(bone)
		var at := sk.global_transform * sk.get_bone_global_pose(b).origin
		var r: Dictionary = z.take_hit(bone, at, Vector3.RIGHT, Vector3(0, 0, -1), pick[1], "sharp", true, 1.5, 40.0,
			Vector3.ZERO, t.p, {"weapon": "machete", "HeavyAttack": true})
		var outcomes: Array = (r.get("outcomes", []) as Array).map(func(o): return o.get("type", "") + ":" + str(o.get("bone", o.get("part", ""))))
		var cuts := z.flesh_log.filter(func(e: Dictionary) -> bool: return e.has("limb_cut") or e.has("di2_cut"))
		t.log_lines.append("archetypes: %s machete %s: outcomes %s, stamps %d, cuts %d" % [arch, bone, outcomes,
			z.gore.stamp_count(), cuts.size()])
		await t._wait(0.5)
		var c := sk.global_transform * sk.get_bone_global_pose(sk.get_bone_parent(b)).origin
		cam.global_position = c + Vector3(-0.9, 0.1, 0.6) * z.body_scale
		cam.look_at(c + Vector3(0, -0.3, 0), Vector3.UP)
		await t._wait(0.2)
		await _shot(t, out, "%s_hit_%s" % [arch.to_lower(), bone])
		z.queue_free()
	# Perf only on request (it adds ~10 s to a suite near its time limit): --archetype-perf.
	if "--archetype-perf" in OS.get_cmdline_user_args():
		await _perf(t, main, cam)


## [part id, damage that zeroes it] for the first dismemberable part of arm_left / leg_left / head (arm_left if none).
func _severable(arch: String) -> Array:
	for a: Dictionary in Util.load_json("res://data/archetypes.json"):
		if a["name"] != arch:
			continue
		for id: String in ["arm_left", "leg_left", "head"]:
			for p: Dictionary in a["parts"]:
				if p["id"] == id and p["can_dismember"]:
					return [id, float(a["limb_health"]) * float(p["max_health_fraction"]) * 1.1 + 1.0]
	return ["arm_left", 80.0]


## The flesh suite's perf_check (8 zombies, idle then after one torso hit each) with two of each special body, so the
## numbers compare with its 8-Walker line.
func _perf(t: Node, main: Main, cam: Camera3D) -> void:
	for n in t.get_tree().get_nodes_in_group("zombies"):
		n.remove_from_group("zombies")
		n.queue_free()
	var zs: Array[Zombie] = []
	for i in 8:
		var z := main.spawn_zombie(Vector3((i % 4) * 1.2 - 1.8, 0.1, -3.0 - (i / 4) * 1.5), ARCHETYPES[i % ARCHETYPES.size()]) as Zombie
		z.target = null
		z.rotation.y = PI
		z.gore.set_health(3000.0)
		zs.append(z)
	cam.global_position = Vector3(0, 1.6, 2.5)
	cam.look_at(Vector3(0, 1.0, -3.5), Vector3.UP)
	await t._wait(1.0)
	var idle: Array = await t._measure(2.0)
	for z in zs:
		var sk := z.skeleton
		var at := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
		z.take_hit("spine_03", at, Vector3.RIGHT, Vector3.FORWARD, 20.0, "sharp", false, 1.0, 15.0, Vector3.ZERO, null, {"weapon": "machete"})
	var hit: Array = await t._measure(2.0)
	# A second round: the first can include one-off shader / pipeline compiles of the new bodies' materials.
	for z in zs:
		var sk := z.skeleton
		var at := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("spine_03")).origin
		z.take_hit("spine_03", at, Vector3.RIGHT, Vector3.FORWARD, 20.0, "sharp", false, 1.0, 15.0, Vector3.ZERO, null, {"weapon": "machete"})
	var hit2: Array = await t._measure(2.0)
	t.log_lines.append("perf_check archetypes (8 specials, 2 each): idle %.1f fps / %.2f ms process / %.2f ms physics; after hits %.1f fps / %.2f ms process / %.2f ms physics; second round %.1f fps / %.2f ms process" % [
		idle[0], idle[1], idle[2], hit[0], hit[1], hit[2], hit2[0], hit2[1]])
	for z in zs:
		z.queue_free()


func _shot(t: Node, dir: String, name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	t.get_viewport().get_texture().get_image().save_png(dir.path_join(name + ".png"))
