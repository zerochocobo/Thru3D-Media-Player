extends "res://scripts/ray_menu.gd"
## Reuses flat-screen corner hit areas and the rotation companion's angular sizing.
const LOCK := 1
var _video: Node3D
var _locked := false
var _language := ""
var _factor := 0.0

func composition_root() -> Node3D: return self

func _ready() -> void:
	super(); ray_max_distance = 100.0; set_scene_overlay(true); refresh()

func _draw() -> void:
	_clear_layout(); _backdrop.visible = false
	_backdrop.mesh.size = Vector2(0.55, 0.10)
	_glyph(LOCK, "lock" if _locked else "unlock", Vector2.ZERO, 0.12, true, I18n.t("Unlock screen" if _locked else "Lock screen"))
	_language = I18n.language; apply_scene_overlay()

static func upper_left_corner(video: Node3D) -> int:
	var inverse: Transform3D = (video.global_transform * video.flat_pose).affine_inverse()
	var best := 0
	var score := INF
	for corner in 4:
		var point: Vector3 = inverse * video.panel.to_global(video.screen_corner(corner))
		if point.x - point.y < score: score = point.x - point.y; best = corner
	return best

func sync(video: Node3D, shown: bool, locked: bool) -> void:
	_video = video
	visible = shown and video != null and video.panel.visible
	if not visible: clear_pointer_visuals(); return
	if _locked != locked or _language != I18n.language:
		_locked = locked; refresh()
	var factor: float = video.panel.global_position.distance_to(video.view_camera.global_position) / 2.0 if is_instance_valid(video.view_camera) else video.screen_distance / 2.0
	factor = maxf(0.005, factor)
	var placement: Transform3D = video.global_transform * video.flat_pose
	var anchor: Vector3 = video.panel.to_global(video.screen_corner(upper_left_corner(video))) + placement.basis.z.normalized() * 0.015 * factor
	global_transform = Transform3D(placement.basis.orthonormalized().scaled(Vector3.ONE * factor), anchor)
	if not is_equal_approx(factor, _factor): _factor = factor; composition_layout_changed.emit()

func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not visible or not is_instance_valid(_video) or _video.corner_at(origin, direction) != upper_left_corner(_video): return {}
	var point: Vector3 = _video.panel.to_global(_video.screen_corner(upper_left_corner(_video)))
	return {"target": LOCK, "point": to_local(point), "distance": origin.distance_to(point), "enabled": true}

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand, origin, direction, tracked and not ray_hit(origin, direction).is_empty())

func _draw_pointer(hand: String, origin: Vector3, endpoint: Vector3, valid: bool, hit: bool) -> void:
	if hand != "mouse": super(hand, origin, endpoint, valid, hit)
