class_name DanglingLimbs
extends SkeletonModifier3D
## Arms broken by blunt force stop following the animation and hang (DI2's "broken" limb state).
## A DI2 bone break (zombie.break_points: break child -> {point, normal} in bind pose, metres) re-skins the mesh past
## the break plane onto the break child, whose physics joint DI2 moves to that point: a broken chain bone that is a
## break child hangs from the break point (carried by its parent bone) instead of from its own joint.

var chains: Array = []   # each: Array[int] from shoulder to hand
var weight := 0.85
var _zombie: Node


func _init() -> void:
	active = false   # no per-frame modifier work until a limb breaks (set_broken)


func set_broken(bones: PackedStringArray) -> void:
	var skel := get_skeleton()
	chains.clear()
	for side in ["l", "r"]:
		var up: String = "upperarm_" + side
		if bones.has(up):
			chains.append([skel.find_bone(up), skel.find_bone("lowerarm_" + side), skel.find_bone("hand_" + side)])
	_break_points()   # finds the owning zombie
	active = not chains.is_empty() and not (_zombie and _zombie.dead)   # a corpse stays off (death turns it off)


func _break_points() -> Dictionary:
	if _zombie == null:
		var n := get_parent()
		while n and not n is Zombie:
			n = n.get_parent()
		_zombie = n
	return _zombie.break_points if _zombie else {}


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var bps := _break_points()
	var t := Time.get_ticks_msec() * 0.001
	for chain in chains:
		for i in range(chain.size() - 1):
			var b: int = chain[i]
			var child: int = chain[i + 1]
			if b < 0 or child < 0:
				continue
			var gp := skel.get_bone_global_pose(b)
			var parent := skel.get_bone_parent(b)
			var parent_pose := skel.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
			# Pivot: the joint, or the break point carried by the parent bone (its pose x inverse(its rest) x point).
			var pivot := gp.origin
			var bp: Dictionary = bps.get(skel.get_bone_name(b), {})
			if not bp.is_empty() and parent >= 0:
				pivot = parent_pose * skel.get_bone_global_rest(parent).affine_inverse() * (bp["point"] as Vector3)
			var cur := (skel.get_bone_global_pose(child).origin - pivot).normalized()
			# Hang down in skeleton space, with a little sway so it reads as limp.
			var want := (Vector3(sin(t * 2.1 + i) * 0.15, -1.0, cos(t * 1.7 + i) * 0.1)).normalized()
			if cur.length() < 0.5:
				continue
			var r := Basis(Quaternion.IDENTITY.slerp(Quaternion(cur, want), weight))
			var new_pose := Transform3D(r * gp.basis, pivot + r * (gp.origin - pivot))
			var local := parent_pose.affine_inverse() * new_pose
			skel.set_bone_pose_rotation(b, local.basis.get_rotation_quaternion())
			if not bp.is_empty():
				skel.set_bone_pose_position(b, local.origin)
