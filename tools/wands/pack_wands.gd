extends SceneTree
## build/wands/wands.glb (tools/wands/build_wands.py) -> res://assets/wands/wands.res, one mesh per wand.
## godot --headless --xr-mode off --path app/godot --script ../../tools/wands/pack_wands.gd -- <glb>

func _initialize() -> void:
	var source: String = OS.get_cmdline_user_args()[0]
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(source, state) != OK:
		push_error("cannot read " + source); quit(1); return
	var scene := doc.generate_scene(state)
	var library := MeshLibrary.new()
	var found := 0
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var item := node as MeshInstance3D
		var mesh := item.mesh as ArrayMesh
		var plain := ArrayMesh.new()
		for surface in mesh.get_surface_count():
			plain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(surface))
		plain.resource_name = str(item.name)
		var id := library.get_last_unused_item_id()
		library.create_item(id)
		library.set_item_name(id, str(item.name))
		library.set_item_mesh(id, plain)
		var box := plain.get_aabb()
		print("WAND ", item.name, " length ", snappedf(box.size.z, .001), " from z ", snappedf(box.position.z, .001), " to ", snappedf(box.end.z, .001), " vertices ", plain.surface_get_array_len(0))
		found += 1
	ResourceSaver.save(library, "res://assets/wands/wands.res", ResourceSaver.FLAG_COMPRESS)
	print("WANDS_PACKED ", found)
	scene.free()
	quit(0 if found == 5 else 1)
