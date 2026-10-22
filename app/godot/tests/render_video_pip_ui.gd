extends SceneTree
const PipTest := preload("res://tests/test_video_pip.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/video-pip")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1200, 900)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 70; origin.add_child(camera)
	var video := PipTest.Surface.new(); origin.add_child(video); video.geometry = 3; video.stereo_sbs = true; video._apply_geometry()
	video.panel.visible = false
	video.pip.toggle_slot(1, camera.global_transform); video.pip.toggle_slot(2, camera.global_transform); video.pip.toggle_slot(3, camera.global_transform)
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, null, [], false, true)
	for slot in video.pip.windows:
		var window: Node3D = video.pip.windows[slot]
		window.controls = true; window.refresh(); capture.register_companion(window)
	capture.update(); await frames()
	var captured := []
	for value in capture.slots:
		if value.used:
			captured.append({"index":value.index,"rect":str(value.rect),"nodes":value.nodes.map(func(node): return {"type":node.get_class(),"position":str(node.position),"text":node.text if node is Label3D else "", "priority":Capture._priority(node),"layer":node.layers})})
	FileAccess.open(output.path_join("toolbar-captures.json"),FileAccess.WRITE).store_string(JSON.stringify(captured,"\t"))
	check(capture.layer_reservation() == 5, "Three floating toolbars reuse the existing provider budget")
	for slot in video.pip.windows:
		var window: Node3D = video.pip.windows[slot]
		var controls: Array = capture.slots.filter(func(value): return value.used and value.nodes.has(window._buttons[0].node))
		check(controls.size() == 1, "Each camera toolbar receives an independent high-density plane")
		check(window.frame.layers == 1 and not controls[0].nodes.has(window.frame), "Video pixels never join the menu capture")
		check(controls[0].raw.size.x >= 1024, "Toolbar capture preserves existing high-resolution policy")
		var pixels: Image = controls[0].raw.get_texture().get_image()
		pixels.save_png(output.path_join("toolbar-hd-%d.png" % slot))
		var centres: Array = window._buttons.map(func(button): return button.node.global_position)
		centres.append(window._labels[0].global_position)
		for centre: Vector3 in centres:
			var point: Vector2 = controls[0].camera.unproject_position(centre)
			var area := Rect2i(Vector2i(point) - Vector2i(45,45), Vector2i(90,90)).intersection(Rect2i(Vector2i.ZERO,pixels.get_size()))
			var ink := 0
			for y in range(area.position.y,area.end.y):
				for x in range(area.position.x,area.end.x):
					if pixels.get_pixel(x,y).r > 0.8: ink += 1
			check(ink > 20, "HD capture contains camera %d control at %s: %d ink pixels" % [slot,point,ink])
	capture.set_active(false)
	var first: Node3D = video.pip.windows[1]
	first.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.26, -1.2))
	first.shape_open = true; first.refresh()
	await frames(); viewport.get_texture().get_image().save_png(output.path_join("window-new-controls.png"))
	capture.set_active(true); capture.set_process(false); capture.update(); await frames()
	for window in video.pip.windows.values(): window.controls = false; window.shape_open = false; window.refresh()
	capture.update()
	check(capture.active == null and capture.slots.all(func(value): return not value.used), "Hidden toolbars release their capture planes without retaining stale UI")
	# A circular source must stay circular in square, landscape and portrait crops.
	capture.shutdown("circle_test"); video.pip.clear()
	var window := preload("res://scripts/video_pip_window.gd").new(); origin.add_child(window)
	window.global_position = Vector3(0, 0, -1.5); window.frame.visible = true; window.source_aspect = 2.0
	var image := Image.create(512,256,false,Image.FORMAT_RGBA8); image.fill(Color.BLACK)
	for y in range(80,176):
		for x in range(208,304):
			if Vector2(x-256,y-128).length() < 44: image.set_pixel(x,y,Color.WHITE)
	window.picture.set_shader_parameter("color_texture",ImageTexture.create_from_image(image))
	window.picture.set_shader_parameter("source_size",Vector2(512,256))
	window.picture.set_shader_parameter("alpha_enabled",false)
	for shape in [1,3,4]:
		window.set_size(Vector2(0.8,0.45)); window.set_aspect(shape); window.crop_parameters(); await frames()
		var rendered := viewport.get_texture().get_image()
		var lo := Vector2i(1200,900); var hi := Vector2i.ZERO
		for y in 900:
			for x in 1200:
				var pixel := rendered.get_pixel(x,y)
				if pixel.r > 0.9 and pixel.g > 0.9 and pixel.b > 0.9: lo=lo.min(Vector2i(x,y));hi=hi.max(Vector2i(x,y))
		var extent := hi-lo
		check(extent.x > 30 and absf(float(extent.x)/maxi(1,extent.y)-1.0)<0.025, "Aspect %d crops the source without stretching a circle" % shape)
		rendered.save_png(output.path_join("shape-%d.png" % shape))
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP UI render: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
