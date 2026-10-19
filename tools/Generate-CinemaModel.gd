extends SceneTree
## godot --headless --xr-mode off --path app/godot --script ../../tools/Generate-CinemaModel.gd
## Deterministically regenerates the committed model from its source blueprint.

const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const OUTPUT := "res://environments/grand_cinema/"

func _initialize() -> void:
	var output_path := ProjectSettings.globalize_path(OUTPUT)
	var error := DirAccess.make_dir_recursive_absolute(output_path)
	if error != OK:
		push_error("Cannot create cinema source asset directory: %s" % error)
		quit(1)
		return
	var scene := Blueprint.build()
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	error = document.append_from_scene(scene, state)
	if error == OK:
		error = document.write_to_filesystem(state, output_path.path_join("cinema.glb"))
	if error != OK:
		push_error("Cinema GLB export failed: %s" % error)
		scene.free()
		quit(1)
		return
	var file := FileAccess.open(output_path.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		push_error("Cannot write cinema manifest: %s" % FileAccess.get_open_error())
		scene.free()
		quit(1)
		return
	file.store_string(JSON.stringify(Blueprint.manifest(), "\t", false) + "\n")
	file.close()
	var mesh: ArrayMesh = scene.get_child(0).mesh
	var triangles := 0
	for surface in range(mesh.get_surface_count()):
		triangles += mesh.surface_get_array_index_len(surface) / 3
	print("CINEMA_MODEL_OK surfaces=%d triangles=%d seats=%d path=%s" % [mesh.get_surface_count(),
		triangles, Blueprint.manifest().seats.size(), output_path])
	scene.free()
	quit(0)
