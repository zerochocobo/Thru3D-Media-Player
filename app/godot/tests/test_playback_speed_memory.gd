extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

class Host extends "res://tests/test_file_mode_memory.gd".Host:
	var rates: Array = []
	var accept := true
	func set_mpv_speed(id: int, rate: float) -> bool:
		if not accept: return false
		rates.append([id, rate])
		return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target and button.enabled:
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			var direction: Vector3 = -button.node.global_basis.z
			menu.press_pointer("right", origin, direction, true)
			menu.release_pointer("right", origin, direction, true)
			return true
	return false

func drag(menu: Node3D, target: int, fraction: float) -> void:
	var button: Dictionary = menu._buttons.filter(func(row): return row.target == target)[0]
	var surface: Node3D = menu._input_surface(target)
	var point := Vector3(menu.SLIDER_LEFT + menu.SLIDER_WIDTH * fraction, button.rect.get_center().y, 1)
	menu.press_pointer("right", surface.to_global(point), -surface.global_basis.z, true)
	menu.release_pointer("right", surface.to_global(point), -surface.global_basis.z, true)

func _run() -> void:
	const Privacy := preload("res://scripts/media_privacy.gd")
	Privacy.configure(Privacy.NONE); Privacy.configure_file_settings(Privacy.NONE)
	var output := ProjectSettings.globalize_path("res://../../build/output/playback-speed-memory/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(output)
	var main := Main.new(); var video := Video.new(); var host := Host.new()
	main.video = video; main.settings_path = output.path_join("settings.cfg")
	root.add_child(video); video.set_process(false); video.platform = host
	check(video.open_local("file:///global-speed-menu.mp4", "Menu", 0, false), "Menu source opens")
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; menu.toggle()
	check(click(menu, 11) and menu._adjust_rows.has(453), "Ray opens playback speed control")
	for fraction in [0.0, 1.0]:
		drag(menu, 453, fraction)
		var stored := ConfigFile.new()
		var expected := 0.25 if fraction == 0.0 else 3.0
		check(stored.load(main.settings_path) == OK and is_equal_approx(float(stored.get_value("video", "playback_speed")), expected)
			and is_equal_approx(video.playback_speed, expected) and is_equal_approx(float(host.rates.back()[1]), expected), "Slider release saves the accepted global rate")
	check(click(menu, Menu.SPEED_RESET) and video.playback_speed == 1.0, "Ray resets speed to 1x")
	var reset := ConfigFile.new(); reset.load(main.settings_path)
	check(reset.get_value("video", "playback_speed") == 1.0, "Ray reset persists globally")
	_check_global_speed(main, video, host)
	menu.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Global playback speed memory: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check_global_speed(main: Node3D, video: Node3D, host: Host) -> void:
	const Privacy := preload("res://scripts/media_privacy.gd")
	Privacy.configure(Privacy.NONE); Privacy.configure_file_settings(Privacy.NONE)
	host.accept = true
	main.settings = ConfigFile.new()
	main._restore_playback_speed()
	check(video.playback_speed == 1.0 and video.preferred_playback_speed == 1.0, "Existing installations without a saved speed start at 1x")
	for invalid in [NAN, INF, 0, 3.1, "1.5", true, {"bad": true}]:
		main.settings.set_value("video", "playback_speed", invalid)
		main._restore_playback_speed()
		check(video.playback_speed == 1.0 and video.preferred_playback_speed == 1.0, "Malformed saved speed safely defaults to 1x: " + str(invalid))
	check(video.open_local("file:///global-speed-first.mp4", "First", 0, false), "First video opens through the actual source path")
	main._on_playback_adjustment("playback_speed", 1.65); main._save_playback_adjustments()
	check(video.open_local("file:///global-speed-next.mp4", "Next")
		and video.playback_speed == 1.65 and host.rates.back() == [video.media.session_id, 1.65], "Next video receives the global rate even without file memory")
	video.close_video()
	check(video.open_local("file:///global-speed-reopened.mp4", "Reopened", 0, false)
		and video.playback_speed == 1.65, "Closing playback and opening another video retains speed")
	video._reopen_at(2000, false)
	check(video.playback_speed == 1.65 and video.preferred_playback_speed == 1.65 and host.rates.back()[1] == 1.65, "Decoder reopen retains the actual and global rate")
	var previous: Dictionary = video.capture_cast_view()
	check(video.open_cast("http://192.168.1.20/live.mp4", "Live", 4, 0)
		and video.playback_speed == 1.0 and video.preferred_playback_speed == 1.65, "Unknown cast capability temporarily uses 1x without losing the global choice")
	main._save_playback_adjustments()
	var stored := ConfigFile.new(); stored.load(main.settings_path)
	check(stored.get_value("video", "playback_speed") == 1.65, "Saving other controls during a restricted cast preserves the remembered rate")
	video._on_state(video.media.session_id, JSON.stringify({"state": "playing", "details": {
		"seekable": "yes", "position_seconds": "0", "duration_seconds": "100"}}))
	check(video.playback_speed == 1.65 and host.rates.back()[1] == 1.65, "Cast inherits the rate after confirming playback-speed capability")
	main._on_playback_adjustment("playback_speed", 2.25); main._save_playback_adjustments()
	video.cast_token = 0
	video.open_local("file:///global-speed-return.mp4", "Return", 0, false)
	video.restore_cast_view(previous)
	check(video.playback_speed == 2.25 and video.preferred_playback_speed == 2.25, "Returning from a cast uses the newest global speed")
	host.accept = false
	main._on_playback_adjustment("playback_speed", 2.5); main._save_playback_adjustments()
	stored.load(main.settings_path)
	check(video.playback_speed == 2.25 and stored.get_value("video", "playback_speed") == 2.25, "Rejected native rate change cannot overwrite saved speed")
	check(video.open_local("file:///global-speed-rejected.mp4", "Rejected", 0, false)
		and video.playback_speed == 1.0 and video.preferred_playback_speed == 2.25, "Rejected automatic rate leaves actual speed at 1x and preserves the global choice")
	host.accept = true
	check(video.open_local("file:///global-speed-retry.mp4", "Retry", 0, false)
		and video.playback_speed == 2.25, "Next source retries the remembered rate after a backend rejection")
	var restarted := Main.new(); var fresh_video := Video.new()
	root.add_child(fresh_video); fresh_video.set_process(false); fresh_video.platform = host
	restarted.video = fresh_video; restarted.settings_path = main.settings_path
	check(restarted.settings.load(restarted.settings_path) == OK, "A fresh application instance reads saved settings from disk")
	restarted._restore_playback_speed()
	check(fresh_video.open_local("file:///global-speed-after-restart.mp4", "After restart", 0, false)
		and fresh_video.playback_speed == 2.25 and host.rates.back()[1] == 2.25
		and restarted._menu_state().playback_speed == 2.25, "Restart applies the last rate to the backend and menu")
	restarted._on_playback_adjustment("playback_speed", 1.0); restarted._save_playback_adjustments()
	stored.load(restarted.settings_path)
	check(stored.get_value("video", "playback_speed") == 1.0
		and fresh_video.open_local("file:///global-speed-reset.mp4", "Reset", 0, false)
		and fresh_video.playback_speed == 1.0, "Reset to 1x is remembered for subsequent videos")
	fresh_video.free(); restarted.free()
