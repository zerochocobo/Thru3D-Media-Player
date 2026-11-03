extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func choose(menu: Node3D, value: bool) -> bool:
	for id in menu.choices.targets:
		var choice: Dictionary = menu.choices.targets[id]
		if choice.get("key") != "video_auto_3d" or choice.get("value") != value: continue
		for button in menu._buttons:
			if button.target != id or not button.enabled: continue
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			var direction: Vector3 = -button.node.global_basis.z
			menu.press_pointer("right", origin, direction, true)
			menu.release_pointer("right", origin, direction, true)
			return true
	return false

func _run() -> void:
	I18n.use("en")
	var main := Main.new()
	var output := ProjectSettings.globalize_path("res://../../build/output/video-auto-3d-20261103")
	DirAccess.make_dir_recursive_absolute(output)
	main.settings_path = output.path_join("settings.cfg")
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///auto-3d-ui.mp4"; video.media.begin(7)
	var library := Library.new(); main.recent_menu = library
	library.settings_provider = main._library_settings; library.setting_changed.connect(main._on_setting_changed)
	root.add_child(library); library.set_process(false)
	library.visible = true; library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB; library.refresh()
	var menu := Menu.new(); main.player_menu = menu
	menu.state_provider = main._menu_state; menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu.section = 1; menu.refresh()
	main.settings.set_value("effects", "auto_3d", true)
	check(not video.Auto3D.load_enabled(main.settings) and not video.default_auto_depth, "Existing photo conversion does not enable the video default")
	var row_keys: Array = library.rows.map(func(row): return row.get("key", ""))
	check(row_keys.find("video_auto_3d") >= 0 and row_keys.find("video_auto_3d") + 1 == row_keys.find("depth_render"), "Global default directly precedes its effect setting")
	check(not library.rows[row_keys.find("video_auto_3d")].has("hint"), "Tooltip is not repeated as permanent explanatory text")
	for stereo in [false, true]:
		video.stereo_sbs = stereo; menu.refresh()
		var default_tile: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("video_auto_3d"))[0]
		var effect_tile: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("depth_render"))[0]
		check(is_equal_approx(default_tile.rect.position.y, effect_tile.rect.position.y) and default_tile.rect.position.x < effect_tile.rect.position.x, "Related 3D settings share one row for mono and stereo")
	video.stereo_sbs = false; menu.refresh()
	check(choose(library, true) and video.default_auto_depth, "Library ray enables the shared video default")
	check(not video.depth_requested and not video.auto_depth and main.settings.get_value("effects", "auto_3d"), "Changing default preserves the current video and photo preference")
	var stored := ConfigFile.new(); stored.load(main.settings_path)
	check(video.Auto3D.load_enabled(stored), "Enabled choice persists for startup")
	menu.refresh_values()
	check(menu._setting_choices("video_auto_3d").value, "Open playback settings refresh from the library choice")
	check(choose(menu, false) and not video.default_auto_depth, "Playback ray disables the same global preference")
	check(not library.rows.filter(func(row): return row.get("key") == "video_auto_3d")[0].value, "Open library refreshes after the playback choice")
	stored.load(main.settings_path)
	check(not video.Auto3D.load_enabled(stored), "Disabled choice persists for startup")
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language); menu.refresh(); library.refresh()
		var labels := menu.find_children("*", "Label3D", true, false)
		check(labels.any(func(label): return label.text == I18n.t(video.Auto3D.TITLE)), "Playback label is localized: " + language)
		check(menu._tips.values().has(I18n.t(video.Auto3D.HINT)) and library._tips.values().has(I18n.t(video.Auto3D.HINT)), "Both menus share the one-sentence tooltip: " + language)
		for label in labels:
			if label.text != I18n.t(video.Auto3D.TITLE): continue
			check(menu.FONT.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size < 0.44,
				"Setting heading fits its tile: " + language)
	video.geometry = 1; video.stereo_sbs = true; menu.refresh()
	check(choose(menu, true) and video.default_auto_depth and not video.depth_requested, "VR playback can change the future default without converting its current video")
	I18n.use("en")
	main.recent_menu = null; main.player_menu = null
	library.free(); menu.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Video auto 3D: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
