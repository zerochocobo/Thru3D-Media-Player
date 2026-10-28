extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Controls := preload("res://scripts/immersive_adjustments.gd")
const Overlay := preload("res://scripts/immersive_adjustment_overlay.gd")
var feedback: Array[Dictionary] = []
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/immersive-adjustments/render")
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1600, 1200); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.fov = 60; view.add_child(camera)
	var overlay := Overlay.new(); overlay.source = func(): return feedback
	camera.add_child(overlay); overlay.set_process(false)
	var state := {"has_video": true, "stereo": true, "geometry": 1, "viewing_eye": 0,
		"view_horizontal": 12.5, "view_vertical": -6.4, "view_zoom": 15.0, "stereo_horizontal": .75, "screen_rotation": 0.0}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position = Vector3(0, -.35, -1.8)
	menu.toggle(); menu.section = 1; menu._adjustment = "screen"
	var library := Library.new(); camera.add_child(library)
	library.settings_provider = func(): return {}
	library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.CONTROLS_TAB
	library.position = Vector3(0, 0, -1.8); library.visible = false
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.visible = true; library.visible = false
		for stereo in [true, false]:
			state.stereo = stereo; menu.refresh()
			await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			check(view.get_texture().get_image().save_png(output.path_join("settings_%s_%s.png" % [language, "stereo" if stereo else "mono"])) == OK, "Render VR settings " + language)
			check(menu._adjust_rows.size() == (5 if stereo else 4), "All picture sliders visible " + language)
			for target in [Menu.VR_HORIZONTAL, Menu.VR_VERTICAL, Menu.VR_ZOOM]:
				var row: Dictionary = menu._adjust_rows[target]
				check(row.button.enabled and row.label.text.contains("%"), "Usable slider with value " + language)
			var reset: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.VR_RESET)[0]
			var label: Label3D = reset.node.get_child(0)
			check(menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size < reset.rect.size.x - .02, "Reset caption fits " + language)
		menu.visible = false; library.visible = true; library.controls_page.mode = 0; library.refresh()
		var rows := library.controls_page.items()
		var start := rows.find(rows.filter(func(row): return row.get("fixed", "") == "Left grip + stick ← / →")[0])
		library.scroll = start; library.refresh()
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(view.get_texture().get_image().save_png(output.path_join("instructions_%s.png" % language)) == OK, "Render fixed instructions " + language)
		var shown := "\n".join(library.find_children("*", "Label3D", true, false).filter(func(label): return label.is_visible_in_tree()).map(func(label): return label.text))
		for title in ["Horizontal position", "Vertical position", "Depth / zoom", "Stereo horizontal alignment", "Reset VR adjustments"]:
			check(shown.contains(I18n.t(title)), "Fixed instruction visible " + language + " " + title)
		var fixed_count := 0
		for button in library._buttons:
			if button.target < Library.ROW_BASE or button.target >= Library.ROW_BASE + library._drawn_slots(): continue
			var index: int = library._first_line() + button.target - Library.ROW_BASE
			if index < rows.size() and rows[index].get("fixed", "") in ["Left grip + stick ← / →", "Left grip + stick ↑ / ↓", "Right grip + stick ↑ / ↓", "Right grip + stick ← / →", "Either grip + same stick press"]:
				fixed_count += 1
				check(not button.enabled and not button.has("choice_key"), "Fixed instruction cannot be rebound " + language)
		check(fixed_count == 5, "All fixed controls fit one scrolled page " + language)
		library.visible = false; menu.visible = false
		for key in Controls.TITLES:
			var meter := Controls.new()
			meter.show_feedback(key, -7.75 if key == "stereo_horizontal" else -.125, "movie", 1000)
			feedback = meter.feedback_snapshot("movie", 1000); overlay.refresh()
			await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var gauge: Node3D = overlay.rows[0]
			check(overlay.visible and gauge.clock.text.contains(I18n.t(Controls.TITLES[key])) and gauge.clock.text.contains("%"), "Gauge identifies active metric and value " + language + key)
			check(gauge.clock.get_aabb().size.x <= gauge.WIDTH + .01, "Localized gauge caption fits " + language + key)
			check(gauge.thumb.position.x < gauge.origin.position.x and gauge.fill.visible, "Negative adjustment fills left of zero")
			check(view.get_texture().get_image().save_png(output.path_join("gauge_%s_%s.png" % [language, key])) == OK, "Render live gauge " + language + key)
		var paired := Controls.new()
		paired.show_feedback("view_vertical", .18, "movie", 1000); paired.show_feedback("stereo_horizontal", 10.0, "movie", 1000)
		feedback = paired.feedback_snapshot("movie", 1000); overlay.refresh()
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(overlay.rows[0].visible and overlay.rows[1].visible and overlay.rows[0].position.y - overlay.rows[1].position.y > .135, "Two gauges stay separate " + language)
		check(overlay.rows[1].maximum.text == "+10%" and overlay.rows[1].minimum.text == "-10%", "Horizontal gauge endpoints show new limits")
		check(view.get_texture().get_image().save_png(output.path_join("gauge_%s_paired.png" % language)) == OK, "Render simultaneous hands " + language)
		feedback = paired.feedback_snapshot("movie", 2025); overlay.refresh()
		check(is_equal_approx(overlay.rows[0].clock.modulate.a, .5), "Gauge text fades with its plate")
		feedback = []; overlay.refresh()
		check(not overlay.visible and not overlay.rows[0].visible and not overlay.rows[1].visible, "Expired feedback leaves no visible primitives")
	view.free()
	for failure in failures: push_error(failure)
	print("Immersive adjustments render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
