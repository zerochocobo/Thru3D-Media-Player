extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var packet := {}
	func set_mpv_secondary_subtitle(_session: int, _track: int, _delay: float) -> bool: return true
	func get_mpv_subtitles(_session: int, _sequence: int) -> String: return JSON.stringify(packet)
	func close_mpv_video(_session: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func shot(viewport: SubViewport, file: String) -> Image:
	for frame in 5: await process_frame
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	check(result.save_png(file) == OK, "Save " + file.get_file())
	return result

func white_pixels(picture: Image) -> int:
	var result := 0
	for y in picture.get_height():
		for x in picture.get_width():
			var pixel := picture.get_pixel(x, y)
			if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.85: result += 1
	return result

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/dual-subtitles/render")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 55; camera.position.y = 0.08; viewport.add_child(camera)
	var menu := Player.new(); viewport.add_child(menu); menu.set_process(false)
	var state := {"has_video": true, "source_uri": "file:///lesson.mkv", "title": "Lesson", "duration_ms": 120000,
		"subtitle_options": [{"id": 1, "title": "English", "codec": "subrip"}, {"id": 2, "title": "中文", "codec": "subrip"}],
		"subtitle_track": 1, "secondary_subtitle_track": 2, "dual_subtitles_available": true,
		"dual_subtitles_enabled": false, "subtitle_edit_secondary": false,
		"subtitle_browse_available": true, "subtitle_auto_load": true,
		"narration_available": true, "narration_enabled": true, "narration_source": 2,
		"narration_status": "speaking", "narration_language": "auto", "narration_resolved_language": "zh",
		"subtitle_size": 100.0, "secondary_subtitle_delay": 0.7}
	menu.state_provider = func(): return state
	menu.toggle(); menu.position = Vector3(0, -0.40, -1.85); menu._activate(110)
	for locale in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(locale)
		for mode in ["single", "dual", "sync", "narration"]:
			state.dual_subtitles_enabled = mode != "single"; state.subtitle_edit_secondary = mode != "single"
			menu._set_subtitle_detail("appearance" if mode == "sync" else ("narration" if mode == "narration" else "")); menu.refresh()
			for entry in menu._buttons:
				if not entry.node.is_visible_in_tree(): continue
				# Textless hit areas, such as the footer status, have no label to fit.
				if entry.node.get_child_count() == 0 or not entry.node.get_child(0) is Label3D: continue
				var text: Label3D = entry.node.get_child(0)
				check(menu.text_width(text.text, text.font_size / menu.TEXT_RASTER_SCALE) <= entry.rect.size.x + 0.01, "Button label fits " + locale + "/" + text.text)
			check(is_equal_approx(menu._subtitle_panel_bounds.size.x, 1.10), "Original panel width " + locale)
			await shot(viewport, output.path_join(locale + "-" + mode + ".png"))
	menu.free()
	I18n.use("en")
	viewport.size = Vector2i(960, 640); camera.fov = 75; camera.position = Vector3(0, 1.6, 0)
	var video := Video.new(); viewport.add_child(video); video.view_camera = camera; video.set_process(false)
	var host := Host.new(); video.platform = host; video.local_uri = "file:///lesson.mkv"
	video.media.begin(7); video.media.playback = {"details": {"subtitle_tracks": [{"id": 1, "codec": "subrip"}, {"id": 2, "codec": "subrip"}]}}
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	video.subtitles.select(1); video.dual_subtitles.enabled = true; video.dual_subtitles.state.select(2)
	video._flat.size = Vector2(1.9, 1); video.panel.visible = true
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8); color.fill(Color(0.1, 0.25, 0.4))
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("source_size", Vector2(2, 2)); video.material.set_shader_parameter("stereo_sbs", false)
	var counts: Array[int] = []
	var sequence := 0
	for mode in ["primary", "both", "secondary", "hidden"]:
		sequence += 1
		host.packet = {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55,
			"sequence": sequence, "age_ms": 0, "command_id": 1, "track_id": 1, "timeline_valid": true,
			"delay_seconds": 0.0, "start_seconds": "0", "end_seconds": "10", "position_seconds": "5",
			"text": "ENGLISH ORIGINAL" if mode in ["primary", "both"] else "",
			"secondary": {"sequence": sequence, "source_epoch": 2, "command_id": 1, "track_id": 2, "timeline_valid": true,
				"delay_seconds": 0.0, "start_seconds": "0", "end_seconds": "10", "position_seconds": "5",
				"text": "中文对照字幕" if mode in ["both", "secondary"] else ""}}
		video._subtitle_poll_ms = 0; video._poll_subtitles()
		counts.append(white_pixels(await shot(viewport, output.path_join("captions-" + mode + ".png"))))
	check(counts[0] > 100 and counts[2] > 100, "Both actual glyph alphabets are rendered")
	check(counts[1] > maxi(counts[0], counts[2]) + 100, "Combined production canvas contains both text blocks")
	check(counts[3] == 0, "Cleared cues leave no stale glyph pixels")
	host.packet.text = "ENGLISH ORIGINAL"; host.packet.secondary.text = "中文对照字幕"
	var projected_counts: Array[int] = []
	for geometry in [video.Geometry.Geometry.HALF_EQUIRECT, video.Geometry.Geometry.EQUIRECT_360]:
		sequence += 1; host.packet.sequence = sequence; host.packet.secondary.sequence = sequence
		video.geometry = geometry; video._apply_geometry(); video._subtitle_poll_ms = 0; video._poll_subtitles()
		var pixels := white_pixels(await shot(viewport, output.path_join("captions-projected-%d.png" % geometry)))
		projected_counts.append(pixels)
		check(pixels > 100, "Both subtitles survive immersive projection %d" % geometry)
	video.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "white_pixels": counts, "projected_white_pixels": projected_counts}))
	for failure in failures: printerr("FAIL: " + failure)
	print("Dual subtitle render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
