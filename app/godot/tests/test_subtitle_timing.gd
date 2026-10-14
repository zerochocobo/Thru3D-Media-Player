extends SceneTree
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const A := "file:///timing-test/movie-a.mkv"
const B := "smb://timing-test/share/movie-b.mkv"
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var serial := 100
	var calls: Array = []
	var accepted := true
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool,
		_depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		serial += 1; return serial
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_subtitle_delay(id: int, seconds: float) -> bool:
		calls.append([id, seconds]); return accepted

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func row(menu: Node) -> Dictionary:
	for id in menu.choices.sliders:
		if menu.choices.targets[id].key == "subtitle_delay":
			return {"id": id, "slider": menu.choices.sliders[id]}
	return {}

func origin(menu: Node3D, slider: Dictionary, fraction: float) -> Vector3:
	return slider.node.to_global(Vector3(slider.left + slider.width * fraction, 0, 1))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var directory := "user://subtitle-timing-test-%d" % Time.get_ticks_usec()
	var timing := Timing.new(directory)
	for value in [INF, NAN]: check(Timing.delay(value) == 0, "Invalid timing normalizes to zero")
	check(Timing.delay(100) == 10 and Timing.delay(-100) == -10 and is_equal_approx(Timing.delay(0.26), 0.3), "Range and tenth-second precision")
	for value in [NAN, INF, 10.1, -10.1, "1.0", true]:
		check(not timing.remember(A, {"delay_seconds": value}), "Persistent timing rejects invalid values")
	check(not timing.remember("http://127.0.0.1:12345/temporary", {"delay_seconds": 1.0}), "Transient stream URLs never become video identities")
	check(timing.remember(A, {"delay_seconds": 1.2}) and timing.save(), "First video delay saves")
	check(timing.remember(B, {"delay_seconds": -2.3}) and timing.save(), "Second video has independent delay")
	var reloaded := Timing.new(directory); reloaded.load_saved()
	check(is_equal_approx(reloaded.lookup(A).delay_seconds, 1.2) and is_equal_approx(reloaded.lookup(B).delay_seconds, -2.3), "Per-video values survive a real reload")
	var bank := FileAccess.get_file_as_string(directory.path_join("file_subtitle_timing_0.json"))
	check(not bank.contains(A) and not bank.contains(B), "Saved records contain hashes instead of media URLs")
	var renamed := "file:///timing-test/movie-a-renamed.mkv"
	check(reloaded.relocate(A, renamed) and reloaded.save() and reloaded.lookup(A).is_empty() and is_equal_approx(reloaded.lookup(renamed).delay_seconds, 1.2), "Renaming preserves the video's timing")
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.subtitle_timing = Timing.new(directory + "-ui")
	var host := Host.new(); video.platform = host
	var main := Main.new(); main.video = video; main.settings_path = directory.path_join("global.cfg")
	check(video.open_local(A, "A", 0, true, false, "movie-a.mkv") and video.subtitle_delay == 0 and host.calls.back()[1] == 0, "A new source applies zero before its first subtitle")
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 1, "codec": "subrip"}], "pgs_supported": true}}
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.setting_requested.connect(main._on_player_setting)
	menu.toggle(); menu._activate(110); menu._activate(Menu.SUBTITLE_APPEARANCE)
	var sync := row(menu)
	check(not sync.is_empty() and sync.slider.span == Vector3(-10, 10, 0.1), "Subtitle adjustment contains the bounded timing slider")
	check(not sync.slider.reset.enabled and not sync.slider.reset.node.visible, "Zero timing hides its reset button")
	var p := origin(menu, sync.slider, 0.575)
	menu.press_pointer("right", p, -menu.global_basis.z, true)
	check(is_equal_approx(video.subtitle_delay, 1.5) and video.subtitle_timing.entries.is_empty() and menu.has_pointer_capture(), "Press previews +1.5 seconds without writing settings")
	check(sync.slider.label.text == "+1.5 s" and sync.slider.reset.node.visible, "Positive timing displays its sign and exposes reset")
	menu.update_pointer("left", origin(menu, sync.slider, 0), -menu.global_basis.z, true)
	check(is_equal_approx(video.subtitle_delay, 1.5), "Other hand cannot change the timing capture")
	menu.release_pointer("left", p, -menu.global_basis.z, true)
	check(menu.has_pointer_capture(), "Other hand cannot commit the slider")
	menu.release_pointer("right", p, -menu.global_basis.z, true)
	check(is_equal_approx(video.subtitle_timing.lookup(A).delay_seconds, 1.5) and not menu.has_pointer_capture(), "Release saves only the current video's timing")
	check(not main.settings.has_section_key("subtitles", "delay") and not FileAccess.file_exists(main.settings_path), "Timing never writes global subtitle preferences")
	sync = row(menu)
	var reset: Dictionary = sync.slider.reset
	p = reset.node.to_global(Vector3(0, 0, 1))
	check(menu.ray_hit(p, -menu.global_basis.z).target == reset.target, "Timing reset has its own ray target")
	menu.press_pointer("right", p, -menu.global_basis.z, true); menu.release_pointer("right", p, -menu.global_basis.z, true)
	check(video.subtitle_delay == 0 and video.subtitle_timing.lookup(A).delay_seconds == 0 and not row(menu).slider.reset.node.visible, "Reset saves zero and hides itself")
	for step in [0.1, -0.1]:
		var id: int = menu.choices.targets.keys().filter(func(target): return menu.choices.targets[target].kind == "nudge" and is_equal_approx(menu.choices.targets[target].step, step))[0]
		var nudge: Dictionary = menu._buttons.filter(func(button): return button.target == id)[0]
		p = nudge.node.to_global(Vector3(0, 0, 1))
		var sequence: int = video.subtitle_timing.sequence
		menu.press_pointer("right", p, -menu.global_basis.z, true)
		check(video.subtitle_timing.sequence == sequence, "Fine adjustment waits for trigger release")
		menu.release_pointer("right", p, -menu.global_basis.z, true)
		check(video.subtitle_timing.sequence == sequence + 1 and is_equal_approx(video.subtitle_delay, 0.1 if step > 0 else 0.0), "Fine button changes exactly one tenth and saves once")
	check(video.set_subtitle_delay(-10) and video.commit_subtitle_delay(-10, A), "Negative endpoint persists")
	menu.refresh()
	var lower: int = menu.choices.targets.keys().filter(func(target): return menu.choices.targets[target].kind == "nudge" and menu.choices.targets[target].step < 0)[0]
	check(not menu._buttons.filter(func(button): return button.target == lower)[0].enabled, "Fine adjustment cannot move below the lower limit")
	host.accepted = false
	check(not video.set_subtitle_delay(10) and video.subtitle_delay == -10, "Rejected native command preserves the active value")
	sync = row(menu); p = origin(menu, sync.slider, 1.0)
	menu.press_pointer("right", p, -menu.global_basis.z, true); menu.release_pointer("right", p, -menu.global_basis.z, true)
	check(video.subtitle_delay == -10 and row(menu).slider.label.text == "-10.0 s", "Rejected slider commit restores the visible native value")
	host.accepted = true
	menu.refresh(); sync = row(menu); p = origin(menu, sync.slider, 0.625)
	menu.press_pointer("right", p, -menu.global_basis.z, true)
	check(is_equal_approx(video.subtitle_delay, 2.5) and video.subtitle_timing.lookup(A).delay_seconds == -10, "Another A drag previews without prematurely overwriting its saved timing")
	check(video.open_local(B, "B", 0, true, false, "movie-b.mkv") and video.subtitle_delay == 0 and host.calls.back()[1] == 0, "Switching to another video clears the prior offset")
	menu.refresh()
	check(is_equal_approx(video.subtitle_timing.lookup(A).delay_seconds, 2.5) and video.subtitle_delay == 0 and host.calls.back()[1] == 0 and not menu.has_pointer_capture(), "A captured drag commits to A during source redraw without shifting B")
	check(video.set_subtitle_delay(-0.5) and video.commit_subtitle_delay(-0.5, B), "B maintains its own negative correction")
	check(video.open_local(A, "A", 0, true, false, "movie-a.mkv") and is_equal_approx(video.subtitle_delay, 2.5) and host.calls.back()[1] == 2.5, "Reopening A restores A's value before first playback")
	var saved := Timing.new(video.subtitle_timing.directory); saved.load_saved()
	check(is_equal_approx(saved.lookup(A).delay_seconds, 2.5) and is_equal_approx(saved.lookup(B).delay_seconds, -0.5), "Independent offsets survive another store instance")
	video.media.playback = {"details": {"pgs_supported": true, "subtitle_tracks": [{"id": 1, "codec": "hdmv_pgs_subtitle"}]}}
	video.subtitles.select(1)
	menu.dismiss(); menu.toggle(); menu._activate(110); menu._activate(Menu.SUBTITLE_APPEARANCE)
	check(row(menu).slider.label.text == "+2.5 s" and menu.choices.sliders.size() == 3, "PGS shares the per-video sync slider")
	check(not video.set_subtitle_delay(NAN) and not video.set_subtitle_delay(INF), "Non-finite UI requests cannot reach native playback")
	video.close_video(); menu.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Subtitle timing checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
