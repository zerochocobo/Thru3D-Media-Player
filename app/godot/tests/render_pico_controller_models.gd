extends SceneTree
const Pico := preload("res://scripts/pico_controller_model.gd")
const Visuals := preload("res://scripts/input_visuals.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/pico-controller-models")
	DirAccess.make_dir_recursive_absolute(output)
	var viewports := []
	var models := []
	var visuals := Visuals.new()
	for id in ["pico-neo3", "pico-4", "pico-4u"]:
		for left in [true, false]:
			var viewport := SubViewport.new(); viewport.size = Vector2i(480, 380)
			viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			root.add_child(viewport); viewports.append(viewport)
			var environment := WorldEnvironment.new(); environment.environment = Environment.new()
			environment.environment.background_mode = Environment.BG_COLOR
			environment.environment.background_color = Color(0.045, 0.06, 0.085)
			viewport.add_child(environment)
			var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.26
			viewport.add_child(camera); camera.position = Vector3(0.20 if left else -0.20, 0.23, 0.30)
			camera.look_at(Vector3(0, 0.005, 0.005))
			var model := Pico.new(); viewport.add_child(model); models.append(model)
			check(model.setup(id, left), "Load preview " + id)
			visuals._prepare_meshes(model, false)
			var title: String = {"pico-neo3": "PICO Neo3", "pico-4": "PICO 4 / 4 Pro", "pico-4u": "PICO 4 Ultra"}[id]
			var label := Label.new(); label.text = title + ("  ·  Left" if left else "  ·  Right")
			label.position = Vector2(20, 15); label.add_theme_font_size_override("font_size", 22)
			viewport.add_child(label)
	visuals.free()
	var neutral_images := []
	for pressed in [false, true]:
		for model in models:
			model.update_inputs({"trigger": 1.0, "grip": 1.0, "primary": Vector2(0.6, 0.8), "primary_click": true,
				"ax_button": true, "by_button": true, "menu_button": true} if pressed else {})
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var sheet := Image.create(1440, 760, false, Image.FORMAT_RGBA8)
		for i in viewports.size():
			var image: Image = viewports[i].get_texture().get_image()
			var geometry_pixels := 0
			var changed := 0
			for y in range(70, 365):
				for x in range(20, 460):
					var color := image.get_pixel(x, y)
					if color.r > 0.3 and color.g > 0.3 and color.b > 0.3: geometry_pixels += 1
					if pressed:
						var previous: Color = neutral_images[i].get_pixel(x, y)
						if absf(color.r - previous.r) + absf(color.g - previous.g) + absf(color.b - previous.b) > 0.12: changed += 1
			check(geometry_pixels > 1000, "Model has visible textured geometry %d: %d" % [i, geometry_pixels])
			if pressed: check(changed > 20, "Pressed controls change rendered geometry %d: %d pixels" % [i, changed])
			else: neutral_images.append(image)
			sheet.blit_rect(image, Rect2i(0, 0, 480, 380), Vector2i((i / 2) * 480, (i % 2) * 380))
		check(sheet.save_png(output.path_join("pressed.png" if pressed else "neutral.png")) == OK, "Save six-controller contact sheet")
	for viewport in viewports: viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("PICO controller render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
