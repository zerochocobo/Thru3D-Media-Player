extends "res://scripts/library_menu.gd"
signal puzzle_requested
# Outside the browser home range (985000+); 985001 was its Open button.
const PUZZLE_OPEN := 984995
var puzzle_progress_provider: Callable
var puzzle_mode_provider: Callable

func _draw() -> void:
	super._draw()

func _activate(target: int) -> void:
	if target==PUZZLE_OPEN:
		if not audio_import_mode and not subtitle_picker_mode and not image_picker_mode: puzzle_requested.emit()
		return
	super._activate(target)
