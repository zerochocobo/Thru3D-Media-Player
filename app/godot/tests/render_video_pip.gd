extends SceneTree
const PipWindow := preload("res://scripts/video_pip_window.gd")
const Pip := preload("res://scripts/video_pip.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var window: Node3D
var output := ProjectSettings.globalize_path("res://../../build/output/video-pip")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func draw() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func pixel(image: Image, x: float, y: float = 0.5) -> Color:
	return image.get_pixel(int(image.get_width() * x), int(image.get_height() * y))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(800, 450); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 1.125
	viewport.add_child(camera)
	window = PipWindow.new(); window.size = Vector2(2.0, 1.125); viewport.add_child(window)
	window.global_position = Vector3(0, 0, -2); window.frame.visible = true
	var source := Image.create(512, 256, false, Image.FORMAT_RGBA8)
	# Constant eyes prove that seam/crop/rotation/alignment cannot bleed into the other eye.
	source.fill_rect(Rect2i(0, 0, 256, 256), Color.RED)
	source.fill_rect(Rect2i(256, 0, 256, 256), Color.BLUE)
	var texture := ImageTexture.create_from_image(source)
	var material: ShaderMaterial = window.picture
	check(preload("res://scripts/video_pip_compositor.gd").parameters(material,
		preload("res://scripts/video_pip_compositor.gd").COMMON).size() == 43, "Unchanged material defaults are available to the native atlas")
	material.set_shader_parameter("color_texture", texture)
	material.set_shader_parameter("source_size", Vector2(512, 256))
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("stereo_sbs", true)
	window.crop_parameters()
	for geometry in [0, 1, 2, 3]:
		material.set_shader_parameter("video_geometry", geometry)
		for view in [1, 2]:
			for zoom in [1.0, 8.0]:
				material.set_shader_parameter("viewing_eye", view)
				window.zoom = zoom; window.crop_center = Vector2(1, 0); window.crop_basis = Basis.IDENTITY; window.crop_parameters()
				var image: Image = await draw()
				var color := pixel(image, 0.5)
				check((color.r > 0.9 and color.b < 0.1) if view == 1 else (color.b > 0.9 and color.r < 0.1), "Correct eye at projection %d, eye %d, zoom %.1f" % [geometry, view, zoom])
				if geometry == 3 and view == 2 and zoom == 1: image.save_png(output.path_join("stereo-right.png"))
	material.set_shader_parameter("video_geometry", 0)
	material.set_shader_parameter("viewing_eye", 1); window.crop_parameters()
	material.set_shader_parameter("swap_eyes", true)
	var image: Image = await draw()
	check(pixel(image, 0.5).b > 0.9, "Eye swap applies once")
	material.set_shader_parameter("swap_eyes", false)
	# Top/bottom uses the same eye-local crop, independent of Half layout pixel aspect.
	source.fill_rect(Rect2i(0, 0, 512, 128), Color.GREEN); source.fill_rect(Rect2i(0, 128, 512, 128), Color.BLUE)
	texture.update(source)
	material.set_shader_parameter("top_bottom", true); material.set_shader_parameter("stereo_half", true)
	image = await draw(); check(pixel(image, 0.5).g > 0.9 and pixel(image, 0.5).b < 0.1, "Half top-bottom left crop stays within upper eye")
	material.set_shader_parameter("viewing_eye", 2); window.crop_parameters()
	image = await draw(); check(pixel(image, 0.5).b > 0.9 and pixel(image, 0.5).g < 0.1, "Half top-bottom right crop stays within lower eye")
	material.set_shader_parameter("top_bottom", false); material.set_shader_parameter("stereo_half", false)
	material.set_shader_parameter("stereo_sbs", false); material.set_shader_parameter("viewing_eye", 0)
	# Longitude endpoints use matching red edges, green interior; looking backwards crosses the seam.
	source.fill(Color.GREEN); source.fill_rect(Rect2i(0, 0, 90, 256), Color.RED); source.fill_rect(Rect2i(422, 0, 90, 256), Color.RED)
	texture.update(source)
	window.zoom = 1; window.crop_basis = Basis(Vector3.UP, PI); window.crop_parameters()
	material.set_shader_parameter("video_geometry", 3)
	image = await draw(); image.save_png(output.path_join("panorama-seam.png"))
	check(pixel(image, 0.2).r > 0.9 and pixel(image, 0.8).r > 0.9 and pixel(image, 0.5).g < 0.1, "360 crop crosses longitude seam continuously")
	for geometry in [1, 2]:
		material.set_shader_parameter("video_geometry", geometry)
		image = await draw()
		check(pixel(image, 0.5).r < 0.05 and pixel(image, 0.5).g < 0.05, "Invalid hemisphere/lens is black, not edge smear: %d" % geometry)
	# Rotation and magnification use displayed per-eye coordinates.
	material.set_shader_parameter("video_geometry", 0); material.set_shader_parameter("rotation_degrees", 90)
	source.fill(Color.BLUE); source.fill_rect(Rect2i(0, 0, 256, 256), Color.RED); texture.update(source)
	window.zoom = 1; window.crop_center = Vector2(0.5, 0.5); window.crop_parameters()
	image = await draw()
	check(pixel(image, 0.5, 0.2).r > 0.9 and pixel(image, 0.5, 0.8).b > 0.9, "Rotation is applied after crop coordinates")
	material.set_shader_parameter("rotation_degrees", 0)
	source.fill(Color.BLUE); source.fill_rect(Rect2i(240, 0, 32, 256), Color.RED); texture.update(source)
	window.zoom = 1; window.crop_parameters(); image = await draw()
	check(pixel(image, 0.25).b > 0.9 and pixel(image, 0.5).r > 0.9, "1x shows the frozen baseline crop")
	window.zoom = 8; window.crop_parameters(); image = await draw()
	check(pixel(image, 0.25).r > 0.9 and pixel(image, 0.75).r > 0.9, "8x magnifies source without resizing window")
	# A second material borrows identical RIDs; clearing a native lease detaches every consumer.
	var binding := Binding.new(); binding.material = material; binding.color_rid = texture.get_rid()
	var borrowed := ShaderMaterial.new(); borrowed.shader = Binding.PAIR_SHADER
	binding.share_with(borrowed)
	check(RenderingServer.material_get_param(borrowed.get_rid(), "color_texture") == texture.get_rid(), "Shared picture uses the exact main texture")
	check(borrowed.get_shader_parameter("pip_enabled") != true, "Sharing uniforms never overwrites independent crop state")
	material.set_shader_parameter("grade_enabled", true); binding.share_with(borrowed)
	check(borrowed.get_shader_parameter("grade_enabled") == true, "Shared picture follows grading changes")
	material.set_shader_parameter("grade_enabled", null); binding.share_with(borrowed)
	check(borrowed.get_shader_parameter("grade_enabled") != true, "Resetting a main uniform clears the consumer override")
	# This test's ImageTexture owns the RID; native wrapper retirement is covered by binding tests.
	binding.color_rid = RID(); binding.unbind()
	check(RenderingServer.material_get_param(borrowed.get_rid(), "color_texture") == null, "Lease retirement detaches borrowed texture")
	binding.unshare(borrowed)
	material.set_shader_parameter("color_texture", texture)
	# UI preview uses the physical .48 m window and a perspective camera.
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE; camera.fov = 55
	window.size = Vector2(0.8, 0.45); window.position = Vector3(0, 0.2, -1.5)
	window.zoom = 1.5; window.controls = true; window.zoom_open = true; window.refresh(); window.crop_parameters()
	image = await draw(); check(image.save_png(output.path_join("window-controls.png")) == OK, "Window toolbar preview saved")
	check(window._buttons.size() == 12, "All five toolbar controls and seven magnifications render")
	for button in window._buttons:
		if not button.enabled: continue
		var node: Node3D = button.node
		check(window.ray_hit(node.to_global(Vector3(0, 0, 0.2)), -node.global_basis.z).get("target", -1) == button.target, "Every toolbar/zoom control has an unobstructed ray target")
	window.queue_free(); await process_frame
	# Actual manager placement, with three live consumers and a yaw-level panoramic group.
	viewport.size = Vector2i(1200, 800); camera.fov = 75; camera.position = Vector3(0, 1.5, 0)
	var group := preload("res://tests/test_video_pip.gd").Surface.new()
	viewport.add_child(group); group.geometry = 3; group._apply_geometry(); group.panel.layers = 2; camera.cull_mask = 1
	group.material.set_shader_parameter("alpha_enabled", false)
	group.material.set_shader_parameter("source_size", Vector2(512, 256))
	group._binding.material = group.material; group._binding.color_rid = texture.get_rid()
	group.pip.set_count(3, camera.global_transform)
	group.pip.windows[2].controls = true; group.pip.windows[2].refresh()
	group.pip.sync()
	image = await draw(); check(image.save_png(output.path_join("panorama-three-windows.png")) == OK, "Three-window panoramic layout preview saved")
	check(group._binding._consumers.size() == 3 and group.pip.windows.values().all(func(w): return w.frame.visible), "All three windows render from a single shared binding")
	group.pip.clear(); group._binding.color_rid = RID(); group._binding.unbind()
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
