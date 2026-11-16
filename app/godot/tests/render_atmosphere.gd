extends SceneTree
## Desktop pictures of every atmosphere theme, with a flat screen to keep clear and a floor.
const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const Field := preload("res://scripts/atmosphere/atmosphere_field.gd")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/atmosphere/render")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color(0.05, 0.07, 0.11)
	viewport.add_child(environment)
	var head := Vector3(0, 1.6, 0)
	var camera := Camera3D.new(); camera.current = true; camera.fov = 80; camera.position = head; viewport.add_child(camera)
	var screen := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(3.2, 1.8); screen.mesh = quad
	var picture := StandardMaterial3D.new(); picture.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; picture.albedo_color = Color(0.22, 0.24, 0.30)
	screen.material_override = picture; screen.position = Vector3(0, 1.7, -3.5); viewport.add_child(screen)
	var ground := MeshInstance3D.new(); var plane := PlaneMesh.new(); plane.size = Vector2(30, 30); ground.mesh = plane
	var soil := StandardMaterial3D.new(); soil.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; soil.albedo_color = Color(0.09, 0.10, 0.12)
	ground.material_override = soil; viewport.add_child(ground)
	var field := Field.new(); viewport.add_child(field)
	var frame := {"transform": screen.global_transform, "size": quad.size}
	var failed := false
	for id in Catalog.ids():
		for keep in [true, false]:
			field.build(id, 1, false)
			for step in 240: field.step(1.0 / 60.0, true, head, 0.0, frame if keep else {}, false)
			screen.visible = keep
			await process_frame; await process_frame; await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			image.save_png(output.path_join("%s%s.png" % [id, "" if keep else "-open"]))
			if keep:
				# The picture's own pixels must stay exactly its colour.
				var a := camera.unproject_position(screen.to_global(Vector3(-1.5, 0.8, 0)))
				var b := camera.unproject_position(screen.to_global(Vector3(1.5, -0.8, 0)))
				var expected := image.get_pixelv(Vector2i((a + b) * 0.5))
				var touched := 0
				for y in range(int(a.y), int(b.y), 3):
					for x in range(int(a.x), int(b.x), 3):
						var pixel := image.get_pixel(x, y)
						if absf(pixel.r - expected.r) + absf(pixel.g - expected.g) + absf(pixel.b - expected.b) > 0.02: touched += 1
				print("%s: %d particles, %d sampled picture pixels touched" % [id, field.particle_count(), touched])
				if touched > 0: failed = true
			field.clear()
	await _menu(output)
	quit(1 if failed else 0)

## The scene menu's atmosphere row, in each language.
func _menu(output: String) -> void:
	var Menu := load("res://scripts/scenery_menu.gd")
	var Library := load("res://scripts/background_library.gd")
	var I18n := load("res://scripts/i18n.gd")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1500, 1500); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.current = true; viewport.add_child(camera)
	var library: Node = Library.new(); library.directory = output.path_join("library-" + str(Time.get_ticks_usec())); viewport.add_child(library)
	var air := {"theme": "snow", "amount": 1, "sound": true, "folder": false}
	var menu: Node3D = Menu.new(); menu.library = library
	menu.state_provider = func(mode): return {"selected": "belfast", "choice": "belfast", "status": "", "busy": false, "import_progress": {}, "atmosphere": air}
	menu.command.connect(func(operation, value):
		if operation == "atmosphere": air[value.key] = value.value)
	viewport.add_child(menu)
	for language in ["zh", "en", "ja"]:
		I18n.use(language); menu.open("global")
		await create_timer(.15).timeout; await RenderingServer.frame_post_draw
		var a := camera.unproject_position(menu.to_global(Vector3(-.80, menu._top + .055, 0)))
		var b := camera.unproject_position(menu.to_global(Vector3(.80, menu._bottom - .10, 0)))
		viewport.get_texture().get_image().get_region(Rect2i(Vector2i(a.floor()), Vector2i((b - a).ceil()))).save_png(output.path_join("menu-%s.png" % language))
		menu.visible = false
	# Pressing the row's buttons sends the choice and redraws with it.
	menu._activate(menu.ATMOSPHERE + 1); menu._activate(menu.ATMOSPHERE_AMOUNT); menu._activate(menu.ATMOSPHERE_SOUND)
	print("menu: ", air)
	if air.theme != "rain" or air.amount != 2 or air.sound != false: printerr("Atmosphere row commands failed"); quit(1)
	menu._activate(menu.ATMOSPHERE)
	if air.theme != "": printerr("Atmosphere off failed"); quit(1)
