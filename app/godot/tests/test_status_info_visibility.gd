extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Overlay := preload("res://scripts/playback_status_overlay.gd")
const Fps := preload("res://scripts/fps_overlay.gd")
const I18n := preload("res://scripts/i18n.gd")
const KEY := "show_status_info"
const HINT := "Show subtitle, narration and loading status in the upper left."
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/status-info-20261109")
var render := "--render" in OS.get_cmdline_user_args()
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func target(menu: Node3D, key: String, value: bool) -> int:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("key", "") == key and item.get("value") == value: return id
	return -1
func capture(view: SubViewport, name: String) -> void:
	if not render: return
	for i in 3: await process_frame; await RenderingServer.frame_post_draw
	view.get_texture().get_image().save_png(output.path_join(name + ".png"))
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1400, 1400); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.fov = 70; view.add_child(camera)
	var main := Main.new(); main.settings_path = output.path_join("settings-%d.cfg" % Time.get_ticks_usec())
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	var menu := Menu.new(); menu.state_provider = main._menu_state
	view.add_child(menu); menu.set_process(false); menu.position = Vector3(0, -0.45, -1.55)
	main.player_menu = menu; main.video_menu = menu; menu.setting_requested.connect(main._on_player_setting)
	var library := Library.new(); library.settings_provider = main._library_settings
	view.add_child(library); library.set_process(false); main.recent_menu = library
	library.setting_changed.connect(main._on_setting_changed)
	library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB
	var fps := Fps.new(); view.add_child(fps); fps.set_process(false); fps.set_shown(true); main.fps_overlay = fps
	var overlay := Overlay.new(); overlay.source = main._playback_status_sample
	view.add_child(overlay); overlay.set_process(false); main.playback_status_overlay = overlay
	video.media.begin(7); video.media.state = "playing"; video.requested_play = true
	video.local_uri = "smb://fixture/movie.mp4"; video._waiting_first = false
	video._loading_status = {"remote": true, "phase": "buffering"}
	video.media.playback = {"details": {"paused_for_cache": "yes"}}
	menu.hide(); library.hide(); overlay.refresh()
	check(overlay.visible and main._menu_state()[KEY] and main._library_settings()[KEY], "Missing setting defaults on in HUD and both menus")
	main._on_setting_changed(KEY, false)
	check(not overlay.visible and overlay.text.is_empty() and fps.visible, "Global off clears HUD immediately and preserves FPS")
	check(not video.loading_caption().is_empty() and video.requested_play, "Hidden HUD preserves loading and playback")
	var saved := ConfigFile.new(); check(saved.load(main.settings_path) == OK and not saved.get_value("ui", KEY, true), "Off persists to disk")
	main.settings = saved
	check(main._playback_status_sample().is_empty() and not main._menu_state()[KEY], "Reload preserves off")
	menu.show(); menu.section = 1; menu.refresh()
	check(menu._panel_status.text.contains(I18n.t("Buffering…")), "Loading remains visible inside the menu")
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.hide(); library.show(); library.refresh()
		library._set_scroll(library._max_scroll(), false)
		var index := -1
		for i in library.rows.size():
			if library.rows[i].get("key", "") == KEY: index = i
		check(index >= 0 and library.rows[index + 1].key == "show_fps", language + " global switch immediately above FPS")
		var id := target(library, KEY, true)
		check(id >= 0 and library._tips.get(id) == I18n.t(HINT), language + " global localized tooltip")
		if id >= 0: library.choices.action(id)
		check(main._menu_state()[KEY] and main._library_settings()[KEY], language + " global choice synchronizes both menus")
		await capture(view, "global-" + language)
		library.hide(); menu.show(); menu.section = 1; menu.refresh()
		id = target(menu, KEY, false)
		var fps_id := target(menu, "show_fps", false)
		check(id >= 0 and menu._tips.get(id) == I18n.t(HINT), language + " player localized tooltip")
		if id >= 0 and fps_id >= 0:
			var status_button: Dictionary = menu._buttons.filter(func(b): return b.target == id)[0]
			var fps_button: Dictionary = menu._buttons.filter(func(b): return b.target == fps_id)[0]
			check(status_button.rect.position.y > fps_button.rect.end.y and fps_button.rect.position.y > Menu.POPUP_BOTTOM + 0.05, language + " rows have no overlap or bottom clipping")
			menu._hover = {"right_hand": id}; menu._update_tooltip()
			await capture(view, "player-" + language)
			menu._hover.clear(); menu._update_tooltip(); menu.choices.action(id)
		check(not main._library_settings()[KEY] and not menu._state[KEY], language + " player choice synchronizes global and visible menu")
	menu.hide(); library.hide(); overlay.refresh()
	video.media.playback = {}; main._on_player_setting(KEY, true)
	check(not overlay.visible and overlay.text.is_empty(), "Re-enabling does not replay expired buffering")
	video.media.playback = {"narration": {"startup_hold": true}}; overlay.refresh()
	check(overlay.visible, "New narration status appears when enabled")
	main._on_player_setting(KEY, false); overlay.refresh()
	check(not overlay.visible and not video.loading_caption().is_empty(), "Off hides narration without cancelling preparation")
	video.media.error = "Network failure"; video.media.state = "failed"; menu.show_playback_error()
	check(menu.visible and menu._state.error == "Network failure", "Failure panel survives disabled status HUD")
	main.free(); overlay.free(); fps.free(); library.free(); menu.free(); video.free(); view.free()
	for failure in failures: push_error(failure)
	print("Status info visibility: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
