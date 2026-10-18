extends "res://scripts/ray_menu.gd"
signal requested
var companion: Node3D
func composition_root() -> Node3D:
	return companion if is_instance_valid(companion) and companion.is_visible_in_tree() else self
func _place_device_status(_centre: Vector2) -> void: pass
func _draw() -> void:
	_clear_layout(); _set_backdrop(Vector2(0.001,0.001)); _backdrop.visible=false
	_button(1,"",Vector2.ZERO,Vector2(0.32,0.075))
	_icon("puzzle",Vector3(-0.115,0,0.008),0.032,Color(0.93,0.95,0.98))
	_label(_fit_title(I18n.t("Enter puzzle game"),"",0.23,18),Vector3(0.025,0,0.008),18)
func _activate(_target: int) -> void: requested.emit()
