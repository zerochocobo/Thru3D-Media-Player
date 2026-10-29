extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Canvas := preload("res://scripts/flat_subtitle_canvas.gd")
const Existing := preload("res://tests/test_subtitle_layers.gd")
const Layer := preload("res://scripts/video_layer.gd")
const Menu := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var samples := []
var output := ProjectSettings.globalize_path("res://../../build/output/flat-subtitle-layers")
class Host extends Existing.Host:
	func video_layer_mask() -> String: return "1 640 360"

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames(count := 3) -> void:
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1200, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var origin := XROrigin3D.new(); viewport.add_child(origin)
	var camera := XRCamera3D.new(); origin.add_child(camera)
	camera.fov = 75; camera.position = Vector3(0, 1.6, 0)
	var video := Video.new(); origin.add_child(video); video.set_process(false)
	video.view_camera = camera
	var host := Host.new()
	var layers := Existing.Layers.new(null)
	layers._flip = true; layers._settings = true; layers.runtime_layers = 16
	layers.reserved_layers = 8; layers.runtime_image_size = Vector2i(4096, 4096)
	video.platform = host; video.video_layer = layers
	video.media.begin(7); video.media.state = "playing"; video.media.frame_counter = 1
	video.media.format = {"width": 1920, "height": 1080}
	video.stereo_sbs = false; video._layer_session = true; video._layer_generation = layers.generation
	video._apply_geometry()
	video.panel.visible = true
	video.caption.text = "字幕边缘 清晰轮廓\nSubtitle edges 012345"
	video.caption.visible = true; video._place_caption()
	await frames()
	var baseline_font := video.caption.font
	var baseline_pose: Transform3D = video.caption.global_transform
	var baseline_bounds: AABB = video.caption.get_aabb()
	video._update_layer()
	check(video.caption.layers == 1 and not video._flat_subtitle_on_layer, "Initial capture keeps the original glyphs visible")
	await frames(4)
	video._update_layer()
	var canvas: Node = video._flat_subtitle_canvas
	check(video._flat_subtitle_on_layer and video.caption.layers == 0, "Ready caption is submitted once and removed from the eye buffer")
	check(layers.shown.size() == Layer.STRIDE * 2, "Mono video plus one subtitle layer")
	check(host.copies == 1 and host.created[0][0] == Layer.SUBTITLE_SLOT, "Reuses existing subtitle slot, one upload")
	check(video.caption.font == baseline_font and video.caption.font_size == 40 and is_equal_approx(video.caption.pixel_size, 0.0016), "Original font, size and fallback are untouched")
	check(video.caption.global_transform.is_equal_approx(baseline_pose), "Original caption placement is untouched")
	var captured: AABB = canvas.label.get_aabb()
	check((captured.position * video.caption.pixel_size).is_equal_approx(baseline_bounds.position)
		and (captured.size * video.caption.pixel_size).is_equal_approx(baseline_bounds.size), "Oversampling preserves exact layout bounds: %s / %s" % [captured, baseline_bounds])
	check(canvas.label.font != ThemeDB.fallback_font and canvas.label.font.oversampling == 2.0
		and not canvas.label.font.generate_mipmaps and ThemeDB.fallback_font.oversampling == 0.0, "Capture uses its own oversampled font without mutating menu/shared fonts")
	var copies: int = host.copies
	for i in 5: video._update_layer()
	check(host.copies == copies, "An unchanged cue never reuploads each frame")
	# Pose and global scale never rerasterize the cue or alter its baseline.
	var revision: int = canvas.version
	for size in [1.0, 1.5, 1.8]:
		video.set_screen_scale(size); video._place_caption()
		await frames()
		video._update_layer()
		check(canvas.version == revision and host.copies == copies, "Screen scale preserves logical layout and cached pixels: %s %s %s" % [canvas.version, revision, video.caption.width])
		var pose: Transform3D = canvas.pose(video.caption)
		var point: Vector2 = canvas.rect.get_center()
		check(pose.origin.is_equal_approx(video.caption.to_global(Vector3(point.x, point.y, 0) * video.caption.pixel_size)), "Layer centre follows original label coordinate system")
	video.set_screen_scale(1.0)
	for rotation in [-45.0, 0.0, 45.0]:
		video.set_screen_rotation(rotation); video._place_caption(); video._update_layer()
		check(canvas.pose(video.caption).basis.is_equal_approx(video.caption.global_basis), "Source rotation preserves upright subtitle basis")
	video.set_screen_rotation(0.0)
	video.set_screen_curve(0.35); video._place_caption(); video._update_layer()
	check(video._flat_subtitle_on_layer and layers.shown[Layer.STRIDE] == 0, "Text stays on its original flat plane on a curved screen")
	video.set_screen_curve(0.0)
	for quality in 3:
		layers.supersampling = quality; video._update_layer()
		check(layers.shown[Layer.STRIDE + 18] == quality, "Subtitle sampling follows quality without any sharpening flag")
	layers._settings = false; video._update_layer()
	check(layers.shown[Layer.STRIDE + 18] == 0, "No filter extension has a supported fallback")
	layers._settings = true
	# Alpha's mask consumes a layer too. Text falls back before sacrificing the video or menus.
	layers.runtime_layers = 12; layers.alpha_blend = true; video.stereo_sbs = true
	video.alpha_requested = true; video._layer_alpha_allowed = true
	video._update_layer()
	check(video.video_layer_shown and layers.shown.size() == Layer.STRIDE * 4 and video.caption.layers == 1
		and not video._flat_subtitle_on_layer, "Alpha mask has priority over text when the reserved budget is full: shown=%s count=%s layers=%s alpha=%s" % [video.video_layer_shown, layers.shown.size()/Layer.STRIDE, video.caption.layers, video._layer_alpha()])
	video.alpha_requested = false; layers.alpha_blend = false; video.stereo_sbs = false
	# Keep eight menu/system reservations even with an unusually low runtime limit.
	layers.runtime_layers = 9
	video._layer_session = false; video.depth_requested = true; video.depth_enabled = true
	video._binding.warped = true
	video._binding.ticket = {"session_id": 7, "width": 1280, "height": 720, "slot_token": 1, "warp_texture_id": 77}
	check(video._subtitle_layer_extras(origin).is_empty() and not video._flat_subtitle_on_layer, "Insufficient budget never steals menu reservations")
	layers.runtime_layers = 10
	video._update_layer()
	check(video.video_layer_shown and not video._flat_subtitle_on_layer and video.caption.layers == 1
		and layers.shown.size() == Layer.STRIDE * 2, "Exact stereo budget retains video and original text, no overfull submission")
	layers.runtime_layers = 11; video._update_layer()
	check(video._flat_subtitle_on_layer and layers.shown.size() == Layer.STRIDE * 3 and layers.reserved_layers == 8, "One free layer restores text while all menu reservations remain")
	layers.runtime_layers = 16
	video._binding.warped = false; video.depth_requested = false; video.depth_enabled = false
	video._layer_session = true
	layers.refuse_show = true; video._update_layer()
	check(not video._flat_subtitle_on_layer and video.caption.layers == 1, "Rejected submission restores visible eye-buffer caption")
	layers.refuse_show = false
	video.caption.text = "新的一句，不能继续显示旧字幕"; video._place_caption(); video._update_layer()
	check(not video._flat_subtitle_on_layer and video.caption.layers == 1, "Changed cue never submits the stale previous text")
	await frames(4); video._update_layer()
	check(video._flat_subtitle_on_layer, "Changed cue becomes an independent layer when ready")
	layers.generation += 1; video._layer_generation = layers.generation
	copies = host.copies; video._update_layer()
	check(host.copies == copies + 1, "New XR generation reuploads the current cue")
	# Switching the shared slot to PGS and back must not reuse overwritten text pixels.
	video.caption.visible = false
	var bitmap := {"version": 1, "width": 100, "height": 20, "x": 400, "y": 600, "canvas_width": 1280, "canvas_height": 720}
	var pixels := PackedByteArray(); pixels.resize(100 * 20 * 4)
	video.bitmap_subtitles.apply(video.material, bitmap, 1, pixels)
	video._update_layer(); copies = host.copies
	video.bitmap_subtitles.clear(video.material); video.caption.visible = true; video._place_caption(); video._update_layer()
	check(host.copies == copies + 1 and video._flat_subtitle_on_layer, "PGS-to-text switch replaces the shared slot image")
	# Every supported size and vertical position retains the same layout and anchor.
	for size in [0.5, 1.0, 2.0]:
		for position in [0.0, 0.5, 1.0]:
			video.subtitle_size = size; video.subtitle_flat_position = position
			video._place_caption(); await frames(); video._place_caption()
			var expected_pose: Transform3D = video.caption.global_transform
			var expected_bounds: AABB = video.caption.get_aabb()
			video._update_layer(); await frames(4); video._update_layer()
			var actual_bounds: AABB = canvas.label.get_aabb()
			check(video.caption.global_transform.is_equal_approx(expected_pose), "Size/position controls keep original placement")
			check((actual_bounds.position * video.caption.pixel_size).is_equal_approx(expected_bounds.position)
				and (actual_bounds.size * video.caption.pixel_size).is_equal_approx(expected_bounds.size), "50/100/200 percent retains exact font metrics")
	video.subtitle_size = 1.0; video.subtitle_flat_position = 0.0; video._place_caption()
	video._update_layer(); await frames(4); video._update_layer()
	layers.runtime_image_size = Vector2i(32, 32); video._update_layer(); await frames(4); video._update_layer()
	check(not video._flat_subtitle_on_layer and video.caption.layers == 1, "Too-small runtime texture limit leaves the original caption visible")
	layers.runtime_image_size = Vector2i(4096, 4096); video._update_layer(); await frames(4); video._update_layer()
	check(video._flat_subtitle_on_layer, "Restored image limit recovers the caption layer")
	video.caption.position.y += 20.0; video._update_layer()
	check(not video._flat_subtitle_on_layer and video.caption.layers == 1, "Text outside the video hole cannot disappear behind the scene")
	video._place_caption(); video._update_layer()
	for style in video.SubtitleStyle.PRESETS:
		video.subtitle_style = style.value; video._place_caption(); video._update_layer()
		await frames(4); video._update_layer()
		check(canvas.label.modulate == video.caption.modulate and canvas.label.outline_modulate == video.caption.outline_modulate,
			"All subtitle palettes retain their original text and outline colours")
	video.subtitle_style = video.SubtitleStyle.DEFAULT; video._place_caption(); video._update_layer()
	await frames(4); video._update_layer()
	video.caption.visible = false; video._update_layer()
	check(not video._flat_subtitle_on_layer and layers.shown.size() == Layer.STRIDE, "Subtitle off removes the layer immediately")
	video.caption.visible = true; video._flat_subtitle_layer_version = -1
	host.refuse_slot = Layer.SUBTITLE_SLOT; video._update_layer()
	check(video._subtitle_layer_failed and video.caption.layers == 1 and video.video_layer_shown, "Upload failure retains video and readable fallback")
	host.refuse_slot = -1; video._subtitle_layer_failed = false
	# Layout and crispness: desktop reconstruction of the submitted quad over a coloured background.
	await render_comparison(viewport, camera, video)
	var menus := Menu.new()
	menus.enabled = true
	check(menus.layer_reservation() == 5 and Menu.DENSITY == 1320 and Menu.MAX_GROUPS == 5,
		"Production menu retains all five captures and original density")
	menus.free()
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"checks": checks, "failures": failures, "samples": samples,
		"scope": "Desktop capture, layout, compositing and budget mocks; XR runtime filtering/optics remain unmeasured"}, "\t"))
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Flat subtitle layers: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func render_comparison(viewport: SubViewport, camera: Camera3D, video: Node3D) -> void:
	video.panel.visible = false
	camera.position = Vector3.ZERO
	var background := WorldEnvironment.new(); viewport.add_child(background)
	background.environment = Environment.new(); background.environment.background_mode = Environment.BG_COLOR
	background.environment.background_color = Color(0.05, 0.25, 0.5)
	var quad := MeshInstance3D.new(); quad.mesh = QuadMesh.new(); viewport.add_child(quad)
	var material := ShaderMaterial.new(); var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never; uniform sampler2D tex: source_color, filter_linear, repeat_disable; void fragment(){vec4 c=texture(tex,UV); ALBEDO=c.a>0.0001?c.rgb/c.a:vec3(0.0); ALPHA=c.a;}"
	material.shader = shader; quad.material_override = material
	var canvas: Node = video._flat_subtitle_canvas
	for text in ["字幕边缘 清晰轮廓", "繁體字幕 複雜筆畫", "日本語 字幕の輪郭", "Subtitle edges 012345", "双语字幕 😀\nSecond line"]:
		video.caption.text = text; video.caption.visible = true; video._place_caption()
		video.caption.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.8))
		video.caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		canvas.request(video.caption)
		await frames(4)
		check(canvas.request(video.caption), "Capture ready for pixel comparison")
		var captured: Image = canvas.viewport.get_texture().get_image()
		check(captured.get_used_rect().has_area(), "Capture contains visible glyphs")
		captured.save_png(output.path_join("source_%d.png" % samples.size()))
		quad.mesh.size = canvas.physical_size(video.caption); quad.global_transform = canvas.pose(video.caption)
		material.set_shader_parameter("tex", canvas.viewport.get_texture())
		quad.visible = false; video.caption.layers = 1
		await frames(); var before := viewport.get_texture().get_image()
		quad.visible = true; video.caption.layers = 0
		await frames(); var after := viewport.get_texture().get_image()
		before.save_png(output.path_join("before_%d.png" % samples.size()))
		after.save_png(output.path_join("after_%d.png" % samples.size()))
		var a := white_stats(before); var b := white_stats(after)
		check(a.count > 100 and b.count > a.count * 0.9, "Solid white strokes retain contrast: %s / %s" % [a.count, b.count])
		# Thresholded ink centroids change with edge coverage; the layout's box locates the text.
		check(a.extent.get_center().distance_to(b.extent.get_center()) < 1.0, "Glyph bounds centre remains within one output pixel")
		check(a.extent.position.distance_to(b.extent.position) < 3.0 and a.extent.size.distance_to(b.extent.size) < 4.0, "Glyph extent and baseline are preserved")
		samples.append({"text": text, "before": a, "after": b, "texture": canvas.viewport.size})
	quad.free()

func white_stats(image: Image) -> Dictionary:
	var count := 0; var center := Vector2.ZERO; var extent := Rect2()
	for y in range(300, 600):
		for x in range(100, 1100):
			var c := image.get_pixel(x, y)
			if minf(c.r, minf(c.g, c.b)) < 0.9: continue
			var p := Vector2(x, y)
			extent = extent.expand(p) if count else Rect2(p, Vector2.ZERO)
			count += 1; center += p
	return {"count": count, "center": center / maxf(count, 1), "extent": extent}
