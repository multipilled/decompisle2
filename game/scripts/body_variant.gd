extends RefCounted
## DI2 variant bodies (tools/archetype_bodies.py VARIANTS, recon/ARCHETYPES.md "P2 variant bodies"): the elemental /
## hazard Walker / Runner meshes are mesh-only glbs on SKEL_ZombieStandard that play their class body's clips.
## DI2 plays the class's sequences on them and retargets every bone at runtime by its TranslationRetargetingMode
## (FAnimationRuntime::RetargetBoneTransform). The class clips are already retargeted onto the class mesh
## (tools/merge_anims.py), so <variant>.retarget.json holds only the class mesh -> variant mesh step for the bones
## whose rest differs:
##   Skeleton: translation = the variant's rest; AnimationScaled: translation x k (|variant| / |class|);
##   AnimationRelative: translation + dt, rotation * dq (dq = inv(class rest q) * variant rest q).
## Bones without a track in a clip (constant at the class rest, dropped by remove_immutable_tracks) take the variant
## mesh's own rest pose from the skeleton (ZombieAnim / DI2Anim rest fallback).
## Used from zombie.gd: `anim = BodyVariant.borrow_clips(visual, mesh_body)` when the mesh glb has no AnimationPlayer.

static var _libs := {}  # mesh body -> AnimationLibrary (built once per variant; the clips are shared by every spawn)


## Adds an AnimationPlayer to `visual` holding the class clips retargeted onto this mesh; returns it.
static func borrow_clips(visual: Node, mesh_body: String) -> AnimationPlayer:
	var skel := Util.find_first(visual, "Skeleton3D")
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	visual.add_child(ap)
	ap.add_animation_library("", _library(mesh_body, str(visual.get_path_to(skel))))
	return ap


static func _library(mesh_body: String, skel_path: String) -> AnimationLibrary:
	if _libs.has(mesh_body):
		return _libs[mesh_body]
	var rt: Dictionary = Util.load_json("res://assets/di2/%s/%s.retarget.json" % [mesh_body, mesh_body])
	var src := str(rt["clips_from"])
	var scene := (load("res://assets/di2/%s/%s.glb" % [src, src]) as PackedScene).instantiate()
	var src_ap := Util.find_first(scene, "AnimationPlayer") as AnimationPlayer
	var src_skel := str(src_ap.get_node(src_ap.root_node).get_path_to(Util.find_first(scene, "Skeleton3D")))
	var bones: Dictionary = rt.get("bones", {})
	var lib := AnimationLibrary.new()
	var t0 := Time.get_ticks_usec()
	var copied := 0
	for n: StringName in src_ap.get_animation_list():
		var a := src_ap.get_animation(n)
		var d := _retarget(a, bones, src_skel, skel_path)
		copied += int(d != a)
		lib.add_animation(n, d)
	scene.free()
	print("BodyVariant: %s borrows %d %s clips (%d bones retargeted, %d clips copied) in %.0f ms" % [mesh_body,
		lib.get_animation_list().size(), src, bones.size(), copied, (Time.get_ticks_usec() - t0) / 1000.0])
	_libs[mesh_body] = lib
	return lib


## The clip itself (shared with the class body) when it has no track on a re-targeted bone and the skeleton path is
## the same; otherwise a copy with those tracks re-targeted (and the paths moved to this mesh's skeleton).
static func _retarget(a: Animation, bones: Dictionary, src_skel: String, skel_path: String) -> Animation:
	var hits := []  # [track, bone entry]
	for bone: String in bones:
		for typ in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D]:
			var i := a.find_track(NodePath(src_skel + ":" + bone), typ)
			if i >= 0:
				hits.append([i, bones[bone]])
	if hits.is_empty() and src_skel == skel_path:
		return a
	var d := a.duplicate() as Animation
	if src_skel != skel_path:
		for i in d.get_track_count():
			var bone := str(d.track_get_path(i).get_concatenated_subnames())
			if bone != "":
				d.track_set_path(i, NodePath(skel_path + ":" + bone))
	for h: Array in hits:
		var i: int = h[0]
		var b: Dictionary = h[1]
		var mode := str(b["mode"])
		if d.track_get_type(i) == Animation.TYPE_POSITION_3D:
			for k in d.track_get_key_count(i):
				var v: Vector3 = d.track_get_key_value(i, k)
				if mode == "Skeleton":
					v = _v3(b["t"])
				elif mode == "AnimationScaled":
					v *= float(b["k"])
				elif mode == "AnimationRelative":
					v += _v3(b["dt"])
				d.track_set_key_value(i, k, v)
		elif mode == "AnimationRelative":
			var dq := Quaternion(float(b["dq"][0]), float(b["dq"][1]), float(b["dq"][2]), float(b["dq"][3]))
			for k in d.track_get_key_count(i):
				d.track_set_key_value(i, k, (d.track_get_key_value(i, k) as Quaternion) * dq)
	return d


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
