extends "res://scripts/ray_menu.gd"
## Hover-only replacement for the lower-left resize bracket on free flat video.
const ROTATE := 1
const TIP := "Hold either curved arrow to keep turning, or drag to rotate; release to snap to the nearest 90°."
const DRAG_START := 4.0
const HOLD_DELAY_MS := 500
const HOLD_REPEAT_MS := 650
var _language := ""
var _angle_label: Label3D
var _factor := 0.0
var _video: Node3D
var _corner := 2

func composition_root() -> Node3D: return self

func _ready() -> void:
	super()
	ray_max_distance = 100.0
	set_scene_overlay(true)
	refresh()

func _draw() -> void:
	_clear_layout()
	_backdrop.visible = false
	# Invisible bounds only constrain the shared tooltip, with room for one short sentence.
	_backdrop.mesh.size = Vector2(0.90, 0.10)
	_text_button(ROTATE, "", Vector2.ZERO, Vector2(0.30, 0.30))
	_tips[ROTATE] = I18n.t(TIP)
	var arc := MeshInstance3D.new()
	arc.mesh = _arc_mesh()
	var ink := StandardMaterial3D.new()
	ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ink.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ink.cull_mode = BaseMaterial3D.CULL_DISABLED
	ink.no_depth_test = true
	ink.albedo_color = Color(1, 1, 1, 0.9)
	ink.render_priority = 5
	arc.material_override = ink
	add_child(arc); _decorations.append(arc)
	_angle_label = _label("", Vector3(-0.09, -0.16, 0.004), TEXT_AUX)
	_angle_label.visible = false
	_language = I18n.language
	apply_scene_overlay()

func sync(video: Node3D, shown: bool, dragging: bool = false, corner: int = -1) -> void:
	_video = video
	visible = shown and video != null and video.geometry == 0 and not video.local_uri.is_empty() and video.panel.visible
	if not visible:
		clear_pointer_visuals()
		return
	if _language != I18n.language: refresh()
	var factor: float = video.panel.global_position.distance_to(video.view_camera.global_position) / 2.0 if is_instance_valid(video.view_camera) else video.screen_distance / 2.0
	factor = maxf(0.005, factor)
	var placement: Transform3D = video.global_transform * video.flat_pose
	_corner = corner if corner >= 0 else lower_left_corner(video)
	var anchor: Vector3 = video.panel.to_global(video.screen_corner(_corner)) + placement.basis.z.normalized() * 0.015 * factor
	# Share the corner's exact position. There is no floating button beside the picture.
	global_transform = Transform3D(placement.basis.orthonormalized().scaled(Vector3.ONE * factor), anchor)
	if not is_equal_approx(factor, _factor):
		_factor = factor; composition_layout_changed.emit()
	_angle_label.visible = dragging
	_angle_label.text = "%d°" % roundi(video.screen_rotation)
	if dragging: _hide_tooltip()

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand, origin, direction, tracked and not ray_hit(origin, direction).is_empty())

func _draw_pointer(hand: String, origin: Vector3, endpoint: Vector3, valid: bool, hit: bool) -> void:
	if hand != "mouse": super(hand, origin, endpoint, valid, hit)

func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not visible or not is_instance_valid(_video) or _video.corner_at(origin, direction) != _corner: return {}
	var point: Vector3 = _video.panel.to_global(_video.screen_corner(_corner))
	return {"target": ROTATE, "point": to_local(point), "distance": origin.distance_to(point), "enabled": true}

## Select the visible lower-left after a quarter/half turn, rather than an encoded image corner.
static func lower_left_corner(video: Node3D) -> int:
	var inverse: Transform3D = (video.global_transform * video.flat_pose).affine_inverse()
	var best := 2
	var score := INF
	for corner in 4:
		var point: Vector3 = inverse * video.panel.to_global(video.screen_corner(corner))
		if point.x + point.y < score:
			score = point.x + point.y; best = corner
	return best

static func _arc_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for segment in 20:
		var at := vertices.size()
		for angle in [PI + PI * 0.5 * segment / 20.0, PI + PI * 0.5 * (segment + 1) / 20.0]:
			for radius in [0.102, 0.118]: vertices.append(Vector3(cos(angle) * radius, sin(angle) * radius, 0))
		indices.append_array(PackedInt32Array([at, at + 1, at + 2, at + 2, at + 1, at + 3]))
	var at := vertices.size()
	vertices.append_array(PackedVector3Array([Vector3(0.035, -0.11, 0), Vector3(-0.015, -0.077, 0), Vector3(-0.015, -0.143, 0)]))
	indices.append_array(PackedInt32Array([at, at + 1, at + 2]))
	at = vertices.size()
	vertices.append_array(PackedVector3Array([Vector3(-0.11, 0.035, 0), Vector3(-0.143, -0.015, 0), Vector3(-0.077, -0.015, 0)]))
	indices.append_array(PackedInt32Array([at, at + 1, at + 2]))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func valid_capture(video: Node3D, grab: Dictionary) -> bool:
	return video != null and grab.has("rotate") and video.geometry == 0 and video.panel.visible \
		and video.local_uri == grab.uri and video.media.session_id == grab.session

## Intersect the unrotated placement plane, so rotating the panel never feeds back into the drag.
static func ray_angle(video: Node3D, ray: Variant) -> Variant:
	if ray == null or not ray[0].is_finite() or not ray[1].is_finite(): return null
	var inverse: Transform3D = (video.global_transform * video.flat_pose).affine_inverse()
	var origin: Vector3 = inverse * ray[0]
	var direction: Vector3 = inverse.basis * ray[1]
	if direction.z >= -0.00001 or origin.z <= 0.0: return null
	var point := origin + direction * (-origin.z / direction.z)
	# Aim through the centre is undefined. Retain the last valid angle until the ray leaves it.
	if Vector2(point.x, point.y).length() < minf(video._flat.size.x, video._flat.size.y) * 0.08: return null
	return atan2(point.y, point.x)

func begin(video: Node3D, hand: String, ray: Variant) -> Dictionary:
	var corner := lower_left_corner(video)
	if ray == null or video.corner_at(ray[0], ray[1]) != corner: return {}
	var angle: Variant = ray_angle(video, ray)
	if angle == null: return {}
	var placement: Transform3D = video.global_transform * video.flat_pose
	var inverse := placement.affine_inverse()
	var origin: Vector3 = inverse * ray[0]
	var direction: Vector3 = inverse.basis * ray[1]
	var local_corner: Vector3 = inverse * video.panel.to_global(video.screen_corner(corner))
	var offset := origin + direction * ((local_corner.z - origin.z) / direction.z) - local_corner
	return {"hand": hand, "uri": video.local_uri, "session": video.media.session_id, "moved": false,
		"rotate": {"start": video.screen_rotation, "last": float(angle), "travel": 0.0, "corner": corner,
			"dragging": false, "hold_direction": -1.0 if offset.x > offset.y + 0.001 else 1.0,
			"next_hold": Time.get_ticks_msec() + HOLD_DELAY_MS}}

static func drag(video: Node3D, grab: Dictionary, ray: Variant) -> void:
	if not valid_capture(video, grab): return
	var angle: Variant = ray_angle(video, ray)
	var turn: Dictionary = grab.rotate
	if angle == null:
		turn["rebase"] = true
		return
	if turn.get("rebase", false):
		turn.last = float(angle); turn.erase("rebase")
		return
	turn.travel -= rad_to_deg(wrapf(float(angle) - float(turn.last), -PI, PI))
	turn.last = float(angle)
	if not turn.dragging:
		if absf(turn.travel) < DRAG_START: return
		turn.dragging = true
		turn.start = video.screen_rotation
	grab.moved = true
	video.set_screen_rotation(float(turn.start) + float(turn.travel))

static func hold_tick(video: Node3D, grab: Dictionary, now_ms: int) -> void:
	if not valid_capture(video, grab) or grab.rotate.dragging or now_ms < int(grab.rotate.next_hold): return
	video.set_screen_rotation(roundf(video.screen_rotation / 90.0) * 90.0 + 90.0 * float(grab.rotate.hold_direction))
	grab.moved = true
	# One step per interval, including after a slow frame; never burst through missed steps.
	grab.rotate.next_hold = now_ms + HOLD_REPEAT_MS

static func finish(video: Node3D, grab: Dictionary, _cancelled: bool = false) -> bool:
	if not valid_capture(video, grab) or not grab.moved: return false
	video.set_screen_rotation(roundf(video.screen_rotation / 90.0) * 90.0)
	return true
