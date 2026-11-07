extends SceneTree

const Main := preload("res://scripts/main.gd")
const Player := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/screen-curve-modes/routes")

class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func tap(menu: Node3D, target: int) -> void:
	for button in menu._buttons:
		if button.target == target:
			var at: Vector2 = button.rect.get_center()
			var point: Vector3 = menu.to_global(Vector3(at.x, at.y, 1))
			menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
			menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
			return

func choose(menu: Node3D, value: String) -> void:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "choose" and item.get("key") == "screen_curve_mode" and item.value == value:
			tap(menu, target); return
	check(false, "Ray choice exists: " + value)

func mode_field(menu: Node3D) -> bool:
	return menu.choices.targets.values().any(func(item): return item.get("key") == "screen_curve_mode")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var cfg := ConfigFile.new()
	cfg.set_value("appearance", "background", "belfast")
	cfg.set_value("screen", "cinema", {"enabled": false})
	cfg.set_value("screen", "curve_degrees", 120.0)
	cfg.set_value("ui", "language", "zh")
	cfg.save(output.path_join("settings.cfg"))
	var main := Main.new(); main.settings_path = output.path_join("settings.cfg")
	main.display = SupportedDisplay.new(); root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	main.video.local_uri = "file:///curve-modes-fixture.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"
	main.video.media.format = {"width": 1920, "height": 1080}; main.video._apply_geometry()
	main.video.panel.visible = true
	main._sync_cinema_screen()
	var menu: Node3D = main.player_menu
	menu.visible = true; menu._adjustment = "screen"; menu.refresh()
	check(main._curve_modes_available() and mode_field(menu), "Panorama free screen exposes curve modes")
	check(main.video.screen_curve_mode == "horizontal", "New settings default to horizontal")
	check(menu.choices.targets.values().filter(func(item): return item.get("key") == "screen_curve_mode" and item.get("kind") == "choose").size() == 3, "All three modes use adjacent buttons")
	check(not menu.choices.targets.values().any(func(item): return item.get("key") == "screen_curve_mode" and item.get("kind") == "open"), "Curve modes have no select control")
	for mode in ["vertical", "spherical", "horizontal", "spherical"]:
		choose(menu, mode)
		check(main.video.effective_curve_mode() == mode, "Tracked ray commits curve mode: " + mode)
		check(cfg.load(main.settings_path) == OK and cfg.get_value("screen", "curve_mode", "") == mode, "Mode persists to settings: " + mode)
		check(main.video.screen_curve == 120.0, "Changing mode preserves slider angle")
		check(menu._adjust_rows[Player.SCREEN_CURVE_SLIDER].span == Vector3(0, 180, 0.1), "All modes retain continuous 0–180 slider")
	var corner: Vector3 = main.video.screen_corner(1)
	main._on_playback_adjustment("screen_distance", 8.0)
	check(main.video.screen_corner(1).is_equal_approx(corner), "Production distance slider preserves sphere shape")
	for scenery in ["dark", "passthrough", "morning", "night", "belfast"]:
		main.background.select(scenery); main._update_background(); menu.refresh()
		var available: bool = scenery in ["morning", "night", "belfast"]
		check(main._curve_modes_available() == available and mode_field(menu) == available, "Mode field follows actual background: " + scenery)
		check(main.video.effective_curve_mode() == ("spherical" if available else "horizontal"), "Geometry follows actual background: " + scenery)
		check(main.video.screen_curve_mode == "spherical", "Background switch retains preference: " + scenery)
	main._set_cinema_mode(true); menu.refresh()
	check(not mode_field(menu) and main.video.effective_curve_mode() == "horizontal", "Upright cinema retains its original curve")
	main._on_player_setting("screen_curve_mode", "vertical")
	check(main.video.screen_curve_mode == "spherical", "Hidden mode action cannot change upright cinema")
	main._set_cinema_mode(false); menu.refresh()
	check(mode_field(menu) and main.video.effective_curve_mode() == "spherical", "Returning to free screen restores sphere")
	main.photo_active = true; main._sync_cinema_screen()
	check(not main._curve_modes_available() and main.video.effective_curve_mode() == "horizontal", "Photo context excludes video-only modes")
	main.photo_active = false
	main.portrait_screen.active = true; main._sync_cinema_screen()
	check(not main._curve_modes_available() and main.video.effective_curve_mode() == "horizontal", "Cutout placement excludes experimental modes")
	main.portrait_screen.active = false
	main.video.geometry = 2; main._sync_cinema_screen()
	check(not main._curve_modes_available(), "Immersive video keeps its original projection")
	main.video.geometry = 0; main._sync_cinema_screen()
	check(main.video.effective_curve_mode() == "spherical", "Ordinary flat video recovers the selected shape")
	main.background.choice = "custom"
	check(main._curve_modes_available(), "Custom panorama uses the same curve choices")
	main.background.choice = "cinema"
	check(not main._curve_modes_available(), "Giant cinema cannot inherit the free-screen experiment")
	main.background.choice = "private_beach"
	check(not main._curve_modes_available(), "Beach cannot inherit the panorama experiment")
	main.background.choice = "belfast"
	var restored := preload("res://scripts/mpv_video_display.gd").new()
	restored.restore_screen_curve(cfg, "screen"); restored.set_curve_modes_available(true)
	check(restored.effective_curve_mode() == "spherical", "A fresh display restores the saved mode")
	restored.free(); main.free()
	for failure in failures: push_error(failure)
	print("Screen curve mode routes: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
