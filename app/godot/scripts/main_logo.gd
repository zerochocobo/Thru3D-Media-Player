extends MeshInstance3D

## One transparent icon + wordmark asset shared by the startup and library.
const TEXTURE := preload("res://branding/thru3d-logo-transparent.png")

func _init(width: float = 0.9) -> void:
	name = "MainLogo"
	var quad := QuadMesh.new()
	quad.size = Vector2(width, width * TEXTURE.get_height() / TEXTURE.get_width())
	mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.albedo_texture = TEXTURE
	material.render_priority = 12
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func align_navigation(icon_centre: float, text_left: float) -> void:
	# The source has unequal transparent margins. Lay out its two UV regions
	# against the same anchors as the navigation, without rescaling the artwork.
	var pixel_size: float = mesh.size.x / TEXTURE.get_width()
	var height: float = mesh.size.y
	mesh.size.x = 800.0 * pixel_size
	(material_override as StandardMaterial3D).uv1_scale.x = 800.0 / TEXTURE.get_width()
	# Visible icon spans source x=128..773; the wordmark begins at x=825.
	position.x = icon_centre - (450.5 - 400.0) * pixel_size
	var wordmark := MeshInstance3D.new()
	wordmark.name = "Wordmark"
	var quad := QuadMesh.new()
	quad.size = Vector2((TEXTURE.get_width() - 800.0) * pixel_size, height)
	wordmark.mesh = quad
	wordmark.position.x = text_left + quad.size.x * 0.5 - 25.0 * pixel_size - position.x
	var material := material_override.duplicate() as StandardMaterial3D
	material.uv1_scale.x = (TEXTURE.get_width() - 800.0) / TEXTURE.get_width()
	material.uv1_offset.x = 800.0 / TEXTURE.get_width()
	wordmark.material_override = material
	wordmark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(wordmark)
