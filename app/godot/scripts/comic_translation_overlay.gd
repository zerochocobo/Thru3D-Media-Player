extends RefCounted
## OCR rectangles, text layout and ray peek all use the same page UV coordinates.
const Fonts := preload("res://scripts/ray_menu.gd")
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const BACKGROUND := Color.WHITE
const FOREGROUND := Color(0.035, 0.04, 0.05, 1.0)
const WRAP := TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
var photo: Node3D
var viewport: SubViewport
var canvas: Control
var shown := 0
var hovered := {}
var _depth_margin := -1.0

class BubbleCanvas extends Control:
	var items := []
	var concealed := {}
	var background := BACKGROUND
	var foreground := FOREGROUND
	func _draw() -> void:
		# Paint every opaque mask before any text; overlapping OCR boxes cannot erase text.
		for item: Dictionary in items:
			if not concealed.has(item.id): draw_rect(item.mask, background)
		for item: Dictionary in items:
			if concealed.has(item.id): continue
			draw_set_transform(item.position, 0.0, Vector2.ONE * item.draw_scale)
			item.paragraph.draw(get_canvas_item(), Vector2.ZERO, foreground)
		draw_set_transform(Vector2.ZERO)

func _init(owner: Node3D) -> void: photo = owner

static func layout(entry: Dictionary, output_size: Vector2) -> Dictionary:
	var block: Dictionary = entry.block
	# hit_rect/hit_rows describe a selectable balloon, not the area containing its ink.
	var bounds: Array = block.get("rect", block.get("hit_rect", []))
	if bounds.size() != 4 or entry.size.x <= 0 or entry.size.y <= 0: return {}
	var region: Rect2 = entry.region
	var ratio: Vector2 = region.size * output_size / entry.size
	var origin: Vector2 = region.position * output_size
	var page := Rect2(origin, region.size * output_size)
	# Cover antialiased ink at the OCR boundary too. Never spill onto the adjacent page.
	var start := (origin + Vector2(bounds[0] - 1, bounds[1] - 1) * ratio).floor()
	var end := (origin + Vector2(bounds[2] + 1, bounds[3] + 1) * ratio).ceil()
	var cover := Rect2(start, end - start).intersection(page)
	if not cover.has_area(): return {}
	return {"rect": cover, "uv": Rect2(cover.position / output_size, cover.size / output_size)}

static func paragraph(text: String, font: Font, pixels: int, width: float, language: String) -> TextParagraph:
	var value := TextParagraph.new()
	value.alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.break_flags = WRAP; value.width = width
	value.add_string(text, font, pixels, language)
	return value

static func fits(value: TextParagraph, size: Vector2) -> bool:
	if value.get_size().y > size.y: return false
	for line in value.get_line_count():
		if value.get_line_size(line).x > size.x + 0.01: return false
	return true

static func fit_text(text: String, font: Font, size: Vector2, language: String = "en", scale: float = 1.0) -> Dictionary:
	# Remove service/OCR visual line breaks. Target-language word boundaries drive reflow.
	text = Protocol.normalize(text, language)
	if text.is_empty() or size.x <= 0 or size.y <= 0: return {}
	var low := 1; var high := maxi(1, ceili(size.y)); var best := 1
	while low <= high:
		var mid := (low + high) / 2
		var candidate := paragraph(text, font, mid, size.x, language)
		if fits(candidate, size): best = mid; low = mid + 1
		else: high = mid - 1
	best = maxi(1, floori(best * minf(1.0, scale)))
	# Draw exactly what was measured, without Label's implicit minimum-size expansion.
	var value := paragraph(text, font, best, size.x, language)
	var extent := value.get_size()
	var draw_scale := minf(1.0, minf(size.y / maxf(1.0, extent.y), size.x / maxf(1.0, extent.x)))
	return {"paragraph": value, "font_size": best, "size": extent * draw_scale, "draw_scale": draw_scale, "text": text}

func _create() -> void:
	if viewport: return
	viewport = SubViewport.new(); viewport.transparent_bg = true
	viewport.disable_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	photo.add_child(viewport)
	# Draw in the photo material itself so neither compositor cuts nor edge feather
	# can clear an independent translation plane after it has covered the original.
	photo.material.set_shader_parameter("comic_overlay_texture", viewport.get_texture())

func update(entries: Array, cache: Dictionary, scale: float, appearance: String = "light") -> void:
	if entries.is_empty() or cache.is_empty(): clear(); return
	_create()
	if canvas: canvas.free()
	canvas = BubbleCanvas.new(); viewport.add_child(canvas)
	if appearance == "dark":
		canvas.background = Color(0.045,0.055,0.075,1.0); canvas.foreground = Color(0.98,0.985,1.0,1.0)
	var dimensions: Vector2 = photo._size
	viewport.size = Vector2i((dimensions * (2048.0 / maxf(dimensions.x, dimensions.y))).round())
	canvas.size = Vector2(viewport.size)
	shown = 0
	var font := Fonts.ui_font()
	for entry: Dictionary in entries:
		if not cache.has(entry.key): continue
		var geometry := layout(entry, Vector2(viewport.size))
		if geometry.is_empty(): continue
		var cover: Rect2 = geometry.rect
		var padding := minf(6.0, minf(cover.size.x, cover.size.y) * 0.04) / maxf(0.5, scale)
		var rect := cover.grow(-padding)
		var fit := fit_text(str(cache[entry.key].text), font, rect.size, str(entry.get("target", "auto")), scale)
		if fit.is_empty(): continue
		fit["position"] = rect.position + (rect.size - fit.size) / 2.0
		fit["cover"] = cover; fit["mask"] = cover; fit["uv"] = geometry.uv
		fit["id"] = "%s:%s" % [entry.get("page", 0), entry.get("id", entry.key)]
		canvas.items.append(fit); shown += 1
	_depth_margin = -1.0
	canvas.concealed = hovered.duplicate(); _redraw()
	sync(true)

func peek(points: Array) -> void:
	var next := {}
	if canvas:
		for point: Vector2 in points:
			for item: Dictionary in canvas.items:
				if item.uv.has_point(point): next[item.id] = true
			if not next.is_empty(): break # Existing right/left ray priority.
	if next == hovered: return
	hovered = next
	if canvas: canvas.concealed = hovered.duplicate(); _redraw()

func _redraw() -> void:
	canvas.queue_redraw()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func sync(show: bool) -> void:
	if not viewport: return
	# Cover both eyes' displaced original ink without stretching the translated letters.
	# 0.0175 is the photo shader's maximum half-disparity; the native pair is capped lower.
	var margin: float = ceili(Vector2(viewport.size).x * 0.0175 * photo.depth_strength) + 1 if photo.depth_requested else 0.0
	if margin != _depth_margin and canvas:
		_depth_margin = margin
		for item: Dictionary in canvas.items:
			item.mask = item.cover.grow_individual(margin,0,margin,0).intersection(Rect2(Vector2.ZERO,Vector2(viewport.size)))
			item.uv = Rect2(item.mask.position / Vector2(viewport.size),item.mask.size / Vector2(viewport.size))
		_redraw()
	visible(show and photo.panel.visible and not photo.loading and not photo.inspect \
		and photo.geometry == 0 and not photo.stereo_sbs and not photo.portrait_requested \
		and not photo.spatial_requested and photo.gallery.mode in [0, 4] and not photo._transition_active and photo._reveal_seconds <= 0
	)

func visible(show: bool) -> void:
	if viewport: photo.material.set_shader_parameter("comic_overlay_enabled", show and shown > 0)

func clear() -> void:
	shown = 0; hovered.clear(); visible(false)
	if canvas: canvas.free(); canvas = null

func close() -> void:
	clear()
	if viewport: photo.material.set_shader_parameter("comic_overlay_texture", null)
	if viewport: viewport.queue_free(); viewport = null
