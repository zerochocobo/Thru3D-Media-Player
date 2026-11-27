extends SceneTree
const Plant := preload("res://environments/magic_cottage/specimen.gd")
const Discovery := preload("res://environments/magic_cottage/discovery.gd")
func _initialize() -> void:
	var dir:="res://environments/magic_cottage/flora"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var artist:=Plant.new()
	for id in Discovery.SPECIES.size():
		var forms:=MeshLibrary.new()
		for stage in 3:
			artist.sculpt(id,stage)
			forms.create_item(stage)
			forms.set_item_name(stage,["Sprout","Growing","Mature"][stage])
			forms.set_item_mesh(stage,artist.mesh)
		var err:=ResourceSaver.save(forms,dir+"/species-%02d.res"%id,ResourceSaver.FLAG_COMPRESS)
		if err!=OK:
			push_error(error_string(err))
			artist.free()
			quit(err)
			return
	artist.free()
	print("Baked thirty botanical forms.")
	quit()
