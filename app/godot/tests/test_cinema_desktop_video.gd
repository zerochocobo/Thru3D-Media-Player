extends SceneTree
## Original generated clips only; never print media URIs or filenames.

const DesktopVideo := preload("res://scripts/environments/cinema_desktop_video.gd")
const Bookmarks := preload("res://scripts/bookmark_store.gd")
var checks := 0
var failures: Array[String] = []
var video: Node3D
var samples := ProjectSettings.globalize_path("res://../../build/output/cinema-desktop-video/samples")
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-desktop-video")


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)


func settle(seconds: float) -> void:
	await create_timer(seconds).timeout


func wait_video(uri: String, timeout: float = 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000)
	while Time.get_ticks_msec() < deadline:
		if video.local_uri == uri and video.media.state in ["playing", "paused", "ended"]:
			return true
		if video._candidate == null and not video.picker_error.is_empty():
			return false
		await process_frame
	return false


func wait_seek() -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while video.control.in_flight > 0 and Time.get_ticks_msec() < deadline:
		await process_frame


func texture_hash() -> String:
	var texture: Texture2D = video.material.get_shader_parameter("color_texture")
	if not texture:
		return ""
	var image := texture.get_image()
	if not image or image.is_empty():
		return ""
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(image.get_data())
	return hash.finish().hex_encode()


func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	video = DesktopVideo.new()
	for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.audio_timing, video.whisper_memory, video.recent_files, video.narration.memory]:
		memory.directory = output.path_join("test-state")
	video.bookmark_store = Bookmarks.new(output.path_join("test-state"))
	video.audio_muted = true
	video.open_timeout_ms = 700
	root.add_child(video)
	var pose := Transform3D(Basis.from_euler(Vector3(0, 0.17, 0)), Vector3(0, 12.4, -3.965))
	video.set_flat_world_pose(pose)
	video.screen_scale = 12.0
	video._apply_geometry()
	var mp4 := samples.path_join("synthetic-audio.mp4")
	var mkv := samples.path_join("synthetic-audio.mkv")
	var ogv := samples.path_join("synthetic-audio.ogv")
	if OS.get_cmdline_user_args().has("--decoder-smoke-only"):
		check(video.open_local(mp4, "Original test clip"), "A local original MP4 is accepted by the real desktop decoder")
		check(await wait_video(mp4), "MP4 produces a usable video texture")
		check(int(video.media.format.width) == 320 and int(video.media.format.height) == 180, "Real MP4 source dimensions reach the shared media state")
		await settle(0.2)
		check(video.control.observed_position_ms > 80, "Real decoder playback clock advances")
		await finish()
		return
	var picker := [0]
	video.file_picker_requested.connect(func(): picker[0] += 1)
	video.pick_file()
	check(picker[0] == 1, "File selection delegates to the production host instead of creating separate UI")
	check(video.open_library(mp4, "Original MP4"), "Inherited library opening delegates to the real desktop implementation")
	check(await wait_video(mp4), "MP4 opens with real decoder frames")
	check(int(video.media.format.width) == 320 and int(video.media.format.height) == 180, "Decoded MP4 dimensions are real source dimensions")
	check(video.geometry == 0 and video.flat_pose.is_equal_approx(pose), "Opening a film preserves the fixed flat world screen pose")
	check(not video.history_enabled and not video._remember_file, "Experimental playback cannot write normal movie history")
	check(video.material.get_shader_parameter("color_texture") == video._desktop_player.get_video_texture(), "Actual decoder texture feeds the production video shader")
	check(video.control.duration_ms > 3500 and video.control.duration_ms < 4500, "Real source duration populates the production timeline")
	check(video.snapshot().backend == "desktop_ffmpeg" and video.media.snapshot().backend == "desktop_ffmpeg" and video.layout_snapshot().backend == "desktop_ffmpeg", "All information snapshots identify the real desktop decoder")
	check(not video.media.snapshot().presentation_identity.source_pts_verified and not video.layout_snapshot().playback_control.source_frame_pts_verified, "Desktop snapshots do not claim native source PTS or Android pair verification")
	var mono_size: Vector2 = video._flat.size
	video.toggle_stereo()
	for layout in [1, 2, 3, 4]:
		video.set_stereo_layout(layout)
	check(not video.stereo_sbs and not video.top_bottom and not video.stereo_half and video.geometry == 0 and video._flat.size.is_equal_approx(mono_size), "Direct stereo shortcuts cannot split or resize a mono desktop film")
	var first_hash := texture_hash()
	await settle(0.3)
	check(video.control.observed_position_ms > 150, "Actual playback position advances")
	if DisplayServer.get_name() != "headless":
		check(not first_hash.is_empty() and texture_hash() != first_hash, "Rendered video pixels change over time")
	video.toggle_play()
	var paused_position: int = video.control.observed_position_ms
	await settle(0.2)
	check(not video.requested_play and video.media.state == "paused", "Production play toggle really pauses the decoder")
	check(absi(video.control.observed_position_ms - paused_position) < 90, "Paused playback clock remains stable")
	check(video.seek_absolute(1400), "Production timeline supports real absolute seek")
	await wait_seek()
	check(not video.requested_play and video._desktop_player.paused, "Seeking while paused restores the paused intent")
	check(absi(video.control.observed_position_ms - 1400) < 350, "Absolute seek reports the actual decoder clock near its target")
	check(video.seek_relative(450), "Production relative seek uses the same decoder")
	await wait_seek()
	check(video.control.observed_position_ms > 1650 and video.control.observed_position_ms < 2300, "Relative seek starts from the prior real timeline position")
	check(not video.set_playback_speed(1.5) and is_equal_approx(video.playback_speed, 1.0), "Unsupported rate changes fail without falsifying playback speed")
	check(video.set_audio_options(-1, 25, false), "Production volume control is accepted")
	check(is_equal_approx(video._desktop_player.volume_db, linear_to_db(0.25)), "Volume changes the real VideoStreamPlayer gain")
	var master := AudioServer.get_bus_index("Master")
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 0.3
	var capture_index := AudioServer.get_bus_effect_count(master)
	AudioServer.add_bus_effect(master, capture)
	video.toggle_play()
	capture.clear_buffer()
	await settle(0.25)
	var pcm := capture.get_buffer(capture.get_frames_available())
	var peak := 0.0
	for sample in pcm:
		peak = maxf(peak, maxf(absf(sample.x), absf(sample.y)))
	check(not pcm.is_empty() and peak > 0.000001, "Decoded soundtrack produces real nonzero PCM on the audio bus")
	AudioServer.remove_bus_effect(master, capture_index)
	video.toggle_play()
	check(video.toggle_mute() and video._desktop_player.volume_db <= -79, "Production mute silences the actual decoder player")
	check(video.set_volume_level(0) and video.audio_muted, "Zero volume remains muted")
	check(video.change_volume(20) and not video.audio_muted, "Raising volume restores audible gain")
	video.set_audio_options(-1, 20, true)
	var before_uri: String = video.local_uri
	var before_texture: Texture2D = video.material.get_shader_parameter("color_texture")
	check(not video.open_local(samples.path_join("does-not-exist.mp4"), "Missing test clip"), "Missing input is rejected clearly")
	check(video.local_uri == before_uri and video.material.get_shader_parameter("color_texture") == before_texture, "A failed replacement preserves the old stream and bound image")
	check(video.open_local(samples.path_join("synthetic-corrupt.mp4"), "Corrupt test clip"), "Corrupt input enters guarded decoder validation")
	await settle(0.9)
	check(not video.picker_error.is_empty() and video.local_uri == before_uri, "Undecodable replacement fails while preserving the current movie")
	check(video.open_local(samples.path_join("synthetic-audio-only.wav"), "Audio-only test clip"), "Audio-only input enters video-track validation")
	await settle(0.9)
	check(not video.picker_error.is_empty() and video.local_uri == before_uri, "Audio-only input cannot replace the video with an empty screen")
	for entry in [[mkv, "Original MKV"], [ogv, "Original OGV"]]:
		var previous_pose: Transform3D = video.flat_pose
		check(video.open_local(entry[0], entry[1]), "Original container replacement is accepted")
		check(video.material.get_shader_parameter("color_texture") == before_texture, "Replacement retains the old texture during preparation")
		check(await wait_video(entry[0]), "Original replacement container decodes real video")
		check(video.flat_pose.is_equal_approx(previous_pose) and video.geometry == 0, "Container changes preserve fixed world placement and flat projection")
		before_texture = video.material.get_shader_parameter("color_texture")
	video.loop_enabled = true
	video.seek_absolute(video.control.duration_ms - 350)
	await wait_seek()
	if not video.requested_play:
		video.toggle_play()
	await settle(0.8)
	check(video.media.state == "playing" and video.control.observed_position_ms < 1800, "Repeat restarts the real source after EOS")
	video.loop_enabled = false
	var completed := [0]
	video.playback_completed.connect(func(): completed[0] += 1)
	video.seek_absolute(video.control.duration_ms - 300)
	await wait_seek()
	await settle(0.8)
	check(video.media.state == "ended" and completed[0] == 1 and video.playback_end_ready(), "EOS emits one production completion event and retains timeline readiness")
	check(absi(video.control.observed_position_ms - video.control.duration_ms) < 10, "EOS leaves the timeline at its real duration")
	video.toggle_play()
	await settle(0.2)
	check(video.requested_play and video.media.state == "playing" and video.control.observed_position_ms < 800, "Play after EOS really starts the film again")
	var silent_subtitle := samples.path_join("synthetic-silent-subtitle.mkv")
	check(video.open_local(silent_subtitle, "Original silent subtitled clip"), "A video-plus-subtitle container with no audio is accepted")
	check(await wait_video(silent_subtitle), "A missing audio stream does not crash or stall subtitle packet processing")
	await settle(0.25)
	check(video.control.observed_position_ms > 150 and video.media.state == "playing", "Silent subtitled video continues decoding real frames")
	video.close_video()
	await process_frame
	check(video.local_uri.is_empty() and video.media.state == "closed" and not video.panel.visible, "Close clears the production media state and screen visibility")
	check(video.material.get_shader_parameter("color_texture") == null and video._desktop_player == null and video._candidate == null, "Close releases players and their bound native textures")
	check(video.get_children().filter(func(node): return node is VideoStreamPlayer).is_empty(), "Close leaves no decoder player nodes in the scene tree")
	await finish()


func finish() -> void:
	video.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("Cinema desktop video: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
