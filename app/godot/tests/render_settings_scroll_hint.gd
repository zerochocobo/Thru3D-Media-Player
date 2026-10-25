extends SceneTree
## Production settings at both ends and between rows; output is disposable.
const Menu := preload("res://scripts/library_menu.gd")

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("THRU3D_TEST_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/settings-scroll-hint")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.set_process(false); menu.visible = true
	menu.I18n.use("zh")
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.DISPLAY_TAB
	menu.settings_provider = func(): return {"watch_color": "violet"}
	menu.refresh()
	for state in ["top", "float-high", "float-low", "fractional", "bottom", "short"]:
		if state == "short": menu.tab = Menu.BACKGROUND_TAB; menu.refresh()
		else:
			menu._set_scroll({"fractional": 0.66, "bottom": menu._max_scroll()}.get(state, 0.0))
			menu._settings_scroll_hint_time = 0.0
			menu._animate_settings_scroll_hint(Menu.SCROLL_HINT_PERIOD * (0.25 if state == "float-high" else (0.75 if state == "float-low" else 0.0)))
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		if viewport.get_texture().get_image().save_png(output.path_join(state + ".png")) != OK:
			push_error("Could not save " + state); quit(1); return
	# The existing eye-buffer animation path keeps compositor textures parked.
	menu.tab = Menu.DISPLAY_TAB; menu.refresh(); menu._set_scroll(0)
	if "--animation" in OS.get_cmdline_user_args():
		menu._settings_scroll_hint_time = 0.0
		for frame in 48:
			menu._animate_settings_scroll_hint(Menu.SCROLL_HINT_PERIOD / 48)
			await process_frame; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("float-%02d.png" % frame))
	var capture := preload("res://scripts/menu_composition.gd").new()
	viewport.add_child(capture); capture.configure(camera, camera, null, [menu], false, true); capture.set_process(false)
	capture.update()
	var signature: int = capture._visual_signature()
	var repaint_count: int = capture.repaints
	for step in 32:
		menu._animate_settings_scroll_hint(0.1)
		capture.update()
		if capture._visual_signature() != signature or capture.repaints != repaint_count:
			push_error("Arrow animation repainted the menu layer"); quit(1); return
	if menu._settings_scroll_hint.layers & camera.cull_mask == 0:
		push_error("Animated arrow is missing from the eye buffer"); quit(1); return
	capture.free(); menu.free(); viewport.free()
	print("Settings scroll hint render: 6 frames; animation keeps menu layers unchanged")
	quit(0)
