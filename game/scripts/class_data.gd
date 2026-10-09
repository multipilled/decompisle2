class_name ClassData
extends RefCounted
## One DI2 held-item animation class (data/classes/<id>.json, built by tools/build_class_data.py).
## Slots hold DI2's selection groups in order; `pick` evaluates each group's expression against the caller's
## facts exactly like the anim sets do (first group whose expression holds and has items wins, items weighted).
## Expressions go through DI2Expr: "#Name" is a fact or a DI2 expression alias, "{Self}.Var" -> facts["Self.Var"].

static var cache := {}

var id := ""
var base := ""
var glb := ""
var slots: Dictionary = {}


## data/classes/<id>.json id of a DI2 HeldItemClassData asset name, exactly as tools/build_class_data.py's
## class_id(): DA_[Exp<n>_|Horde_]HeldItem[_]ClassData_<Name> -> <name> lowercased.
static func id_for(di2_class: String) -> String:
	var re := RegEx.create_from_string("^DA_(Exp\\d_|Horde_)?HeldItem_?ClassData_")
	return re.sub(di2_class, "").to_lower() if di2_class != "" else ""


static func load_class(class_id: String) -> ClassData:
	if cache.has(class_id):
		return cache[class_id]
	var path := "res://data/classes/%s.json" % class_id
	if not FileAccess.file_exists(path):
		return null
	var d: Dictionary = Util.load_json(path)
	var c := ClassData.new()
	c.id = d["id"]
	c.base = d["base"]
	c.glb = d["glb"]
	c.slots = d["slots"]
	cache[class_id] = c
	return c


func has_slot(slot: String) -> bool:
	return slots.has(slot)


## The item DI2 would play for `slot` under `facts`: {role: {clips, len, detect, chain, camera, ...}}.
func pick(slot: String, facts := {}) -> Dictionary:
	for g: Dictionary in slots.get(slot, {}).get("groups", []):
		var items: Array = g["items"]
		if items.is_empty() or not ClassData.eval_expr(g["expr"], facts):
			continue
		return items[randi() % items.size()]
	return {}


## Every item of a slot (e.g. all StandardAttack entries), for tests and tooling.
func all_items(slot: String) -> Array:
	var out := []
	for g: Dictionary in slots.get(slot, {}).get("groups", []):
		out.append_array(g["items"])
	return out


## First 1P clip of `role` in the picked item ("" when the slot has none).
func clip(slot: String, role := "main", facts := {}) -> String:
	var it := pick(slot, facts)
	# Pose slots (UpperBodyIdle, AimPose...) hold FirstPersonAsset / ThirdPersonAsset instead of one asset.
	var key := role if it.get(role) is Dictionary else ("firstpersonasset" if role == "main" and it.get("firstpersonasset") is Dictionary else role)
	var r: Dictionary = it.get(key, {}) if it.get(key) is Dictionary else {}
	var clips: Array = r.get("clips", [])
	return clips[0] if not clips.is_empty() else ""


## Sample clips of a blend space slot (e.g. UpperBodyWalkRunSprintBlendSpace), first item.
func blend_clips(slot: String) -> Array:
	var it := pick(slot, {})
	return it.get("main", {}).get("clips", []) if not it.is_empty() else []


## DI2 expression check (aliases resolved through data/expression_aliases.json).
static func eval_expr(expr: String, facts: Dictionary) -> bool:
	return DI2Expr.eval(expr, facts)
