extends "res://scripts/photo_menu.gd"
const PHOTO_PUZZLE := 519
var puzzle_mode_provider: Callable

func _bar_action_x(target: int) -> float:
	return {PHOTO_AUDIO:-0.55,PHOTO_PUZZLE:-0.44,PHOTO_RETURN:-0.33,PHOTO_LAYOUT:-0.22,
		107:-0.11,100:0.0,108:0.11,FAVORITE:0.22,PHOTO_SHUFFLE:0.44}.get(target,0.0)

func _draw_bar() -> void:
	super._draw_bar()
	_round(PHOTO_PUZZLE,"puzzle",Vector2(_bar_action_x(PHOTO_PUZZLE),0.215),0.08,
		true,puzzle_mode_provider.is_valid() and bool(puzzle_mode_provider.call()),I18n.t("Puzzle mode"))

func _activate(target: int) -> void:
	if target==PHOTO_PUZZLE:
		action_requested.emit("photo_puzzle"); return
	super._activate(target)
