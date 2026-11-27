extends RefCounted
## One world-fixed mesh for the current adjustment, shared by photos and videos.
const Placement := preload("res://scripts/cinema_placement.gd")
const MEDIA_KEY := "grid_media"
const DEFAULT_MEDIA := "video"
const MEDIA_MODES := ["off", DEFAULT_MEDIA, "video_photo"]
var mesh: MeshInstance3D

static func load_media(settings: ConfigFile) -> String:
	if settings.has_section_key("ui", MEDIA_KEY):
		var value: Variant = settings.get_value("ui", MEDIA_KEY)
		return value if value is String and value in MEDIA_MODES else DEFAULT_MEDIA
	# Keep an explicit old choice. Photos-only maps to Off to keep the video grid disabled.
	var legacy: Variant = settings.get_value("ui", "grid_for_video", DEFAULT_MEDIA)
	if legacy is bool: return "video_photo" if legacy else "off"
	return DEFAULT_MEDIA

func hide() -> void:
	if is_instance_valid(mesh): mesh.hide()

func show_for(anchor: Node3D, head: Transform3D, fixed_pose: Variant = null, drop: float = 1.25) -> void:
	if not anchor.is_visible_in_tree():
		hide()
		return
	if not is_instance_valid(mesh):
		mesh = MeshInstance3D.new()
		mesh.name = "ScreenAdjustmentGrid"
		mesh.mesh = _build_mesh()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.top_level = true
		mesh.hide()
	if mesh.get_parent() != anchor:
		var previous := mesh.get_parent()
		if previous:
			previous.visibility_changed.disconnect(_anchor_visibility_changed)
			previous.remove_child(mesh)
		anchor.add_child(mesh)
		anchor.visibility_changed.connect(_anchor_visibility_changed)
		mesh.hide()
	if not mesh.visible:
		mesh.global_transform = fixed_pose if fixed_pose is Transform3D else Transform3D(Placement.upright(head.basis), head.origin - Vector3.UP * drop)
		mesh.show()

func _anchor_visibility_changed() -> void:
	if not mesh.get_parent().is_visible_in_tree(): hide()

static func _build_mesh() -> ImmediateMesh:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.075, 0.11, 0.13)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var grid := ImmediateMesh.new()
	grid.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for x in range(-20, 21, 2): _strip(grid, Vector3(x, 0, -0.5), Vector3(x, 0, -60), Vector3(0.008, 0, 0))
	for z in range(1, 11) + range(15, 61, 5): _strip(grid, Vector3(-20, 0, -z), Vector3(20, 0, -z), Vector3(0, 0, 0.008))
	grid.surface_end()
	return grid

static func _strip(grid: ImmediateMesh, a: Vector3, b: Vector3, width: Vector3) -> void:
	for point in [a - width, b - width, b + width, a - width, b + width, a + width]: grid.surface_add_vertex(point)
