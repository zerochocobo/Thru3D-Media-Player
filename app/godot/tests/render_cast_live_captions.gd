extends SceneTree
const Player := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Host extends "res://tests/test_cast_listening.gd".Host:
	func get_mpv_subtitles(_id: int, _sequence: int) -> String: return "{}"

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var output := OS.get_environment("THRU3D_LISTENING_RENDER_OUTPUT")
	var report_path := OS.get_environment("THRU3D_LISTENING_REPORT")
	if output.is_empty() or report_path.is_empty(): push_error("Controller report and output directory required"); quit(1); return
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(report_path))
	if not report is Dictionary: push_error("Invalid controller report"); quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(960, 540); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(0, 1.6, 0); viewport.add_child(camera)
	var video := Player.new(); viewport.add_child(video); video.set_process(false); video.view_camera = camera
	var host := Host.new(); host.report = report; video.platform = host; video.history_enabled = false
	for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.subtitle_encoding, video.audio_timing, video.whisper_memory, video.narration.memory, video.listening.memory, video.recent_files]: memory.read_only = true
	video.open_cast("http://192.0.2.1/no-subtitles.mp4", "No authored subtitles", 81, 5000, false)
	video.control.observe(5000, 120000)
	video.media.playback = {"details": {"seekable": "yes", "partially_seekable": "no", "audio_track_id": "1", "audio_tracks": [{"id": 1, "stream_index": 0}], "subtitle_tracks": [], "paused": "yes", "duration_seconds": "120"}}
	video.media.last_pair = {"session_id": video.media.session_id}; video._waiting_first = false; video.panel.visible = true
	video.subtitles.select(0); video._flat.size = Vector2(1.9, 1); video._apply_geometry()
	video._subtitle_poll_ms = Time.get_ticks_msec() + 60000; video._subtitle_received_ms = Time.get_ticks_msec()
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8); color.fill(Color(0.1, 0.3, 0.6))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8); alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(2, 2)); video.material.set_shader_parameter("model_size", Vector2(2, 2))
	check(video.listening.set_option("listening_enabled", true), "No-subtitle cast can enable recognition")
	var samples := []
	for mode in ["flat", "depth", "alpha", "off"]:
		video.alpha_requested = mode == "alpha"; video.alpha_enabled = mode == "alpha"
		video.depth_requested = mode == "depth"; video.depth_enabled = mode == "depth"
		video.material.set_shader_parameter("alpha_enabled", mode == "alpha")
		if mode == "off": video.listening.set_option("listening_enabled", false)
		video.listening._poll_at = 0; video.listening.tick(); video._poll_subtitles()
		for i in 4: await process_frame; await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var white := 0
		for y in image.get_height():
			for x in image.get_width():
				var pixel := image.get_pixel(x, y)
				if pixel.r > 0.75 and pixel.g > 0.75 and pixel.b > 0.75: white += 1
		image.save_png(output.path_join(mode + ".png"))
		samples.append({"mode": mode, "caption_visible": video.caption.visible, "caption_length": video.caption.text.length(), "white_pixels": white})
		if mode == "off": check(not video.caption.visible and video.caption.text.is_empty() and white == 0, "Turning recognition off leaves an unsubtitled source clear")
		else:
			check(video.caption.visible and video.caption.text.contains("Live speech"), "Production controller cue reaches actual caption: " + mode)
			check(white > 20, "Actual glyph pixels visible with no authored subtitle: " + mode)
		check(video.subtitles.requested_track == 0 and video.subtitle_tracks().is_empty(), "Recognition needs no authored subtitle track: " + mode)
	var result := {"checks": checks, "failures": failures, "samples": samples,
		"scope": "Production controller JSON to production Godot caption and GL pixels; completed-ASR/native clock and video image are synthetic; no headset"}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	video.free(); viewport.free()
	print("Cast live caption pixels: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
