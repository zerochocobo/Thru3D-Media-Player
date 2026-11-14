extends ColorRect
## Fades a finished transparent subtitle canvas as one layer. Glyphs are drawn opaque first;
## multiplying the premultiplied pixels afterwards keeps outlines from showing through the fill.

func _init() -> void:
	name = "SubtitleFade"
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var blend := CanvasItemMaterial.new()
	blend.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	material = blend
	set_opacity(1.0)

func set_opacity(opacity: float) -> void:
	opacity = clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 1.0
	color = Color(opacity, opacity, opacity, opacity)
	visible = opacity < 1.0
