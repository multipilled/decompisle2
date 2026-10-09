extends Node3D
## Whole-map check for a DI2 level (DI2Map, recon/TEST_MAP.md "Whole map"). Own scene (scenes/map_walk_test.tscn),
## so it needs no hook in main.gd; run it in the background:
##   RUN_TEST_LIMIT=900 RUN_TEST_ENGINE_ARGS="res://scenes/map_walk_test.tscn" tools/with_cpu.sh me tools/with_lock.sh me \
##     tools/run_test.sh --mapwalktest=game/test_out/di2-whole-map [--map=nh04] [--no-walk] [--no-shots]
## 1. Loads the map, logs DI2Map's stats (load time, meshes, instances, collision).
## 2. Fixed cameras: one high oblique and one street-level shot per area (map.json "areas": one per DI2 level package).
## 3. Bot: the real Player, driven through its move actions, walks a waypoint loop (a street-level point per area,
##    ordered round the map centre) along paths on a navmesh baked from the map's collision. Fails on a fall through
##    the floor (more than FALL_M below the lowest path point) or a leg it cannot finish. The navmesh's agent size is
##    the Player's capsule (player.gd: radius 0.33, height 1.75); its climb / slope are test-harness values, not DI2's.
## Results: map_walk.log (CHECK lines) and PNGs in the output folder.

const FALL_M := 3.0
const LEG_TIMEOUT := 90.0
const REACH_M := 0.9
const SETTLE_FRAMES := 45  ## DI2's eye adaptation (di2_post.gd) settles from a jump cut in under a second

var out_dir := ""
var map_name := "nh04"
var walk := true
var shots := true
var m: Node3D
var p: Player
var cam: Camera3D
var log_lines: PackedStringArray = []
var fails := 0


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
		if a.begins_with("--mapwalktest="):
			out_dir = a.trim_prefix("--mapwalktest=")
		elif a.begins_with("--map="):
			map_name = a.trim_prefix("--map=")
		elif a == "--no-walk":
			walk = false
		elif a == "--no-shots":
			shots = false
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://test_out/di2-whole-map")
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_tree().create_timer(880.0, true, false, true).timeout.connect(func() -> void:
		_log("WATCHDOG: timed out")
		_finish(1))
	if not DI2Map.exists(map_name):
		_log("FAIL no map %s" % map_name)
		_finish(1)
		return
	m = DI2Map.create(map_name)
	add_child(m)
	_log("map %s: %s" % [map_name, m.stats])
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 4000.0
	add_child(cam)
	cam.make_current()
	await _frames(5)
	await _perf("spawn view", Vector3(0, 1.7, 6), Vector3(0, 1.5, -10))
	await _perf("over the map", Vector3(40, 60, 60), Vector3(0, 0, 0))
	var areas: Array = m.data.get("areas", [])
	if shots:
		await _area_shots(areas)
	if walk:
		await _walk(areas)
	_log("CHECK map_walk %s (%d failures)" % ["ok" if fails == 0 else "FAIL", fails])
	_finish(0 if fails == 0 else 1)


# --- fixed cameras ---------------------------------------------------------------------------------------------------

func _area_shots(areas: Array) -> void:
	for a: Dictionary in areas:
		var c := _v(a["center"])
		var s := _v(a["size"])
		var r := maxf(maxf(s.x, s.z) * 0.6, 20.0)
		cam.make_current()
		# high oblique from the map's south-east, looking at the area centre
		cam.global_position = c + Vector3(r * 0.6, r * 0.7, r * 0.6)
		cam.look_at(c, Vector3.UP)
		await _frames(SETTLE_FRAMES)
		await _shot("area_%s_high" % a["name"])
		# street level: 1.7 m above the ground under the centre (first hit of a ray from far above), looking north
		var g = _ground(Vector3(c.x, c.y + 200.0, c.z), 400.0)
		if g != null:
			cam.global_position = (g as Vector3) + Vector3(0, 1.7, 0)
			cam.look_at(cam.global_position + Vector3(0, -0.1, -1), Vector3.UP)
			await _frames(SETTLE_FRAMES)
			await _shot("area_%s_ground" % a["name"])


func _ground(from: Vector3, depth: float) -> Variant:
	var q := PhysicsRayQueryParameters3D.create(from, from - Vector3(0, depth, 0), Util.WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if hit else null


# --- bot walk -------------------------------------------------------------------------------------------------------

func _walk(areas: Array) -> void:
	var t0 := Time.get_ticks_msec()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.33  # Player capsule (player.gd)
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.45  # test harness
	nm.agent_max_slope = 46.0  # test harness
	nm.cell_size = 0.25
	nm.cell_height = 0.1
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = Util.WORLD
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, src, m)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	var region := NavigationRegion3D.new()
	region.navigation_mesh = nm
	add_child(region)
	_log("navmesh: %d polygons, %d vertices, baked in %.1f s" % [nm.get_polygon_count(), nm.get_vertices().size(),
		(Time.get_ticks_msec() - t0) / 1000.0])
	var nav := get_world_3d().navigation_map
	var probe := nm.get_vertices()[0] if nm.get_vertices().size() > 0 else Vector3.ZERO
	for k in 600:  # the region's polygons join the navigation map on a later sync
		await get_tree().physics_frame
		if NavigationServer3D.map_get_closest_point(nav, probe).distance_to(probe) < 0.5 and probe != Vector3.ZERO:
			_log("navigation map synced after %d physics frames" % (k + 1))
			break
	# waypoints: the navmesh point nearest each area's centre at street level (y 0 = the spawn floor), round the
	# centre of all areas, starting and ending at the spawn origin
	var mid := Vector3.ZERO
	var na := 0
	for a: Dictionary in areas:
		if String(a["name"]).ends_with("_Fixed"):
			mid += _v(a["center"])
			na += 1
	mid /= maxf(na, 1.0)
	var pts := []
	for a: Dictionary in areas:
		# walkable tiles only: the _Lighting tiles overlap their _Fixed tile, the Vista is unreachable backdrop
		if not (String(a["name"]).ends_with("_Fixed") or String(a["name"]).ends_with("_Main")):
			continue
		var c := _v(a["center"])
		var w := NavigationServer3D.map_get_closest_point(nav, Vector3(c.x, 0.0, c.z))
		pts.append({"name": a["name"], "pos": w, "ang": atan2(w.x - mid.x, w.z - mid.z)})
	pts.sort_custom(func(x, y) -> bool: return x["ang"] < y["ang"])
	var start := NavigationServer3D.map_get_closest_point(nav, Vector3.ZERO)
	pts.push_front({"name": "spawn", "pos": start})
	pts.push_back({"name": "spawn", "pos": start})
	p = Player.new()
	p.name = "Dani"
	add_child(p)
	p.global_position = start + Vector3(0, 0.1, 0)
	var pcs := p.find_children("", "Camera3D", true, false)
	if pcs.size() > 0:
		(pcs[0] as Camera3D).make_current()  # walk shots from Dani's own first-person camera
	await _frames(10)
	var walked := 0.0
	for i in range(1, pts.size()):
		var target: Vector3 = pts[i]["pos"]
		var path := NavigationServer3D.map_get_path(nav, p.global_position, target, true)
		var res: Dictionary = await _leg(path, target)
		walked += float(res["dist"])
		var ok: bool = res["ok"]
		if not ok:
			fails += 1
		_log("leg %d -> %s: %s, path %d pts %.1f m (end %.1f m from waypoint), walked %.1f m in %.1f s%s" % [i,
			pts[i]["name"], "ok" if ok else "FAIL", path.size(), _path_len(path),
			(path[-1] - target).length() if path.size() else -1.0, res["dist"], res["t"], res.get("why", "")])
		if res.get("fell", false):
			break
		if not ok:
			p.global_position = target + Vector3(0, 0.1, 0)  # carry on from the waypoint (the failure is logged)
			await _frames(5)
		if i % 3 == 0:
			await _shot("walk_leg%02d" % i)
	_log("bot walked %.0f m" % walked)
	Input.action_release("move_forward")


## Frame rate and draw calls from a fixed camera (after the exposure settles).
func _perf(label: String, from: Vector3, at: Vector3) -> void:
	cam.make_current()
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	await _frames(SETTLE_FRAMES)
	var t0 := Time.get_ticks_usec()
	await _frames(60)
	var ms := (Time.get_ticks_usec() - t0) / 60000.0
	_log("perf %s: %.1f fps (%.1f ms/frame), %d draw calls, %d objects, %d primitives" % [label, 1000.0 / ms, ms,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])


func _leg(path: PackedVector3Array, target: Vector3) -> Dictionary:
	var wall0 := Time.get_ticks_msec()
	var t := 0.0
	var dist := 0.0
	var k := 1
	var last := p.global_position
	var low := INF
	for q in path:
		low = minf(low, q.y)
	var stuck_t := 0.0
	var best := INF
	while k < path.size():
		var to := path[k] - p.global_position
		to.y = 0.0
		if to.length() < REACH_M:
			k += 1
			continue
		p.rotation.y = atan2(-to.x, -to.z)  # Player moves along -Z of its basis
		Input.action_press("move_forward")
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		dist += (p.global_position - last).length()
		last = p.global_position
		if p.global_position.y < low - FALL_M:
			Input.action_release("move_forward")
			return {"ok": false, "fell": true, "t": t, "dist": dist, "why": " FELL to y %.1f at %s" % [p.global_position.y, p.global_position]}
		var d := (path[-1] - p.global_position).length()
		if d < best - 0.25:
			best = d
			stuck_t = 0.0
		else:
			stuck_t += get_physics_process_delta_time()
		if stuck_t > 2.0 and p.is_on_floor():
			Input.action_press("jump")  # over a kerb / low prop the navmesh let through
			await get_tree().physics_frame
			Input.action_release("jump")
		if t > LEG_TIMEOUT or stuck_t > 12.0 or Time.get_ticks_msec() - wall0 > 100000:
			Input.action_release("move_forward")
			return {"ok": false, "t": t, "dist": dist, "why": " STUCK at %s (%.1f m to go)" % [p.global_position, d]}
	Input.action_release("move_forward")
	var off := (target - p.global_position)
	off.y = 0.0
	return {"ok": true, "t": t, "dist": dist, "why": " (%.1f m from waypoint)" % off.length()}


func _path_len(path: PackedVector3Array) -> float:
	var s := 0.0
	for i in range(1, path.size()):
		s += (path[i] - path[i - 1]).length()
	return s


# --- helpers -------------------------------------------------------------------------------------------------------

func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(n: String, c: Camera3D = null) -> void:
	if c != null:
		c.make_current()
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(n + ".png"))
	if c != null:
		cam.make_current()


func _log(s: String) -> void:
	print(s)
	log_lines.append(s)


func _finish(code: int) -> void:
	var f := FileAccess.open(out_dir.path_join("map_walk.log"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(log_lines) + "\n")
	get_tree().quit(code)
