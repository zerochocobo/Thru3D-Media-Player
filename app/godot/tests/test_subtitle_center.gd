extends SceneTree
const Depth := preload("res://scripts/subtitle_depth.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	for angle in [-60.0, -14.0, 0.0, 27.0, 60.0]:
		var legacy := ConfigFile.new()
		legacy.set_value("subtitles", "elevation_degrees", angle)
		for vertical in [false, true]:
			var center := Depth.restore_center(legacy, vertical)
			check(center == (Vector2(angle, 0) if vertical else Vector2(0, angle)), "Old shared angle migrates only to its original axis")
			check(Depth.center_anchor(center).is_equal_approx(Depth.anchor(angle, vertical)), "Migration preserves the complete old plane orientation")
	for index in 5:
		var legacy := ConfigFile.new()
		legacy.set_value("subtitles", "position", index)
		for vertical in [false, true]:
			check(Depth.center_anchor(Depth.restore_center(legacy, vertical)).is_equal_approx(Depth.anchor(Depth.restore_position(legacy), vertical)), "Old five-position presets also retain their placement")
	var settings := ConfigFile.new()
	settings.set_value("subtitles", "elevation_degrees", -18.0)
	Depth.save_centers(settings, Vector2(24, -12), Vector2(-30, 16))
	settings.set_value("subtitles", "elevation_degrees", 52.0)
	var restored := ConfigFile.new(); restored.parse(settings.encode_to_text())
	check(Depth.restore_center(restored, false) == Vector2(24, -12) and Depth.restore_center(restored, true) == Vector2(-30, 16), "New centres survive serialization and override stale legacy values")
	settings.set_value("subtitles", "horizontal_center_x_degrees", "bad")
	settings.set_value("subtitles", "horizontal_center_y_degrees", INF)
	check(Depth.restore_center(settings, false) == Vector2(0, 52), "Malformed new values fall back per axis without losing the legacy angle")
	for x in [-60.0, 0.0, 60.0]:
		for y in [-60.0, 0.0, 60.0]:
			var ray := Depth.center_anchor(Vector2(x, y)) * Vector3.FORWARD
			check(is_equal_approx(rad_to_deg(atan2(ray.x, -ray.z)), x) and is_equal_approx(rad_to_deg(asin(ray.y)), y), "Both centre axes independently retain their angles")
	var video := Video.new(); root.add_child(video); video.set_process(false)
	var app := Main.new(); app.video = video
	var directory := ProjectSettings.globalize_path("res://../../build/output/subtitle-center/session-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	app.settings_path = directory.path_join("settings.cfg")
	app.settings = ConfigFile.new()
	app.settings.set_value("subtitles", "elevation_degrees", -22.0)
	app.settings.set_value("subtitles", "direction", 1)
	app.settings.set_value("subtitles", "flat_position", 0.4)
	app._restore_subtitle_settings()
	check(video.subtitle_center() == Vector2(-22, 0), "Startup honours the saved vertical layout before any edits")
	app._on_player_setting("subtitle_vertical_position", 15.0)
	app._on_setting_changed("subtitle_direction", 0)
	check(video.subtitle_center() == Vector2(0, -22), "Editing vertical subtitles cannot move horizontal subtitles")
	app._on_playback_adjustment("subtitle_horizontal_position", 25.0)
	app._save_playback_adjustments()
	app._on_setting_changed("subtitle_vertical_position", -10.0)
	app._on_setting_changed("subtitle_direction", 1)
	check(video.subtitle_center() == Vector2(-22, 15), "Switching back restores both independent vertical coordinates")
	var saved := ConfigFile.new(); check(saved.load(app.settings_path) == OK, "Settings saved to disk")
	app.settings = saved; app._restore_subtitle_settings()
	check(video.subtitle_horizontal_center == Vector2(25, -10) and video.subtitle_vertical_center == Vector2(-22, 15), "Both layouts survive an application reload")
	check(is_equal_approx(video.subtitle_flat_position, 0.4), "Flat subtitle position stays unchanged")
	app._on_player_setting("subtitle_horizontal_position", 0.0)
	check(video.subtitle_center() == Vector2(0, 15) and video.subtitle_horizontal_center == Vector2(25, -10), "Resetting one axis preserves the other axis and other layout")
	check(app._menu_state().subtitle_vertical_position == 15 and app._library_settings().subtitle_vertical_position == 15, "Player and global settings expose the same active coordinates")
	video.geometry = 1; video._apply_geometry(); video.caption.text = "字幕中心"; video.caption.visible = true
	for direction in [0, 1]:
		video.subtitle_direction = direction; video._place_caption()
		check(video.projected_subtitles.anchor_basis.is_equal_approx(Depth.center_anchor(video.subtitle_center())), "Production projection uses both axes of the selected layout")
	video.free(); app.free()
	for failure in failures: push_error(failure)
	print("Subtitle centre checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
