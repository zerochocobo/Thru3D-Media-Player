extends SceneTree
## godot --headless --xr-mode off --path app/godot --script ../../tools/Generate-CinemaModel.gd
## Deterministically regenerates the auditorium manifest from its source blueprint.
## The visible model is then built from this manifest by tools/Build-CinemaModel.ps1 (Blender).

const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const OUTPUT := "res://environments/grand_cinema/"

func _initialize() -> void:
	var output_path := ProjectSettings.globalize_path(OUTPUT)
	var error := DirAccess.make_dir_recursive_absolute(output_path)
	if error != OK:
		push_error("Cannot create cinema source asset directory: %s" % error)
		quit(1)
		return
	var file := FileAccess.open(output_path.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		push_error("Cannot write cinema manifest: %s" % FileAccess.get_open_error())
		quit(1)
		return
	var manifest := Blueprint.manifest()
	file.store_string(JSON.stringify(manifest, "\t", false) + "\n")
	file.close()
	print("CINEMA_MANIFEST_OK seats=%d walkable=%d colliders=%d path=%s" % [manifest.seats.size(),
		manifest.walkable.size(), manifest.colliders.size(), output_path])
	quit(0)
