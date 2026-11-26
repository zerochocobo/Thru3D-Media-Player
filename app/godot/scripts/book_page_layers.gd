extends Node
## The pages being read, shown on OpenXR quad layers while they lie still. The eye buffer resamples a
## page texture once more before the lenses and blurs small type; the compositor samples the layer at
## display resolution (as it does for video and menus). A hole in the eye buffer, drawn on the page's
## plane, lets the layer show through, so the wand and its light stay in front. A leaf in the air is
## the 3D book's own: the layers step aside while pages turn or riffle.
##
## Swapchain rules follow menu_composition.gd: each layer keeps one fixed-size viewport for the
## session, is never hidden or detached (an idle layer shrinks to a sub-pixel quad), repaints by
## switching its viewport between UPDATE_ALWAYS and UPDATE_DISABLED, and retires its viewport when
## the session stops.

const MenuComposition := preload("res://scripts/menu_composition.gd")
const QiyuController := preload("res://scripts/qiyu_controller.gd")
const HOLE_SHADER := preload("res://shaders/menu_layer_hole.gdshader")
const HIDDEN_SIZE := Vector2(0.0005, 0.0005)
## Under the eye buffer and under the menus' layers (from -6), so the ring and panels cover pages.
const ORDER := [-8, -7]
## After the page itself, before the wand's light, the aim spot and notes on the page (10+).
const HOLE_PRIORITY := 9
## Page pixels: about 1.4x the display density of Quest 3 at the tome's size and distance (a page
## spans ~29 degrees), as for the menus; XR2 Gen1 headsets resolve less and read fewer pixels.
const PIXELS := Vector2i(1152, 1536)
const LOW_END_PIXELS := Vector2i(768, 1024)
## Frames a changed page keeps repainting its layer.
const REPAINT_FRAMES := 6
const SUPERSAMPLING_PROPERTY := "XR_FB_composition_layer_settings/manual/supersampling_mode"

var enabled := false
var display: RefCounted
var _layers: Array[Dictionary] = []
var _origin: Node3D
var _low_end := false

## Whether quad layers can be used; the layers themselves are made when a page is first shown, so a
## session that never opens a book leaves the whole layer budget to video.
func configure(target_origin: Node3D, target_display: RefCounted, low_end: bool) -> void:
	display = target_display; _origin = target_origin; _low_end = low_end
	var xr := XRServer.find_interface("OpenXR")
	var probe := OpenXRCompositionLayerQuad.new()
	enabled = xr != null and xr.is_initialized() and xr.get_view_count() == 2 and probe.is_natively_supported() 		and not QiyuController.runtime
	probe.free()
	if enabled: xr.session_stopping.connect(_renew)

func _ensure() -> void:
	if not _layers.is_empty(): return
	for index in ORDER.size():
		_layers.append(_make(_origin, LOW_END_PIXELS if _low_end else PIXELS, ORDER[index], index))

func _make(origin: Node3D, pixels: Vector2i, order: int, index: int) -> Dictionary:
	var submit := SubViewport.new(); submit.size = pixels
	submit.transparent_bg = true; submit.disable_3d = true; submit.world_2d = World2D.new()
	submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(submit)
	var sheet := TextureRect.new(); sheet.size = Vector2(pixels)
	sheet.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; sheet.stretch_mode = TextureRect.STRETCH_SCALE
	sheet.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	submit.add_child(sheet)
	# The paragraph being read aloud: a warm wash and a bar in the margin, drawn into the page itself.
	var wash := ColorRect.new(); wash.color = Color(1.0, 0.78, 0.35, 0.16); wash.visible = false
	var bar := ColorRect.new(); bar.color = Color(0.92, 0.58, 0.18, 0.9); bar.visible = false
	submit.add_child(wash); submit.add_child(bar)
	var layer := OpenXRCompositionLayerQuad.new()
	layer.name = "BookPage%d" % index
	layer.sort_order = order; layer.alpha_blend = true; layer.enable_hole_punch = false
	layer.quad_size = HIDDEN_SIZE
	origin.add_child(layer)
	layer.layer_viewport = submit
	for property in layer.get_property_list():
		if property.name == SUPERSAMPLING_PROPERTY: layer.set(property.name, 1)
	var hole := MeshInstance3D.new(); hole.mesh = QuadMesh.new()
	hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new(); material.shader = HOLE_SHADER; material.render_priority = HOLE_PRIORITY
	hole.material_override = material; hole.visible = false; hole.top_level = true
	add_child(hole)
	return {"submit": submit, "sheet": sheet, "wash": wash, "bar": bar, "layer": layer, "hole": hole, "texture": null,
		"light": Color(-1, -1, -1), "mark": Rect2(), "paint": 0}

## Kept for the session once configured: the video layer leaves room for them.
func layer_reservation() -> int:
	return _layers.size()

## The pages to show this frame: [{texture, transform (global, page centre, facing the reader), size
## (metres), light, mark (Rect2 in page UV of the paragraph read aloud, or empty)}], at most two. An empty list puts every layer aside.
## [reading]: a book is open, so the eye buffer stays transparent between turns (no flicker of the sky).
func show_pages(pages: Array, reading: bool = false) -> void:
	if not enabled or (pages.is_empty() and _layers.is_empty()): return
	_ensure()
	if display != null and display.has_method("set_book_layers"): display.set_book_layers(reading or not pages.is_empty())
	var opaque: bool = display != null and display.get("applied_passthrough") == false \
		and display.get("video_layer") == false and display.get("browser_layer") == false
	for index in _layers.size():
		var slot: Dictionary = _layers[index]
		var page: Dictionary = pages[index] if index < pages.size() else {}
		var texture: Texture2D = page.get("texture")
		if texture == null:
			if slot.hole.visible: slot.hole.visible = false; slot.layer.quad_size = HIDDEN_SIZE
			continue
		if texture != slot.texture or not (page.light as Color).is_equal_approx(slot.light):
			slot.texture = texture; slot.light = page.light
			slot.sheet.texture = texture
			slot.sheet.modulate = Color(slot.light, 1.0)
			slot.paint = REPAINT_FRAMES
		var mark: Rect2 = page.get("mark", Rect2())
		if mark != slot.mark:
			slot.mark = mark
			var pixels := Vector2(slot.submit.size)
			var shown := mark.has_area()
			slot.wash.visible = shown; slot.bar.visible = shown
			if shown:
				var pad := pixels.x * 0.02
				slot.wash.position = mark.position * pixels - Vector2(pad, pad * 0.5)
				slot.wash.size = mark.size * pixels + Vector2(pad * 2.0, pad)
				slot.bar.position = slot.wash.position; slot.bar.size = Vector2(pixels.x * 0.007, slot.wash.size.y)
			slot.paint = REPAINT_FRAMES
		var place: Transform3D = page.transform
		slot.layer.global_transform = place
		slot.layer.quad_size = page.size
		slot.hole.global_transform = place
		var quad := slot.hole.mesh as QuadMesh
		if quad.size != page.size: quad.size = page.size
		var material: ShaderMaterial = slot.hole.material_override
		material.set_shader_parameter("menu_texture", texture)
		material.set_shader_parameter("opaque_scene", opaque)
		slot.hole.visible = true

func _process(_delta: float) -> void:
	for slot in _layers:
		# A few frames: a new layer gets its swapchain only after it is first submitted, and each
		# repaint must land in an acquired image the compositor keeps.
		if int(slot.paint) > 0:
			slot.submit.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			slot.paint = int(slot.paint) - 1
		elif slot.submit.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			slot.submit.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _renew() -> void:
	for slot in _layers:
		slot.submit = MenuComposition.renew_submit(slot.layer, slot.submit)
		slot.paint = REPAINT_FRAMES

## Debug only: moves the layers (base order, then base + 1) and repaints them.
func debug_order(base: int) -> void:
	for index in _layers.size():
		_layers[index].layer.sort_order = base + index; _layers[index].paint = REPAINT_FRAMES

## Debug state for device probes.
func describe() -> Dictionary:
	var slots := []
	for slot in _layers:
		slots.append({"hole": slot.hole.visible, "size": [slot.layer.quad_size.x, slot.layer.quad_size.y], "paint": slot.paint,
			"update": slot.submit.render_target_update_mode, "texture": slot.texture != null, "order": slot.layer.sort_order,
			"native": slot.layer.is_natively_supported(), "viewport": slot.layer.layer_viewport == slot.submit,
			"origin": slot.layer.get_parent() is XROrigin3D, "pos": [snappedf(slot.layer.global_position.x, 0.01), snappedf(slot.layer.global_position.y, 0.01), snappedf(slot.layer.global_position.z, 0.01)]})
	return {"enabled": enabled, "slots": slots}
