extends SceneTree
# Dumps the first positions of every surface of a glb as Godot imports it (to compare with the raw glb order).
# usage: godot --headless --path game -s res://../tools/debug/dump_mesh_positions.gd -- <res://...glb> <out.json>
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene := (load(args[0]) as PackedScene).instantiate()
	var out := {}
	var stack: Array = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D:
			var m: Mesh = n.mesh
			var surfs := []
			for s in m.get_surface_count():
				var a := m.surface_get_arrays(s)
				var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				var first := []
				for i in mini(8, v.size()):
					first.append([v[i].x, v[i].y, v[i].z])
				surfs.append({"count": v.size(), "first": first, "name": str(m.surface_get_material(s).resource_name if m.surface_get_material(s) else "")})
			out[str(n.name)] = surfs
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	quit()
