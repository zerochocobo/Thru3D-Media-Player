extends SceneTree
## Exercise real first-pair dispatch, including the compositor path missing from preference-only tests.
const Video := preload("res://scripts/mpv_video_display.gd")
const TransitionTest := preload("res://tests/test_video_mode_transition.gd")
const LayerTest := preload("res://tests/test_frame_picture_layer.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Main := preload("res://scripts/main.gd")
const Compact := preload("res://tests/test_compact_library.gd")
var checks := 0
var failures: Array[String] = []

class Host extends TransitionTest.Host:
	var opens: Array = []
	var layers: Array[bool] = []
	var next_id := 100
	var external_request := {}
	func external_playback_poll() -> String:
		var result := external_request.duplicate(); external_request.clear()
		return JSON.stringify(result)
	func mpv_supported() -> bool: return true
	func set_mpv_video_layer(enabled: bool) -> void: layers.append(enabled)
	func open_mpv_video(uri: String, at: int, stereo: bool, _profile: String, alpha: bool, _vulkan: bool,
			depth: bool = false, tb: bool = false, _exact: bool = false) -> int:
		next_id += 1
		opens.append({"uri": uri, "at": at, "depth": depth, "stereo": stereo, "alpha": alpha, "tb": tb})
		return next_id

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func first_pair(video: Node3D, host: Host, layer: bool, format: Dictionary = {}) -> void:
	var id: int = video.media.session_id
	host.claim = {"session_id": id, "logical_session_id": id, "generation": 1, "format_revision": 1,
		"effect_revision": 1, "slot_token": 1, "pts_us": 1234000, "width": 1920, "height": 1080,
		"stereo_sbs": false, "alpha_requested": false, "inference_ran": false, "depth_requested": false,
		"depth_ran": false, "color_target": "layer" if layer else "texture"}
	host.claim.merge(format, true)
	video._on_pair(id, JSON.stringify({"slot_token": 1}))
	video._present_pending()

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-auto-3d-startup/" + str(Time.get_ticks_usec()))
	for layer in [false, true]:
		for source in ["externalvideo://startup/video", "file:///startup.mp4", "smb://fixture/share/startup.mp4", "webvideo://startup/video"]:
			for enabled in [false, true]:
				var host := Host.new()
				# Frame-copy failure must not decide whether the initial default is applied.
				host.reject_capture = true
				var video := Video.new(); root.add_child(video); video.set_process(false)
				video.platform = host; video._binding = TransitionTest.ProbeBinding.new()
				video.mode_memory = Memory.new(output.path_join(str(checks)))
				video.default_auto_depth = enabled
				if layer: video.video_layer = LayerTest.Layers.new(null)
				var label := "%s layer=%s default=%s" % [source.get_slice(":", 0), layer, enabled]
				check(video.open_local(source, "Video", 1234), label + ": open")
				check(host.layers.back() == layer and not host.opens.back().depth, label + ": wait for decoded format before inference")
				first_pair(video, host, layer)
				check(video.auto_depth == enabled and video.depth_requested == enabled, label + ": initial default survives real first-pair dispatch")
				check(host.snapshots.is_empty() and host.freezes.is_empty(), label + ": initial layout needs no transition snapshot")
				if enabled:
					check((host.opens.size() == 2 and host.opens.back().depth and not host.layers.back()) if layer else
						(host.revisions.size() == 1 and host.revisions.back()[1]), label + ": native depth startup actually dispatched")
					check(video.picker_error.is_empty() and not video.mode_transition.active(), label + ": no rollback to provisional 2D")
					first_pair(video, host, false, {"depth_requested": true, "depth_ran": true})
					check(video.depth_requested and video.depth_enabled and video.depth_ready(), label + ": converted output is bound and usable")
					check(host.opens.size() == (2 if layer else 1), label + ": no repeated decoder reopen")
				else:
					check(host.opens.size() == 1 and host.revisions.is_empty(), label + ": Off starts no conversion")
				video.free()
	# Native stereo and user choices still take priority over the automatic default.
	for layer in [false, true]:
		var host := Host.new(); host.reject_capture = true
		var video := Video.new(); root.add_child(video); video.set_process(false)
		video.platform = host; video._binding = TransitionTest.ProbeBinding.new()
		video.default_auto_depth = true
		if layer: video.video_layer = LayerTest.Layers.new(null)
		check(video.open_local("externalvideo://native/video", "Video"), "Native stereo source opens")
		first_pair(video, host, layer, {"stereo_mode": "ab2l"})
		check(video.stereo_sbs and video.top_bottom and not video.depth_requested, "Decoded native stereo is never converted")
		check(host.opens.all(func(item): return not item.depth) and host.revisions.all(func(item): return not item[1]), "Native stereo dispatch stays depth-free")
		video.free()
		video = Video.new(); root.add_child(video); video.set_process(false)
		host = Host.new(); host.reject_capture = true
		video.platform = host; video._binding = TransitionTest.ProbeBinding.new()
		video.default_auto_depth = true
		if layer: video.video_layer = LayerTest.Layers.new(null)
		video.open_local("externalvideo://manual/video", "Video")
		video.set_depth(false)
		first_pair(video, host, layer)
		check(not video.auto_depth and not video.depth_requested, "Manual Off before first frame overrides startup default")
		# Once a picture exists, explicit mode changes retain the normal preservation/rollback contract.
		video.set_depth(true)
		check(not host.snapshots.is_empty() if layer else not host.freezes.is_empty(), "Manual conversion still requests a preserved frame")
		check(not video.depth_requested and not video.picker_error.is_empty(), "Manual copy failure still rolls back safely")
		video.free()
	await check_external_entry(output)
	for failure in failures: push_error(failure)
	print("Video auto 3D startup: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_external_entry(output: String) -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var main := Compact.Harness.new(); root.add_child(main)
	main.settings_path = output.path_join("external-settings.cfg")
	var host := Host.new(); host.reject_capture = true
	var video := Video.new(); main.add_child(video); video.set_process(false); main.video = video
	video.platform = host; video._binding = TransitionTest.ProbeBinding.new()
	video.video_layer = LayerTest.Layers.new(null)
	var photo := Main.PhotoDisplay.new(); main.add_child(photo); photo.set_process(false); main.photo = photo
	var player := Main.PlayerMenu.new(); main.add_child(player); player.set_process(false)
	main.video_menu = player; main.player_menu = player; player.state_provider = main._menu_state
	player.layout_head_provider = main._head_pose
	var library := Main.LibraryMenu.new(); main.add_child(library); library.set_process(false)
	main.recent_menu = library; library.layout_head_provider = main._head_pose
	for enabled in [true, false, true]:
		main._on_setting_changed("video_auto_3d", enabled)
		var stored := ConfigFile.new()
		check(stored.load(main.settings_path) == OK, "External entry reads the persisted user option")
		video.default_auto_depth = video.Auto3D.load_enabled(stored)
		var uri := "externalvideo://entry-%d/video" % checks
		host.external_request = {"uri": uri, "title": "Video", "temporary": true, "start_ms": 1234}
		main._external_video_poll_ms = 0; main._poll_external_video()
		check(video.local_uri == uri and host.opens.back().at == 1234, "Production external poll dispatches the caller's new video")
		first_pair(video, host, true)
		check(video.depth_requested == enabled and video.auto_depth == enabled, "Production external handoff honors saved default On/Off")
		if enabled:
			first_pair(video, host, false, {"depth_requested": true, "depth_ran": true})
			check(video.depth_ready(), "External entry reaches converted output after first-frame initialization")
	# Exercise saved projection preferences through the production external poll and real first pairs.
	main._on_setting_changed("video_auto_3d", false)
	for layer in [false, true]:
		for preference in [
			{"enabled": false, "mode": {"geometry": 3, "layout": 2, "fisheye_fov": 180, "swap_eyes": false}},
			{"enabled": true, "mode": {}},
			{"enabled": true, "mode": {"geometry": 1, "layout": 1, "fisheye_fov": 180, "swap_eyes": false}},
			{"enabled": true, "mode": {"geometry": 3, "layout": 2, "fisheye_fov": 180, "swap_eyes": true}},
			{"enabled": true, "mode": {"geometry": 0, "layout": 0, "fisheye_fov": 180, "swap_eyes": false}},
		]:
			main._on_last_video_mode_changed(preference.mode)
			main._on_reuse_last_video_mode_changed(preference.enabled)
			video.free()
			video = Video.new(); main.add_child(video); video.set_process(false); main.video = video
			host = Host.new(); host.reject_capture = true
			video.platform = host; video._binding = TransitionTest.ProbeBinding.new()
			video.mode_memory = Memory.new(output.path_join("external-mode-%d" % checks))
			if layer: video.video_layer = LayerTest.Layers.new(null)
			var stored := ConfigFile.new()
			check(stored.load(main.settings_path) == OK, "Fresh external player loads the saved projection preferences")
			video.load_last_mode_preferences(stored)
			video.last_mode_changed.connect(main._on_last_video_mode_changed)
			video.reuse_last_mode_changed.connect(main._on_reuse_last_video_mode_changed)
			var expected: Dictionary = preference.mode if preference.enabled and not preference.mode.is_empty() else \
				{"geometry": 1, "layout": 1, "fisheye_fov": 180, "swap_eyes": false}
			for size in [Vector2i(8192, 4096), Vector2i(1920, 1080)]:
				if not preference.enabled and size.y == 1080:
					expected = {"geometry": 0, "layout": 0, "fisheye_fov": 180, "swap_eyes": false}
				var uri := "externalvideo://projection-%d/video" % checks
				host.external_request = {"uri": uri, "title": "Video", "temporary": true, "start_ms": 1234}
				main._external_video_poll_ms = 0; main._poll_external_video()
				check(video.local_uri == uri, "Cold/warm external mode request reaches the actual player")
				var revisions := host.revisions.size()
				first_pair(video, host, layer, {"width": size.x, "height": size.y, "stereo_sbs": host.opens.back().stereo})
				if host.revisions.size() > revisions:
					first_pair(video, host, layer, {"width": size.x, "height": size.y, "stereo_sbs": int(expected.layout) != 0})
				var chosen: Dictionary = video.current_lock(); chosen.swap_eyes = video.swap_eyes
				check(video.LastMode.clean(chosen) == expected, "External first pair honors saved mode before 2:1 inference: %s/%s/%s" % [layer, preference, size])
				check(video.media.frame_counter > 0 and not video.depth_requested and video.picker_error.is_empty(), "External projection reaches a frame without AI conversion or startup rollback")
				check(host.snapshots.is_empty() and host.freezes.is_empty(), "Automatic/inherited external VR needs no manual transition capture")
				if preference.enabled:
					var reloaded := ConfigFile.new(); reloaded.load(main.settings_path)
					var fresh := Video.new(); fresh.load_last_mode_preferences(reloaded)
					check(fresh.reuse_last_mode and fresh.last_mode == expected, "Resolved external mode remains available after restart")
					fresh.free()
	main.queue_free(); await process_frame; await process_frame
