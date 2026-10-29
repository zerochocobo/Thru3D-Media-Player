extends SceneTree
const WindowScript := preload("res://scripts/video_pip_window.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var output := ProjectSettings.globalize_path("res://../../build/output/video-pip")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func draw() -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	I18n.use("zh")
	viewport = SubViewport.new(); viewport.size = Vector2i(1280, 800); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.85; viewport.add_child(camera)
	var state := {"has_video": true, "pip_count": 0, "pip_slots": []}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	viewport.add_child(menu)
	menu.toggle(); menu.position.z = -2; menu._activate(Menu.PIP)
	for slots in [[], [1], [1, 3], [1, 2, 3]]:
		state.pip_slots = slots; state.pip_count = slots.size(); menu.refresh()
		var image: Image = await draw()
		check(image.save_png(output.path_join("popup-add-%d.png" % slots.size())) == OK, "Popup state saved")
	state.pip_slots = [1]; state.pip_count = 1; menu.refresh()
	var number: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PIP_COUNT + 1)[0]
	menu.update_pointer("right_hand", number.node.to_global(Vector3(0,0,0.5)), -number.node.global_basis.z, true)
	var hovered: Image = await draw(); hovered.save_png(output.path_join("popup-hover-close.png"))
	check(menu.pip_controls._faces[0].icon.visible, "Close X is visible in the rendered hover state")
	menu._pip_open=false; camera.size=1.65
	for bookmarks in [false,true]:
		for music in [false,true]:
			state.bookmarks=[{"id":"a","position_ms":1000}] if bookmarks else []
			state.audio_play_during_video=music
			menu.refresh()
			var row_image: Image = await draw()
			check(row_image.save_png(output.path_join("entry-row-%d-%d.png" % [int(bookmarks),int(music)]))==OK,"Optional entry row rendered")
	menu.queue_free(); await process_frame
	camera.size = 0.85
	var window := WindowScript.new(); viewport.add_child(window); window.position = Vector3(0, 0.05, -2)
	window.frame.visible = true
	window.frame.material_override = window._material(Color(0.12, 0.22, 0.28), 1)
	window.controls = true; window.refresh()
	for state_name in ["rest", "right", "bottom", "corner", "held"]:
		window.set_resize_feedback({}, true)
		window.cancel_pointer("right_hand")
		var point: Vector2 = window.corner_point(3) if state_name in ["corner", "held"] else window.edge_point(3 if state_name == "right" else 1)
		if state_name == "held": window.set_resize_feedback({"corner": 3}, false)
		elif state_name != "rest": window.update_pointer("right_hand", window.to_global(Vector3(point.x, point.y, 0.8)), -window.global_basis.z, true)
		var feedback: Image = await draw()
		check(feedback.save_png(output.path_join("resize-feedback-%s.png" % state_name)) == OK, "Resize state rendered: " + state_name)
		if state_name != "rest":
			var centre := Vector2i(camera.unproject_position(window.to_global(Vector3(point.x, point.y, 0))))
			var ink := 0
			for y in range(centre.y - 18, centre.y + 18):
				for x in range(centre.x - 18, centre.x + 18):
					var pixel := feedback.get_pixel(x, y)
					if pixel.r > 0.85 and pixel.g > 0.6: ink += 1
			check(ink > 20, "Resize feedback produces bright pixels at the hit location: " + state_name)
	window.set_resize_feedback({}, true); window.cancel_pointer("right_hand")
	window.controls = true; window.shape_open = true; window.refresh()
	for shape in [0, 3]:
		window.set_aspect(shape)
		var image: Image = await draw(); image.save_png(output.path_join("ratio-selected-%d.png" % shape))
		var selected: Dictionary = window._buttons.filter(func(b): return b.get("selected", false))[0]
		var centre: Vector2 = camera.unproject_position(selected.node.global_position)
		var area := Rect2i(Vector2i(centre) - Vector2i(30, 15), Vector2i(60, 30))
		var white := 0
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				var pixel := image.get_pixel(x,y)
				if pixel.r > 0.8 and pixel.g > 0.8 and pixel.b > 0.8: white += 1
		check(white > 20, "Selected ratio has actual bright caption pixels")
	window.shape_open = false; window.zoom_open = true; window.zoom = 4; window.refresh()
	var image: Image = await draw(); image.save_png(output.path_join("zoom-selected-4.png"))
	check(window._buttons.filter(func(b): return b.get("selected", false)).size() == 1, "Exactly one zoom shows its check mark")
	var still := Image.create(400,200,false,Image.FORMAT_RGBA8)
	still.fill(Color(0.9,0.15,0.1))
	still.fill_rect(Rect2i(200,0,200,200),Color(0.1,0.8,0.25)); still.generate_mipmaps()
	window.show_image(ImageTexture.create_from_image(still)); window.controls=true; window.refresh()
	var picture: Image = await draw(); picture.save_png(output.path_join("image-frame.png"))
	var left: Vector2i = Vector2i(camera.unproject_position(window.to_global(Vector3(-0.1,0,0))))
	var right: Vector2i = Vector2i(camera.unproject_position(window.to_global(Vector3(0.1,0,0))))
	check(picture.get_pixelv(left).r > picture.get_pixelv(left).g and picture.get_pixelv(right).g > picture.get_pixelv(right).r, "Static image shader displays the complete image with correct horizontal orientation")
	check(window._buttons.size()==3 and window._buttons.all(func(b):return b.target in [1,5,6]), "Image toolbar separates close-window, replace-image, and return-to-video controls")
	window.queue_free(); await process_frame
	camera.size=2.1; camera.position.x=-0.1
	var library := preload("res://scripts/library_menu.gd").new()
	viewport.add_child(library); library.set_process(false); library.visible=true; library.position.z=-2
	library.begin_image_picker()
	for section in [library.Section.LOCAL,library.Section.CLOUD]:
		library.section=section
		if section==library.Section.CLOUD:
			library._cloud_stack=[{"id":"/images","title":"Images"}]
			library._cloud_total=100; library._cloud_next=1
		library.refresh()
		var picker: Image = await draw()
		check(picker.save_png(output.path_join("image-picker-%d.png" % section))==OK,"Image picker footer rendered with paging")
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP feedback render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
