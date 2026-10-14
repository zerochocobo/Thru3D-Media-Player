extends RefCounted
## Session-only placement. Head movement changes H, never the saved local transform L.
## Explicit placement/dragging updates L; no settings file stores this mode or these poses.
var enabled := false
var _poses: Dictionary = {}

func set_enabled(value: bool) -> void:
	if enabled == value: return
	enabled = value
	_poses.clear()

func capture(key: StringName, head: Transform3D, world: Transform3D) -> void:
	if enabled: _poses[key] = head.affine_inverse() * world

func forget(key: StringName) -> void: _poses.erase(key)

func pose(key: StringName, head: Transform3D) -> Variant:
	return head * _poses[key] if enabled and _poses.has(key) else null
