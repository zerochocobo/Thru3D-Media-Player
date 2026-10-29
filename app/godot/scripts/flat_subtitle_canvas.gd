extends Node
## A cropped, pixel-aligned capture of the existing Label3D layout. Like menu_composition,
## an orthographic camera renders only on content changes, independently of the eye buffers.
## Font oversampling improves the source contour without changing font size or wrapping.
const RASTER_SCALE := 2.0
const MAX_SIZE := Vector2i(4096, 2048)
const MAX_PIXELS := 4 * 1024 * 1024
const FIELDS := [&"text", &"font_size", &"outline_size", &"width", &"line_spacing", &"offset",
	&"horizontal_alignment", &"vertical_alignment", &"autowrap_mode", &"autowrap_trim_flags",
	&"justification_flags", &"text_direction", &"language", &"structured_text_bidi_override",
	&"structured_text_bidi_override_options", &"uppercase", &"modulate", &"outline_modulate"]
var viewport: SubViewport
var label: Label3D
var camera: Camera3D
var rect := Rect2() # Logical glyph pixels, in the original Label3D's local XY coordinates.
var version := 0
var _signature: Array = []
var _source_font: Font
var _draw_after := -1
var _limit := MAX_SIZE

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(16, 16)
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	label = Label3D.new()
	label.pixel_size = 1.0
	label.no_depth_test = true
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	viewport.add_child(label)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.05; camera.far = 2.0
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_COLOR
	camera.environment.background_color = Color(0, 0, 0, 0)
	viewport.add_child(camera)

func signature(caption: Label3D) -> Array:
	var result: Array = [caption.font if caption.font else ThemeDB.fallback_font]
	for field in FIELDS:
		# Physical screen scaling cancels out of logical width, apart from float32 noise.
		result.append(snappedf(caption.width, 0.001) if field == &"width" else caption.get(field))
	return result

func matches(caption: Label3D) -> bool:
	return _signature == signature(caption)

func request(caption: Label3D, image_limit := Vector2i.ZERO) -> bool:
	var limit := image_limit.min(MAX_SIZE) if image_limit.x > 0 and image_limit.y > 0 else MAX_SIZE
	var key := signature(caption)
	if key != _signature or limit != _limit:
		_signature = key; _limit = limit
		version += 1
		_draw_after = -1; rect = Rect2()
		var font: Font = key[0]
		if font != _source_font:
			_source_font = font
			label.font = font.duplicate(true)
			_oversample(label.font)
		for field in FIELDS: label.set(field, caption.get(field))
		# Label3D shapes its mesh deferred; fit only after those queued updates.
		call_deferred("_fit", version)
	return _draw_after >= 0 and Engine.get_frames_drawn() > _draw_after and rect.has_area()

func _oversample(font: Font) -> void:
	if font is FontFile or font is SystemFont:
		font.oversampling = RASTER_SCALE
		font.generate_mipmaps = false
	for fallback in font.fallbacks: _oversample(fallback)

func _fit(expected_version: int) -> void:
	if expected_version != version: return
	var bounds := label.get_aabb()
	if bounds.size.x <= 0 or bounds.size.y <= 0: return
	# Preserve the original origin/baseline. Padding includes outline and the bilinear footprint.
	var margin := float(label.outline_size + 2)
	var minimum := (Vector2(bounds.position.x, bounds.position.y) - Vector2.ONE * margin) * RASTER_SCALE
	var maximum := (Vector2(bounds.end.x, bounds.end.y) + Vector2.ONE * margin) * RASTER_SCALE
	minimum = minimum.floor(); maximum = maximum.ceil()
	var size := Vector2i(ceili((maximum.x - minimum.x) / 64) * 64, ceili((maximum.y - minimum.y) / 32) * 32)
	if size.x > _limit.x or size.y > _limit.y or size.x * size.y > MAX_PIXELS: return
	rect = Rect2(minimum / RASTER_SCALE, Vector2(size) / RASTER_SCALE)
	viewport.size = size
	camera.size = rect.size.y
	camera.position = Vector3(rect.get_center().x, rect.get_center().y, 1.0)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_draw_after = Engine.get_frames_drawn() + 1

func pose(caption: Label3D) -> Transform3D:
	return caption.global_transform * Transform3D(Basis.IDENTITY, Vector3(rect.get_center().x, rect.get_center().y, 0) * caption.pixel_size)

func physical_size(caption: Label3D) -> Vector2:
	return rect.size * caption.pixel_size * Vector2(caption.global_basis.x.length(), caption.global_basis.y.length())

func fits_surface(caption: Label3D, surface: Transform3D, size: Vector2) -> bool:
	# The existing video hole exposes this layer. Oversized text outside it must retain
	# the original depth-independent label, rather than disappear behind the cinema scene.
	var bounds := label.get_aabb()
	var to_surface := surface.affine_inverse() * caption.global_transform
	var screen := Rect2(-size * 0.5, size)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			# Scale label coordinates before applying its translation.
			var point := to_surface * (Vector3(x, y, 0) * caption.pixel_size)
			if not screen.has_point(Vector2(point.x, point.y)): return false
	return true
