extends SceneTree
const Guide := preload("res://scripts/picture_center_guide.gd")
var checks := 0
var failures: Array[String] = []
var output := ""
var viewport: SubViewport

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func frame(name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(image.save_png(output.path_join(name + ".png")) == OK, "Save " + name)
	return image

func patch(image: Image, centre: Vector2i, size: int = 32) -> Image:
	return image.get_region(Rect2i(centre - Vector2i.ONE * size, Vector2i.ONE * size * 2))

func difference(a: Image, b: Image) -> Dictionary:
	var changed := 0; var peak := 0.0; var sum := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y); var q := b.get_pixel(x, y)
			var d := maxf(absf(p.r-q.r), maxf(absf(p.g-q.g), absf(p.b-q.b)))
			if d > 0.025: changed += 1
			peak = maxf(peak, d); sum += d
	return {"changed": changed, "peak": peak, "sum": sum}

func alpha_sum(image: Image) -> float:
	var sum := 0.0
	for y in image.get_height():
		for x in image.get_width(): sum += image.get_pixel(x, y).a
	return sum

func alpha_difference(a: Image, b: Image) -> float:
	var peak := 0.0
	for y in a.get_height():
		for x in a.get_width(): peak = maxf(peak, absf(a.get_pixel(x, y).a - b.get_pixel(x, y).a))
	return peak

func projected_direction(camera: Camera3D, head: Vector3, point: Vector3) -> Vector2:
	var direction: Vector3 = camera.global_basis.inverse() * (point - head)
	var clip: Vector4 = camera.get_camera_projection() * Vector4(direction.x, direction.y, direction.z, 0.0)
	return Vector2((clip.x / clip.w + 1) * viewport.size.x * 0.5, (1 - clip.y / clip.w) * viewport.size.y * 0.5)

func ink_centre(image: Image, expected: Vector2) -> Vector2:
	var total := 0.0; var weighted := Vector2.ZERO
	var centre := Vector2i(expected)
	for y in range(centre.y - 28, centre.y + 29):
		for x in range(centre.x - 28, centre.x + 29):
			var alpha := image.get_pixel(x, y).a
			total += alpha; weighted += Vector2(x + 0.5, y + 0.5) * alpha
	return weighted / total if total > 0.01 else Vector2(-1000, -1000)

func _run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/picture-center-guide/render")
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1440, 900)
	viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; viewport.add_child(camera)
	var screen := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(8, 5); screen.mesh = quad
	screen.position.z = -2.02; viewport.add_child(screen)
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.render_priority = -10; screen.material_override = material
	var hole := MeshInstance3D.new(); hole.mesh = quad; hole.position.z = -2.01; viewport.add_child(hole)
	var hole_material := ShaderMaterial.new(); hole_material.shader = preload("res://shaders/video_layer_hole.gdshader")
	hole_material.render_priority = -9; hole.material_override = hole_material; hole.visible = false
	var guide := Guide.new(); viewport.add_child(guide); guide.set_process(false)
	var sample := {"identity": "render", "head": Transform3D.IDENTITY, "centre": Vector3(0.25, -0.12, -2), "held": true, "hand": "right_hand"}
	var eye_centre := Vector2i(viewport.size / 2)
	for bright in [false, true]:
		material.albedo_color = Color.WHITE if bright else Color(0.025, 0.035, 0.03)
		guide.clear()
		var baseline := await frame("bright-base" if bright else "dark-base")
		guide.sync(sample, 1000)
		var image := await frame("bright-split" if bright else "dark-split")
		for point in [guide.ring.global_position, guide.cross.global_position]:
			var centre := Vector2i(camera.unproject_position(point))
			var delta := difference(patch(image, centre), patch(baseline, centre))
			check(delta.changed >= 50 and delta.changed < 700, "Recognizable mark over bright/dark picture: " + str(delta))
			check(delta.peak >= 0.15 and delta.peak < 0.98, "Core or outline keeps useful contrast over bright/dark content")
		var detail := patch(image, Vector2i(camera.unproject_position(guide.cross.global_position)), 24)
		detail.resize(240, 240, Image.INTERPOLATE_NEAREST)
		check(detail.save_png(output.path_join("bright-detail.png" if bright else "dark-detail.png")) == OK, "Save pixel detail")
	hole.visible = true; guide.clear()
	var clear_image := await frame("hole-base")
	check(alpha_sum(patch(clear_image, eye_centre)) < 0.1, "Production underlay shader actually clears eye-buffer alpha")
	sample.centre = Vector3(0, 0, -2)
	guide.sync(sample, 2000); guide.sync(sample, 2160)
	var aligned := await frame("hole-joined")
	var coverage := alpha_sum(patch(aligned, eye_centre))
	check(coverage > 70.0 and coverage < 400.0, "Larger translucent references restore useful coverage above the video hole")
	check(aligned.get_pixelv(eye_centre).a < 0.02, "Joined centre remains hollow for precise alignment")
	guide.sync(sample, 2300)
	var contracted := await frame("hole-contracted")
	check(difference(patch(aligned, eye_centre), patch(contracted, eye_centre)).changed > 4, "The one-shot contraction changes actual pixels")
	var eye_images: Array[Image] = []
	for side in [-1, 1]:
		camera.position.x = side * 0.032
		eye_images.append(await frame("left-eye" if side < 0 else "right-eye"))
	check(alpha_difference(patch(eye_images[0], eye_centre), patch(eye_images[1], eye_centre)) < 0.005, "Translated eyes render the same zero-disparity marks, not merely mutually aligned finite-depth marks")
	camera.position.x = 0
	guide.sync(sample, 2500)
	var settled := await frame("hole-settled")
	guide.release("right_hand", 2600); sample.held = false; sample.hand = ""
	guide.sync(sample, 2690)
	var faded := await frame("half-fade")
	check(alpha_sum(patch(faded, eye_centre)) < alpha_sum(patch(settled, eye_centre)) * 0.65, "Release lowers real pixel coverage")
	guide.sync(sample, 2780)
	var gone := await frame("released")
	check(alpha_sum(patch(gone, eye_centre)) < 0.1, "Release leaves no stale mark over the video underlay")
	# Test actual shader pixels with eye translation in VIEW_MATRIX, then with
	# asymmetric/canted optics. Do not force identical pixels across different FOVs.
	screen.hide(); hole.hide()
	var reference: Image
	sample.held = true; sample.hand = "right_hand"
	for distance in [0.6, 2.0, 24.0, 80.0]:
		sample.centre = Vector3(0.22, -0.12, -1).normalized() * distance
		guide.sync(sample, 4000)
		var image := await frame("depth-" + str(distance))
		if reference:
			for point in [guide.ring.global_position, guide.cross.global_position]:
				var region := Vector2i(projected_direction(camera, Vector3.ZERO, point))
				check(alpha_difference(patch(image, region), patch(reference, region)) < 0.02, "Content distance cannot change mark size, position or depth disparity")
		else: reference = image
	var head := Transform3D(Basis.from_euler(Vector3(0.12, 0.23, -0.08)), Vector3(2, 1.7, -3))
	sample.head = head; sample.centre = head * (Vector3(0.22, -0.12, -1).normalized() * 2.0)
	guide.sync(sample, 4100)
	for side in [-1, 1]:
		camera.global_transform = head * Transform3D(Basis(Vector3.UP, side * deg_to_rad(5.0)), Vector3(side * 0.032, 0, 0))
		camera.set_frustum(0.075, Vector2(side * 0.008, 0.003), 0.05, 100)
		var optical_image := await frame("canted-left" if side < 0 else "canted-right")
		for point in [guide.ring.global_position, guide.cross.global_position]:
			var expected := projected_direction(camera, head.origin, point)
			check(ink_centre(optical_image, expected).distance_to(expected) < 1.0, "Canted/asymmetric eye preserves the same optical direction within one pixel")
	guide.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Picture centre render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
