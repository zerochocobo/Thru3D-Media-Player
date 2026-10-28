extends "res://scripts/library_menu.gd"
signal puzzle_requested
# Outside the browser home range (985000+); 985001 was its Open button.
const PUZZLE_OPEN := 984995
var puzzle_progress_provider: Callable
var puzzle_mode_provider: Callable

func _draw() -> void:
	super._draw()
	var images := media_filter==2 and section not in [Section.SETTINGS,Section.MEDIA_SERVER]
	var progress := puzzle_progress_provider.is_valid() and bool(puzzle_progress_provider.call())
	# The browser has nothing to do with puzzles; the button only crowded its footer.
	if (images or progress) and section != Section.WEB and not audio_import_mode and not subtitle_picker_mode and not image_picker_mode and not compact and not collections.active() and file_actions.modal.is_empty() and not account_panel.active() and not controls_page.active():
		var y := -0.80 if section==Section.MEDIA_SERVER and server_browser.focused() else -0.65
		_round(PUZZLE_OPEN,"puzzle",Vector2(-0.36,y),0.08,true,puzzle_mode_provider.is_valid() and bool(puzzle_mode_provider.call()),I18n.t("Puzzle mode" if images else "Unfinished games"))

func _activate(target: int) -> void:
	if target==PUZZLE_OPEN:
		if not audio_import_mode and not subtitle_picker_mode and not image_picker_mode: puzzle_requested.emit()
		return
	super._activate(target)
