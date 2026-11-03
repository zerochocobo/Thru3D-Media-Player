extends SceneTree
## Real decoded sample frames, production video surface and menus. Desktop GL only.
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func capture(viewport: SubViewport, path: String, crop := Rect2i()) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if crop.has_area(): image = image.get_region(crop)
	check(image.save_png(path) == OK, "Save " + path.get_file())

func run() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("NATIVE_ALPHA_PROBE_INPUT")))
	var output := str(config.output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 512); viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 90; camera.far = 100; viewport.add_child(camera)
	var video := Video.new(); viewport.add_child(video); video.set_process(false)
	video.view_camera = camera; video.sharpness = 0.0
	video.geometry = 1; video.stereo_sbs = true
	video.media.last_pair = {"pts_us": 12000000}
	video.material.set_shader_parameter("alpha_enabled", false)
	for entry in config.frames:
		var source := Image.load_from_file(str(entry.frame))
		check(source != null and not source.is_empty(), "Decoded sample frame exists")
		if source == null: continue
		video.media.format = {"width": source.get_width(), "height": source.get_height(), "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
		video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(source))
		video.material.set_shader_parameter("source_size", Vector2(source.get_size()))
		video._apply_geometry(); video.panel.visible = true
		video.set_packed_mask(true)
		check(video.geometry == 1 and video.material.get_shader_parameter("packed_alpha") == true, "Native mask activates without changing 180")
		for eye in 2:
			video.set_viewing_eye(eye + 1)
			await capture(viewport, output.path_join("alpha-%d-%d.png" % [entry.index, eye]))
		video.set_packed_mask(false)
		await capture(viewport, output.path_join("opaque-%d.png" % entry.index))
		var opaque := viewport.get_texture().get_image()
		check(opaque.get_pixel(256, 256).a > 0.99 and not video.alpha_requested, "Off returns opaque without AI")
	video.free(); viewport.free()
	await process_frame
	await render_menu(output)
	for failure in failures: push_error(failure)
	print("Native Alpha render checks=%d failures=%d; desktop only" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func render_menu(output: String) -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 800); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 1.6; viewport.add_child(camera)
	var state := {"has_video": true, "geometry": 1, "stereo": true, "playing": true, "packed_mask_available": true,
		"packed_mask": true, "alpha_requested": true, "alpha_enabled": true, "title": "180° SBS · Alpha", "fisheye_fov": 180,
		"duration_ms": 77322, "position_ms": 12000, "volume": 80, "audio_available": true}
	var menu := Menu.new(); menu.state_provider = func(): return state
	viewport.add_child(menu); menu.set_process(false); menu.position = Vector3(0, -0.22, -1.4)
	menu.visible = true; menu._mode_open = true
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for geometry in ([0, 1, 2, 3] if language == "zh" else [1]):
			state.geometry = geometry; menu.refresh()
			var native: Array = menu._buttons.filter(func(b): return b.target == Menu.MODE_PACKED)
			check(native.size() == (1 if geometry in [1, 2] else 0), "Visibility " + str(geometry))
			if not native.is_empty():
				var caption: Label3D = native[0].node.get_child(0)
				check(menu.text_width(caption.text, menu.TEXT_BODY) <= native[0].rect.size.x - 0.012, "Native label fits " + language)
				for other in menu._buttons:
					if other.target != Menu.MODE_PACKED: check(not other.rect.intersects(native[0].rect), "Native hit target separate from " + str(other.target))
			await capture(viewport, output.path_join("menu-%s-%d.png" % [language, geometry]), Rect2i(120, 150, 1040, 560))
	I18n.use("zh"); state.geometry = 1; state.packed_mask = false; state.alpha_requested = false
	menu.refresh(); await capture(viewport, output.path_join("menu-zh-off.png"), Rect2i(120, 150, 1040, 560))
	state.top_bottom = true; state.packed_mask_available = false
	menu.refresh(); await capture(viewport, output.path_join("menu-zh-disabled.png"), Rect2i(120, 150, 1040, 560))
	viewport.free(); await process_frame
