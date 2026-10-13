extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
func centroid(image: Image) -> Vector2:
	var mass := 0.0
	var total := Vector2.ZERO
	for y in range(240, 565):
		for x in range(150, 1100):
			var c := image.get_pixel(x, y)
			var w := maxf(0, minf(c.r, minf(c.g, c.b)) - 0.4)
			mass += w; total += Vector2(x, y) * w
	if mass < 2: failures.append("Projected text is missing")
	return total / maxf(mass, 0.001)
func glyph_bounds(image: Image) -> Rect2i:
	var bounds := Rect2i()
	var found := false
	for y in range(240, 565):
		for x in range(150, 1100):
			var pixel := image.get_pixel(x, y)
			if minf(pixel.r, minf(pixel.g, pixel.b)) <= 0.85: continue
			if not found: bounds = Rect2i(x, y, 1, 1); found = true
			else: bounds = bounds.merge(Rect2i(x, y, 1, 1))
	return bounds
func eye_centers(viewport: SubViewport, eye: Camera3D, video: Node3D, capture_prefix: String = "") -> Array[Vector2]:
	var centers: Array[Vector2] = []
	for index in 2:
		eye.position.x = (index - 0.5) * 0.063
		video.material.set_shader_parameter("probe_eye", index)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var pixels := viewport.get_texture().get_image()
		centers.append(centroid(pixels))
		if not capture_prefix.is_empty(): pixels.save_png(capture_prefix + "_eye%d.png" % index)
	return centers
func check_centered_pair(centers: Array[Vector2], reference: Vector2, expected: float, context: String) -> void:
	if absf(centers[0].x - centers[1].x - expected) > 0.9:
		failures.append(context + ": stereo disparity mismatch")
	if absf((centers[0].x + centers[1].x) * 0.5 - reference.x) > 0.4:
		failures.append(context + ": distance moves the shared subtitle center")
	if absf(centers[0].y - centers[1].y) > 0.4:
		failures.append(context + ": unequal eye elevation")
	if centers[0].x <= reference.x or centers[1].x >= reference.x:
		failures.append(context + ": both eyes must converge toward the subtitle")
func _initialize(): call_deferred("_run")
func _run():
	var output := OS.get_environment("PROJECTED_SUBTITLE_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var head := Camera3D.new()
	viewport.add_child(head)
	head.position.y = 1.6
	var eye := Camera3D.new()
	eye.fov = 90
	viewport.add_child(eye)
	eye.position.y = 1.6
	eye.make_current()
	var video := Video.new()
	viewport.add_child(video)
	video.set_process(false)
	video.view_camera = head
	video.caption.visible = true
	video.caption.text = "I"
	var shader := Shader.new()
	var source: String = load("res://shaders/video_rvm_pair.gdshader").code
	shader.code = source.replace("void vertex() {", "uniform int probe_eye = 0;\nvoid vertex() {").replace("eye_index = int(VIEW_INDEX);", "eye_index = probe_eye;")
	video.material.shader = shader
	var colour := Image.create(2, 2, false, Image.FORMAT_RGB8); colour.fill(Color(0.1, 0.2, 0.35))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8); alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(colour))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(2, 2))
	video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("sharpness", 0)
	var samples: Array[Dictionary] = []
	var surface_samples: Array[Dictionary] = []
	var motion_samples: Array[Dictionary] = []
	var roll_samples: Array[Dictionary] = []
	for direction in [0, 1]:
		video.subtitle_direction = direction
		for geometry in [1, 2, 3]:
			video.geometry = geometry
			video._apply_geometry()
			video.panel.visible = true
			video._place_caption()
			eye.position.x = 0
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var reference := centroid(viewport.get_texture().get_image())
			var previous_disparity := INF
			for distance in [0.1, 0.5, 1.0, 5.0]:
				video.subtitle_distance = distance
				video._place_caption()
				video.material.set_shader_parameter("alpha_enabled", geometry == 2)
				var capture := output.path_join("direction%d_geometry%d_distance%.1f" % [direction,geometry,distance]) if distance in [0.1, 5.0] else ""
				var centers := await eye_centers(viewport, eye, video, capture)
				# One actual plane: physical camera projection provides all binocular disparity.
				var expected: float = 360.0 * 0.063 / distance
				var actual := centers[0].x - centers[1].x
				check_centered_pair(centers, reference, expected, "Video projection")
				if actual >= previous_disparity: failures.append("Greater distance must reduce both eyes' convergence")
				previous_disparity = actual
				samples.append({"direction":direction,"geometry":geometry,"distance_m":distance,"actual_pixels":actual,"expected_pixels":expected,"left_x":centers[0].x,"right_x":centers[1].x,"reference_x":reference.x,"center_shift_pixels":(centers[0].x + centers[1].x) * 0.5 - reference.x,"vertical_pixels":centers[0].y - centers[1].y})
				# Rotation uses the independent subtitle surface, also used over native video layers.
				video.set_screen_rotation(90)
				video._sync_subtitle_surface()
				var surface_centers := await eye_centers(viewport, eye, video)
				check_centered_pair(surface_centers, reference, expected, "Separate subtitle surface")
				for index in 2:
					if surface_centers[index].distance_to(centers[index]) > 0.4: failures.append("Separate surface changes eye placement")
				surface_samples.append({"direction":direction,"geometry":geometry,"distance_m":distance,"left_x":surface_centers[0].x,"right_x":surface_centers[1].x,"center_shift_pixels":(surface_centers[0].x + surface_centers[1].x) * 0.5 - reference.x})
				video.set_screen_rotation(0)
			# Keep a spectator eye fixed and vary the pose supplied to production caption placement.
			# Following the head would move actual glyph pixels against the stationary video here.
			video.material.set_shader_parameter("probe_eye", 0)
			eye.position.x = -0.0315
			head.transform = Transform3D(Basis(), Vector3(0, 1.6, 0))
			video._place_caption()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var baseline := centroid(viewport.get_texture().get_image())
			var plane: Transform3D = video.material.get_shader_parameter("subtitle_world_to_patch")
			for pose in [Vector3(0, 60, 0), Vector3(0, -60, 0), Vector3(35, 0, 0), Vector3(-35, 0, 0), Vector3(0, 0, 40), Vector3(20, -45, -30)]:
				head.rotation = pose * PI / 180.0
				head.position = Vector3(0, 1.6, 0)
				for frame in 12:
					video._place_caption()
					await process_frame
				await RenderingServer.frame_post_draw
				var shift := centroid(viewport.get_texture().get_image()).distance_to(baseline)
				var current: Transform3D = video.material.get_shader_parameter("subtitle_world_to_patch")
				if shift > 0.15 or not current.is_equal_approx(plane): failures.append("Head rotation moves caption relative to video")
				motion_samples.append({"direction":direction,"geometry":geometry,"head_rotation_degrees":[pose.x,pose.y,pose.z],"glyph_shift_pixels":shift})
			# A video adjustment must carry its captions with it; the local anchor stays unchanged.
			video.turn_view(0.1, 0.05)
			video.zoom_view(0.1)
			video._place_caption()
			var anchor: Basis = video.SubtitleDepth.anchor(video.subtitle_position, direction == 1)
			if not video.projected_subtitles.anchor_basis.is_equal_approx(anchor): failures.append("Video adjustment changes local caption anchor")
			video.reset_view()
			head.transform = Transform3D(Basis(), Vector3(0, 1.6, 0))
			video._center_on_view()
	# Both eyes must retain upright glyph bounds at every supported immersive projection.
	video.caption.text = "中文 ABC"
	video.subtitle_distance = 5.0
	video.subtitle_position = 0.0
	video.material.set_shader_parameter("alpha_enabled", true)
	for geometry in [1, 2, 3]:
		video.geometry = geometry
		video._apply_geometry()
		for direction in [0, 1]:
			video.subtitle_direction = direction
			for index in 2:
				eye.position.x = (index - 0.5) * 0.063
				video.material.set_shader_parameter("probe_eye", index)
				var baseline := Rect2i()
				for angle in [0, -90, 90]:
					video.set_screen_rotation(angle)
					video._place_caption()
					video._sync_subtitle_surface()
					await process_frame
					await RenderingServer.frame_post_draw
					await RenderingServer.frame_post_draw
					var bounds := glyph_bounds(viewport.get_texture().get_image())
					if angle == 0: baseline = bounds
					if bounds.size.x == 0 or bounds != baseline: failures.append("Roll rotates or moves VR glyphs")
					roll_samples.append({"geometry": geometry, "direction": direction, "eye": index, "roll": angle, "bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]})
		video.set_screen_rotation(0)
	video.projected_subtitles.clear(video.material)
	video.material.set_shader_parameter("alpha_enabled", true)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var dark := viewport.get_texture().get_image()
	var bright := 0
	for y in range(240,565):
		for x in range(150,1100):
			var c := dark.get_pixel(x,y)
			if minf(c.r,minf(c.g,c.b))>0.8: bright+=1
	if bright != 0: failures.append("CC Off leaves projected glyphs")
	var report := {"state":"passed" if failures.is_empty() else "failed","samples":samples,"surface_samples":surface_samples,"motion_samples":motion_samples,"roll_samples":roll_samples,"failures":failures,"scope":"Production video and separate subtitle shaders + actual glyph pixels, physical plane distance from 0.1m to 5m, two desktop eye cameras and head rotation changes; native XR acceptance remains separate"}
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify(report))
	viewport.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
