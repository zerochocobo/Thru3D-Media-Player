extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var quad: MeshInstance3D
var output := ProjectSettings.globalize_path("res://../../build/output/photo-feather-20261104")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func pixel(image: Image, uv: Vector2) -> Color:
	var point := camera.unproject_position(Vector3((uv.x - 0.5) * 2, (0.5 - uv.y) * 2, 0))
	return image.get_pixel(roundi(point.x), roundi(point.y))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.screen_curve = 0
	var source := Image.create(32, 32, false, Image.FORMAT_RGBA8); source.fill(Color.RED)
	photo._texture = ImageTexture.create_from_image(source)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo.queue.assign([{"uri":"file:///feather.png", "title":"feather.png"}]); photo.index = 0
	if DisplayServer.get_name() != "headless":
		viewport = SubViewport.new(); viewport.size = Vector2i(512, 512); viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
		var world := WorldEnvironment.new(); world.environment = Environment.new()
		world.environment.background_mode = Environment.BG_COLOR; world.environment.background_color = Color.BLUE; viewport.add_child(world)
		camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 2.2; camera.position.z = 3; viewport.add_child(camera)
		# Normalize screen coverage to inspect the production shader's opacity at
		# fixed UV coordinates, even when the physical photo is tiny or very narrow.
		quad = MeshInstance3D.new(); quad.mesh = QuadMesh.new(); quad.mesh.size = Vector2(2, 2); viewport.add_child(quad)
	for dimensions in [Vector2(1920,1080), Vector2(32000,1000), Vector2(1000,32000)]:
		photo._size = dimensions; photo._apply_geometry()
		for size in [0.05, 0.4, 1.0, 30.0]:
			photo.set_screen_scale(size)
			var feather: Vector2 = photo.material.get_shader_parameter("edge_feather")
			var metres: Vector2 = feather * photo._flat.size
			var tag := "%dx%d-%s" % [dimensions.x, dimensions.y, size]
			check(feather.x > 0 and feather.y > 0 and maxf(feather.x, feather.y) <= 0.030001, "Each edge occupies at most 3 percent: " + tag)
			check(is_equal_approx(metres.x, metres.y) and metres.x <= 0.070001, "All edges have equal physical width, capped at 7 cm")
			var keep: Vector2 = photo._layer_keep()
			check(keep.x > feather.x and keep.y > feather.y and maxf(keep.x, keep.y) < 0.035, "Compositor overlap stays opaque and retains over 93 percent of each dimension")
			photo._size_placeholder(0, {"width": dimensions.x, "height": dimensions.y})
			var placeholder: float = photo._placeholder_material.get_shader_parameter("feather_metres")
			check(is_equal_approx(placeholder, metres.x), "Loading placeholder matches final photo edge")
			photo.gallery.mode = photo.Gallery.Layout.WALL
			check(photo.gallery._card_feather(photo._flat.size).is_equal_approx(feather), "Photo wall shares the same bounded edge")
			photo.gallery.mode = photo.Gallery.Layout.SINGLE
			if viewport:
				quad.material_override = photo.material.duplicate()
				var image := await frame()
				for uv in [Vector2(.5,.5), Vector2(.04,.5), Vector2(.96,.5), Vector2(.5,.04), Vector2(.5,.96)]:
					var color := pixel(image, uv)
					check(color.r > .98 and color.b < .02, "Rendered interior stays opaque: " + tag + "/" + str(uv))
				if size == 0.05:
					image.save_png(output.path_join(tag + "-fixed.png"))
					quad.material_override.set_shader_parameter("edge_feather", Vector2.ONE * 0.07 / photo._flat.size)
					var old := await frame(); old.save_png(output.path_join(tag + "-old.png"))
					if dimensions.x == 32000: check(pixel(old, Vector2(.5,.5)).r < .15, "Old fixed-width shader reproduces the disappearing narrow photo")
	# Focus animation interpolates between card and full-photo dimensions; keep
	# the feather bounded at every intermediate size, including fragment fades.
	photo._size = Vector2(32000,1000); photo._apply_geometry(); photo.set_screen_scale(0.05)
	photo.gallery._add(0, Transform3D.IDENTITY, Vector2(.4,.2), photo.Gallery.RECT)
	photo.gallery.focus = 0; photo.gallery.returning = true
	for layout in [photo.Gallery.Layout.WALL, photo.Gallery.Layout.FRAGMENTS]:
		photo.gallery.mode = layout
		for progress in [0.0, 0.25, 0.5, 0.75, 1.0]:
			photo.gallery.progress = progress; photo.gallery._animate_focus()
			var feather: Vector2 = photo.gallery.cards[0].node.material_override.get_shader_parameter("edge_feather")
			check(maxf(feather.x, feather.y) <= .030001, "Focus animation keeps feather within the current short side")
			if progress == 1.0: check(feather.is_equal_approx(photo._edge_feather()), "Expanded preview ends with the same feather as the photo")
	photo.gallery.mode = photo.Gallery.Layout.MAGAZINE
	check(photo._edge_feather() == Vector2.ZERO, "Magazine pages still have no feather")
	await strength_checks(photo)
	photo.free()
	if viewport: viewport.free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Photo feather: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func strength_checks(photo: Node3D) -> void:
	photo.gallery.focus = -1; photo.gallery.mode = photo.Gallery.Layout.WALL
	for strength in [0.0, 0.5, 1.0, 2.0, 3.0]:
		photo.set_edge_feather_strength(strength)
		var feather: Vector2 = photo.material.get_shader_parameter("edge_feather")
		check(is_equal_approx(maxf(feather.x, feather.y), .03 * strength), "Strength scales the bounded default; zero means hard edges")
		var keep: Vector2 = photo._layer_keep()
		check(keep.x > feather.x and keep.y > feather.y and maxf(keep.x, keep.y) < .1, "Hard and strongest edges retain a valid opaque compositor overlap")
		var card: Dictionary = photo.gallery.cards[0]
		check(card.node.material_override.get_shader_parameter("edge_feather").is_equal_approx(photo.gallery._card_feather(card.size)), "Changing strength immediately updates existing wall cards")
		photo._size_placeholder(0, {"width":32000,"height":1000})
		check(is_equal_approx(photo._placeholder_material.get_shader_parameter("feather_metres"), feather.y * photo._flat.size.y), "Loading uses the selected strength, including zero")
		if viewport:
			quad.material_override = photo.material.duplicate()
			var image := await frame()
			check(pixel(image, Vector2(.5,.5)).r > .98, "Even maximum feather preserves the image centre")
			if strength == 0:
				check(pixel(image, Vector2(.5,.005)).r > .98, "Hard-edge image stays opaque right up to the boundary")
				quad.material_override.set_shader_parameter("crop_center", Vector2(2,.5))
				var outside := await frame()
				check(pixel(outside, Vector2(.5,.5)).b > .98, "Hard edges do not create black pixels outside valid flat source UV")
			elif strength == 3:
				check(pixel(image, Vector2(.5,.04)).b > .2, "Stronger feather produces a wider visible fade")
			image.save_png(output.path_join("strength-%s.png" % strength))
		photo.gallery.mode = photo.Gallery.Layout.MAGAZINE; photo._shape_screen()
		check(photo.material.get_shader_parameter("edge_feather") == Vector2.ZERO and photo.edge_feather_strength == strength, "Magazine forces hard edges without overwriting the global preference")
		photo._size_placeholder(0, {"width":32000,"height":1000})
		check(photo._placeholder_material.get_shader_parameter("feather_metres") == 0.0, "Magazine loading also remains hard edged")
		photo.gallery.mode = photo.Gallery.Layout.WALL; photo._shape_screen()
		check(photo._edge_feather().is_equal_approx(feather), "Leaving magazine restores the global photo strength")
	var restored := Photo.new()
	var settings := ConfigFile.new(); restored.restore_view_settings(settings)
	check(restored.edge_feather_strength == 1, "Older settings without this key keep the current default")
	for value in [NAN, INF, -1.0, 5.0, 0.0]:
		settings.set_value("photo_screen", "edge_feather_strength", value); restored.restore_view_settings(settings)
		check(restored.edge_feather_strength == (clampf(value, 0, 3) if is_finite(value) else 1.0), "Stored strength validates finite bounds and preserves zero")
	restored.free()
