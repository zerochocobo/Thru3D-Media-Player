extends SceneTree

const Metadata := preload("res://scripts/spatial_video_metadata.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Existing := preload("res://tests/test_file_mode_memory.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var raw := {"baseline_meters": 0.0192, "horizontal_fov_degrees": 63.4, "horizontal_disparity": 0.02}
	check(Metadata.normalize(raw) == raw, "Preserve real iPhone-style units")
	for bad in [null, "0.02", [], {"baseline_meters": -1, "horizontal_fov_degrees": 180, "horizontal_disparity": INF},
		{"baseline_meters": NAN, "horizontal_fov_degrees": "63.4", "horizontal_disparity": true}]:
		check(Metadata.normalize(bad).is_empty(), "Reject malformed metadata " + str(bad))
	check(Metadata.normalize({"horizontal_disparity": 0}).has("horizontal_disparity"), "Zero disparity is a valid authored value")
	check(Metadata.normalize({"horizontal_fov_degrees": 60, "horizontal_disparity": 1.01}) == {"horizontal_fov_degrees": 60.0}, "Validate fields independently")
	check(is_equal_approx(Metadata.fov_scale(60, 2, 2), 2 * tan(PI / 6)), "FOV sets angular screen width")
	for args in [[0, 2, 2], [180, 2, 2], [60, 0, 2], [60, 2, 0], [NAN, 2, 2]]:
		check(Metadata.fov_scale(args[0], args[1], args[2]) < 0, "Reject invalid FOV geometry")
	var output := ProjectSettings.globalize_path("res://../../build/output/spatial-metadata-20261016/memory-" + str(Time.get_ticks_usec()))
	var host := Existing.Host.new()
	var video := Video.new()
	video.mode_memory = Memory.new(output)
	video.recent_files.directory = output.path_join("recent")
	video.bookmark_store.directory = output.path_join("bookmarks")
	root.add_child(video)
	video.platform = host
	video.history_enabled = false
	var uri := "file:///metadata_LR.mov"
	check(video.open_local(uri, "metadata_LR.mov"), "Open native stereo source")
	video.media.format = {"width": 3840, "height": 1080, "spatial_video": true, "spatial_metadata": raw}
	video._complete_layout()
	check(video.spatial_metadata() == raw and video.spatial_auto_disparity, "Recognize spatial metadata with default automatic correction")
	check(video.stereo_offset_uv().is_equal_approx(Vector2(-0.02, 0)), "Positive Apple disparity uses the opposite sampling sign")
	check(video.material.get_shader_parameter("stereo_offset").is_equal_approx(Vector2(-0.02, 0)), "Actual material receives source correction")
	check(video._hole_material.get_shader_parameter("stereo_offset").is_equal_approx(video.stereo_offset_uv()), "Compositor hole uses identical offset")
	var copy := video.spatial_metadata(); copy.horizontal_disparity = 0.5
	check(video.spatial_metadata() == raw, "Callers cannot mutate source metadata")
	video.set_stereo_alignment("stereo_horizontal", 1.0)
	video.set_stereo_alignment("stereo_vertical", -0.5)
	video.commit_stereo_view()
	check(video.stereo_offset_uv().is_equal_approx(Vector2(-0.01, -0.005)), "Manual correction adds independently in display-eye units")
	video.toggle_eye_order()
	check(video.stereo_offset_uv().is_equal_approx(Vector2(0.03, -0.005)), "Source correction reverses with swapped eyes; manual correction does not")
	video.set_viewing_eye(1)
	check(video._hole_material.next_pass == null, "Mono view removes stereo correction border")
	video.set_viewing_eye(0)
	video.toggle_eye_order()
	var session := video.media.session_id
	var calls := host.calls.size()
	check(video.set_spatial_auto_disparity(false), "Source correction can be disabled")
	check(video.stereo_offset_uv().is_equal_approx(Vector2(0.01, -0.005)), "Off keeps the user's own corrections")
	check(host.calls.size() == calls and video.media.session_id == session, "Display toggle does not reopen decoding")
	var fresh := Memory.new(output); fresh.load_saved()
	check(fresh.lookup(uri).get("spatial_auto_disparity") == false, "Source correction choice persists per file")
	video.mode_memory = fresh
	check(video.open_local(uri, "metadata_LR.mov") and not video.spatial_auto_disparity, "Reopening restores the user's opt-out")
	video.media.format = {"width": 3840, "height": 1080, "spatial_video": true, "spatial_metadata": raw}
	video._complete_layout()
	video.reset_stereo_alignment()
	check(not video.spatial_auto_disparity and video.spatial_metadata() == raw, "Reset alignment leaves source parameters and preference intact")
	video.set_spatial_auto_disparity(true)
	video.screen_curve = 0.7
	check(video.match_spatial_fov() and video.screen_curve == 0.0, "FOV preset selects a flat screen")
	check(is_equal_approx(rad_to_deg(2 * atan(video._flat.size.x / (2 * video.screen_distance))), 63.4), "Actual screen geometry matches authored horizontal FOV")
	var camera := Camera3D.new(); root.add_child(camera)
	video.view_camera = camera
	camera.global_position = video.panel.global_position + Vector3(0, 0, 2)
	check(video.spatial_fov_scale() > 0.0, "FOV matching uses the actual centred viewer")
	camera.global_position.x += 0.2
	check(video.spatial_fov_scale() < 0.0 and not video.match_spatial_fov(), "Off-axis viewing does not claim an exact angle match")
	camera.global_position = video.panel.global_position - Vector3(0, 0, 2)
	check(video.spatial_fov_scale() < 0.0, "A viewer behind the screen cannot match its front-facing FOV")
	video.view_camera = null; camera.queue_free()
	var scale := video.screen_scale
	video._apply_geometry()
	check(video.screen_scale == scale, "New frames do not overwrite a one-shot screen choice")
	video._accept_spatial_metadata({"spatial_metadata": {"horizontal_fov_degrees": 179.0}})
	check(video.spatial_fov_scale() < 0 and not video.match_spatial_fov(), "Unavailable screen size is rejected without silently clamping")
	video._accept_spatial_metadata({"spatial_metadata": raw})
	video.media.begin(session + 1)
	check(video.spatial_metadata() == raw and video.is_spatial_video(), "Processing generation retains source metadata")
	video._reopen_after_context_loss(uri, "metadata_LR.mov", 2000, true)
	check(video.is_spatial_video() and video.spatial_metadata() == raw and video.spatial_auto_disparity, "Context recovery retains live source and correction preference")
	# Test the actual menu dispatch and state, with all persistence inside the fixture.
	var main := Main.new(); main.video = video; main.settings_path = output.path_join("main.cfg")
	var menu := Menu.new(); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu)
	menu.toggle(); menu._adjustment = "stereo_view"; menu.refresh()
	check(menu._buttons.any(func(b): return b.target == Menu.SPATIAL_DISPARITY), "Spatial stereo popup exposes the source correction toggle")
	menu._activate(Menu.SPATIAL_DISPARITY)
	check(not video.spatial_auto_disparity, "Menu toggle reaches the actual video controller")
	menu._adjustment = "screen"; menu.refresh()
	check(menu._buttons.any(func(b): return b.target == Menu.SPATIAL_FOV and b.enabled), "Screen popup offers available FOV matching")
	check(menu._buttons.filter(func(b): return b.target == Menu.SPATIAL_FOV)[0].node.get_child(0).text == I18n.t("Match spatial video capture FOV"),
		"Video action explicitly identifies spatial videos")
	menu._activate(Menu.SPATIAL_FOV)
	check(video.screen_curve == 0 and main.settings.get_value("screen", "scale", -1) == video.screen_scale, "FOV operation uses normal screen preference saving")
	var tracked := Camera3D.new(); root.add_child(tracked); video.view_camera = tracked
	tracked.global_position = video.panel.global_position + Vector3(0,0,2)
	menu.refresh_values()
	var knob: Object = menu._adjust_rows[450].knob
	check(menu.press_pointer("right_hand",menu.to_global(Vector3(.2,knob.position.y,1)),-menu.global_basis.z,true), "Capture video distance slider")
	tracked.global_position.x += .2; menu.refresh_values()
	check(menu.has_pointer_capture() and menu._adjust_rows[450].knob == knob \
		and not menu._buttons.filter(func(b): return b.target == Menu.SPATIAL_FOV)[0].enabled, "FOV button state changes preserve video slider capture")
	menu.release_pointer("right_hand",Vector3.ZERO,Vector3.ZERO,false)
	video.view_camera = null; tracked.queue_free()
	# Both composition eyes remain inside their own packed images, even at legal extremes.
	var layer := preload("res://scripts/video_layer.gd").new(null)
	var origin := Node3D.new(); root.add_child(origin)
	for disparity in [-1.0, -0.02, 0.0, 0.02, 1.0]:
		video._accept_spatial_metadata({"spatial_metadata": {"horizontal_disparity": disparity}})
		video.set_spatial_auto_disparity(true)
		var values: PackedFloat32Array = layer.layer_values(video, origin)
		for eye in 2:
			var i := eye * layer.STRIDE
			var rect := Rect2(values[i + 9], values[i + 10], values[i + 11], values[i + 12])
			check(Rect2(eye * 2048, 0, 2048, 4096).encloses(rect) and rect.has_area(), "Spatial correction cannot cross an eye's compositor image rectangle")
	video._accept_spatial_metadata({"spatial_metadata": {}})
	check(video.spatial_metadata().is_empty() and video.stereo_offset_uv() == Vector2.ZERO, "Explicit empty metadata clears a prior value")
	check(video.open_local("file:///ordinary_LR.mp4", "ordinary_LR.mp4") and video.spatial_auto_disparity, "Next file starts with the default preference")
	check(video.spatial_metadata().is_empty() and not video.is_spatial_video() and not video.set_spatial_auto_disparity(false), "Ordinary stereo never inherits Apple metadata")
	menu._adjustment = "stereo_view"; menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.SPATIAL_DISPARITY), "Ordinary stereo keeps its original popup")
	menu._adjustment = "screen"; menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.SPATIAL_FOV), "Ordinary/converted videos have no spatial capture action")
	video.close_video()
	check(video.material.get_shader_parameter("stereo_offset") == Vector2.ZERO, "Close clears actual material correction")
	main.video = null; main.free(); menu.queue_free(); video.queue_free(); origin.queue_free()
	await process_frame
	print("Spatial video metadata checks=%d failures=%d" % [checks, failures.size()])
	for message in failures: push_error(message)
	quit(0 if failures.is_empty() else 1)
