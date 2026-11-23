extends "res://scripts/photo_menu.gd"
const PHOTO_PUZZLE := 519
var puzzle_mode_provider: Callable

# The puzzle sits between music and the layout button; music moves one slot left to make room.
func _bar_action_x(target: int) -> float:
	if target==PHOTO_PUZZLE: return -0.56 if _bar_has_return() else -0.42
	if target==PHOTO_AUDIO: return -0.70 if _bar_has_return() else -0.56
	return super._bar_action_x(target)

func _draw_bar() -> void:
	super._draw_bar()
	if _scenery_open: return
	_round(PHOTO_PUZZLE,"puzzle",Vector2(_bar_action_x(PHOTO_PUZZLE),0.215),0.08,
		true,puzzle_mode_provider.is_valid() and bool(puzzle_mode_provider.call()),I18n.t("Puzzle mode"))
	_expand_bar_action_hits()

func _activate(target: int) -> void:
	if target==PHOTO_PUZZLE:
		action_requested.emit("photo_puzzle"); return
	super._activate(target)
