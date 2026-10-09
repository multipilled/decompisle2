extends SceneTree
## godot --headless --path game --script res://tools_gd/cam_track.gd -- <glb> <clip>...
## Prints camera_root's view pitch (bone +Z, the UE camera's look axis) and weapon tip height over each clip.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene: Node = load(args[0]).instantiate()
	root.add_child(scene)
	var sk: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var ap: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var cb := sk.find_bone("camera_root")
	var wb := sk.find_bone("weapon_01_r")
	for clip in args.slice(1):
		var line := "%-50s" % clip
		var len := ap.get_animation(clip).length
		var anim := ap.get_animation(clip)
		for i in 8:
			_pose(sk, anim, len * i / 7.0)
			var g := sk.get_bone_global_pose(cb)
			var v := g.basis * Vector3(0, 0, 1)
			var w := sk.get_bone_global_pose(wb).origin - g.origin
			line += " %+5.1f°/%+.2f" % [rad_to_deg(asin(clampf(v.normalized().y, -1, 1))), w.y]
		print(line)
	quit()


## Applies `anim` at `t` straight from its tracks (AnimationPlayer only switches clips on a processed frame).
func _pose(sk: Skeleton3D, anim: Animation, t: float) -> void:
	sk.reset_bone_poses()
	for tr in anim.get_track_count():
		var b := sk.find_bone(String(anim.track_get_path(tr).get_concatenated_subnames()))
		if b < 0:
			continue
		match anim.track_get_type(tr):
			Animation.TYPE_POSITION_3D:
				sk.set_bone_pose_position(b, anim.position_track_interpolate(tr, t))
			Animation.TYPE_ROTATION_3D:
				sk.set_bone_pose_rotation(b, anim.rotation_track_interpolate(tr, t))
	sk.force_update_all_bone_transforms()
