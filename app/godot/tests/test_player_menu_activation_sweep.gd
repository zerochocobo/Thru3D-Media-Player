extends SceneTree
## Activates every enabled player-menu control, and every control one step below it, through the
## real _activate_hit -> signal -> main handler path. A Release build has no freed-instance check,
## so a stale node reached from these handlers crashes there; the desktop debug engine only logs it.
## Prints "SWEEP <first> <second>" to stderr before each activation to attribute any such error.
const HostTest := preload("res://tests/test_player_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const XrDisplay := preload("res://scripts/xr_display.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/player-menu-sweep")
var main: Node3D
var activations := 0

class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true

class InputMain extends "res://scripts/main.gd":
	func _ray(_hand: String) -> Variant: return null
	func _input_focused() -> bool: return true
	func _head_tracked() -> bool: return true

func _initialize() -> void: _run.call_deferred()

func _frames(count: int = 2) -> void:
	for i in count: await process_frame

func _targets() -> Array[int]:
	var menu: Node3D = main.player_menu
	var found: Array[int] = []
	if not menu.visible: return found
	for button in menu._buttons:
		if button.enabled and is_instance_valid(button.node) and button.node.is_visible_in_tree() and not found.has(int(button.target)):
			found.append(int(button.target))
	return found

## Reopens the playing media and the requested state: activations may stop or replace it.
## Extra user args: cinema, cast, pip, web, tracks.
func _prepare() -> void:
	var args := OS.get_cmdline_user_args()
	var video: Node3D = main.video
	if video.local_uri != "file:///sweep.mp4" or video.media.state != "playing":
		video.local_uri = "file:///sweep.mp4"
		video.media.begin(video.media.session_id + 1); video.media.state = "playing"
		video.media.format.width = 1920; video.media.format.height = 1080
		video._apply_geometry()
		video._waiting_first = false; video.requested_play = true
		video.control.duration_ms = 600000
	main.photo_active = false; main.player_menu = main.video_menu
	if args.has("tracks"):
		video.media.playback = {"details": {
			"audio_tracks": [{"id": 1, "language": "en", "title": "Main"}, {"id": 2, "language": "ja", "title": "Commentary"}],
			"subtitle_tracks": [{"id": 1, "language": "en", "codec": "subrip"}, {"id": 2, "language": "zh", "codec": "ass"}]}}
	if args.has("cast"):
		video.cast_token = 5; main.cast_session.token = 5
		main.cast_session.previous = {"photo": false, "uri": "file:///before.mp4", "title": "before", "position": 0, "playing": true,
			"queue": [], "queue_context": {}, "mode": {}, "playback_mode": "single", "metadata": {}, "location": {}}
	if args.has("pip") and video.pip.windows.is_empty():
		video.pip.set_count(2, main._head_pose())
	if args.has("web") and main.recent_menu.web_browser.playback_return.is_empty():
		main.recent_menu.web_browser.playback_return = {"native_uri": video.local_uri, "retained": true, "page_uri": "https://example.com/watch", "position_ms": 0}

func _reset() -> void:
	_prepare()
	main._show_player_menu()
	main.player_menu._reset_navigation(); main.player_menu.refresh()
	await _frames()

func _activate(path: Array) -> void:
	printerr("SWEEP %s" % " ".join(path.map(func(t): return str(t))))
	activations += 1
	var menu: Node3D = main.player_menu
	if menu.visible: menu._activate_hit({"target": path[-1], "point": Vector3.ZERO, "enabled": true, "distance": 1.0})
	await _frames()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "en")
	config.save(output.path_join("settings.cfg"))
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 800); viewport.own_world_3d = true
	root.add_child(viewport)
	main = InputMain.new()
	main.settings_path = output.path_join("settings.cfg")
	main.display = SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.video.set_process(false); main.photo.set_process(false)
	main.report_timer.stop()
	main.video.history_enabled = false; main.photo.history_enabled = false
	main.video.mode_memory = Memory.new(output.path_join("modes.cfg"))
	main.video.recent_files = Catalog.new(output.path_join("recent.cfg"))
	main.video.platform = HostTest.Host.new()
	main.video.media.begin(7)
	if OS.get_cmdline_user_args().has("cinema"):
		main.background.select("cinema"); main._update_background()
		var deadline := Time.get_ticks_msec() + 20000
		while main.cinema_environment.loading and Time.get_ticks_msec() < deadline:
			await create_timer(0.01).timeout
		main._update_background(); main._sync_cinema_screen()
	# Breadth-first over distinct menu states (their control sets), replaying each path from a reset.
	var queue: Array = [[]]
	var seen := {}
	var limit := 2500
	while not queue.is_empty() and activations < limit:
		var path: Array = queue.pop_front()
		await _reset()
		for index in path.size(): await _activate(path.slice(0, index + 1))
		var targets := _targets()
		var key := "%d|%s" % [int(main.player_menu.section), targets]
		if targets.is_empty() or seen.has(key): continue
		seen[key] = true
		for target in targets:
			if path.size() < 4: queue.append(path + [target])
	printerr("SWEEP done %d activations, %d states" % [activations, seen.size()])
	quit()
