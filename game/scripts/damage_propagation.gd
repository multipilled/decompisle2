class_name DamagePropagation
extends Node
## DI2's UDamageEffectsPropagationComponent on a zombie (recon/RE_PROPAGATION.md; BP_Base_AI's
## DamageEffectsPropagation, data/body_proxies.json from tools/build_body_proxies.py):
## - the body nodes of BodyProxy_ZombieStandard (bone-local transforms, Links made two-way, BodyNodeData like Size);
## - StartEffect(name, location, bone, amount) (0x14121f3e0): the node nearest `location` among those on `bone`
##   (else the nearest of all) gets value = sat(value + amount), then WeightEffectData (0x141227d30) re-rolls which
##   nodes may show the effect;
## - every tick (0x141223b50), per running effect: each node's value moves toward its largest neighbour,
##   v += (max neighbour - v) x PropagationSpeed x dt (capped at 1, from the previous tick's values); then the one
##   node with the largest value >= CosmeticEffectThreshold that hasn't spawned yet and is shown spawns the effect's
##   CosmeticEffect at its transform, with the effect's CosmeticEffectParameters, the node's BodyNodeData and the
##   StartEffect parameters (the splatter damage facts);
## - StopEffect(name) (0x141221590 -> 0x14121c560) destroys the effect's spawned CEs and drops its state (the
##   splatter they baked stays).
## Statuses start it from DI2's BPs: Burning / Corroded ReceiveBeginInstance -> "Begin Propagation Effect" ->
## StartEffectWithParameters(name, origin location, EncodeSplatterMeshDamageParamsForPropagation(Health,
## MaxHealth, EstimatedDamage), origin bone, 1.0); their ReceiveEnd -> StopEffect.

const DATA_PATH := "res://data/body_proxies.json"
## fx.DamagePropagationThreshold (DefaultScalability: 0 at every level), ...ThrottleEpicentreWeight (0.5),
## ...ThrottleEpicentreFalloff (0.1).
const THROTTLE := 0.0
const EPICENTRE_WEIGHT := 0.5
const EPICENTRE_FALLOFF := 0.1

static var _data := {}

var z: Zombie
var nodes: Array[Dictionary] = []      # {bone, bone_idx, xf (glTF bone-local), data, links}
var defs := {}                          # effect name -> body_proxies.json effect
var running := {}                       # effect name -> {values, spawned, shown, speed, params, state, fx: Array}


static func data() -> Dictionary:
	if _data.is_empty():
		_data = Util.load_json(DATA_PATH)
	return _data


func setup(zombie: Zombie) -> void:
	z = zombie
	var d := data()
	var sk := z.skeleton
	for n: Dictionary in d["BodyProxy_ZombieStandard"]["nodes"]:
		var gl: Dictionary = n["gl"]
		nodes.append({"bone": str(n["bone"]), "bone_idx": sk.find_bone(str(n["bone"])),
			"xf": Zombie._gl_xform({"t": gl["t"], "q": gl["q"]}), "data": n.get("data", {}), "links": n["links"]})
	for e: Dictionary in d["propagation"]["effects"]:
		defs[str(e["name"])] = e


## The node's world transform: bone pose x node (bone-local, proxy x node), FUN_141208920.
func node_xf(i: int) -> Transform3D:
	var n: Dictionary = nodes[i]
	var sk := z.skeleton
	return sk.global_transform * sk.get_bone_global_pose(int(n["bone_idx"])) * (n["xf"] as Transform3D)


func _valid(i: int) -> bool:
	return int(nodes[i]["bone_idx"]) >= 0


## StartEffect / StartEffectWithParameters. `state` = the splatter damage facts {health, damage} (fractions of max).
func start_effect(effect: String, location: Vector3, bone: String, amount := 1.0, state := {}) -> void:
	var def: Dictionary = defs.get(effect, {})
	if def.is_empty() or not def.get("enabled", true):
		return
	var node := _nearest(location, bone)
	if node < 0:
		return
	if not running.has(effect):
		var vals := PackedFloat32Array()
		vals.resize(nodes.size())
		var spawned := PackedByteArray()
		spawned.resize(nodes.size())
		running[effect] = {"values": vals, "spawned": spawned, "shown": PackedByteArray(), "speed": _speed(def),
			"state": state, "fx": []}
	var rt: Dictionary = running[effect]
	if not state.is_empty():
		rt["state"] = state
	var vals: PackedFloat32Array = rt["values"]
	vals[node] = clampf(vals[node] + amount, 0.0, 1.0)
	rt["values"] = vals
	rt["shown"] = _weight(node)


## StopEffect: the effect's CEs go (their baked splatter stays), and its state.
func stop_effect(effect: String) -> void:
	var rt: Dictionary = running.get(effect, {})
	for p in rt.get("fx", []):
		if is_instance_valid(p):
			p.queue_free()
	running.erase(effect)


## PropagationSpeed: the first entry whose expression holds on the owner (empty = always).
func _speed(def: Dictionary) -> float:
	var facts := z.part_facts.duplicate()
	for s: Array in def["speed"]:
		var expr := str(s[0])
		if expr == "" or DI2Expr.eval(expr, facts):
			return float(s[1])
	return 0.0


## FUN_1412066c0: nearest node on `bone`, else nearest overall.
func _nearest(location: Vector3, bone: String) -> int:
	var best := -1
	var bd := INF
	for pass_bone in [true, false]:
		for i in nodes.size():
			if not _valid(i) or (pass_bone and nodes[i]["bone"] != bone):
				continue
			var dd := node_xf(i).origin.distance_squared_to(location)
			if dd < bd:
				bd = dd
				best = i
		if best >= 0:
			return best
	return best


## WeightEffectData (0x141227d30): a random weight per node, +EpicentreWeight on the start node, and down its links
## (recursively) +(EpicentreWeight - k x EpicentreFalloff); nodes whose weight exceeds Threshold x 2 x the mean are
## shown. With fx.DamagePropagationThreshold = 0 (every scalability level) every node is.
func _weight(start: int) -> PackedByteArray:
	var w := PackedFloat32Array()
	w.resize(nodes.size())
	var total := 0.0
	for i in nodes.size():
		w[i] = randf()
		total += w[i]
	total += EPICENTRE_WEIGHT
	w[start] += EPICENTRE_WEIGHT
	var spread := EPICENTRE_WEIGHT - EPICENTRE_FALLOFF
	var extra := 0.0
	if spread > 0.0:
		for j: int in nodes[start]["links"]:
			w[j] += spread
			extra += _weight_down(j, w, spread) + spread
	var cut := THROTTLE * 2.0 * ((extra + total) / float(nodes.size()))
	var shown := PackedByteArray()
	shown.resize(nodes.size())
	for i in nodes.size():
		shown[i] = 1 if w[i] > cut else 0
	return shown


## FUN_141228030: the boost keeps falling by EpicentreFalloff per link (DI2 walks links without a visited set;
## the recursion ends when the boost reaches 0).
func _weight_down(i: int, w: PackedFloat32Array, boost: float) -> float:
	var b := boost - EPICENTRE_FALLOFF
	if b <= 0.0:
		return 0.0
	var sum := 0.0
	for j: int in nodes[i]["links"]:
		w[j] += b
		sum += _weight_down(j, w, b) + b
	return sum


func _process(delta: float) -> void:
	if running.is_empty() or z == null:
		return
	# The statuses' ReceiveEnd -> StopEffect.
	var st: Dictionary = z.gore.status_states()
	for effect: String in running.keys():
		var status: String = {"Burning": "burning", "Corroded": "caustic"}.get(effect, "")
		if status != "" and float(st.get(status, 0.0)) <= 0.0:
			stop_effect(effect)
	for effect: String in running.keys():
		_tick(effect, delta)


func _tick(effect: String, dt: float) -> void:
	var rt: Dictionary = running[effect]
	var def: Dictionary = defs[effect]
	var old: PackedFloat32Array = rt["values"]
	var vals := old.duplicate()
	var speed := float(rt["speed"])
	var threshold := float(def["threshold"])
	var spawned: PackedByteArray = rt["spawned"]
	var shown: PackedByteArray = rt["shown"]
	var pick := -1
	var best := threshold
	for i in nodes.size():
		if not _valid(i):
			continue
		var v := old[i]
		if speed > 0.0 and v < 1.0:
			var m := v
			for j: int in nodes[i]["links"]:
				if _valid(j) and old[j] > m:
					m = old[j]
			if v < m:
				v = minf((m - v) * speed * dt + v, 1.0)
				vals[i] = v
		if v >= best and spawned[i] == 0 and (shown.is_empty() or shown[i] != 0) and (pick < 0 or v > best):
			best = v
			pick = i
	rt["values"] = vals
	if pick >= 0:
		spawned[pick] = 1
		rt["spawned"] = spawned
		_spawn(effect, pick, rt)


## The effect's CosmeticEffect at the node: its SplatterMesh through Flesh (projected along the node's X, world-up
## frame for bAlignToWorldUp CEs), its particles through DI2Particles when the particle port has the CE.
func _spawn(effect: String, i: int, rt: Dictionary) -> void:
	var def: Dictionary = defs[effect]
	var ce := str(def["ce"])
	var xf := node_xf(i)
	var bone := str(nodes[i]["bone"])
	var ax := xf.basis.x.normalized()
	var rest_x: Vector3 = z.gore.world_dir_to_rest(bone, xf.origin, ax)
	var impact := {"bone": bone, "rest_point": z.gore.world_point_to_rest(bone, xf.origin), "rest_normal": rest_x,
		"rest_into": -rest_x, "rest_up": z.gore.world_dir_to_rest(bone, xf.origin, Vector3.UP)}
	var made := Flesh.apply_hit(z.gore, [[ce, 0.0]], impact, rt.get("state", {}))
	var params: Dictionary = (def.get("params", {}) as Dictionary).duplicate()
	params.merge(nodes[i]["data"], true)
	if DI2Particles.db().get("ce", {}).has(ce):
		var att := _attachment(bone)
		DI2Particles.play_ce(att, ce, xf.origin, ax, -ax, -1.0, params)
		for c in att.get_children():
			if not (rt["fx"] as Array).has(c):
				(rt["fx"] as Array).append(c)
	z.flesh_log.append({"propagation": effect, "node": i, "bone": bone, "stamps": made, "size": params.get("Size", -1.0)})


func _attachment(bone: String) -> BoneAttachment3D:
	var nm := "Propagation_" + bone
	var att := z.skeleton.get_node_or_null(nm) as BoneAttachment3D
	if att == null:
		att = BoneAttachment3D.new()
		att.name = nm
		att.bone_name = bone
		z.skeleton.add_child(att)
	return att
