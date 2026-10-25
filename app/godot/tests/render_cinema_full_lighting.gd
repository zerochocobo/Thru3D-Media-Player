extends "res://tests/render_cinema_player.gd"
## Production host, full imported room and menu lighting actions; no XR claims.
var performance_views: Array[Dictionary] = []

func _run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/cinema-full-lighting")
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() == "headless": quit(2); return
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark"); config.set_value("ui", "language", "zh")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new(); viewport.size = Vector2i(1440, 960)
	viewport.own_world_3d = true; viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	main = RenderMain.new(); main.settings_path = output.path_join("settings.cfg")
	main.display = Logic.SupportedDisplay.new(); viewport.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false)
	main._head_placed = true; main.report_timer.stop()
	main.video.history_enabled = false; main.photo.history_enabled = false
	main.video.platform = HostTest.Host.new()
	main.video.local_uri = "file:///original-cinema-lighting-test.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"; main.video.requested_play = true
	main.video._waiting_first = false; main.video.control.duration_ms = 600000
	_set_video_source(Vector2i(640, 360)); main.video.panel.visible = true
	main._on_setting_changed("background", "cinema")
	var deadline := Time.get_ticks_msec() + 60000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await process_frame
	main._update_background(); main._sync_cinema_screen(); _close_menus()
	check(main._cinema_scene_active(), "Full dual-baked production room loads", main.cinema_environment.error)
	if not main._cinema_scene_active(): await _finish(); return
	var environment: Node3D = main.cinema_environment
	var model: Node3D = environment._model
	check(model.find_children("*", "Light3D", true, false).is_empty(), "No dynamic room lights or shadow maps")
	var ids: Array = environment._light_materials.map(func(entry): return entry.material.get_instance_id())
	check(ids.size() <= 20, "Lighting shares materials across all 336 chairs", ids.size())
	var seats := 0
	for node in model.find_children("Seats_*", "MeshInstance3D", true, false):
		var material := node.get_active_material(0) as ShaderMaterial
		check(material != null and material.shader == environment.Description.SEAT_SHADER, "Chair chunk uses dual vertex lighting: " + node.name)
		var arrays: Array = node.mesh.surface_get_arrays(0)
		check(arrays[Mesh.ARRAY_TEX_UV2] != null and arrays[Mesh.ARRAY_TEX_UV2].size() == arrays[Mesh.ARRAY_VERTEX].size(), "Off-state channels survive GLB import: " + node.name)
		var has_off_blue := false
		for color: Color in arrays[Mesh.ARRAY_COLOR]:
			if color.a < .99: has_off_blue = true; break
		check(has_off_blue, "Off-state blue is baked data, not default alpha: " + node.name)
		seats += 1
	check(seats == 168, "Original 84 near/far chunk pairs retained")
	await _viewing_level_renders(environment)
	var views := [
		["01-overview", Vector3(13, 10, 28), Vector3(0, 4, 15), 75.0],
		["02-aisle", Vector3(12.4, 5.25, 16.9), Vector3(9.3, 3.85, 17.6), 62.0],
		["03-wall", Vector3(13.1, 5.25, 17.4), Vector3(16.7, 4.8, 18.3), 60.0],
		["04-front", Vector3(0, 2.1, 3.5), Vector3(0, 5, 25), 75.0],
		["05-rear", Vector3(0, 7.95, 31), Vector3(0, 10, -4), 75.0],
		["06-centre", Vector3(-.45, 5.25, 19.9), Vector3(0, 10, -4), 75.0],
		["09-footwell", Vector3(-.45, 5.25, 19.9), Vector3(-.45, 4.05, 19.0), 75.0],
		# The back of the chair ahead is what a seated viewer studies most closely.
		["10-seatback", Vector3(-.45, 5.25, 19.9), Vector3(-.45, 4.35, 18.4), 40.0],
		# Close details: the exit beside the screen, the projection booth, the armrest.
		["13-door", Vector3(13.0, 1.65, 4.2), Vector3(16.7, 1.2, 1.4), 60.0],
		["13-booth", Vector3(0, 7.95, 28.0), Vector3(0, 10.3, 32.4), 50.0],
		["13-armrest", Vector3(-.45, 5.25, 19.9), Vector3(-.9, 4.71, 19.75), 45.0],
	]
	for view in views:
		main.xr_camera.global_position = view[1]; main.xr_camera.look_at(view[2], Vector3.UP); main.xr_camera.fov = view[3]
		for mode in ["on", "off"]:
			# The off bake is the playing state; off with no film keeps a little house light.
			if mode == "off":
				main.video.requested_play = true; main._cinema_lights_idle_since = -1
			main._on_setting_changed("cinema_lights", mode)
			environment._process(1.0)
			var frame := await _shot(view[0] + "-" + mode)
			check(environment._light_mix == (1.0 if mode == "on" else 0.0), "Manual " + mode + " reaches independent bake")
			performance_views.append({"view": view[0], "mode": mode,
				"draw_calls": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
				"primitives": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
				"objects": viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)})
			if view[0] == "06-centre":
				main.video.requested_play = mode == "off"
				# Auto raises the lights only after playback has stopped for a moment.
				main._cinema_lights_idle_since = -1 if mode == "off" else Time.get_ticks_msec() - main.CINEMA_LIGHTS_UP_DELAY_MS - 1
				main._on_setting_changed("cinema_lights", "auto"); environment._process(1.0)
				var automatic := await _shot("07-auto-" + ("playing" if mode == "off" else "paused"))
				check(frame.get_data() == automatic.get_data(), "Auto " + mode + " renders identically to manual bake")
	main._on_setting_changed("cinema_lights", "off"); environment._process(1.0)
	main.video.requested_play = false; main._sync_cinema_lights(); environment._process(1.0)
	check(environment._light_mix == 0, "Manual off survives pause")
	main._on_setting_changed("cinema_lights", "on"); main.video.requested_play = true; main._sync_cinema_lights(); environment._process(1.0)
	check(environment._light_mix == 1, "Manual on survives playback")
	main._on_setting_changed("cinema_lights", "auto")
	main.video.media.state = "paused"; main._sync_cinema_lights()
	check(not environment.lights_on, "A pause does not flash the house lights at once")
	main._cinema_lights_idle_since = Time.get_ticks_msec() - main.CINEMA_LIGHTS_UP_DELAY_MS - 1
	main._sync_cinema_lights(); environment._process(1.0)
	check(environment._light_mix == 1, "A sustained pause opens house lights even before play intent updates")
	main.video.media.state = "playing"
	# Move the actual camera across the old coplanar fixtures. Both bakes must
	# retain their safety diffusers instead of alternating with the dark backing.
	for fixture in [
		["exit-left", Vector3(-16.73, 2.88, 1.4)],
		["exit-right", Vector3(16.73, 2.88, 1.4)],
		["stage", Vector3(0, .14, -3.92)],
	]:
		for mode in ["on", "off"]:
			main._on_setting_changed("cinema_lights", mode); environment._process(1.0)
			for shift in [-.08, 0.0, .08]:
				main.xr_camera.global_position = Vector3(shift, 5.25 + shift * .3, 19.9)
				main.xr_camera.look_at(fixture[1], Vector3.UP)
				await process_frame; await process_frame
				var frame := viewport.get_texture().get_image()
				var pixel := frame.get_pixel(720, 480)
				# glTF unlit factors are linear; Compatibility presents sRGB pixels.
				var expected := (Color(.85, .50, .26) if fixture[0] == "stage" else Color(.20, .95, .50)).linear_to_srgb()
				var visible_light := absf(pixel.r - expected.r) < .04 and absf(pixel.g - expected.g) < .04 and absf(pixel.b - expected.b) < .04
				if fixture[0] == "stage" and mode == "off":
					# The stage strip is house lighting: dark while the house is dark, so it
					# cannot shimmer under the picture during playback. Exits stay lit.
					check(pixel.get_luminance() < .02, "Stage strip goes dark with the house lights: %s" % shift, pixel)
				else:
					check(visible_light, "Fixture remains visible during head shift: %s %s %s" % [fixture[0], mode, shift], pixel)
				if shift == 0.0: frame.save_png(output.path_join("10-%s-%s.png" % [fixture[0], mode]))
	for i in 40:
		environment.set_lighting("on" if i % 2 else "off", true); environment._process(.05)
	check(ids == environment._light_materials.map(func(entry): return entry.material.get_instance_id()), "Repeated fades allocate no new material or geometry")
	main._on_setting_changed("cinema_lights", "auto"); environment._process(1.0)
	main._show_player_menu(); main._place_menu(main.player_menu, true)
	await _shot("08-production-controls")
	var textures := {}
	for node in model.find_children("*", "MeshInstance3D", true, false):
		for index in node.mesh.get_surface_count():
			var material: Material = node.get_active_material(index)
			if material is ShaderMaterial:
				for key in ["surface_texture", "light_texture", "light_off_texture"]:
					var texture: Variant = material.get_shader_parameter(key)
					if texture is Texture2D: textures[texture.get_instance_id()] = texture
	# Film light: a red left strip reddens the left wall, a blue right strip the
	# right wall, with the house dark. Baked screen zones scaled by film colour.
	main._on_setting_changed("cinema_lights", "off"); environment._process(1.0)
	main.xr_camera.global_position = Vector3(0, 6.5, 22); main.xr_camera.look_at(Vector3(0, 6, -4), Vector3.UP); main.xr_camera.fov = 95.0
	var dark := Color.BLACK
	environment.set_film_light([dark, dark, dark])
	# Let newly imported material pipelines finish before comparing screenshots.
	for frame in 20:
		await process_frame; await RenderingServer.frame_post_draw
	var unlit := await _shot("11-film-none")
	environment.set_film_light([Color(4, 0, 0), dark, Color(0, 0, 4)])
	var film := await _shot("11-film-red-left-blue-right")
	var left_before := unlit.get_pixel(60, 480); var left_after := film.get_pixel(60, 480)
	var right_before := unlit.get_pixel(1380, 480); var right_after := film.get_pixel(1380, 480)
	check(left_after.r > left_before.r + .05 and left_after.r > left_after.b, "Red left strip reddens the left wall", [left_before, left_after])
	check(right_after.b > right_before.b + .05 and right_after.b > right_after.r, "Blue right strip blues the right wall", [right_before, right_after])
	environment.set_film_light([Color(1, 1, 1), Color(1, 1, 1), Color(1, 1, 1)])
	var grey := await _shot("11-film-reference-grey")
	environment.set_film_light([dark, dark, dark])
	main._on_setting_changed("cinema_lights", "auto")
	check(grey.get_pixel(60, 480).get_luminance() > unlit.get_pixel(60, 480).get_luminance() + .02, "A reference-grey film lights the hall")
	var texture_report: Array = []
	var texture_bytes := 0
	for texture: Texture2D in textures.values():
		var image: Image = texture.get_image()
		texture_bytes += image.get_data_size()
		texture_report.append({"path": texture.resource_path, "width": image.get_width(), "height": image.get_height(),
			"compressed": image.is_compressed(), "mipmaps": image.has_mipmaps(), "bytes": image.get_data_size(), "format": image.get_format()})
	check(texture_bytes <= 48 * 1024 * 1024, "Resident room texture payload stays within 48 MiB desktop compressed budget", texture_bytes)
	check(texture_report.all(func(item): return item.compressed and item.mipmaps), "Every room texture is GPU-compressed and mipmapped")
	check(performance_views.all(func(item): return item.draw_calls <= 140 and item.primitives <= 250000), "All desktop views fit scene draw/triangle budgets", performance_views)
	var file := FileAccess.open(output.path_join("performance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"views": performance_views, "room_textures": texture_report, "room_texture_bytes": texture_bytes,
		"lighting_materials": ids.size(), "hardware_scope": "Desktop GL only. Geometry and memory budgets are not Quest 2/PICO Neo3 frame-time measurements."}, "\t")); file.close()
	await _finish()

func _viewing_level_renders(environment: Node3D) -> void:
	var samples: Array = []
	var dark := Color.BLACK
	environment.set_film_light([dark, dark, dark])
	for view in [
		["overview", Vector3(13, 10, 28), Vector3(0, 4, 15), 75.0],
		["seatback", Vector3(-.45, 5.25, 19.9), Vector3(-.45, 4.35, 18.4), 40.0]]:
		main.xr_camera.global_position = view[1]
		main.xr_camera.look_at(view[2], Vector3.UP); main.xr_camera.fov = view[3]
		var previous := -1.0
		for level in ["low", "dim", "soft"]:
			environment.set_viewing_brightness(level, true)
			var frame := await _shot("12-viewing-" + view[0] + "-" + level)
			var luminance := 0.0
			var count := 0
			for y in range(0, frame.get_height(), 8):
				# The overview's screen is on the right; measure room lighting only.
				for x in range(0, frame.get_width() / 2, 8):
					luminance += frame.get_pixel(x, y).get_luminance(); count += 1
			luminance /= count
			check(previous < 0 or luminance > previous + .002, "Viewing tiers visibly brighten real room pixels: " + view[0] + " " + level, luminance)
			previous = luminance
			samples.append({"view": view[0], "level": level, "mix": environment._light_mix, "mean_luminance": luminance})
	environment.set_viewing_brightness("low", false)
	var file := FileAccess.open(output.path_join("viewing-levels.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(samples, "\t")); file.close()
