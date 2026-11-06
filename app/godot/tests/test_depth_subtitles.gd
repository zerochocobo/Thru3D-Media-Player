extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Existing := preload("res://tests/test_subtitle_layers.gd")
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var checks := 0

class Host extends Existing.Host:
	var snapshot := {}
	func get_mpv_subtitles(_id: int, _sequence: int) -> String: return JSON.stringify(snapshot)
	func get_mpv_subtitle_bitmap(_id: int, _version: int) -> PackedByteArray:
		var pixels := PackedByteArray(); pixels.resize(300 * 50 * 4); pixels.fill(255); return pixels
	func set_mpv_secondary_subtitle(_id: int, _track: int, _delay: float) -> bool: return true
	func set_mpv_narration(_id: int, _json: String) -> bool: return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")
func ground_fixture(_x: float,_z: float) -> float: return 1.0

func poll(video: Node3D, host: Host, changes: Dictionary = {}) -> void:
	host.snapshot.sequence += 1
	host.snapshot.merge(changes, true)
	video._subtitle_poll_ms = 0
	video._poll_subtitles()
	video._update_layer()

func run() -> void:
	var origin := XROrigin3D.new(); root.add_child(origin)
	var camera := XRCamera3D.new(); origin.add_child(camera)
	var video := Video.new(); origin.add_child(video); video.set_process(false)
	video.view_camera = camera
	var host := Host.new(); video.platform = host
	var layers := Existing.Layers.new(null); video.video_layer = layers; layers._flip = true
	video.media.begin(7); video.media.state = "playing"; video.media.frame_counter = 1
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 9, "codec": "subrip"}]}}
	video.panel.visible = true
	video.subtitles.select(9)
	video.subtitles.set_delay(0.25); video.subtitle_delay = 0.25
	host.snapshot = {"session_id": 7, "sequence": 0, "generation": 3, "source_epoch": 2,
		"mpv_source_handle": 55, "command_id": 4, "required_command_id": 4, "track_id": "9",
		"timeline_valid": true, "age_ms": 20, "start_seconds": "1.0", "end_seconds": "3.0",
		"position_seconds": "1.5", "delay_seconds": 0.25, "text": "第一行\nSecond line"}
	video.subtitle_flat_position = 0.67; video.subtitle_size = 1.5; video.subtitle_style = "yellow_black"
	video._apply_geometry(); poll(video, host)
	await process_frame
	video._place_caption()
	var original_pose: Transform3D = video.caption.global_transform
	var original_cue: Dictionary = video.subtitles.cue.duplicate(true)
	check(video._depth_subtitles == null and video.caption.layers == 1, "Ordinary 2D never creates the new presentation module")
	video.depth_requested = true; poll(video, host)
	check(video.depth_subtitles_available() and not video.depth_subtitles_below() and video._depth_subtitles == null
		and video.caption.layers == 1, "Conversion defaults to the exact original in-screen subtitle path")
	video.set_subtitle_below_screen(true); poll(video, host)
	var below: Node3D = video._depth_subtitles
	check(video.depth_subtitles_below() and below.text.visible and video.caption.layers == 0, "Conversion uses only the separate below-screen label")
	check(video.caption.global_transform.is_equal_approx(original_pose) and video.caption.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM,
		"The original caption layout is untouched while hidden")
	check(below.text.text == video.caption.text and below.text.modulate == video.caption.modulate
		and below.text.font_size == video.caption.font_size and below.text.pixel_size == video.caption.pixel_size,
		"Below-screen text reads the already composed cue and style")
	check(video.subtitles.requested_track == 9 and video.subtitles.requested_delay == 0.25 and video.subtitle_flat_position == 0.67,
		"Track, timing and saved flat position remain owned by the original controller")
	check(video.subtitles.cue.text == original_cue.text and video.subtitles.cue.delay_seconds == original_cue.delay_seconds,
		"Layout does not rewrite native cue data")
	check(not video._subtitle_surface.visible and video.material.get_shader_parameter("separate_subtitles") == true,
		"No duplicate inline or separate legacy caption")
	await process_frame
	var text_top: Vector3 = video.subtitle_transform().affine_inverse() * below.text.global_transform * Vector3(0, below.text.get_aabb().end.y, 0)
	check(text_top.y < -video._flat.size.y * 0.5,
		"Multiline text including the top line lies entirely below the screen")
	var below_pose: Transform3D = below.text.global_transform
	video.subtitle_ground_provider=ground_fixture
	below.sync()
	var cleared_text: Vector3=below.text.global_transform*below.text.get_aabb().position
	check(cleared_text.y>=1.024 and video.subtitle_below_screen and below.text.font_size==video.caption.font_size,"Physical ground lifts the complete cue without changing preference or font size")
	video.subtitle_ground_provider=Callable(); below.sync()
	check(below.text.global_transform.is_equal_approx(below_pose),"Removing physical ground restores the requested below-screen anchor")
	video.depth_enabled = false; poll(video, host)
	video.depth_enabled = true; poll(video, host)
	check(below.text.global_transform.is_equal_approx(below_pose), "Transient model readiness does not move subtitles")
	video.subtitle_flat_position = 1.0; poll(video, host)
	check(below.text.global_transform.is_equal_approx(below_pose), "A saved in-screen position cannot move the screen-down label")
	video.subtitle_flat_position = 0.67
	# Native timing/identity rejection must still clear the new display.
	poll(video, host, {"position_seconds": "4.0"})
	check(not below.text.visible and not below.hole.visible and not below.bitmap.visible, "Expired cues clear the screen-down display")
	poll(video, host, {"position_seconds": "1.5", "generation": 2})
	check(not below.text.visible, "Old decoder generations cannot show text in the new module")
	poll(video, host, {"generation": 3, "text": "恢复后的字幕"})
	check(below.text.text == "恢复后的字幕" and below.text.visible, "A current cue recovers normally")
	video.subtitles.select(0); poll(video, host)
	check(not below.text.visible and not below.bitmap.visible, "Subtitles off still clears all presentation paths")
	video.subtitles.select(9); poll(video, host)
	# The existing composed second track is passed through, not reimplemented.
	video.dual_subtitles.enabled = true
	video.dual_subtitles.state.select(10)
	video.dual_subtitles.state.text = "Secondary track"
	video._subtitle_poll_ms = Time.get_ticks_msec() + 10000
	video._poll_subtitles()
	check(below.text.text.contains("Secondary track") and below.text.text == video.caption.text, "Dual subtitle composition is reused verbatim")
	video.dual_subtitles.enabled = false
	video.narration.enabled = true; video.narration.hide_subtitles = true
	video._poll_subtitles(); video._update_layer()
	check(not below.text.visible and not below.bitmap.visible and not below.hole.visible, "Narration's hide-subtitles policy also hides the new display")
	video.narration.enabled = false; poll(video, host)
	# PGS goes through the same native timing fence and pixel cache as before.
	var picture := {"visible": true, "version": 1, "width": 300, "height": 50, "x": 810, "y": 950, "canvas_width": 1920, "canvas_height": 1080}
	poll(video, host, {"bitmap": picture, "text": ""})
	var texture: Texture2D = video.bitmap_subtitles.texture
	video.subtitle_ground_provider=ground_fixture; below.sync()
	var bitmap_bottom: Vector3=below.bitmap.global_transform*Vector3(-below.bitmap.mesh.size.x*.5,-below.bitmap.mesh.size.y*.5,0)
	check(bitmap_bottom.y>=1.024 and video.bitmap_subtitles.texture==texture,"Physical ground lifts bitmap subtitles without replacing decoded pixels")
	video.subtitle_ground_provider=Callable(); below.sync()
	var rect: Vector4 = video.material.get_shader_parameter("bitmap_subtitle_rect")
	check(below.bitmap.visible and not below.text.visible and not video._subtitle_surface.visible, "PGS has one independent below-screen fallback")
	check(below.bitmap.material_override.get_shader_parameter("bitmap_subtitle_texture") == texture, "PGS reuses the original decoded texture without OCR or redecoding")
	var bitmap_pose: Transform3D = below.bitmap.global_transform
	poll(video, host)
	check(texture == video.bitmap_subtitles.texture and bitmap_pose.is_equal_approx(below.bitmap.global_transform), "Paused PGS keeps its texture and stable position")
	# Opting out recovers the exact original PGS UV rectangle and cue.
	video.depth_requested = false; video.depth_enabled = false; video.set_subtitle_below_screen(false); poll(video, host)
	check(not below.active and not below.bitmap.visible and not below.hole.visible and texture == video.bitmap_subtitles.texture
		and rect == video.material.get_shader_parameter("bitmap_subtitle_rect"), "PGS round trip restores the unmodified original rectangle and pixels")
	check(video.material.get_shader_parameter("separate_subtitles") == false, "Ordinary 2D PGS returns to the original inline shader")
	video.depth_requested = true; poll(video, host)
	video.set_subtitle_below_screen(false)
	check(video.depth_requested and not below.active and video.material.get_shader_parameter("separate_subtitles") == false,
		"Users can keep conversion on while restoring in-screen PGS")
	video.set_subtitle_below_screen(true)
	# All bounded video layouts are supported; immersive geometry and disc buttons stay isolated.
	video.depth_requested = true
	video.stereo_sbs = true
	for top_bottom in [false, true]:
		video.top_bottom = top_bottom
		check(video.depth_subtitles_below(), "Native SBS/TB supports screen-down subtitles")
	video._spatial_video = true; check(video.depth_subtitles_below(), "Spatial video supports screen-down subtitles")
	video._spatial_video = false
	video.stereo_sbs = false
	for geometry in [1, 2, 3, 4]:
		video.geometry = geometry; check(not video.depth_subtitles_below(), "Immersive geometry is isolated: %d" % geometry)
	video.geometry = 0
	video.disc.menu_session = true; check(not video.depth_subtitles_below(), "Disc menu overlays are isolated")
	video.disc.menu_session = false
	video.alpha_requested = true; check(not video.depth_subtitles_below(), "Portrait mode is isolated")
	video.alpha_requested = false
	poll(video, host, {"bitmap": {}, "text": original_cue.text})
	video.depth_requested = false; video.depth_enabled = false; video.set_subtitle_below_screen(false); poll(video, host)
	await process_frame
	video._place_caption()
	check(video.caption.global_transform.is_equal_approx(original_pose) and video.caption.layers == 1
		and not below.text.visible and video.subtitle_flat_position == 0.67, "Text round trip restores the exact old pose and preference")
	video.set_subtitle_below_screen(true); video.depth_requested = false; poll(video, host)
	check(below.active and below.text.visible, "Ordinary 2D also uses the opted-in presentation module")
	video._unbind()
	check(not below.active and not below.text.visible and not below.bitmap.visible and not below.hole.visible, "Unbinding/closing hides the new module immediately")
	# Menu change is display-only and keyed for refresh, including an already open appearance panel.
	var menu := Menu.new(); root.add_child(menu)
	menu._subtitle_appearance_open = true
	menu._state = {"has_video": true, "geometry": 0, "subtitle_flat_position": 67.0, "subtitle_below_available": true}
	var rows: Array = menu._subtitle_controls()
	check(rows.back().field.key == "subtitle_below_screen", "Screen-down toggle is the last appearance setting")
	var old_key: String = menu._base_bar_key()
	check(rows.any(func(row): return row.field.key == "subtitle_flat_position"), "Ordinary flat menu retains position control")
	menu._state.subtitle_below_screen = true
	rows = menu._subtitle_controls()
	check(not rows.any(func(row): return row.field.key == "subtitle_flat_position") and menu._base_bar_key() != old_key,
		"Screen-down policy removes only the in-screen slider and invalidates the open menu")
	for key in ["subtitle_delay", "subtitle_size", "subtitle_style", "subtitle_line"]:
		check(rows.any(func(row): return row.field.key == key), "Existing adjustment retained: " + key)
	check(menu._state.subtitle_flat_position == 67.0, "Hiding a control cannot overwrite its preference")
	menu._state.geometry = 1; menu._state.subtitle_below_available = false; menu._state.subtitle_below_screen = false
	check(not menu._subtitle_controls().any(func(row): return row.field.key == "subtitle_below_screen"), "Immersive appearance never contains the screen-down toggle")
	check(menu._subtitle_controls().any(func(row): return row.field.key == "subtitle_distance"), "Immersive distance control stays available")
	var bitmap_shader: Shader=below.bitmap.material_override.shader
	var hole_shader: Shader=below.hole.material_override.shader
	video.set_surface_front_only(true)
	check(not video.caption.no_depth_test and not video.caption.double_sided
		and not below.text.no_depth_test and not below.text.double_sided,"Physical media applies depth and front-face policy to both text labels")
	for surface in [below.bitmap,below.hole]:
		var code: String=surface.material_override.shader.code
		check("cull_back" in code and not "depth_test_disabled" in code,"Below-screen bitmap and hole use physical surface variants")
	video.set_surface_front_only(false)
	check(video.caption.no_depth_test and video.caption.double_sided and below.text.no_depth_test and below.text.double_sided,"Ordinary media restores both text label policies")
	check(below.bitmap.material_override.shader==bitmap_shader and below.hole.material_override.shader==hole_shader,"Ordinary media restores the original bitmap and hole shaders")
	var early := Video.new(); early.set_surface_front_only(true); root.add_child(early); early.set_process(false)
	check(not early.caption.no_depth_test and not early.caption.double_sided,"Front-face policy selected before ready reaches the newly created label")
	early.free()
	menu.free(); origin.free()
	for failure in failures: print("FAIL: " + failure)
	print("Depth subtitle isolation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
