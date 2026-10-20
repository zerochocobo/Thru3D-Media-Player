extends SceneTree
## The compositor-layer backdrop must draw the same scenery as Godot's own sky, including the
## user's background yaw; otherwise the panorama flips whenever a video or menu layer appears.
const Display := preload("res://scripts/xr_display.gd")
const Background := preload("res://scripts/app_background.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/background-seam")
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func color_error(a: Color, b: Color) -> float:
	return maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b)))
func frames() -> void:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw

func render(sky_mode: bool, yaw: float, panorama: Texture2D, look: Vector3, menu_layer := false, energy := 1.0) -> Image:
	var viewport := SubViewport.new(); viewport.size = Vector2i(320, 240)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 90; viewport.add_child(camera)
	camera.rotation = look
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var sky := Sky.new(); var material := PanoramaSkyMaterial.new(); material.panorama = panorama; sky.sky_material = material
	material.energy_multiplier = energy
	var display := Display.new()
	display.attach_backdrop(camera)
	display.configure(viewport, world.environment, null, true)
	display.preview = false
	display.set_scenery(sky, yaw)
	display.set_video_layer(not sky_mode and not menu_layer)
	display.set_menu_layers(not sky_mode and menu_layer)
	await frames()
	var image := viewport.get_texture().get_image()
	viewport.queue_free(); await process_frame
	return image

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
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
	await check_seam()
	await check_live_brightness()
	print("Layer backdrop: %d checks, %d failures, worst %.4f" % [checks, failures.size(), worst])
	for failure in failures: push_error(failure)
	quit(1 if not failures.is_empty() else 0)

func check_seam() -> void:
	# Both image edges are identical. Only the distant centre is bright: a line at the
	# join can therefore only come from sampling unrelated longitudes via a coarse mip.
	var source := Image.create(1024, 512, false, Image.FORMAT_RGB8)
	source.fill(Color(0.08, 0.10, 0.14))
	source.fill_rect(Rect2i(256, 64, 512, 384), Color(1.0, 0.95, 0.85))
	source.generate_mipmaps()
	var panorama := ImageTexture.create_from_image(source)
	var worst := 0.0
	for yaw in [0.0, 37.0]:
		for pitch in [0.0, -0.65, -1.3, -PI/2, PI/2]:
			# Moving the join across neighbouring pixel pairs exercises derivative quads
			# that straddle it; an exactly centred seam can miss the bug entirely.
			for offset in [-0.009, 0.0, 0.009]:
				var look := Vector3(pitch, PI + deg_to_rad(yaw) + offset, 0)
				var expected: Image = await render(true, yaw, panorama, look)
				var actual: Image = await render(false, yaw, panorama, look)
				var excess := 0.0
				for y in range(40, 200):
					for x in range(148, 172):
						var a := actual.get_pixel(x, y); var b := expected.get_pixel(x, y)
						excess = maxf(excess, maxf(a.r - b.r, maxf(a.g - b.g, a.b - b.b)))
				worst = maxf(worst, excess)
				check(excess < 0.05, "Mipmapped seam has no bright line at yaw %s pitch %s offset %s: excess %.3f" % [yaw, pitch, offset, excess])
				if yaw == 0.0 and pitch == -0.65 and offset == 0.009:
					expected.save_png(output.path_join("fixture-sky.png"))
					actual.save_png(output.path_join("fixture-backdrop.png"))
	var builtin := load("res://backgrounds/belfast_sunset_puresky.jpg") as Texture2D
	for pitch in [0.0, -0.65, -1.3, -PI/2, PI/2]:
		var look := Vector3(pitch, PI + 0.009, 0)
		var expected: Image = await render(true, 0.0, builtin, look)
		var actual: Image = await render(false, 0.0, builtin, look)
		var menu: Image = await render(false, 0.0, builtin, look, true)
		expected.save_png(output.path_join("belfast-sky-%s.png" % pitch))
		actual.save_png(output.path_join("belfast-backdrop-%s.png" % pitch))
		var excess := 0.0
		var menu_difference := 0.0
		for y in range(40, 200):
			for x in range(148, 172):
				var a := actual.get_pixel(x, y); var b := expected.get_pixel(x, y)
				# The tessellated sphere can shift isolated source speckles by one
				# pixel relative to the analytic sky. Compare a local upper envelope
				# so those speckles cannot masquerade as a new bright seam.
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						var neighbor := expected.get_pixel(x + ox, y + oy)
						b = Color(maxf(b.r, neighbor.r), maxf(b.g, neighbor.g), maxf(b.b, neighbor.b))
				excess = maxf(excess, maxf(a.r - b.r, maxf(a.g - b.g, a.b - b.b)))
				var c := menu.get_pixel(x, y)
				menu_difference = maxf(menu_difference, maxf(absf(c.r - a.r), maxf(absf(c.g - a.g), absf(c.b - a.b))))
		worst = maxf(worst, excess)
		check(excess < 0.05, "Packaged 8K Belfast seam has no bright line at pitch %s: excess %.3f" % [pitch, excess])
		check(menu_difference < 0.01, "Menu and video layer backdrops agree at pitch %s: difference %.3f" % [pitch, menu_difference])
	print("Background seam: worst positive channel excess %.4f" % worst)

func check_live_brightness() -> void:
	var viewport := SubViewport.new(); viewport.size=Vector2i(320,240)
	viewport.own_world_3d=true; viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov=90; viewport.add_child(camera)
	var world := WorldEnvironment.new(); world.environment=Environment.new(); viewport.add_child(world)
	var pixels := Image.create(512,256,false,Image.FORMAT_RGB8); pixels.fill(Color(.4,.5,.6))
	var background := Background.new(); background.choice="custom"; background._custom=ImageTexture.create_from_image(pixels); viewport.add_child(background)
	var display := Display.new(); display.attach_backdrop(camera)
	display.configure(viewport,world.environment,null,true); display.preview=false
	# Main forwards AppBackground.changed through this same production display call.
	background.changed.connect(func(): display.set_scenery(background.ready_sky(),background.yaw))
	display.set_scenery(background.ready_sky()); display.set_menu_layers(true)
	var previous := Color.BLACK
	for value in [0.5,1.25,0.75,1.0]:
		background.set_brightness(value); await frames()
		check(display.menu_layers and display.backdrop.visible,"Brightness updates with menu composition continuously enabled")
		var actual := viewport.get_texture().get_image().get_pixel(160,120)
		var expected: Image=await render(true,0,background._custom,Vector3.ZERO,false,value)
		var error := color_error(actual,expected.get_pixel(160,120))
		check(error<.015,"Open-menu brightness %s matches ordinary sky: error %.4f"%[value,error])
		if value==1.25: check(actual.get_luminance()>previous.get_luminance()+.1,"Adjusting brighter is visible before closing the menu")
		if value==0.75: check(actual.get_luminance()<previous.get_luminance()-.05,"Adjusting darker is visible before closing the menu")
		previous=actual
	# Menu/video composition shares the backdrop and must not restore stale energy.
	display.set_video_layer(true); background.set_brightness(.5); display.set_menu_layers(false); await frames()
	var expected: Image=await render(true,0,background._custom,Vector3.ZERO,false,.5)
	check(color_error(viewport.get_texture().get_image().get_pixel(160,120),expected.get_pixel(160,120))<.015,"Closing menu over a video keeps the chosen brightness")
	display.set_menu_layers(true); display._on_session_event("session_begun"); await frames()
	check(color_error(viewport.get_texture().get_image().get_pixel(160,120),expected.get_pixel(160,120))<.015,"Session resume preserves backdrop brightness")
	display.set_menu_layers(false); display.set_video_layer(false); await frames()
	check(color_error(viewport.get_texture().get_image().get_pixel(160,120),expected.get_pixel(160,120))<.015,"Closing all composition layers keeps the same sky brightness")
	viewport.queue_free(); await process_frame
