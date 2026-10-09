extends SceneTree
## godot --headless --path game --script res://tools_gd/dump_rig.gd -- <glb> [clip] [time]
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene: Node = load(args[0]).instantiate()
	root.add_child(scene)
	var sk: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var ap: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	if args.size() > 1:
		ap.play(args[1])
		ap.seek(float(args[2]) if args.size() > 2 else 0.0, true)
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i)
		if n.contains("camera") or n.contains("hand") or n.contains("weapon") or n in ["root", "pelvis", "spine_03", "neck_01", "head", "upperarm_r", "clavicle_r"] or sk.get_bone_parent(i) == -1:
			var g := sk.get_bone_global_pose(i)
			var e := g.basis.get_euler() * 57.2958
			print("%-22s parent=%-16s pos=(%.3f, %.3f, %.3f) rot=(%.0f, %.0f, %.0f)" % [n, sk.get_bone_name(sk.get_bone_parent(i)) if sk.get_bone_parent(i) >= 0 else "-", g.origin.x, g.origin.y, g.origin.z, e.x, e.y, e.z])
	quit()
