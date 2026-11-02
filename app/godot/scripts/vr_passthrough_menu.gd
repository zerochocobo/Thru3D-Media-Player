extends "res://scripts/ray_menu.gd"
signal exit_requested
const OFFSET := Vector3(0, -0.38, -1.2)

func _ready() -> void:
	super._ready()
	refresh()

func _draw() -> void:
	_clear_layout()
	_backdrop.visible = false
	_button(1, I18n.t("Disable temporary passthrough"), Vector2.ZERO, Vector2(0.48, 0.095), true, "", true)
	set_scene_overlay(true) # The short unfolding surface must never hide the exit control.

func follow_head(head: Transform3D) -> void:
	global_transform = head * Transform3D(Basis.IDENTITY, OFFSET)

func _activate(target: int) -> void:
	if target == 1: exit_requested.emit()

func has_pointer_capture() -> bool: return false
func grab_hit(origin: Vector3, direction: Vector3) -> Dictionary: return ray_hit(origin, direction)
func composition_root() -> Node3D: return self
func composition_visible() -> bool: return visible
