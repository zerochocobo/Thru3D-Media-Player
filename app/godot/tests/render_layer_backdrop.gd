extends SceneTree
## The compositor-layer backdrop must draw the same scenery as Godot's own sky, including the
## user's background yaw; otherwise the panorama flips whenever a video or menu layer appears.
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw

func render(sky_mode: bool, yaw: float, panorama: Texture2D, look: Vector3) -> Image:
	var viewport := SubViewport.new(); viewport.size = Vector2i(320, 240)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 90; viewport.add_child(camera)
	camera.rotation = look
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var sky := Sky.new(); var material := PanoramaSkyMaterial.new(); material.panorama = panorama; sky.sky_material = material
	var display := Display.new()
	display.attach_backdrop(camera)
	display.configure(viewport, world.environment, null, false)
	display.preview = false
	display.set_scenery(sky, yaw)
	display.set_video_layer(not sky_mode)
	await frames()
	var image := viewport.get_texture().get_image()
	viewport.queue_free(); await process_frame
	return image

func run() -> void:
	# Asymmetric test panorama: red grows with u, green with v, a blue band near u = 0.2.
	var source := Image.create(512, 256, false, Image.FORMAT_RGB8)
	for y in 256:
		for x in 512:
			var u := x / 511.0
			source.set_pixel(x, y, Color(u, y / 255.0, 1.0 if absf(u - 0.2) < 0.03 else 0.2))
	var panorama := ImageTexture.create_from_image(source)
	var worst := 0.0
	for yaw in [0.0, 37.0, -110.0]:
		for look in [Vector3.ZERO, Vector3(0.3, 1.2, 0), Vector3(-0.4, -2.3, 0)]:
			var expected: Image = await render(true, yaw, panorama, look)
			var actual: Image = await render(false, yaw, panorama, look)
			var total := 0.0; var samples := 0
			for y in range(8, 232, 16):
				for x in range(8, 312, 16):
					var a := expected.get_pixel(x, y); var b := actual.get_pixel(x, y)
					total += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b); samples += 1
			var mean := total / samples
			worst = maxf(worst, mean)
			check(mean < 0.05, "Backdrop matches sky at yaw %s look %s: mean error %.3f" % [yaw, look, mean])
	print("Layer backdrop: %d checks, %d failures, worst %.4f" % [checks, failures.size(), worst])
	for failure in failures: push_error(failure)
	quit(1 if not failures.is_empty() else 0)
