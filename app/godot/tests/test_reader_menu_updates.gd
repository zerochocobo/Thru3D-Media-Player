extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const Settings := preload("res://scripts/comic_reading_settings.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/player-improvements-20261105/ui")
	DirAccess.make_dir_recursive_absolute(output)
	var render := "--render" in OS.get_cmdline_user_args()
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(-0.12, 0, 2.2); camera.fov = 50; viewport.add_child(camera)
	var library := Library.new(); viewport.add_child(library); library.visible = true; library.set_process(false)
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for selected in [false, true]:
			library.section = Library.Section.WEB if selected else Library.Section.RECENT; library.refresh()
			var button: Dictionary = library._buttons.filter(func(b): return b.target == Library.NAV_BASE + Library.Section.WEB)[0]
			var title: Label3D = button.node.get_child(0)
			var beta: Label3D = button.node.find_children("*", "Label3D", true, false).filter(func(label): return label.text == "Beta")[0]
			var width := title.font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title.font_size).x * title.pixel_size
			var badge_width := beta.font.get_string_size(beta.text, HORIZONTAL_ALIGNMENT_LEFT, -1, beta.font_size).x * beta.pixel_size
			check(is_equal_approx(title.position.y, beta.position.y), "Browser title and Beta share one line: " + language)
			check(beta.position.x >= title.position.x + width + 0.011 and beta.position.x + badge_width <= 0.171, "Localized title and badge fit without overlap: " + language)
			check(title.text == I18n.t(Library.NAV[Library.Section.WEB]), "Browser title remains complete: " + language)
			for x in [title.position.x + width / 2, beta.position.x + badge_width / 2]:
				var origin: Vector3 = button.node.to_global(Vector3(x, 0, 0.5))
				check(library.ray_hit(origin, -button.node.global_basis.z).get("target") == button.target, "Title and badge retain one clickable target")
			if render:
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				viewport.get_texture().get_image().save_png(output.path_join(language + "-browser-" + str(selected) + ".png"))
	library.free()
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		var settings := Settings.new(); var state := settings.snapshot([])
		state.merge({"comic_supported": true, "has_image": true})
		var menu := Photo.new(); viewport.add_child(menu); menu.visible = true; menu.set_process(false)
		menu.state_provider = func(): return state
		menu.adjustment_requested.connect(func(key, value):
			settings.set_option(key, value); state.merge(settings.snapshot([]), true))
		var commits: Array = []
		var actions: Array = []
		menu.action_requested.connect(func(action): actions.append(action))
		menu.setting_requested.connect(func(key, value): commits.append([key, value]))
		menu._activate(menu.PHOTO_COMIC_VOICE)
		check(menu.choices.targets.values().any(func(field): return field.get("key") == "comic_speed"), "Reading speed has an interactive field: " + language)
		for custom in [false, true]:
			settings.voice_kind = "custom" if custom else "preset"
			state.comic_voice_kind = settings.voice_kind; menu.refresh()
			var labels := menu.find_children("*", "Label3D", true, false)
			check(labels.any(func(label): return label.text == I18n.t("Reading speed")), "Reading speed remains visible for preset and cloned voices")
			var preview: Dictionary = menu._buttons.filter(func(b): return b.target == menu.PHOTO_COMIC_PREVIEW)[0]
			for fraction in [0.15, 0.5, 0.85]:
				var preview_origin: Vector3 = preview.node.to_global(Vector3((fraction - 0.5) * preview.rect.size.x, 0, 0.5))
				check(not preview.enabled or menu.ray_hit(preview_origin, -preview.node.global_basis.z).get("target") == menu.PHOTO_COMIC_PREVIEW, "Available voice preview has an unobstructed target across its button")
			if preview.enabled:
				var preview_origin: Vector3 = preview.node.to_global(Vector3(0, 0, 0.5))
				menu.press_pointer("right_hand", preview_origin, -preview.node.global_basis.z, true)
				menu.release_pointer("right_hand", preview_origin, -preview.node.global_basis.z, true)
				check(actions.back() == "comic_preview", "Real ray click starts auditioning the selected voice")
			var target: int = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("key") == "comic_speed")[0]
			var slider: Dictionary = menu.choices.sliders[target]
			var origin: Vector3 = slider.node.to_global(Vector3(slider.left + slider.width * 0.8, 0, 0.5))
			var direction: Vector3 = -slider.node.global_basis.z
			check(menu.ray_hit(origin, direction).get("target") == target, "Reading speed slider is not covered by another row")
			menu.press_pointer("right_hand", origin, direction, true)
			check(menu.has_pointer_capture(), "Reading speed captures the hand ray while adjusting")
			menu.refresh_values()
			menu.release_pointer("right_hand", origin, direction, true)
			check(not menu.has_pointer_capture() and is_equal_approx(settings.speed, 1.7) and commits.back()[0] == "comic_speed", "Reading speed commits its multiplier on release")
			if render:
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				viewport.get_texture().get_image().save_png(output.path_join(language + "-reading-" + str(custom) + ".png"))
		menu.free()
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Reader menu updates: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
