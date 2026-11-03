extends "res://scripts/photo_menu.gd"
const PHOTO_PUZZLE := 519
var puzzle_mode_provider: Callable

func _bar_action_x(target: int) -> float:
	return super._bar_action_x(target)

func _draw_bar() -> void:
	super._draw_bar()

func _activate(target: int) -> void:
	if target==PHOTO_PUZZLE:
		action_requested.emit("photo_puzzle"); return
	super._activate(target)
