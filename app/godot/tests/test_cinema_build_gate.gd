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
	check(Feature.enabled(), "Cinema is available in Debug and Release")
	check(Feature.normalize_background("cinema") == "cinema", "Saved cinema background is safe for this build")
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
	check(main.background.choice == "cinema", "Production startup handles a persisted debug cinema choice")
	check(main.cinema_environment != null, "Both builds create the production cinema host")
	var deadline := Time.get_ticks_msec() + 30000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	main._update_background()
	check(main._cinema_scene_active(), "Actual runtime loads and activates the bundled cinema")
	check(not main._cinema_request_interaction("seat"), "Retired seat-selection mode remains disabled")
	check(main._cinema_request_interaction("move"), "Both builds allow scene movement")
	check(main.cinema_environment._light_materials.size() >= 3, "Loaded scene attaches dual baked lighting materials")
	var stale := {"background": "cinema", "cinema_ready": true, "cinema_seat": "J15"}
	var library := Library.new()
	library.settings_provider = func(): return stale
	library.section = Library.Section.SETTINGS; library.tab = Library.BACKGROUND_TAB
	get_tree().root.add_child(library); library.toggle(); library.set_process(false)
	var background_row: Dictionary = library.rows[0]
	check(background_row.get("setting",[])==["scene_open",true],"Legacy tab state delegates to the scene picker")
	check(not Library.SETTING_ORDER.has(Library.BACKGROUND_TAB),"Global settings hide the obsolete Background category")
	main.scenery_menu.open("global"); main.scenery_menu.view="adjust"; main.scenery_menu.refresh()
	check(main.scenery.library.allowed("global","cinema"),"Both builds retain cinema capability")
	check(main.scenery_menu.choices.targets.values().any(func(item): return item.get("key","")=="cinema_interaction"),"Both builds expose movement in scene adjustments")
	check(main.scenery_menu._buttons.any(func(item): return item.target==main.scenery_menu.CURRENT),"Both builds expose return to start")
	main.scenery_menu.dismiss()
	var player := Player.new()
	player.session_controls_provider = func(): return {"cinema_visible": true, "cinema_moving": true}
	player.state_provider = func(): return {"has_video": true, "geometry": 0, "screen_scene_locked": true}
	get_tree().root.add_child(player); player.toggle(); player.section = 1; player._adjustment = "screen"; player.refresh()
	var cinema_buttons := 0
	for button in player._buttons:
		if int(button.target) in [Player.FREE_MOVEMENT, Player.CINEMA_LIGHTS]: cinema_buttons += 1
	check(cinema_buttons == 2 and player._buttons.any(func(item): return item.target==Player.SCENERY), "Cinema keeps both footer shortcuts alongside the shared scene entry")
	var actions: Array = []
	player.action_requested.connect(func(action): actions.append(action))
	player.session_control_requested.connect(func(operation): actions.append(operation))
	player._activate_footer(Player.CINEMA_LIGHTS)
	player._activate_footer(Player.FREE_MOVEMENT)
	check(actions.size() == 2, "Cinema controls act in both builds")
	player.queue_free(); library.queue_free(); main.queue_free()
	await get_tree().process_frame; await get_tree().process_frame
	var result := {"actual_debug_build": debug, "checks": checks, "failures": failures, "passed": failures.is_empty(), "scope": "Actual Windows engine binaries on current source; no export, APK, installation or device tests."}
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")); file.close()
	print("CINEMA_BUILD_GATE debug=%s checks=%d failures=%d" % [debug, checks, failures.size()])
	get_tree().quit(0 if failures.is_empty() else 1)
