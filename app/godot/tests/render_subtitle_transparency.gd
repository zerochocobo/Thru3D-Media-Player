extends SceneTree
## Text caption transparency fades the finished caption as one layer: glyph fill and outline
## must match the opaque caption blended uniformly over the background, in every text path.
const Canvas := preload("res://scripts/flat_subtitle_canvas.gd")
const Patch := preload("res://scripts/projected_subtitles.gd")
const Faded := preload("res://scripts/faded_caption.gd")
const TEXT := "字幕测试 Subtitle"
const TOLERANCE := 0.04
var failures: Array[String] = []
var checks := 0
var output := ""

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); print("FAILED: " + message)

func _initialize() -> void: call_deferred("_run")

func _frames(count := 4) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func _caption(alpha: float) -> Label3D:
	var label := Label3D.new()
	label.text = TEXT
	label.font_size = 40
	label.outline_size = 8
	label.pixel_size = 0.0015
	label.no_depth_test = true
	label.modulate = Color(1, 1, 1, alpha)
	label.outline_modulate = Color(0, 0, 0, alpha)
	return label

## The eye-buffer view: a raw Label3D, or the production faded quad replacing it.
func _eye(bg: Color, alpha: float, faded: bool) -> Image:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 120)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.18
	camera.position = Vector3(0, 0, 1)
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_COLOR
	camera.environment.background_color = bg
	viewport.add_child(camera)
	var label := _caption(alpha)
	viewport.add_child(label)
	if faded:
		var canvas := Canvas.new(); viewport.add_child(canvas)
		var quad := Faded.new(); label.add_child(quad)
		var ready := false
		for attempt in 10:
			ready = quad.show_caption(label, canvas, Vector2i.ZERO)
			if ready: break
			await process_frame
		check(ready, "Faded caption becomes ready")
		label.layers = 0
	await _frames()
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	image.convert(Image.FORMAT_RGBA8)
	return image

func _lum(c: Color) -> float: return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## Glyph fill and outline masks from the opaque caption over a mid-grey background.
func _masks(opaque: Image) -> Array:
	var result := []
	for y in opaque.get_height():
		for x in opaque.get_width():
			var l := _lum(opaque.get_pixel(x, y))
			result.append(1 if l > 0.92 else (2 if l < 0.03 else 0))
	return result

func _mean(image: Image, masks: Array, kind: int) -> float:
	var total := 0.0; var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if masks[y * image.get_width() + x] == kind:
				total += _lum(image.get_pixel(x, y)); count += 1
	return total / maxi(count, 1)

## Every channel of a faded canvas is the opaque canvas scaled by the opacity.
func _uniform(opaque: Image, faded: Image, alpha: float, label: String) -> void:
	var worst := 0.0; var covered := 0
	for y in opaque.get_height():
		for x in opaque.get_width():
			var a := opaque.get_pixel(x, y); var b := faded.get_pixel(x, y)
			if a.a > 0.01: covered += 1
			for i in 4: worst = maxf(worst, absf(b[i] - a[i] * alpha))
	check(covered > 500, label + " canvas has glyph coverage")
	check(worst <= 2.5 / 255.0, "%s canvas fades uniformly at %.2f (max error %.4f)" % [label, alpha, worst])

func _flat_canvas(alpha: float) -> Image:
	var label := _caption(alpha)
	root.add_child(label)
	var canvas := Canvas.new(); root.add_child(canvas)
	for attempt in 10:
		if canvas.request(label): break
		await process_frame
	await _frames(2)
	var image := canvas.viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBAF)
	label.queue_free(); canvas.queue_free()
	return image

func _patch_canvas(alpha: float) -> Image:
	var label := _caption(alpha); label.visible = true
	root.add_child(label)
	var patch := Patch.new(); root.add_child(patch)
	await process_frame
	patch.update_patch(label, ShaderMaterial.new(), Basis.IDENTITY, 2.0)
	await _frames(2)
	var image := patch.viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBAF)
	label.queue_free(); patch.queue_free()
	return image

func _strip(images: Array) -> Image:
	var w: int = images[0].get_width(); var h: int = images[0].get_height()
	var out := Image.create_empty(w, h * images.size(), false, Image.FORMAT_RGBA8)
	for i in images.size(): out.blit_rect(images[i], Rect2i(0, 0, w, h), Vector2i(0, h * i))
	return out

func _run() -> void:
	output = OS.get_environment("QUEST_SUBTITLE_PREVIEW_DIR")
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	var masks := _masks(await _eye(Color(0.2, 0.2, 0.2), 1.0, false))
	var report := {}
	for background in [["dark", Color(0.2, 0.2, 0.2)], ["bright", Color(0.95, 0.95, 0.95)]]:
		var bg: Color = background[1]
		var rows := [await _eye(bg, 1.0, false)]
		for transparency in [50, 80]:
			var alpha: float = 1.0 - transparency / 100.0
			var image := await _eye(bg, alpha, true)
			rows.append(image)
			var fill := _mean(image, masks, 1); var outline := _mean(image, masks, 2)
			var want_fill := _lum(bg.lerp(Color.WHITE, alpha)); var want_outline := _lum(bg.lerp(Color.BLACK, alpha))
			report["%s_%d" % [background[0], transparency]] = {"fill": fill, "expected_fill": want_fill, "outline": outline, "expected_outline": want_outline}
			check(absf(fill - want_fill) <= TOLERANCE, "%s %d%% fill %.3f expected %.3f" % [background[0], transparency, fill, want_fill])
			check(absf(outline - want_outline) <= TOLERANCE, "%s %d%% outline %.3f expected %.3f" % [background[0], transparency, outline, want_outline])
		if not output.is_empty(): _strip(rows).save_png(output.path_join("text_transparency_%s.png" % background[0]))
	var flat_opaque := await _flat_canvas(1.0)
	var patch_opaque := await _patch_canvas(1.0)
	for alpha in [0.5, 0.2]:
		_uniform(flat_opaque, await _flat_canvas(alpha), alpha, "Flat/layer")
		_uniform(patch_opaque, await _patch_canvas(alpha), alpha, "Immersive")
	print(JSON.stringify(report))
	print("Subtitle transparency render checks=%d failures=%d" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
