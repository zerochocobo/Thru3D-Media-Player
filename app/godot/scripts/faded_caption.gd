extends MeshInstance3D
## Eye-buffer display of a semi-transparent Label3D through its faded canvas capture.
## Label3D blends its outline and fill separately, so the outline would show through the fill.
## Kept as a child of the label: hiding the label hides this quad as well.

func _init() -> void:
	name = "FadedCaption"
	mesh = QuadMesh.new()
	cast_shadow = SHADOW_CASTING_SETTING_OFF
	visible = false
	var appearance := ShaderMaterial.new()
	appearance.shader = preload("res://shaders/subtitle_surface.gdshader")
	appearance.render_priority = 1
	appearance.set_shader_parameter("bitmap_subtitle_rect", Vector4(0, 0, 1, 1))
	appearance.set_shader_parameter("bitmap_subtitle_enabled", true)
	material_override = appearance

## True once [source] is drawn by this quad; until its capture is ready the label stays in use.
func show_caption(source: Label3D, canvas: Node, image_limit: Vector2i) -> bool:
	visible = source.visible and not source.text.is_empty() and source.modulate.a < 1.0 and canvas.request(source, image_limit)
	if not visible: return false
	(mesh as QuadMesh).size = canvas.physical_size(source)
	global_transform = canvas.pose(source)
	global_basis = global_basis.orthonormalized()
	material_override.set_shader_parameter("bitmap_subtitle_texture", canvas.viewport.get_texture())
	return true
