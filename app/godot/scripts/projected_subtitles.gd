extends Node
## One cached caption canvas, projected from each physical eye onto a shared video-anchored plane.
## Only cue changes redraw the canvas. Distance/pose changes update shader parameters.
const PATCH_SIZE := 700
const PROJECTION_RADIUS := 50.0
var plane_pose := Transform3D.IDENTITY
var anchor_basis := Basis.IDENTITY
var viewport: SubViewport
var label: Label
var _text := ""
var _vertical := false
var _size := 1.0
var _style := ""
const SubtitleStyle := preload("res://scripts/subtitle_style.gd")
const SubtitleDepth := preload("res://scripts/subtitle_depth.gd")
var vertical_text: Control
const VerticalText := preload("res://scripts/vertical_subtitle_text.gd")

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(PATCH_SIZE, PATCH_SIZE)
	viewport.transparent_bg = true
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	label = Label.new()
	label.size = Vector2(PATCH_SIZE, PATCH_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 40)
	label.add_theme_constant_override("outline_size", 8)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	viewport.add_child(label)
	vertical_text = VerticalText.new()
	vertical_text.size = Vector2(PATCH_SIZE, PATCH_SIZE)
	vertical_text.visible = false
	viewport.add_child(vertical_text)

func clear(target: ShaderMaterial) -> void:
	if target: target.set_shader_parameter("subtitle_enabled", false)

func update_patch(caption: Label3D, target: ShaderMaterial, anchor: Basis, distance: float, vertical: bool = false, text_size: float = 1.0, text_style: String = SubtitleStyle.DEFAULT, surface_pose: Transform3D = Transform3D.IDENTITY, viewer_position: Vector3 = Vector3.ZERO, world_scale: float = 1.0) -> void:
	if not viewport or not caption.visible or caption.text.is_empty():
		clear(target)
		return
	text_style = SubtitleStyle.normalize(text_style)
	if _text != caption.text or _vertical != vertical or not is_equal_approx(_size, text_size) or _style != text_style:
		_size = text_size
		_style = text_style
		var appearance := SubtitleStyle.colors(_style)
		label.add_theme_color_override("font_color", appearance.text_color)
		label.add_theme_color_override("font_outline_color", appearance.outline_color)
		label.add_theme_font_size_override("font_size", roundi(40 * _size))
		label.add_theme_constant_override("outline_size", maxi(2, roundi(8 * _size)))
		_text = caption.text
		_vertical = vertical
		label.visible = not vertical
		vertical_text.visible = vertical
		if vertical:
			vertical_text.set_text(_text, preload("res://scripts/ray_menu.gd").ui_font(), _size, appearance.text_color, appearance.outline_color)
		else:
			label.text = _text
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	target.set_shader_parameter("subtitle_texture", viewport.get_texture())
	target.set_shader_parameter("subtitle_enabled", true)
	anchor_basis = anchor
	plane_pose = projection_plane(surface_pose, anchor, distance, viewer_position, world_scale)
	target.set_shader_parameter("subtitle_world_to_patch", plane_pose.affine_inverse())

static func projection_plane(surface_pose: Transform3D, anchor: Basis, distance: float, viewer_position: Vector3, world_scale: float = 1.0) -> Transform3D:
	# Move the reference plane along its central viewing ray: preserve its video position,
	# orientation and angular size through zoom, while giving it an actual distance in metres.
	# Viewer orientation is deliberately absent; turning the head never moves the anchor.
	var reference_basis := surface_pose.basis * anchor
	var reference_center := surface_pose.origin + reference_basis * Vector3.FORWARD * PROJECTION_RADIUS
	var offset := reference_center - viewer_position
	var scale := SubtitleDepth.distance(distance) * maxf(world_scale, 0.0001) / maxf(offset.length(), 0.0001)
	return Transform3D(reference_basis.scaled(Vector3.ONE * PROJECTION_RADIUS * scale), viewer_position + offset * scale)

static func runtime_ipd() -> float:
	var xr := XRServer.primary_interface
	if xr and xr.is_initialized() and xr.get_view_count() == 2:
		var left := xr.get_transform_for_view(0, Transform3D.IDENTITY)
		var right := xr.get_transform_for_view(1, Transform3D.IDENTITY)
		return left.origin.distance_to(right.origin) / maxf(XRServer.world_scale, 0.0001)
	return 0.063 # Desktop preview; physical XR obtains the current runtime eye positions.
