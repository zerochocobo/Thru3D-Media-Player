extends Node
## Run the same source against real debug and release engine binaries, no export.
const Feature := preload("res://scripts/environments/cinema_feature.gd")
const Background := preload("res://scripts/app_background.gd")
const CinemaHost := preload("res://scripts/environments/cinema_environment.gd")
const Main := preload("res://scripts/main.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func _ready() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FAIL: " + message)

func _run() -> void:
	var debug := OS.is_debug_build()
	var expected := "--expect-debug" if debug else "--expect-release"
	check(expected in OS.get_cmdline_user_args(), "The actual engine build matches the requested test variant")
	check(Feature.enabled() == debug, "Feature policy follows the engine build")
	check(Feature.normalize_background("cinema") == ("cinema" if debug else "belfast"), "Saved experimental background is safe for this build")
	for choice in ["belfast", "dark", "passthrough", "custom"]:
		check(Feature.normalize_background(choice) == choice, "Ordinary background is unchanged: " + choice)
	I18n.use("en")
	var output := ProjectSettings.globalize_path("res://../../build/output/cinema-build-gate/" + ("debug" if debug else "release"))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--gate-output="): output = argument.trim_prefix("--gate-output=")
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "cinema")
	config.set_value("ui", "language", "en")
	config.set_value("privacy", "history", "none")
	config.save(output.path_join("settings.cfg"))
	var main := Main.new()
	main.settings_path = output.path_join("settings.cfg")
	get_tree().root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false)
	main.report_timer.stop()
	check(main.background.choice == ("cinema" if debug else "belfast"), "Production startup handles a persisted debug cinema choice")
	check((main.cinema_environment != null) == debug, "Only debug creates the production cinema host")
	if debug:
		var deadline := Time.get_ticks_msec() + 30000
		while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await get_tree().process_frame
		main._update_background()
		check(main._cinema_scene_active(), "Debug still loads and activates the bundled cinema")
		check(main._cinema_request_interaction("seat"), "Debug allows seat selection")
		check(main._cinema_request_interaction("move"), "Debug allows scene movement")
	else:
		check(not main._cinema_scene_active(), "Release never activates a saved cinema scene")
		main._on_setting_changed("background", "cinema")
		check(main.background.choice == "belfast", "Release rejects direct cinema background selection")
		check(not main._cinema_request_interaction("seat") and not main._cinema_request_interaction("move"), "Release rejects scene interaction")
		main._on_menu_action("cinema_home")
		check(main.cinema_environment == null, "Release cannot create the host through a stale action")
		var environment := CinemaHost.new()
		get_tree().root.add_child(environment)
		environment.configure(main.xr_origin, main.xr_camera)
		environment.select(true); environment._begin_loading()
		check(not environment.selected and not environment.loading and not environment._requested_model and environment._thread == null and environment._manifest.is_empty(), "Release host rejects direct model and navigation loading")
		environment.queue_free()
		main._set_cinema_mode(true)
		check(main.video.cinema.enabled, "Existing upright cinema screen placement remains available in release")
	var stale := {"background": "cinema", "cinema_ready": true, "cinema_seat": "J15"}
	var library := Library.new()
	library.settings_provider = func(): return stale
	library.section = Library.Section.SETTINGS; library.tab = Library.BACKGROUND_TAB
	get_tree().root.add_child(library); library.toggle(); library.set_process(false)
	var background_row: Dictionary = library.rows[0]
	check(background_row.choices.any(func(option): return option.value == "cinema") == debug, "Background menu exposes the auditorium only in debug")
	check(str(background_row.value) == ("cinema" if debug else "belfast"), "Background menu normalizes stale release settings")
	check(library.rows.any(func(row): return row.get("key", "") == "cinema_interaction") == debug, "Seat and movement settings are hidden in release")
	check(library.rows.any(func(row): return row.get("setting", []) == ["cinema_home", true]) == debug, "Reset-seat action is hidden in release")
	var player := Player.new()
	player.state_provider = func(): return {"has_video": true, "geometry": 0, "screen_scene_locked": true}
	get_tree().root.add_child(player); player.toggle(); player.section = 1; player._adjustment = "screen"; player.refresh()
	var cinema_buttons := 0
	for button in player._buttons:
		if int(button.target) in [Player.CINEMA_SEAT, Player.CINEMA_MOVE, Player.CINEMA_HOME]: cinema_buttons += 1
	check(cinema_buttons == (3 if debug else 0), "Playback screen settings do not expose release auditorium actions even with stale state")
	player.queue_free(); library.queue_free(); main.queue_free()
	await get_tree().process_frame; await get_tree().process_frame
	var result := {"actual_debug_build": debug, "checks": checks, "failures": failures, "passed": failures.is_empty(), "scope": "Actual Windows engine binaries on current source; no export, APK, installation or device tests."}
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")); file.close()
	print("CINEMA_BUILD_GATE debug=%s checks=%d failures=%d" % [debug, checks, failures.size()])
	get_tree().quit(0 if failures.is_empty() else 1)
