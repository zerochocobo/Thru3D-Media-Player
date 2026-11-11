extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Existing := preload("res://tests/test_subtitle_layers.gd")
const Layer := preload("res://scripts/video_layer.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/depth-subtitles")
var samples: Array = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func frames(count := 4) -> void:
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); root.add_child(viewport)
	viewport.size = Vector2i(1200, 900); viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var environment := WorldEnvironment.new(); viewport.add_child(environment)
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.055, 0.075, 0.11, 1)
	var origin := XROrigin3D.new(); viewport.add_child(origin)
	var camera := XRCamera3D.new(); origin.add_child(camera); camera.fov = 75
	var video := Video.new(); origin.add_child(video); video.set_process(false); video.view_camera = camera
	var host := Existing.Host.new(); video.platform = host
	var layers := Existing.Layers.new(null); video.video_layer = layers
	layers._flip = true; layers._settings = true; layers.runtime_layers = 16
	layers.reserved_layers = 8; layers.runtime_image_size = Vector2i(4096, 4096)
	video.media.begin(7); video.media.state = "playing"; video.media.frame_counter = 1
	video.media.format = {"width": 1920, "height": 1080}
	video.panel.visible = true; video._apply_geometry(); video.panel.layers = 0
	video.caption.visible = true; video.caption.text = "屏下字幕 · 保持清晰\nSecond subtitle track"
	video.subtitle_flat_position = 0.73; video._place_caption(); await frames(); video._place_caption()
	var original_pose: Transform3D = video.caption.global_transform
	video.depth_requested = true; video.depth_enabled = true; video._binding.warped = true
	video.subtitle_below_screen = true
	video._binding.ticket = {"session_id": 7, "width": 1280, "height": 720, "slot_token": 1, "warp_texture_id": 77}
	video._update_layer(); await frames(); video._update_layer()
	var below: Node3D = video._depth_subtitles
	check(video._subtitle_on_layer and below.hole.visible and below.text.layers == 0 and video.caption.layers == 0,
		"Ready screen-down capture submits exactly one label and its coverage hole")
	check(not video._flat_subtitle_on_layer and video.caption.global_transform.is_equal_approx(original_pose), "Original layout and original layer ownership remain separate")
	var copies: int = host.copies
	var version: int = below.canvas.version
	for i in 5: video._update_layer()
	check(host.copies == copies and version == below.canvas.version, "Paused screen-down text never rerasterizes or uploads per frame")
	var backdrop := MeshInstance3D.new(); viewport.add_child(backdrop); backdrop.mesh = QuadMesh.new()
	var paint := StandardMaterial3D.new(); paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.albedo_color = Color(0.16, 0.28, 0.38); backdrop.material_override = paint
	for size in [0.5, 1.0, 2.0]:
		for roll in [45.0, -45.0, 90.0]:
			video.subtitle_size = size; video.set_screen_rotation(roll); video._place_caption()
			video._update_layer(); await frames(); video._update_layer()
			var local_top: Vector3 = video.subtitle_transform().affine_inverse() * below.text.global_transform * Vector3(0, below.text.get_aabb().end.y, 0)
			check(local_top.y + (below.text.outline_size + 1) * below.text.pixel_size < below.lower_edge(video._flat.size, roll), "Every line stays below the rotated screen at size %s and roll %s" % [size, roll])
			check(video._subtitle_on_layer and video.subtitle_below_screen, "The explicit below-screen configuration survives rotation")
			backdrop.mesh.size = video._flat.size; backdrop.global_transform = video.panel.global_transform
			camera.global_position = video.panel.global_position + Vector3(0, -0.3, 3.0)
			below.commit(false) # Native layers are mocked; capture the actual fallback geometry.
			await frames(2)
			var image := viewport.get_texture().get_image()
			var bottom_pixel := -INF
			for corner in 4:
				var world: Vector3 = video.panel.to_global(video.screen_corner(corner))
				bottom_pixel = maxf(bottom_pixel, camera.unproject_position(world).y)
			var first_glyph_row := image.get_height()
			for y in range(0, image.get_height(), 2):
				for x in range(0, image.get_width(), 2):
					var color := image.get_pixel(x, y)
					if color.a > 0.9 and minf(color.r, minf(color.g, color.b)) > 0.8:
						first_glyph_row = y
						break
				if first_glyph_row == y: break
			check(first_glyph_row < image.get_height() and first_glyph_row > bottom_pixel, "Fallback renders visible glyphs entirely below the picture at size %s and roll %s" % [size, roll])
			var filename := "text-%s-roll-%s.png" % [size, roll]
			image.save_png(output.path_join(filename))
			samples.append(filename)
	video.subtitle_size = 1.0; video.set_screen_rotation(0); video._place_caption()
	video._update_layer(); await frames(); video._update_layer()
	version = below.canvas.version; copies = host.copies
	video.set_screen_scale(1.5); video._place_caption(); video._update_layer(); await frames(); video._update_layer()
	check(below.canvas.version == version and host.copies == copies, "Moving/scaling the screen keeps cached glyph pixels")
	video.set_screen_scale(1.0); video._place_caption(); video._update_layer(); await frames(); video._update_layer()
	video.set_screen_curve(0.35); video._update_layer()
	check(video._subtitle_on_layer and layers.shown[Layer.STRIDE * 2] == 0, "A curved screen still uses a stable flat subtitle plane")
	video.set_screen_curve(0.0)
	# A changed cue may not punch through the cinema to reveal the old native image.
	video.caption.text = "新字幕不能显示旧句\nFresh cue"; video._place_caption(); video._update_layer()
	check(not video._subtitle_on_layer and below.text.layers == 1 and not below.hole.visible, "New cue falls back until its exact capture is ready")
	await frames(); video._update_layer()
	check(video._subtitle_on_layer and below.hole.visible, "New cue recovers the native layer")
	layers.runtime_layers = 10; video._update_layer()
	check(video.video_layer_shown and not video._subtitle_on_layer and below.text.layers == 1 and not below.hole.visible, "Low layer budget retains visible subtitles and all menu reservations")
	layers.runtime_layers = 16; video._update_layer()
	layers.runtime_image_size = Vector2i(32, 32); video._update_layer(); await frames(); video._update_layer()
	check(not video._subtitle_on_layer and below.text.layers == 1 and not below.hole.visible, "Small runtime texture limits keep readable fallback")
	layers.runtime_image_size = Vector2i(4096, 4096); video._update_layer(); await frames(); video._update_layer()
	layers.refuse_show = true; video._update_layer()
	check(not below.hole.visible and below.text.layers == 1 and not video._subtitle_on_layer, "Rejected submission cannot leave a hole or hide text")
	layers.refuse_show = false; video._update_layer()
	copies = host.copies; layers.generation += 1; video._update_layer()
	check(host.copies > copies and video._subtitle_on_layer, "XR generation changes refresh the screen-down text swapchain")
	# Check the actual coverage shader against an opaque scene, including outside the quad.
	backdrop.visible = false; video.caption.visible = true; video._place_caption(); video._update_layer()
	var wall := MeshInstance3D.new(); viewport.add_child(wall); wall.mesh = QuadMesh.new()
	wall.mesh.size = Vector2(20, 20); wall.material_override = paint
	wall.global_position = video.panel.global_position + Vector3(0, 0, -1)
	await frames()
	var mask_image := viewport.get_texture().get_image()
	var clear := 0; var solid := 0
	for y in range(0, mask_image.get_height(), 3):
		for x in range(0, mask_image.get_width(), 3):
			if mask_image.get_pixel(x, y).a < 0.95: clear += 1
			else: solid += 1
	check(clear > 20 and solid > clear * 10, "Coverage hole exposes glyphs while retaining the surrounding scene")
	mask_image.save_png(output.path_join("coverage-mask.png"))
	wall.queue_free()
	# Native-bitmap-to-text round trips share slot 1 without stale cached images.
	video.caption.visible = false
	var glyph_image: Image = below.canvas.viewport.get_texture().get_image()
	var used := glyph_image.get_used_rect(); glyph_image = glyph_image.get_region(used)
	var cue := {"version": 1, "width": glyph_image.get_width(), "height": glyph_image.get_height(), "x": 0, "y": 0,
		"canvas_width": 1920, "canvas_height": 1080}
	video.bitmap_subtitles.apply(video.material, cue, 1, glyph_image.get_data())
	video._update_layer()
	check(video._subtitle_on_layer and below.kind == "bitmap" and below.hole.visible and not below.bitmap.visible, "PGS occupies the shared native slot below the screen")
	var pgs_top: Vector3 = video.subtitle_transform().affine_inverse() * below.bitmap.global_transform * Vector3(0, below.bitmap.mesh.size.y * 0.5, 0)
	check(pgs_top.y < -video._flat.size.y * 0.5, "The entire PGS crop is below the screen")
	video.material.set_shader_parameter("rotation_degrees", 90); video._update_layer()
	check(below.bitmap.visible and not below.hole.visible and not video._subtitle_on_layer
		and below.bitmap.material_override.get_shader_parameter("rotation_degrees") == 90, "Rotated bitmap retains a visible correctly oriented fallback")
	video.material.set_shader_parameter("rotation_degrees", 0)
	video._bitmap_layer_texture = null; host.refuse_slot = Layer.SUBTITLE_SLOT; video._update_layer()
	check(video._subtitle_layer_failed and below.bitmap.visible and not below.hole.visible and not video._subtitle_surface.visible,
		"Bitmap upload failure retains only the new fallback without an inline duplicate")
	host.refuse_slot = -1; video._subtitle_layer_failed = false; video._update_layer()
	layers.refuse_show = true; video._update_layer()
	check(below.bitmap.visible and not below.hole.visible, "Rejected PGS submission cannot hide the fallback")
	layers.refuse_show = false; video._update_layer()
	below.commit(false); backdrop.visible = true
	backdrop.mesh.size = video._flat.size; backdrop.global_transform = video.panel.global_transform
	await frames(2); viewport.get_texture().get_image().save_png(output.path_join("pgs-fallback.png")); samples.append("pgs-fallback.png")
	copies = host.copies
	video.bitmap_subtitles.clear(video.material); video.caption.visible = true; video._place_caption()
	video._update_layer(); await frames(); video._update_layer()
	check(host.copies == copies + 1 and video._subtitle_on_layer and below.kind == "text", "Returning from PGS replaces its pixels with the current text")
	video.set_subtitle_below_screen(false); await frames(); video._update_layer()
	check(video.depth_requested and video._flat_subtitle_on_layer and not below.active and not below.hole.visible,
		"Opting out while 3D remains on restores the original in-screen text layer")
	video.set_subtitle_below_screen(true); await frames(); video._update_layer()
	check(video._subtitle_on_layer and below.active and below.hole.visible and not video._flat_subtitle_on_layer,
		"Opting back in replaces shared-slot pixels and returns to the separate screen-down layout")
	# Exit must recover original compositor behaviour and preferences with no lingering new hole.
	video._binding.warped = false; video.depth_requested = false; video.depth_enabled = false
	video._layer_session = true; video._layer_generation = layers.generation
	video._place_caption(); video._update_layer(); await frames(); video._update_layer()
	check(video._subtitle_on_layer and below.active, "Ordinary 2D native layer retains the opted-in below-screen layout")
	video.stereo_sbs = true
	for top_bottom in [false, true]:
		video.top_bottom = top_bottom; video._apply_geometry(); video._place_caption(); video._update_layer(); await frames(); video._update_layer()
		check(video._subtitle_on_layer and below.active, "Native SBS/TB submits one below-screen subtitle quad")
	video.stereo_sbs = false; video.set_subtitle_below_screen(false)
	video._place_caption(); video._update_layer(); await frames(); video._update_layer()
	check(video._flat_subtitle_on_layer and not below.active and not below.hole.visible and not below.text.visible,
		"Opting out in ordinary 2D returns to the old text layer and removes every screen-down surface")
	check(video.subtitle_flat_position == 0.73, "Rendering never saves or rewrites the in-screen position")
	# The last appearance setting uses the existing field switch and real ray/trigger handling.
	video.visible = false; backdrop.visible = false; camera.global_position = Vector3.ZERO
	var menu := Menu.new(); viewport.add_child(menu); menu.set_process(false)
	menu.position = Vector3(0, -0.43, -1.85)
	var state := {"has_video": true, "geometry": 0, "depth_requested": true, "subtitle_below_available": true,
		"subtitle_below_screen": false, "subtitle_flat_position": 73.0, "subtitle_track": 9,
		"subtitle_options": [{"id": 9, "codec": "subrip", "title": "中文 / English"}]}
	var choices: Array = []
	menu.state_provider = func(): return state
	menu.setting_requested.connect(func(key, value): state[key] = value; choices.append([key, value]))
	menu.toggle(); menu._activate(110)
	if menu._subtitle_appearance_open: menu._activate(Menu.SUBTITLE_APPEARANCE)
	check(not menu.text_snapshot().contains(I18n.t("Below-screen subtitles")), "Main CC panel remains compact with appearance closed")
	menu._activate(Menu.SUBTITLE_APPEARANCE)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language); state.subtitle_below_screen = false; menu.refresh()
		check(menu.text_snapshot().contains(I18n.t("Below-screen subtitles")) and menu._subtitle_appearance_open and menu._subtitle_controls().back().field.key == "subtitle_below_screen",
			"Opt-in is last in subtitle appearance: " + language)
		await frames(2)
		var filename := "menu-%s-off.png" % language
		viewport.get_texture().get_image().save_png(output.path_join(filename)); samples.append(filename)
		var target: Dictionary = menu._buttons.filter(func(button): return menu.choices.targets.get(button.target, {}).get("key") == "subtitle_below_screen")[0]
		var ray_origin: Vector3 = target.node.to_global(Vector3(0, 0, 1))
		var direction: Vector3 = -menu.global_basis.z
		check(menu.ray_hit(ray_origin, direction).get("target") == target.target, "Opt-in has its own ray hit area")
		menu.press_pointer("right", ray_origin, direction, true); menu.release_pointer("right", ray_origin, direction, true)
		check(state.subtitle_below_screen and choices.back() == ["subtitle_below_screen", true] and menu._subtitle_open,
			"Trigger enables only this preference and keeps the CC panel open")
		await frames(2)
		filename = "menu-%s-on.png" % language
		viewport.get_texture().get_image().save_png(output.path_join(filename)); samples.append(filename)
		var off_target: int = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("key") == "subtitle_below_screen")[0]
		menu._activate(off_target)
		check(not state.subtitle_below_screen and state.subtitle_flat_position == 73.0, "Opt-out retains original in-screen placement")
	state.subtitle_below_available = false; menu.refresh()
	check(not menu.choices.targets.values().any(func(field): return field.get("key") == "subtitle_below_screen"), "Other modes retain the old CC menu without the new toggle")
	var choice_count := choices.size(); menu._activate(22303) # Removed legacy main-panel target.
	check(choices.size() == choice_count, "Stale hidden toggle targets cannot change preferences")
	FileAccess.open(output.path_join("render-verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"checks": checks, "failures": failures, "samples": samples,
		"scope": "Desktop GPU rendering and native-layer mocks; headset optics and runtime composition are not tested"}, "\t"))
	viewport.queue_free(); await process_frame
	for failure in failures: print("FAIL: " + failure)
	print("Depth subtitle rendering: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
