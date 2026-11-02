extends SceneTree
const Fixture := preload("res://tests/test_vr_passthrough.gd")
const Follow := preload("res://tests/test_view_follow.gd")
const Transition := preload("res://tests/test_video_mode_transition.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/vr-passthrough/previews")

class Host extends Fixture.Host:
	func take_mpv_layer_thumbnail(_id: int) -> PackedByteArray:
		var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		for y in size.y:
			for x in size.x:
				var u := float(x % (size.x / 2)) / (size.x / 2)
				var v := float(y) / size.y
				var color := Color(0.1 + 0.25 * u, 0.32 + 0.4 * (1-v), 0.75) if x < size.x / 2 else Color(0.85, 0.28 + 0.3 * (1-v), 0.1 + 0.2 * u)
				if x % 160 < 3 or y % 160 < 3: color = Color(0.85, 0.9, 0.95)
				image.set_pixel(x, y, color)
		return image.get_data()

func _initialize() -> void: run.call_deferred()

func capture_frame(viewport: SubViewport, name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var config := ConfigFile.new(); config.set_value("appearance", "background", "dark")
	config.save(output.path_join("settings.cfg"))
	var main := Follow.FollowMain.new()
	main.settings_path = output.path_join("settings.cfg"); main.display = Follow.SupportedDisplay.new()
	viewport.add_child(main); main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	var v: Node3D = main.video
	v.platform = Host.new()
	main.xr_camera.fov = 70
	v.local_uri = "file:///vr-preview-render.mp4"
	v.media.begin(7); v.media.state = "paused"; v.media.frame_counter = 2
	v.media.format = {"width": 3840, "height": 2160}
	v._waiting_first = false
	v._binding = Transition.ProbeBinding.new()
	v._binding.bind(v.material, {"session_id": 7, "slot_token": 8, "width": 3840, "height": 2160,
		"stereo_sbs": true, "top_bottom": false, "color_target": "layer"})
	v.media.last_pair = v._binding.ticket.duplicate(true)
	v.geometry = 3; v.stereo_sbs = true; v.top_bottom = false
	v._layer_session = true; v._layer_requested = true; v.requested_play = true
	v._apply_geometry(); v.panel.visible = true
	main._on_video_changed()
	# Enter with a current centre direction, then render each source eye independently.
	v.view_yaw = 0; v.view_pitch = 0; v.view_zoom = 0; v.view_horizontal = 0; v._center_on_view()
	main._on_session_control("temporary_passthrough")
	v.platform.status = "ready"; v.vr_passthrough.poll()
	viewport.transparent_bg = true
	var failures := 0
	v.vr_passthrough.material.set_shader_parameter("viewing_eye", 1)
	v.vr_passthrough.release_material.set_shader_parameter("viewing_eye", 1)
	var widths := []
	for frame in 13:
		if frame > 0: v.vr_passthrough.poll(0.02)
		var image := await capture_frame(viewport, "roll-in-%02d" % frame)
		var width := 0
		for x in range(100, 1300):
			if image.get_pixel(x, 430).a > 0.1: width += 1
		widths.append(width)
		if image.get_pixel(50, 50).a > 0.01 or image.get_pixel(650, 645).a < 0.9: failures += 1
	if widths[0] < widths[-1] * 2 or widths[-1] < 180: failures += 1
	for i in range(1, widths.size()):
		if widths[i] > widths[i-1] + 2: failures += 1
	main._leave_vr_passthrough()
	for frame in 12:
		if frame > 0: v.vr_passthrough.poll(0.02)
		var image := await capture_frame(viewport, "roll-out-%02d" % frame)
		if image.get_pixel(650, 645).a < 0.9 or v.requested_play: failures += 1
		if frame == 0 and image.get_pixel(50, 50).a > 0.01: failures += 1
		if frame == 11 and image.get_pixel(50, 50).a < 0.9: failures += 1
	v.vr_passthrough.poll(0.03)
	if v.vr_passthrough.active() or not v.requested_play: failures += 1
	main._on_session_control("temporary_passthrough"); v.vr_passthrough.poll(1.0)
	for language in ["zh", "zh_Hant", "en", "ja"]:
		main.vr_passthrough_menu.I18n.use(language); main.vr_passthrough_menu.refresh()
		for eye in [1, 2]:
			v.vr_passthrough.material.set_shader_parameter("viewing_eye", eye)
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			image.save_png(output.path_join("%s-eye%d.png" % [language, eye]))
			var center := image.get_pixel(700, 430)
			if (eye == 1 and center.b <= center.r) or (eye == 2 and center.r <= center.b): failures += 1
			if image.get_pixel(50, 50).a > 0.01: failures += 1
			if image.get_pixel(650, 645).a < 0.9: failures += 1
			var label: Label3D = main.vr_passthrough_menu._buttons[0].node.find_children("*", "Label3D", true, false)[0]
			if label.get_aabb().size.x * label.scale.x > 0.46: failures += 1
	main.xr_camera.global_transform = Transform3D(Basis.from_euler(Vector3(0.15, 0.9, -0.4)), Vector3(4, 1.8, 2))
	main._sync_vr_passthrough_menu()
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("moved-exit.png"))
	if viewport.get_texture().get_image().get_pixel(650, 645).a < 0.9: failures += 1
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	v._stream_projection = {"kind": "equirectangular", "geometry": 3, "pose": [25, 5, 2], "stereo_mode": 1}
	v._stream_mesh = v.StreamProjection.mesh(v._stream_projection); v._apply_geometry()
	main._on_session_control("temporary_passthrough"); v.vr_passthrough.poll(1.0)
	for eye in [1, 2]:
		v.vr_passthrough.material.set_shader_parameter("viewing_eye", eye)
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		image.save_png(output.path_join("authored-eye%d.png" % eye))
		var center := image.get_pixel(700, 430)
		if center.a < 0.9 or (eye == 1 and center.b <= center.r) or (eye == 2 and center.r <= center.b): failures += 1
		if image.get_pixel(650, 645).a < 0.9: failures += 1
	# Exercise the same capture/quad grouping used on the headset, without a native XR session.
	var capture := preload("res://scripts/menu_composition.gd").new()
	main.add_child(capture)
	capture.configure(main.xr_origin, main.xr_camera, main.display, [main.vr_passthrough_menu], false, true)
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var used: Array = capture.slots.filter(func(slot): return slot.used)
	if capture.active != main.vr_passthrough_menu or used.size() != 1: failures += 1
	if used.size() == 1: used[0].raw.get_texture().get_image().save_png(output.path_join("exit-composition.png"))
	capture.shutdown("test_finished")
	main.free(); viewport.queue_free(); await process_frame; await RenderingServer.frame_post_draw
	print("VR passthrough render: 37 frames, %d failures" % failures)
	quit(0 if failures == 0 else 1)
