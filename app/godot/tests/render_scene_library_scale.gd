extends SceneTree
## Judging a scene library model's unit by eye: godot --xr-mode off --path app/godot --script res://tests/render_scene_library_scale.gd -- <out_dir> <file.glb>=<scale> ...
## Each scene is shown from where the player would stand it, at eye height, with a 1.7 m figure
## and a 1 m floor ruler 2.5 m away in three directions. Writes <out_dir>/<slug>_<view>.png.
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Audit := preload("res://scripts/scene_import/scene_import_audit.gd")
const Layout := preload("res://scripts/scene_import/scene_import_layout.gd")

func _initialize() -> void:
	_run.call_deferred()

func _reference(colour: Color, size: Vector3) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = colour
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var node := MeshInstance3D.new()
	node.mesh = box
	return node

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	# --pictures <out_dir> <file.glb>=<scale> ...: one plain view per scene from where it would be
	# entered, as a stand-in card picture until the real one is taken on a headset.
	var pictures := args.size() > 0 and args[0] == "--pictures"
	if pictures: args = args.slice(1)
	if args.size() < 2:
		push_error("usage: -- <out_dir> <file.glb>=<scale> ...")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(args[0])
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.05, 0.07)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)
	var camera := Camera3D.new()
	camera.far = 4000.0
	camera.fov = 90.0
	root.add_child(camera)
	camera.make_current()
	for item in args.slice(1):
		# <file>=<scale>, or <file>=<scale>@x,y,z,yaw to look from a chosen entry point instead of the player's own.
		var chosen := PackedStringArray()
		if item.contains("@"):
			chosen = item.get_slice("@", 1).split(",")
			item = item.get_slice("@", 0)
		var split: int = item.rfind("=")
		var path: String = item.substr(0, split)
		var scale := float(item.substr(split + 1))
		var slug := path.get_base_dir().get_file()
		var result := Loader.new().load_scene(path, "low", {"use_cache": false})
		if result.has("error"):
			print("FAIL %s: %s" % [slug, result.error])
			continue
		var holder := Node3D.new()
		root.add_child(holder)
		holder.add_child(result.root)
		(result.root as Node3D).scale *= scale
		var stats := Audit.audit(holder)
		var layout := Layout.resolve(holder, stats.bounds)
		var spawn: Transform3D = layout.spawn
		if chosen.size() == 4: spawn = Transform3D(Basis(Vector3.UP, float(chosen[3])), Vector3(float(chosen[0]), float(chosen[1]), float(chosen[2])))
		var eye := spawn.origin + Vector3.UP * 1.6
		var bounds: AABB = stats.bounds
		print("%s scale %s: size %.1f x %.1f x %.1f m, layout %s" % [slug, scale, bounds.size.x, bounds.size.y, bounds.size.z, layout.source])
		if pictures:
			camera.fov = 80.0
			camera.look_at_from_position(eye, eye - spawn.basis.z, Vector3.UP)
			for frame in 3: await process_frame
			await RenderingServer.frame_post_draw
			var shot := root.get_texture().get_image()
			shot.resize(768, 432, Image.INTERPOLATE_LANCZOS)
			shot.save_jpg(args[0].path_join(slug + ".jpg"), 0.85)
			holder.free()
			continue
		var views := {"front": -spawn.basis.z, "back": spawn.basis.z, "left": -spawn.basis.x}
		for name in views:
			var ahead: Vector3 = views[name]
			var figure := _reference(Color(1.0, 0.0, 0.8), Vector3(0.45, 1.7, 0.2))
			var ruler := _reference(Color(1.0, 0.9, 0.0), Vector3(1.0, 0.03, 0.1))
			root.add_child(figure)
			root.add_child(ruler)
			figure.global_transform = Transform3D(Basis.looking_at(ahead, Vector3.UP), spawn.origin + ahead * 2.5 + Vector3.UP * 0.85)
			ruler.global_transform = Transform3D(Basis.looking_at(ahead, Vector3.UP), spawn.origin + ahead * 2.0 + Vector3.UP * 0.02)
			camera.look_at_from_position(eye, eye + ahead, Vector3.UP)
			for frame in 3: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(args[0].path_join("%s_%s.png" % [slug, name]))
			figure.free()
			ruler.free()
		holder.free()
	quit(0)
