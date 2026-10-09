class_name Util
## Shared helpers: physics layers, node lookups, materials from DI2 manifests, bone segment shapes.

const WORLD := 1
const PLAYER := 2
const ZOMBIE := 4
const HITBOX := 8
const DEBRIS := 16

## Unreal-exported rigs face +X; Godot faces -Z.
const UE_TO_GODOT_YAW := PI / 2.0


static func find_first(root: Node, type_name: String) -> Node:
	if root.is_class(type_name):
		return root
	for c in root.get_children():
		var f := find_first(c, type_name)
		if f:
			return f
	return null


static func find_all(root: Node, type_name: String, out: Array = []) -> Array:
	if root.is_class(type_name):
		out.append(root)
	for c in root.get_children():
		find_all(c, type_name, out)
	return out


static func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f else null


## Applies prop.gdshader materials (Unreal texture sets) to every mesh under `root`.
static func apply_prop_materials(root: Node, manifest_path: String) -> Array[ShaderMaterial]:
	var manifest: Dictionary = load_json(manifest_path)
	var dir := manifest_path.get_base_dir()
	var shader: Shader = load("res://shaders/prop.gdshader")
	var blood: Texture2D = load("res://assets/di2/splatter/T_SkinBloodSplatterDetail_A.png")
	var made: Array[ShaderMaterial] = []
	for mi: MeshInstance3D in find_all(root, "MeshInstance3D"):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var src := mesh.surface_get_material(s)
			var entry: Dictionary = manifest.get(src.resource_name if src else "", {})
			var mat := ShaderMaterial.new()
			mat.shader = shader
			for slot in ["albedo", "normal", "mro", "ata"]:
				if entry.has(slot):
					mat.set_shader_parameter(slot + "_tex", load(dir + "/" + entry[slot]))
					mat.set_shader_parameter("has_" + slot, true)
			mat.set_shader_parameter("use_alpha_clip", entry.get("masked", false))
			mat.set_shader_parameter("alpha_clip", entry.get("clip", 0.333))
			mat.set_shader_parameter("blood_detail", blood)
			mi.set_surface_override_material(s, mat)
			made.append(mat)
	return made


## Rest-pose segment (skeleton space) used for a bone's hitbox / physics capsule.
static func bone_segment(skel: Skeleton3D, bone: int, end_bone: int, extend: float) -> Array:
	var a := skel.get_bone_global_rest(bone).origin
	var b: Vector3
	if end_bone >= 0:
		b = skel.get_bone_global_rest(end_bone).origin
	else:
		var p := skel.get_bone_parent(bone)
		var dir := (a - skel.get_bone_global_rest(p).origin).normalized() if p >= 0 else Vector3.UP
		b = a + dir * extend
	return [a, b]


## CollisionShape3D capsule from a to b (skeleton space), expressed in the bone's local frame.
static func capsule_for(skel: Skeleton3D, bone: int, seg: Array, radius: float) -> CollisionShape3D:
	var inv := skel.get_bone_global_rest(bone).affine_inverse()
	var a: Vector3 = inv * seg[0]
	var b: Vector3 = inv * seg[1]
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = max(a.distance_to(b) + radius * 2.0, radius * 2.0 + 0.01)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var axis := (b - a).normalized() if a.distance_to(b) > 0.001 else Vector3.UP
	var basis := Basis(Quaternion(Vector3.UP, axis)) if abs(axis.dot(Vector3.UP)) < 0.999 else (Basis.IDENTITY if axis.y > 0 else Basis(Vector3.RIGHT, PI))
	cs.transform = Transform3D(basis, (a + b) * 0.5)
	return cs


static func is_descendant_bone(skel: Skeleton3D, bone: int, ancestor: int) -> bool:
	var b := bone
	while b >= 0:
		if b == ancestor:
			return true
		b = skel.get_bone_parent(b)
	return false
