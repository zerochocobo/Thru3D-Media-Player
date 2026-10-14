extends RefCounted
## A changed PGS cue uploads one occupied RGBA crop; native pixels are premultiplied.
var texture: ImageTexture
var version := 0
var source := 0

func clear(material: ShaderMaterial) -> void:
	if material:
		material.set_shader_parameter("bitmap_subtitle_enabled", false)
	texture = null
	version = 0
	source = 0

func needs_pixels(bitmap: Dictionary, source_handle: int) -> bool:
	return not texture or version != int(bitmap.get("version", 0)) or source != source_handle

func apply(material: ShaderMaterial, bitmap: Dictionary, source_handle: int, pixels: PackedByteArray, size: float = 1.0, position: float = 0.0) -> bool:
	if not material or bitmap.is_empty():
		clear(material)
		return false
	if needs_pixels(bitmap, source_handle):
		var w := int(bitmap.get("width", 0))
		var h := int(bitmap.get("height", 0))
		if w <= 0 or h <= 0 or pixels.size() != w * h * 4:
			clear(material)
			return false
		var image := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, pixels)
		texture = ImageTexture.create_from_image(image)
		version = int(bitmap.version)
		source = source_handle
	var rect := adjusted_rect(bitmap, size, position)
	material.set_shader_parameter("bitmap_subtitle_texture", texture)
	material.set_shader_parameter("bitmap_subtitle_rect", rect)
	material.set_shader_parameter("bitmap_subtitle_enabled", true)
	return true

## Scale around the cue centre/baseline. Position 0 preserves authored placement;
## positive values lift the baseline toward the top, matching the text slider.
static func adjusted_rect(bitmap: Dictionary, size: float, position: float) -> Vector4:
	var canvas := Vector2(float(bitmap.canvas_width), float(bitmap.canvas_height))
	var scale := clampf(size, 0.5, 2.0) if is_finite(size) else 1.0
	var lift := clampf(position, 0.0, 1.0) if is_finite(position) else 0.0
	var extent := Vector2(float(bitmap.width), float(bitmap.height)) / canvas * scale
	var centre := (float(bitmap.x) + float(bitmap.width) / 2.0) / canvas.x
	var baseline := (float(bitmap.y) + float(bitmap.height)) / canvas.y
	var top := lerpf(baseline - extent.y, 0.0, lift)
	return Vector4(centre - extent.x / 2.0, top, extent.x, extent.y)
