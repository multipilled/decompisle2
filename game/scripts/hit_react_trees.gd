class_name HitReactTrees
extends RefCounted
## DI2's hit-reaction selection (native UHitDeathReactions component; recon/HIT_REACTS.md, recon/ANIMATION.md 8),
## evaluated on data/hit_reacts.json (tools/build_hit_reacts.py):
##   HitReactTreeSet (the archetype's HitDeathReactionsClass.HitReactTrees): the first entry whose expression holds
##   -> that CT_HitReact_* tree, walked node by node: BooleanExpression / NumericExpression branch, a response node
##   fires its HitDeathReactionResponse and continues, LinkMultipleResults runs another tree in place, Module runs a
##   ModularConditionalTree and follows the link of its result -> the ordered response list.
##   Animated responses name an anim set ("HitReactions.Small"): the archetype's AnimSetCollections resolve it to an
##   AnimSet_DataDriven (first group whose expression holds and that has items, weighted pick) or AnimSet_Velocity.
## Facts are FNames (case-insensitive): callers pass lower-case keys, scoped ("hit.force", "victim.ragdoll") and bare.

static var data := {}
static var _first_used := {}    # AnimSetSelectionOrder_FirstThenRandom: set -> first item already played


static func ensure() -> void:
	if data.is_empty():
		data = Util.load_json("res://data/hit_reacts.json")


## The archetype record (Walker / Runner / Shambler / Thug): tree set, stability, anim sets, LaunchWeightScalar ...
static func archetype(family: String) -> Dictionary:
	ensure()
	var a: Dictionary = data["archetypes"]
	return a.get(family, a["Walker"])


static func tree_set(family: String) -> String:
	return str(archetype(family).get("hit_death_reactions", {}).get("HitReactTrees", "DA_HitReactTreeSet_Zombie_Common"))


## The tree the set picks: its first entry whose expression holds (an empty expression always holds).
static func select_tree(set_name: String, facts: Dictionary) -> String:
	ensure()
	for e: Dictionary in data["tree_sets"].get(set_name, []):
		if DI2Expr.eval(str(e["expr"]), facts):
			return str(e["tree"])
	return ""


## Walks `tree` and returns its responses in firing order: each the response record (class, properties) plus
## "_tree" (the tree it fired from).
static func walk(tree: String, facts: Dictionary, out: Array = [], depth := 0) -> Array:
	ensure()
	if depth > 16:
		return out
	var t: Dictionary = data["trees"].get(tree, {})
	var id: Variant = t.get("start")
	var guard := 0
	while id != null and guard < 512:
		guard += 1
		var n: Dictionary = t["nodes"].get(id, {})
		match n.get("k", ""):
			"bool":
				id = n["t"] if DI2Expr.eval(str(n["expr"]), facts) else n["f"]
			"num":
				# NumericExpression: the first [min, max] range holding the value (bounds inclusive, UNVERIFIED #H3).
				var v := DI2Expr.num(DI2Expr.value(str(n["expr"]), facts))
				var nx: Variant = n.get("default")
				for r: Array in n["ranges"]:
					if v >= float(r[0]) and v <= float(r[1]):
						nx = r[2]
						break
				id = nx
			"str":
				id = n["links"].get(str(DI2Expr.value(str(n["expr"]), facts)), n.get("default"))
			"module":
				id = n["links"].get(module_result(str(n["module"]), facts))
			"resp":
				var r: Dictionary = (n["r"] as Dictionary).duplicate()
				r["_tree"] = tree
				out.append(r)
				id = n.get("next")
			"link":
				walk(str(n["tree"]), facts, out, depth + 1)
				id = n.get("next")
			_:
				id = null
	return out


## A ModularConditionalTree's result label ("" for none).
static func module_result(module: String, facts: Dictionary) -> String:
	ensure()
	var t: Dictionary = data["modules"].get(module, {})
	var id: Variant = t.get("start")
	var guard := 0
	while id != null and guard < 64:
		guard += 1
		var n: Dictionary = t["nodes"].get(id, {})
		match n.get("k", ""):
			"bool":
				id = n["t"] if DI2Expr.eval(str(n["expr"]), facts) else n["f"]
			"result":
				return str(n["label"])
			_:
				return ""
	return ""


## The full selection for one impact: {set, tree, responses}.
static func evaluate(family: String, facts: Dictionary) -> Dictionary:
	var s := tree_set(family)
	var tree := select_tree(s, facts)
	return {"set": s, "tree": tree, "responses": walk(tree, facts) if tree != "" else []}


## A response's range remapper (FRangeRemapSettings, exe 0x141b07560): the four expressions evaluated on the facts;
## inside [InStart, InEnd] a lerp from OutStart to OutEnd by (query - InStart) / max(InEnd - InStart, FLT_EPSILON),
## past the end (or exactly at the start of an empty range) OutEnd, before the start OutStart - i.e. clamped (#H13).
## The curve variant (bUseCurve, +0x70) isn't used by these trees.
static func remap(settings: Dictionary, query: float, facts: Dictionary) -> float:
	var i0 := DI2Expr.num(DI2Expr.value(str(settings.get("InputValueStartRangeExpression", "0")), facts))
	var i1 := DI2Expr.num(DI2Expr.value(str(settings.get("InputValueEndRangeExpression", "1")), facts))
	var o0 := DI2Expr.num(DI2Expr.value(str(settings.get("OutputValueAtStartRangeExpression", "0")), facts))
	var o1 := DI2Expr.num(DI2Expr.value(str(settings.get("OutputValueAtEndRangeExpression", "1")), facts))
	var t := (query - i0) / maxf(i1 - i0, 1.1920929e-07)
	var in_range: bool
	var past: bool
	if i1 <= i0:
		in_range = not (i0 < query or query < i1)
		past = query < i0
	else:
		in_range = not (query < i0 or i1 < query)
		past = i0 < query
	if in_range:
		return (o1 - o0) * t + o0
	if past or query == i0:
		return o1
	return o0


## The AnimSetData an anim set name resolves to for this archetype ({} when its collections lack the key).
static func anim_set(family: String, set_name: String) -> Dictionary:
	ensure()
	var e: Dictionary = archetype(family).get("anim_sets", {}).get(set_name, {})
	if e.has("montage"):
		return {"kind": "single", "montage": e["montage"]}
	return data["anim_sets"].get(str(e.get("set", "")), {})


## The montage (AM_*) an anim set picks for the facts ("" for none). `speed` (cm/s) and `vel_local` (the victim's
## velocity in its own frame, UE axes) feed AnimSet_Velocity sets.
static func pick_montage(family: String, set_name: String, facts: Dictionary, speed := 0.0, vel_local := Vector3.ZERO) -> String:
	var a := anim_set(family, set_name)
	match a.get("kind", ""):
		"single":
			return str(a["montage"])
		"groups":
			for g: Dictionary in a["groups"]:
				var items: Array = g.get("items", [])
				if items.is_empty() or not DI2Expr.eval(str(g.get("expr", "")), facts):
					continue
				return _pick_item(items, str(g.get("order", "Random")), set_name + "|" + str(g.get("name", "")))
		"velocity":
			# AnimSet_Velocity (UNVERIFIED #H16): the first speed group whose expression holds and whose speed range holds
			# the victim speed, then the angle group whose cone (CosAngleRangeCentreExtent about AngleRangeCentreDirection)
			# holds the velocity direction (bMatchesZeroVelocity for standing still).
			for sg: Dictionary in a["speed_groups"]:
				if not DI2Expr.eval(str(sg.get("expr", "")), facts) or not _in_speed(sg["speed"], speed):
					continue
				for ag: Dictionary in sg["angle_groups"]:
					if speed < 1e-3:
						if not bool(ag.get("zero", false)):
							continue
					else:
						var d: Array = ag.get("dir", [1, 0, 0])
						var c := Vector3(float(d[0]), float(d[1]), float(d[2])).normalized().dot(vel_local.normalized())
						if c < float(ag.get("cos_extent", -1.0)):
							continue
					return _pick_item(ag["items"], str(ag.get("order", "Random")), set_name)
	return ""


static func _in_speed(r: Dictionary, s: float) -> bool:
	var lo_t := str(r.get("lo_type", "Inclusive"))
	var hi_t := str(r.get("hi_type", "Open"))
	if lo_t == "Inclusive" and s < float(r["lo"]):
		return false
	if lo_t == "Exclusive" and s <= float(r["lo"]):
		return false
	if hi_t == "Inclusive" and s > float(r["hi"]):
		return false
	if hi_t == "Exclusive" and s >= float(r["hi"]):
		return false
	return true


## AnimSetSelectionOrder: Random = weighted pick (all weights 1 in these sets); FirstThenRandom = the first item the
## first time the group is used, then weighted random (both native, UNVERIFIED #H15).
static func _pick_item(items: Array, order: String, key: String) -> String:
	if order == "FirstThenRandom" and not _first_used.has(key):
		_first_used[key] = true
		return str(items[0][1])
	var total := 0.0
	for it: Array in items:
		total += float(it[0])
	var r := randf() * total
	for it: Array in items:
		r -= float(it[0])
		if r <= 0.0:
			return str(it[1])
	return str(items[-1][1])


## {Hit}.<PartId> facts for a bone: every DT_ZombiePartBoneDefinition row listing it (neck_01 is Head and Chest,
## spine_03 is Chest, Torso_Upper and Torso_Bisectable; whether DI2 sets every row is UNVERIFIED #H4).
static func part_ids(bone: String) -> Array:
	ensure()
	var out := []
	for p: String in data["parts"]:
		if bone in data["parts"][p]:
			out.append(p)
	return out


## The bone's part as the hit-death trees use it when the impact bone has no row (a finger, a twist bone): the
## nearest ancestor listed in DT_ZombiePartBoneDefinition.
static func part_bone(skel: Skeleton3D, bone: String) -> String:
	ensure()
	var b := skel.find_bone(bone)
	while b >= 0:
		var n := skel.get_bone_name(b)
		if not part_ids(n).is_empty():
			return n
		b = skel.get_bone_parent(b)
	return bone


## DI2's direction facts (exe 0x1412c6a20 -> 0x1412bf9d0 x3, recon/HIT_REACTS.md 6.4) for `d` = the unit vector from
## the victim toward the hit's source in the victim's own frame, UE axes (X forward, Y right, Z up).
static func direction_facts(d: Vector3) -> Dictionary:
	var out := {}
	var fw := Vector3(1, 0, 0)
	var rt := Vector3(0, 1, 0)
	var up := Vector3(0, 0, 1)
	for row: Array in [[fw, up, rt, "Front180", "Front90", "Back180", "Back90"],
			[rt, up, fw, "Right180", "Right90", "Left180", "Left90"],
			[up, fw, rt, "Above180", "Above90", "Below180", "Below90"]]:
		var axis: Vector3 = row[0]
		var p1 := _plane(d, row[1])
		var p2 := _plane(d, row[2])
		var a1 := axis.dot(p1)
		var a2 := axis.dot(p2)
		if a1 >= 0.0:
			out[row[3]] = true
			if a1 >= 0.70710677 and a2 >= 0.70710677:
				out[row[4]] = true
		else:
			out[row[5]] = true
			if a1 <= -0.70710677 and a2 <= -0.70710677:
				out[row[6]] = true
	return out


static func _plane(d: Vector3, n: Vector3) -> Vector3:
	var p := d - n * d.dot(n)
	return p.normalized() if p.length_squared() >= 1e-8 else Vector3.ZERO


## DI2's posture fact (exe 0x1412c6920): s = (root rotation * +X) . up -> VictimFaceUp / VictimFaceDown / VictimUpright.
static func posture_fact(forward_dot_up: float) -> String:
	if forward_dot_up >= 0.0871558:
		return "VictimFaceUp"
	if forward_dot_up <= -0.0871558:
		return "VictimFaceDown"
	return "VictimUpright"


## A launch settings asset (DA_LaunchSettings_*), {} if none.
static func launch_settings(asset_name: String) -> Dictionary:
	ensure()
	var a: Dictionary = data["assets"].get(asset_name, {})
	return a.get(asset_name, a)


## A CurveFloat asset's value at `x` (linear keys; Curve_*Flinches_ImpulseScale_AI).
static func curve(asset_name: String, x: float) -> float:
	ensure()
	var a: Dictionary = data["assets"].get(asset_name, {})
	var keys: Array = a.get(asset_name, a).get("FloatCurve", {}).get("Keys", [])
	if keys.is_empty():
		return 0.0
	if x <= float(keys[0]["Time"]):
		return float(keys[0]["Value"])
	for i in range(1, keys.size()):
		var k0: Dictionary = keys[i - 1]
		var k1: Dictionary = keys[i]
		if x <= float(k1["Time"]):
			var w := (x - float(k0["Time"])) / maxf(float(k1["Time"]) - float(k0["Time"]), 1e-8)
			return lerpf(float(k0["Value"]), float(k1["Value"]), w)
	return float(keys[-1]["Value"])


## A rich curve from data/hit_react_extra.json keys [[time, value, interp, arrive tangent, leave tangent], ...] at `x`
## (FRichCurve::Eval: constant before the first / after the last key; RCIM_Linear lerp; RCIM_Cubic Hermite with the
## keys' tangents scaled by the segment length; RCIM_Constant holds).
static func curve_keys(keys: Array, x: float) -> float:
	if keys.is_empty():
		return 0.0
	if x <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		var k0: Array = keys[i - 1]
		var k1: Array = keys[i]
		var t0 := float(k0[0])
		var t1 := float(k1[0])
		if x <= t1:
			var dt := maxf(t1 - t0, 1e-8)
			var a := (x - t0) / dt
			match str(k0[2]):
				"RCIM_Constant":
					return float(k0[1])
				"RCIM_Cubic":
					var p0 := float(k0[1])
					var p1 := float(k1[1])
					var m0 := float(k0[4]) * dt
					var m1 := float(k1[3]) * dt
					var a2 := a * a
					var a3 := a2 * a
					return (2.0 * a3 - 3.0 * a2 + 1.0) * p0 + (a3 - 2.0 * a2 + a) * m0 + (a3 - a2) * m1 + (-2.0 * a3 + 3.0 * a2) * p1
				_:
					return lerpf(float(k0[1]), float(k1[1]), a)
	return float(keys[-1][1])


## Lower-cases a fact dictionary's keys (FName lookups in DI2Expr fall back to lower case).
static func lower_keys(f: Dictionary) -> Dictionary:
	var out := {}
	for k: String in f:
		out[k.to_lower()] = f[k]
	return out
