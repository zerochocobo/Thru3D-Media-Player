extends Node3D
## Presentation only. The existing subtitle controller still owns cues, timing, styles and tracks.
## A separate label/bitmap surface keeps the original flat/immersive layouts and preferences intact.
const Canvas := preload("res://scripts/flat_subtitle_canvas.gd")
const Layer := preload("res://scripts/video_layer.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Facing := preload("res://scripts/surface_facing.gd")
var video: Node3D
var text: Label3D
var bitmap: MeshInstance3D
var hole: MeshInstance3D
var canvas: Node
var active := false
var kind := ""
var prepared := false
var _key: Array = []
var _source_key: Array = []
var _uploaded_version := -1
var _generation := -1

func _init(owner_video: Node3D) -> void:
	video = owner_video

func _ready() -> void:
	text = Label3D.new()
	text.name = "BelowScreenText"
	text.no_depth_test = true
	text.visible = false
	add_child(text)
	bitmap = MeshInstance3D.new()
	bitmap.name = "BelowScreenBitmap"
	bitmap.mesh = QuadMesh.new()
	var appearance := ShaderMaterial.new()
	appearance.shader = preload("res://shaders/subtitle_surface.gdshader")
	appearance.render_priority = 1
	appearance.set_shader_parameter("bitmap_subtitle_rect", Vector4(0, 0, 1, 1))
	bitmap.material_override = appearance
	bitmap.visible = false
	bitmap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bitmap)
	hole = MeshInstance3D.new()
	hole.name = "BelowScreenSubtitleHole"
	hole.mesh = QuadMesh.new()
	var mask := ShaderMaterial.new()
	# Reuse the menu's coverage mask: expose only glyphs, never a rectangular hole in the cinema.
	mask.shader = preload("res://shaders/menu_layer_hole_overlay.gdshader")
	mask.render_priority = 2 # Before menu masks (9) and their eye-buffer controls (10+).
	hole.material_override = mask
	hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hole.visible = false
	add_child(hole)
	sync_surface_facing(video._surface_front_only)

func sync_surface_facing(front_only: bool) -> void:
	if text:
		text.no_depth_test=not front_only
		text.double_sided=not front_only
	if bitmap: Facing.apply(bitmap.material_override,front_only)
	if hole: Facing.apply(hole.material_override,front_only)

func suspend() -> void:
	active = false
	kind = ""
	prepared = false
	_uploaded_version = -1
	if text: text.visible = false
	if bitmap: bitmap.visible = false
	if hole: hole.visible = false

static func lower_edge(size: Vector2, roll_degrees: float) -> float:
	var roll := deg_to_rad(roll_degrees)
	return -(absf(sin(roll)) * size.x + absf(cos(roll)) * size.y) * 0.5

func sync() -> void:
	if not video.panel.visible:
		suspend()
		return
	active = true
	var source: Label3D = video.caption
	var pose: Transform3D = video.subtitle_transform()
	var screen: Vector2 = video._flat.size
	var top: float = lower_edge(screen, video.screen_rotation) - 0.015 * video.screen_scale
	var texture: Texture2D = video.bitmap_subtitles.texture
	var rect: Variant = video.material.get_shader_parameter("bitmap_subtitle_rect")
	var rotation_value: Variant = video.material.get_shader_parameter("rotation_degrees")
	var rotation: int = rotation_value if rotation_value != null else 0
	var next_kind := ""
	if source and source.visible and not source.text.is_empty(): next_kind = "text"
	elif texture and rect is Vector4 and video.material.get_shader_parameter("bitmap_subtitle_enabled") == true: next_kind = "bitmap"
	var source_key: Array = [source.font]
	for field in Canvas.FIELDS: source_key.append(source.get(field))
	var next_key := [next_kind, source_key, texture, rect, rotation, pose, screen, top, source.pixel_size]
	if next_key != _key:
		_key = next_key
		prepared = false # No old cue or old pose may hide the current fallback before submission.
		if kind != next_kind: _uploaded_version = -1
	kind = next_kind
	if kind == "text":
		if _source_key != source_key:
			_source_key = source_key
			text.font = source.font
			for field in Canvas.FIELDS: text.set(field, source.get(field))
			# Grow downwards from the screen edge, including bilingual/multiline captions.
			text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		text.pixel_size = source.pixel_size
		# Top alignment grows down; reserve the enlarged outline above the glyph box as well.
		var text_top := top - (source.outline_size + 1) * source.pixel_size
		text.global_transform = Transform3D(pose.basis, pose * Vector3(0, text_top, 0.01))
		_clear_ground(text,text.get_aabb())
	elif kind == "bitmap":
		var extent := Vector2(rect.z, rect.w) * screen
		if rotation in [90, 270]: extent = Vector2(extent.y, extent.x)
		# Keep the complete authored crop (including multiple positioned regions), without clipping.
		extent *= minf(1.0, screen.x * 0.9 / maxf(extent.x, 0.0001))
		bitmap.mesh.size = extent
		bitmap.global_transform = Transform3D(pose.basis, pose * Vector3(0, top - extent.y * 0.5, 0.01))
		_clear_ground(bitmap,AABB(Vector3(-extent.x*.5,-extent.y*.5,0),Vector3(extent.x,extent.y,0)))
		bitmap.material_override.set_shader_parameter("bitmap_subtitle_texture", texture)
		bitmap.material_override.set_shader_parameter("bitmap_subtitle_enabled", true)
		bitmap.material_override.set_shader_parameter("rotation_degrees", rotation)

func _clear_ground(surface: Node3D,bounds: AABB) -> void:
	if not video.subtitle_ground_provider.is_valid(): return
	# Keep the requested below-screen anchor where it fits. On a low physical
	# screen, lift the complete cue above the sand, even if it overlaps the lower
	# image. Font size, timing and the user's below-screen preference stay intact.
	var up := surface.global_basis.y
	if up.y<=.25: return
	for attempt in 4:
		var lift := 0.0
		for x in [0.0,.25,.5,.75,1.0]:
			for y in [0.0,1.0]:
				var point: Vector3=surface.global_transform*(bounds.position+Vector3(bounds.size.x*x,bounds.size.y*y,0))
				var floor_y: float=video.subtitle_ground_provider.call(point.x,point.z)
				if is_finite(floor_y): lift=maxf(lift,floor_y+.025-point.y)
		if lift<=.0001: return
		surface.global_position+=up*(lift/up.y)

func commit(submitted: bool) -> void:
	var on_layer := active and prepared and submitted
	text.visible = active and kind == "text"
	text.layers = 0 if on_layer else 1
	bitmap.visible = active and kind == "bitmap" and not on_layer
	hole.visible = on_layer

func layer_extras(origin: XROrigin3D) -> Array:
	prepared = false
	var layers: RefCounted = video.video_layer
	if not active or kind.is_empty() or video._subtitle_layer_failed \
		or not (video._layer_session or video._frame_picture or video._processed_picture or video._binding.warped) \
		or not layers.available() or not layers.supports(0, false) \
		or not Methods.supports(video.platform, "copy_layer_texture"):
		return []
	var eyes: int = video.pip.compositor.main_eyes if video._processed_picture else (2 if video._binding.warped or video.stereo_sbs else 1)
	if layers.capacity() < eyes + 1: return []
	video._check_subtitle_generation()
	if _generation != layers.generation:
		_generation = layers.generation
		_uploaded_version = -1
	var values: PackedFloat32Array
	if kind == "text":
		if not canvas:
			canvas = Canvas.new()
			add_child(canvas)
		if not canvas.request(text, layers.runtime_image_size): return []
		if _uploaded_version != canvas.version:
			if not video._copy_subtitle_canvas(canvas.viewport):
				video._subtitle_layer_failed = true
				return []
			_uploaded_version = canvas.version
		hole.mesh.size = canvas.physical_size(text)
		hole.global_transform = canvas.pose(text)
		hole.global_basis = hole.global_basis.orthonormalized()
		hole.material_override.set_shader_parameter("menu_texture", canvas.viewport.get_texture())
		values = layers.quad_values(origin, hole.global_transform, hole.mesh.size, Layer.SUBTITLE_SLOT, Vector2(canvas.viewport.size))
		values[18] = [0, Layer.NORMAL_SUPER_SAMPLING, Layer.QUALITY_SUPER_SAMPLING][clampi(layers.supersampling, 0, 2)] if layers._settings else 0
	else:
		# Rotation stays on the existing shader fallback; no resampling or extra bitmap copy.
		if video.material.get_shader_parameter("rotation_degrees") not in [null, 0]: return []
		var texture: ImageTexture = video.bitmap_subtitles.texture
		var size := Vector2i(texture.get_size())
		if texture != video._bitmap_layer_texture:
			var bucket := Vector2i(ceili(size.x / 256.0) * 256, ceili(size.y / 64.0) * 64).max(video._bitmap_layer_size)
			if layers.runtime_image_size.x > 0 and (bucket.x > layers.runtime_image_size.x or bucket.y > layers.runtime_image_size.y): return []
			if not video._copy_bitmap_cue(bucket):
				video._subtitle_layer_failed = true
				return []
			video._bitmap_layer_texture = texture
			video._bitmap_layer_size = bucket
		hole.mesh.size = bitmap.mesh.size * Vector2(bitmap.global_basis.x.length(), bitmap.global_basis.y.length())
		hole.global_transform = bitmap.global_transform
		hole.global_basis = hole.global_basis.orthonormalized()
		hole.material_override.set_shader_parameter("menu_texture", texture)
		values = layers.quad_values(origin, hole.global_transform, hole.mesh.size, Layer.SUBTITLE_SLOT,
			Vector2(video._bitmap_layer_size), Rect2(Vector2.ZERO, Vector2(size)))
	prepared = true
	return [{"values": values, "order": Layer.OVERLAY_ORDER}]
