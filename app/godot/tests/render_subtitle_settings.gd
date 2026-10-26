extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Style := preload("res://scripts/subtitle_style.gd")
const Player := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("SUBTITLE_SETTINGS_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1050)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 60
	viewport.add_child(camera)
	var menu := Library.new()
	camera.add_child(menu)
	var state := {"subtitle_distance": 5.0, "subtitle_position": 0.0}
	menu.settings_provider = func(): return state
	menu.toggle()
	menu._activate(Library.NAV_BASE + Library.Section.SETTINGS)
	menu._activate(Library.TAB_BASE + Library.SUBTITLES_TAB)
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		state.subtitle_distance = 5.0; state.subtitle_position = 0.0; state.subtitle_direction = 0
		state.subtitle_size = 125.0; state.subtitle_style = "yellow_black"
		state.subtitle_line = 2
		menu._activate(Library.TAB_BASE + Library.VIDEO_TAB)
		check(menu.rows.size() == 4 and menu._max_scroll() == 0, "Video defaults to four rows with collapsed groups: " + language)
		await shot(viewport, output.path_join("video_" + language + ".png"))
		menu._choose(menu.rows.filter(func(row): return row.get("video_settings_group", "") == "alpha")[0])
		check(menu.rows.size() == 8, "All four Alpha controls expand: " + language)
		await shot(viewport, output.path_join("alpha_" + language + ".png"))
		menu._choose(menu.rows.filter(func(row): return row.get("video_settings_group", "") == "alpha")[0])
		menu._choose(menu.rows.filter(func(row): return row.get("video_settings_group", "") == "subtitles")[0])
		check(menu.rows.size() == 11, "All seven subtitle controls expand: " + language)
		await shot(viewport, output.path_join("subtitles_top_" + language + ".png"))
		menu._set_scroll(menu._max_scroll())
		await shot(viewport, output.path_join("subtitles_" + language + ".png"))
		var selected := 0; var previews := 0
		for button in menu._buttons:
			var item: Dictionary = menu.choices.targets.get(button.target, {})
			if item.get("key") != "subtitle_style": continue
			previews += 1
			var label: Label3D = button.node.get_child(0)
			var appearance := Style.colors(item.value)
			check(label.text == ("Aa" if language == "en" else I18n.t("Subtitle sample")) and label.modulate == appearance.text_color and label.outline_modulate == appearance.outline_color and label.outline_size > 0, "Style sample shows actual fill and outline: " + language + " " + item.value)
			check(label.outline_render_priority < label.render_priority, "Outline stays behind the sample text")
			check(menu._tips[button.target] == I18n.t(appearance.hint), "Each sample has a localized hover hint")
			var width := label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
			check(width + label.outline_size * 2 * label.pixel_size < button.rect.size.x, "Style sample fits its hit area")
			if button.base_color == menu.SELECTED: selected += 1
		check(previews == 5 and selected == 1, "Five visible styles and exactly one selection")
		check_line_choices(menu, language)
		check(menu.text_snapshot().contains(I18n.t("Subtitle direction")), "Explicit subtitle direction visible: " + language)
		for button in menu._buttons:
			if str(menu.choices.targets.get(button.target, {}).get("value", "")) != "cyan_black": continue
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			menu.update_pointer("right_hand", origin, -menu.global_basis.z, true)
			check(menu._tooltip.visible and menu._tooltip.get_child(0).text == I18n.t("Cyan / black outline"), "Ray hover exposes the style name")
			await shot(viewport, output.path_join("hover_" + language + ".png"))
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
			break
		# Settings fields beyond the visible list may neither draw nor take ray input.
		menu._set_scroll(0)
		for button in menu._buttons:
			if not button.has("list_row") or int(button.list_row) - Library.ROW_BASE < menu._lines(): continue
			check(not button.node.visible, "Offscreen setting field stays hidden")
			var hit: Dictionary = menu.ray_hit(button.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z)
			check(hit.get("target") != button.target, "Offscreen setting field cannot capture the ray")
		menu._set_scroll(menu._max_scroll())
		for direction in [0, 1]:
			state.subtitle_direction = direction
			for angle in [-60.0, 0.0, 60.0]:
				state.subtitle_horizontal_position = angle; state.subtitle_vertical_position = -angle / 2
				state.subtitle_distance = 0.1 if angle < 0 else 5.0
				menu.refresh()
				await shot(viewport, output.path_join("settings_%s_direction%d_%d.png" % [language, direction, angle]))
	menu.free()
	var player := Player.new()
	viewport.add_child(player)
	player.position = Vector3(0, -0.43, -1.85)
	player.set_process(false)
	var player_state := {"has_video": true, "source_uri": "file:///movie.mp4", "title": "影片", "duration_ms": 120000,
		"subtitle_track": 1, "subtitle_options": [{"id": 1, "codec": "subrip", "title": "简体中文"}, {"id": 2, "codec": "subrip", "title": "English"}],
		"subtitle_size": 125.0, "subtitle_style": "yellow_black", "subtitle_line": 2, "text_subtitle_tracks": 2}
	player.state_provider = func(): return player_state
	var track_names := {"zh": ["中文字幕", "英文字幕"], "zh_Hant": ["中文字幕", "英文字幕"], "en": ["Chinese subtitles", "English subtitles"], "ja": ["中国語字幕", "英語字幕"]}
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		player_state.title = I18n.t("Video")
		for index in 2: player_state.subtitle_options[index].title = track_names[language][index]
		for geometry in [0, 1]:
			player_state.geometry = geometry
			player.dismiss(); player.toggle(); player._activate(110)
			check(player._subtitle_open and not player._subtitle_appearance_open and player.choices.sliders.is_empty(), "Player appearance starts collapsed")
			await shot(viewport, output.path_join("player_%s_%s_collapsed.png" % [language, "flat" if geometry == 0 else "immersive"]))
			player._activate(Player.SUBTITLE_APPEARANCE)
			check(player._subtitle_appearance_open and player.choices.sliders.size() == (3 if geometry == 0 else 5), "Player disclosure opens all appropriate controls")
			var visual_styles := player.choices.targets.values().filter(func(item): return item.get("key") == "subtitle_style")
			check(visual_styles.size() == 5, "Player appearance contains the five visual samples")
			check_line_choices(player, language)
			await shot(viewport, output.path_join("player_%s_%s_expanded.png" % [language, "flat" if geometry == 0 else "immersive"]))
			player._activate(Player.SUBTITLE_APPEARANCE)
			check(player._subtitle_open and player.choices.sliders.is_empty(), "Player collapse retains subtitle selection panel")
		player_state.geometry = 0
		player_state.subtitle_options[0].codec = "hdmv_pgs_subtitle"
		player.dismiss(); player.toggle(); player._activate(110); player._activate(Player.SUBTITLE_APPEARANCE)
		check(player.choices.sliders.size() == 3 and not player.choices.targets.values().any(func(item): return item.get("key") == "subtitle_style"), "PGS exposes sync/size/position in every language")
		check(not player.choices.targets.values().any(func(item): return item.get("key") == "subtitle_line"), "PGS does not offer text line filtering")
		await shot(viewport, output.path_join("player_%s_pgs.png" % language))
		for seconds in [-1.5, 2.0]:
			player_state.subtitle_delay = seconds; player.refresh()
			var sync_ids := player.choices.sliders.keys().filter(func(id): return player.choices.targets[id].key == "subtitle_delay")
			check(sync_ids.size() == 1, "Each PGS panel has one sync slider")
			var sync: Dictionary = player.choices.sliders[sync_ids[0]]
			check(sync.label.text == "%+.1f s" % seconds and sync.reset.enabled and sync.reset.node.visible, "Signed time and active reset are visible")
			await shot(viewport, output.path_join("player_%s_pgs_sync_%s.png" % [language, "early" if seconds < 0 else "late"]))
		player_state.subtitle_delay = 0.0; player.refresh()
		for id in player.choices.sliders:
			if player.choices.targets[id].key == "subtitle_delay": check(not player.choices.sliders[id].reset.node.visible, "Zero sync has no visible reset")
		player_state.subtitle_options[0].codec = "subrip"
	viewport.queue_free()
	await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures}, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle settings render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_line_choices(menu: Node3D, language: String) -> void:
	var count := 0
	var selected := 0
	for button in menu._buttons:
		var item: Dictionary = menu.choices.targets.get(button.target, {})
		if item.get("key") != "subtitle_line": continue
		count += 1
		var label: Label3D = button.node.get_child(0)
		check(label.text == I18n.t(Style.LINE_CHOICES[int(item.value)].label), "Localized display line choice: " + language)
		var width := label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
		check(width < button.rect.size.x and button.node.visible, "Display line label fits visible ray target: " + language)
		if button.base_color == menu.SELECTED:
			selected += 1
			check(item.value == 2, "Second display line has selection highlight")
	check(count == 3 and selected == 1, "Three display choices and one selection: " + language)

func shot(viewport: SubViewport, path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(path)
