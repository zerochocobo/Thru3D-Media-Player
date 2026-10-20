extends "res://scripts/ray_menu.gd"
## One ray-operated surface for the global library and the photo mini player.
signal close_requested
signal import_requested(destination: String)
const ChoiceFields := preload("res://scripts/choice_fields.gd")
const StorageView := preload("res://scripts/audio_storage_view.gd")
const SELECTED := Color(0.16, 0.31, 0.27)
const ROW := 100
const MORE := 200
const TAB := 300
const BACK := 400
const PLAY := 401
const PREV_TRACK := 402
const NEXT_TRACK := 403
const QUEUE := 404
const MODE := 405
const ADD_FILES := 406
const NEW_LIST := 407
const ADD_TRACKS := 408
const RENAME := 409
const DELETE_LIST := 410
const REMOVE_TRACK := 411
const DELETE_FILE := 414
const CONFIRM := 415
const SAVE_NAME := 416
const ERASE := 417
const SPACE := 418
const SHIFT := 419
const KEY := 500
const CANCEL_IMPORT := 420
const RETRY_IMPORT := 421
const ADD_TO_LIST := 422
const PLAY_LIST := 423
const VOLUME := 424
const MUTE := 425
const MINIMIZE := 426
const DOCK := 433
const SETTINGS := 434
const SOURCE := 427
const EDIT_LIST := 428
const LIST_OPTIONS := 429
const DONE := 430
const FROM_LIBRARY := 431
const CANCEL := 432
const INLINE_UP := 600
const INLINE_DOWN := 610
const INLINE_REMOVE := 620
const LIST_ROWS := 5
const KEYS := ["1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm_.+"]
var choices := ChoiceFields.new(self)
var audio: Node
var compact := false
var _volume_open := false
var _unmuted_volume := 45.0
var editing := false
var selected_tracks: Array[String] = []
var _modal_history: Array[Dictionary] = []
var _list_offset := 0
var _add_return_offset := 0
var view := "lists"
var playlist_id := ""
var filter := "all"
var offset := 0
var modal := ""
var target_track := ""
var target_playlist := ""
var name_text := ""
var shift := false
var _state := {}
var _rows: Array[Dictionary] = []
var _drag := {}
var _scroll := 0.0
var _refresh_at := 0
var _shown := ""
var _time: Label3D
var _duration: Label3D
var _notice: Label3D
var _storage_labels: Array[Label3D] = []

func _ready() -> void:
	super()
	choices.changed.connect(_choice_changed)
	choices.previewed.connect(_choice_previewed)

func open(_mini: bool) -> void:
	compact = true; _volume_open = false; modal = ""; editing = false; _modal_history.clear(); choices.reset(); _drag.clear()
	if view == "add": view = "tracks"; offset = _add_return_offset
	selected_tracks.clear()
	visible = true; refresh()

func dismiss() -> void:
	choices.reset(); _drag.clear(); super()

func has_pointer_capture() -> bool: return not choices.capture.is_empty() or not _drag.is_empty()
func allows_playback_sticks() -> bool: return false

func navigate_back() -> bool:
	if has_pointer_capture():
		for hand in ["left_hand", "right_hand"]: cancel_pointer(hand)
	elif not choices.opened.is_empty(): choices.reset()
	elif _volume_open: _volume_open = false
	elif not modal.is_empty(): _close_modal()
	elif compact: return false
	elif view == "add": view = "tracks"; selected_tracks.clear(); offset = _add_return_offset
	elif editing: editing = false
	elif view == "tracks": view = "lists"; offset = _list_offset
	else: compact = true
	refresh(); return true

func _open_modal(value: String) -> void:
	_modal_history.append({"modal": modal, "offset": offset})
	modal = value; offset = 0

func _close_modal(all: bool = false) -> void:
	if _modal_history.is_empty(): modal = ""; return
	var previous: Dictionary = _modal_history[0] if all else _modal_history.back()
	if all: _modal_history.clear()
	else: _modal_history.pop_back()
	modal = str(previous.modal); offset = int(previous.offset)

func _capacity() -> int:
	return 6 if view == "lists" and modal.is_empty() else LIST_ROWS

func _playlist_label(row: Dictionary) -> String:
	return I18n.t(str(row.get("label", ""))) if row.get("builtin", false) else str(row.get("label", ""))

static func _track_icon(row: Dictionary) -> String:
	if row.get("kind", "") != "ambience": return "music"
	return {"mountain_stream": "water", "ocean_waves": "water", "gentle_rain": "rain", "summer_night": "night", "distant_city": "city"}.get(str(row.get("id", "")), "ambience")

func _source_caption() -> String:
	if audio.current.is_empty(): return I18n.t("Choose audio")
	var source: Dictionary = audio.library.playlist(audio.queue_source)
	if not source.is_empty(): return I18n.t("Playlist") + " · " + _playlist_label(source)
	return I18n.t("Audio library") if audio.queue_source.is_empty() else str(audio.queue_name) + " · " + I18n.t("Queue")

func _key() -> String:
	var value := _state.duplicate()
	for field in ["audio_position", "audio_progress", "audio_storage"]: value.erase(field)
	return str(value)

func refresh() -> void:
	if not audio: return
	_state = audio.snapshot(); _draw(); _shown = _key()
	composition_changed.emit()

func refresh_values() -> void:
	if not visible or not audio: return
	_state = audio.snapshot()
	if not has_pointer_capture() and _shown != _key(): refresh(); return
	for id in choices.sliders:
		if choices.targets[id].key == "audio_seek":
			if choices.capture.get("target", -1) != id: choices._refresh_slider(id, float(_state.audio_position))
			choices.sliders[id].label.visible = false
	if is_instance_valid(_time):
		var value := float(choices.capture.get("value", _state.audio_position)) if choices.capture.get("item", {}).get("key", "") == "audio_seek" else float(_state.audio_position)
		_time.text = _clock(value)
	if is_instance_valid(_duration): _duration.text = _clock(float(_state.audio_duration))
	if is_instance_valid(_notice): _notice.text = _fit_title(_status(), "", 0.90 if compact else 1.05, TEXT_AUX)
	StorageView.update(self, _storage_labels, _state)
	composition_changed.emit()

func _process(_delta: float) -> void:
	if visible and Time.get_ticks_msec() >= _refresh_at:
		_refresh_at = Time.get_ticks_msec() + 250; refresh_values()

static func _clock(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]

func _status() -> String:
	if _state.get("audio_importing", false):
		var percent := float(_state.audio_progress)
		return I18n.t("Saving to device") + ("  %d%%" % roundi(percent * 100) if percent >= 0 else "") + ("  (+%d)" % int(_state.audio_pending) if int(_state.audio_pending) > 0 else "")
	if not str(_state.get("audio_error", "")).is_empty(): return I18n.t(_state.audio_error)
	if int(_state.get("audio_failed", 0)) > 0: return I18n.t("Imports failed: %d") % int(_state.audio_failed)
	if _state.get("audio_blocked", false): return I18n.t("Audio suspended")
	if _state.get("audio_loading", false): return I18n.t("Loading audio")
	return ""

func _text_action(id: int, title: String, y: float, enabled: bool = true) -> void:
	_button(id, _fit_title(I18n.t(title), "", 1.02, TEXT_BODY), Vector2(0, y), Vector2(1.10, 0.085), enabled)
	set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)

func _caption(text: String, point: Vector2, width: float, font_size: int = 18, ink: Color = MUTED) -> Label3D:
	var label := _label(_fit_title(text, "", width, font_size), Vector3(point.x, point.y, 0.004), font_size)
	label.set_meta("music_text_width", width)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = ink
	return label

func _pill(id: int, text: String, point: Vector2, width: float, enabled: bool = true, primary: bool = false) -> void:
	_button(id, _fit_title(I18n.t(text), "", width - 0.035, 18), point, Vector2(width, 0.075), enabled, "", primary)
	set_label_size(_buttons.back().node.get_child(0), 18)

func _draw() -> void:
	_clear_layout(); _time = null; _duration = null; _notice = null; _storage_labels.clear()
	choices.begin(str([compact, view, playlist_id, modal, filter]), Vector2(-0.39, 0.31))
	var panel_size := Vector2(1.14, 0.54) if compact else Vector2(1.42, 1.22)
	if not modal.is_empty(): panel_size = Vector2(1.42, 1.12) if modal == "name" else Vector2(1.20, 1.0 if modal == "choose_list" else 0.90)
	if modal == "settings": panel_size = Vector2(1.14, 0.60)
	_set_backdrop(panel_size, Vector2.ZERO)
	_block_rays(_backdrop, _backdrop.mesh.size)
	if not modal.is_empty():
		_glyph(BACK, "up", Vector2(-panel_size.x / 2 + 0.09, panel_size.y / 2 - 0.075), 0.075, true, I18n.t("Back"))
		_glyph(CLOSE, "close", Vector2(panel_size.x / 2 - 0.09, panel_size.y / 2 - 0.075), 0.075, true, I18n.t("Close"))
		_draw_modal(); _draw_status(-panel_size.y / 2 + 0.035); choices.finish(); return
	if compact:
		_text_button(SOURCE, "", Vector2(-0.18, 0.205), Vector2(0.68, 0.075))
		_caption(_source_caption(), Vector2(-0.49, 0.205), 0.62, 16)
		_tips[SOURCE] = _source_caption()
		_glyph(QUEUE, "list", Vector2(0.22, 0.205), 0.075, true, I18n.t("Queue"))
		_glyph(SETTINGS, "settings", Vector2(0.35, 0.205), 0.075, true, I18n.t("Settings"))
		_glyph(CLOSE, "close", Vector2(0.48, 0.205), 0.075, true, I18n.t("Close"))
		_draw_transport(); _draw_status(-0.23); choices.finish(); return
	_glyph(BACK, "up", Vector2(-0.60, 0.52), 0.075, true, I18n.t("Back"))
	_label(I18n.t("Music"), Vector3(0, 0.52, 0.004), TEXT_PAGE_TITLE).font = ui_bold_font()
	if view != "add": _glyph(MINIMIZE, "collapse", Vector2(0.34, 0.52), 0.075, true, I18n.t("Now playing"))
	_glyph(SETTINGS, "settings", Vector2(0.47, 0.52), 0.075, true, I18n.t("Settings"))
	_glyph(CLOSE, "close", Vector2(0.60, 0.52), 0.075, true, I18n.t("Close"))
	if view == "add":
		_caption(I18n.t("Add tracks") + " · " + _playlist_label(audio.library.playlist(playlist_id)), Vector2(-0.60, 0.40), 0.91, 21, Color.WHITE)
		_pill(DONE, "Done", Vector2(0.51, 0.40), 0.22, true, true)
	else:
		for i in 3:
			var active: bool = view in [["lists", "tracks"], ["all"], ["queue"]][i]
			_text_button(TAB + i, I18n.t(["Playlists", "Audio library", "Queue"][i]), Vector2(-0.43 + i * 0.43, 0.40), Vector2(0.41, 0.075))
			if active:
				_buttons.back().node.get_child(0).modulate = ACCENT; _buttons.back().foreground = ACCENT
				var underline := _quad(Vector2(0.33, 0.004), Vector3(-0.43 + i * 0.43, 0.355, 0.004), ACCENT, 12)
				add_child(underline); _decorations.append(underline)
	_collect_rows()
	_draw_toolbar()
	offset = clampi(offset, 0, maxi(0, _rows.size() - _capacity()))
	if view == "lists": _draw_playlist_cards()
	else: _draw_track_rows()
	if _rows.is_empty():
		_icon("list" if view in ["tracks", "queue"] else "music", Vector3(0, 0.06, 0.004), 0.08, MUTED)
		_label(I18n.t("No tracks yet"), Vector3(0, -0.055, 0.004), 20).modulate = MUTED
		if view == "tracks" and not audio.library.playlist(playlist_id).get("builtin", true): _pill(ADD_TRACKS, "Add tracks", Vector2(0, -0.18), 0.40, true, true)
		elif view == "queue": _pill(TAB, "Playlists", Vector2(0, -0.18), 0.40, true, true)
	_draw_paging(-0.35)
	_draw_dock(); _draw_status(-0.575); choices.finish()

func _draw_video_switch(y: float) -> void:
	var width := 0.96
	var title := _caption(I18n.t("Play music during video"), Vector2(-width / 2, y), width - 0.15, TEXT_BODY)
	var switch_x := title.position.x + text_width(title.text, TEXT_BODY) + 0.03 + 0.045
	choices.field(null, {"key": "audio_play_during_video", "value": _state.audio_play_during_video, "switch": true, "choices": [], "hint": "Play music during video"}, Vector2(switch_x, y), 0.09, 0.05)

func _collect_rows() -> void:
	_rows.clear()
	if view == "lists": _rows = audio.library.all_playlists()
	elif view == "tracks":
		var list: Dictionary = audio.library.playlist(playlist_id)
		for id in list.get("tracks", []):
			var row: Dictionary = audio.library.resolve(str(id))
			if not row.is_empty(): _rows.append(row)
	elif view == "queue":
		for id in audio.queue:
			var row: Dictionary = audio.library.resolve(str(id))
			if not row.is_empty(): _rows.append(row)
	else:
		for row in audio.library.all_tracks():
			if view == "add" or filter == "all" or (filter == "imported" and str(row.id).begins_with("import_")) or row.get("kind", "") == filter: _rows.append(row)

func _draw_toolbar() -> void:
	var y := 0.275
	if view == "lists":
		_caption(I18n.t("%d playlists") % _rows.size(), Vector2(-0.60, y), 0.65)
		_pill(NEW_LIST, "New playlist", Vector2(0.45, y), 0.34)
	elif view == "all":
		choices.field(null, {"key": "audio_filter", "value": filter, "choices": [{"value": "all", "label": "All"}, {"value": "music", "label": "Music"}, {"value": "ambience", "label": "Ambience"}, {"value": "imported", "label": "Imported audio"}]}, Vector2(-0.34, y), 0.52, 0.075)
		_pill(ADD_FILES, "Import audio", Vector2(0.45, y), 0.34)
	elif view == "add":
		_caption(I18n.t("%d selected") % selected_tracks.size(), Vector2(-0.60, y), 0.70)
		_pill(CANCEL, "Cancel", Vector2(0.51, y), 0.22)
	elif view == "queue":
		_caption(_source_caption(), Vector2(-0.60, y), 0.89)
		_caption("%d / %d" % [maxi(0, audio.queue.find(audio.current) + 1), _rows.size()], Vector2(0.40, y), 0.22, 16)
	else:
		var list: Dictionary = audio.library.playlist(playlist_id)
		_caption(_playlist_label(list), Vector2(-0.60, y + 0.018), 0.66, 21, Color.WHITE)
		_caption(I18n.t("%d sounds" if playlist_id == "ambience" else "%d tracks") % _rows.size(), Vector2(-0.60, y - 0.022), 0.50, 14)
		if editing: _pill(EDIT_LIST, "Done", Vector2(0.49, y), 0.26, true, true)
		else:
			_round(PLAY_LIST, "play", Vector2(0.17, y), 0.075, not _rows.is_empty(), true, I18n.t("Play playlist"))
			if not list.get("builtin", true):
				if not _rows.is_empty(): _glyph(ADD_TRACKS, "plus", Vector2(0.31, y), 0.075, true, I18n.t("Add tracks"))
				_glyph(EDIT_LIST, "edit", Vector2(0.45, y), 0.075, not _rows.is_empty(), I18n.t("Organize tracks"))
				_glyph(LIST_OPTIONS, "more", Vector2(0.59, y), 0.075, true, I18n.t("Playlist options"))

func _draw_playlist_cards() -> void:
	for i in mini(_capacity(), _rows.size() - offset):
		var row: Dictionary = _rows[offset + i]
		var centre := Vector2(-0.33 + (i % 2) * 0.66, 0.135 - (i / 2) * 0.16)
		_button(ROW + i, "", centre, Vector2(0.61, 0.14))
		var node: MeshInstance3D = _buttons.back().node
		_icon("ambience" if row.id == "ambience" else ("music" if row.builtin else "list"), Vector3(-0.25, 0.024, 0.004), 0.038, ACCENT if row.id == audio.queue_source else MUTED, node)
		var name_label := _label(_fit_title(_playlist_label(row), "", 0.40, 20), Vector3(-0.21, 0.024, 0.004), 20, node)
		name_label.set_meta("music_text_width", 0.40)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var detail := I18n.t("%d sounds" if row.id == "ambience" else "%d tracks") % row.tracks.size()
		if row.builtin: detail += " · " + I18n.t("Built-in")
		var subtitle := _label(_fit_title(detail, "", 0.42, TEXT_AUX), Vector3(-0.25, -0.035, 0.004), TEXT_AUX, node)
		subtitle.set_meta("music_text_width", 0.42)
		subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; subtitle.modulate = MUTED
		_tips[ROW + i] = _playlist_label(row)
		if row.id == audio.queue_source: name_label.modulate = ACCENT
		if not row.builtin: _glyph(MORE + i, "more", centre + Vector2(0.25, -0.035), 0.065, true, I18n.t("Playlist options")); _buttons.back().node.position.z = 0.012

func _draw_track_rows() -> void:
	for i in mini(LIST_ROWS, _rows.size() - offset):
		var row: Dictionary = _rows[offset + i]; var y := 0.15 - i * 0.10
		var marked: bool = selected_tracks.has(str(row.id)) if view == "add" else str(row.id) == audio.current
		var width := 0.94 if editing else 1.12
		_button(ROW + i, "", Vector2(-0.62 + width / 2, y), Vector2(width, 0.088), not editing)
		var node: MeshInstance3D = _buttons.back().node
		var ink := ACCENT if marked else Color.WHITE
		if marked:
			_buttons.back().base_color = SELECTED; node.material_override.set_shader_parameter("surface_color", SELECTED)
		var leading := "check" if view == "add" and marked else ("checkbox" if view == "add" else ("pause" if marked and not audio.paused else _track_icon(row)))
		if view == "queue" and not marked:
			_label(str(offset + i + 1), Vector3(-width / 2 + 0.045, 0, 0.004), TEXT_AUX, node).modulate = MUTED
		else: _icon(leading, Vector3(-width / 2 + 0.045, 0, 0.004), 0.030, ink if marked else MUTED, node)
		var title_width := width - (0.36 if view == "all" else 0.16)
		var label := _label(_fit_title(I18n.t(str(row.label)), "", title_width, 20), Vector3(-width / 2 + 0.09, 0, 0.004), 20, node)
		label.set_meta("music_text_width", title_width)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = ink
		_tips[ROW + i] = I18n.t(str(row.label))
		if view == "all":
			var kind := "Imported audio" if str(row.id).begins_with("import_") else ("Ambience" if row.get("kind", "") == "ambience" else "Music")
			var category := _label(_fit_title(I18n.t(kind), "", 0.20, TEXT_AUX), Vector3(width / 2 - 0.025, 0, 0.004), TEXT_AUX, node)
			category.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; category.modulate = MUTED; category.set_meta("music_text_width", 0.20)
		if editing:
			_glyph(INLINE_UP + i, "arrow_up", Vector2(0.38, y), 0.070, offset + i > 0, I18n.t("Move up"))
			_glyph(INLINE_DOWN + i, "arrow_down", Vector2(0.48, y), 0.070, offset + i + 1 < _rows.size(), I18n.t("Move down"))
			_glyph(INLINE_REMOVE + i, "minus", Vector2(0.59, y), 0.070, true, I18n.t("Remove from playlist"))
		elif view != "add": _glyph(MORE + i, "more", Vector2(0.59, y), 0.075, true, I18n.t("Track options"))

func _draw_paging(y: float) -> void:
	if _rows.size() <= _capacity(): return
	_glyph(PREVIOUS, "scroll_up", Vector2(-0.54, y), 0.065, offset > 0, I18n.t("Previous"))
	_label("%d–%d / %d" % [offset + 1, mini(offset + _capacity(), _rows.size()), _rows.size()], Vector3(0, y, 0.004), TEXT_AUX).modulate = MUTED
	_glyph(NEXT, "scroll_down", Vector2(0.54, y), 0.065, offset + _capacity() < _rows.size(), I18n.t("Next"))

func _draw_dock() -> void:
	var line := _quad(Vector2(1.24, 0.002), Vector3(0, -0.405, 0.004), TILE, 12)
	add_child(line); _decorations.append(line)
	_text_button(DOCK, "", Vector2(-0.23, -0.48), Vector2(0.78, 0.12), view != "add")
	_caption(I18n.t(str(_state.audio_title)), Vector2(-0.59, -0.455), 0.72, 20, Color.WHITE)
	_caption(_source_caption(), Vector2(-0.59, -0.505), 0.72, 14)
	_tips[DOCK] = I18n.t("Now playing")
	_glyph(PREV_TRACK, "previous_video", Vector2(0.24, -0.48), 0.080, audio.can_advance(-1), I18n.t("Previous"))
	_round(PLAY, "play" if audio.paused else "pause", Vector2(0.39, -0.48), 0.095, true, true, I18n.t("Play" if audio.paused else "Pause"))
	_glyph(NEXT_TRACK, "next_video", Vector2(0.54, -0.48), 0.080, audio.can_advance(1), I18n.t("Next"))

func _draw_status(y: float) -> void:
	_notice = _label(_fit_title(_status(), "", 0.90 if compact else 1.05, TEXT_AUX), Vector3(-0.035, y, 0.004), TEXT_AUX); _notice.modulate = MUTED
	var action_x: float = _backdrop.mesh.size.x / 2 - 0.065
	if _state.audio_importing: _glyph(CANCEL_IMPORT, "close", Vector2(action_x, y), 0.05, true, I18n.t("Cancel import"))
	elif int(_state.audio_failed) > 0: _glyph(RETRY_IMPORT, "refresh", Vector2(action_x, y), 0.05, true, I18n.t("Retry"))

func _draw_transport() -> void:
	var title := _label(_fit_title(I18n.t(str(_state.audio_title)), "", 0.96, 24), Vector3(0, 0.105, 0.004), 24)
	title.font = ui_bold_font()
	var seek_y := 0.025
	var width := 1.0
	if float(_state.audio_duration) > 0:
		choices.field(null, {"key": "audio_seek", "value": _state.audio_position, "slider": true, "span": Vector3(0, float(_state.audio_duration), 0.1), "unit": "", "source_uri": _state.audio_current, "hide_value": true}, Vector2(0, seek_y), width, 0.06)
		_buttons.back().enabled = not _volume_open
	else:
		var rail := _quad(Vector2(width - 0.03, 0.007), Vector3(0, seek_y, 0.004), MUTED, 14)
		add_child(rail); _decorations.append(rail)
	_time = _label(_clock(float(_state.audio_position)), Vector3(-width / 2 + 0.015, seek_y - 0.043, 0.004), 14)
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; _time.modulate = MUTED
	_duration = _label(_clock(float(_state.audio_duration)), Vector3(width / 2 - 0.015, seek_y - 0.043, 0.004), 14)
	_duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; _duration.modulate = MUTED
	var y := -0.13
	_glyph(PREV_TRACK, "previous_video", Vector2(-0.15, y), 0.085, audio.can_advance(-1), I18n.t("Previous"))
	_round(PLAY, "play" if _state.audio_paused else "pause", Vector2(0, y), 0.115, true, true, I18n.t("Play" if _state.audio_paused else "Pause"))
	_glyph(NEXT_TRACK, "next_video", Vector2(0.15, y), 0.085, audio.can_advance(1), I18n.t("Next"))
	var mode_icon: String = {"sequence": "sequence", "list": "repeat_all", "single": "repeat_one", "shuffle": "shuffle"}[_state.audio_mode]
	var caption: String = {"sequence": "Play in order", "list": "Repeat playlist", "single": "Repeat track", "shuffle": "Shuffle"}[_state.audio_mode]
	_glyph(MODE, mode_icon, Vector2(-0.43, y), 0.085, true, I18n.t(caption))
	# A short, persistent label makes the current repeat state unambiguous in VR.
	_label(I18n.t(caption), Vector3(-0.43, y - 0.055, 0.004), 12).modulate = MUTED
	_glyph(VOLUME, "mute" if float(_state.audio_volume) == 0 else "sound", Vector2(0.43, y), 0.085, true, I18n.t("Music volume"))
	if _volume_open: _draw_volume(y)

func _draw_volume(y: float) -> void:
	var centre := Vector2(0.21, y + 0.115)
	var panel := _quad(Vector2(0.65, 0.13), Vector3(centre.x, centre.y, 0.028), TILE, 30)
	add_child(panel); _decorations.append(panel); _block_rays(panel, panel.mesh.size)
	var first := _buttons.size()
	_glyph(MUTE, "mute" if float(_state.audio_volume) == 0 else "sound", centre + Vector2(-0.26, 0), 0.075, true, I18n.t("Unmute" if float(_state.audio_volume) == 0 else "Mute"))
	choices.field(null, {"key": "audio_volume", "value": _state.audio_volume, "slider": true, "span": Vector3(0, 100, 1), "unit": "%"}, centre + Vector2(0.065, 0), 0.49, 0.075)
	for index in range(first, _buttons.size()):
		var node: MeshInstance3D = _buttons[index].node
		node.position.z = 0.036; node.material_override.render_priority = 31
		for child in node.get_children():
			if child is Label3D: child.render_priority = 36
			elif child is MeshInstance3D: child.material_override.render_priority = 33 + mini(child.get_index(), 3)

func _draw_modal() -> void:
	var heading: String = {"settings": "Settings", "name": "New playlist" if target_playlist.is_empty() else "Rename", "choose_list": "Add to playlist", "confirm_file": "Delete local audio?", "confirm_list": "Delete playlist?", "playlist": "Playlist options", "track": "Track options", "add_source": "Add tracks"}.get(modal, "Music")
	var top := 0.485 if modal == "name" else (0.425 if modal == "choose_list" else 0.375)
	if modal == "settings": top = 0.225
	_label(I18n.t(heading), Vector3(0, top, 0.004), TEXT_TITLE).font = ui_bold_font()
	if modal == "settings":
		_draw_video_switch(0.075)
		_storage_labels = StorageView.draw(self, _state, Vector2(0, -0.09), 0.96, true, true)
		return
	if modal == "name":
		var input := _quad(Vector2(1.16, 0.085), Vector3(0, 0.36, 0.002), TILE, 11)
		add_child(input); _decorations.append(input)
		_label(_fit_title(name_text + "│", "", 1.08, TEXT_BODY), Vector3(0, 0.36, 0.004), TEXT_BODY)
		for r in KEYS.size():
			for c in 10:
				var ch: String = KEYS[r][c]
				_button(KEY + r * 10 + c, ch.to_upper() if shift else ch, Vector2(-0.54 + c * 0.12, 0.21 - r * 0.11), Vector2(0.105, 0.09))
		_button(SHIFT, "⇧", Vector2(-0.44, -0.24), Vector2(0.20, 0.085), true, "", shift)
		_button(SPACE, "␣", Vector2(-0.08, -0.24), Vector2(0.44, 0.085))
		_glyph(ERASE, "backspace", Vector2(0.36, -0.24), 0.08, true, I18n.t("Delete"))
		_pill(CANCEL, "Cancel", Vector2(-0.25, -0.41), 0.40)
		_pill(SAVE_NAME, "Save", Vector2(0.25, -0.41), 0.40, not name_text.strip_edges().is_empty(), true); return
	var label := I18n.t(str(audio.library.resolve(target_track).get("label", ""))) if not target_track.is_empty() else _playlist_label(audio.library.playlist(target_playlist))
	if modal == "add_source": label = _playlist_label(audio.library.playlist(playlist_id))
	_label(_fit_title(label, "", 1.04, 20), Vector3(0, top - 0.10, 0.004), 20).modulate = MUTED
	if modal == "choose_list":
		_rows = audio.library.playlists.duplicate(true)
		offset = clampi(offset, 0, maxi(0, _rows.size() - LIST_ROWS))
		for i in mini(LIST_ROWS, _rows.size() - offset):
			var row: Dictionary = _rows[offset + i]
			_text_action(ROW + i, str(row.label), 0.20 - i * 0.10, not row.tracks.has(target_track))
			if row.tracks.has(target_track): _icon("check", Vector3(0.48, 0.20 - i * 0.10, 0.006), 0.03, ACCENT)
		if _rows.is_empty(): _label(I18n.t("No playlists yet"), Vector3(0, 0.08, 0.004), 20).modulate = MUTED
		_draw_paging(-0.285)
		_pill(NEW_LIST, "New playlist", Vector2(0, -0.385), 0.60, true, true); return
	if modal.begins_with("confirm_"):
		_label(I18n.t("Removes the local file" if modal == "confirm_file" else "Audio stays in your library"), Vector3(0, 0.10, 0.004), 18).modulate = MUTED
		if modal == "confirm_file":
			var names: Array = audio.library.references(target_track)
			_label(I18n.t("Used in playlists: %d") % names.size(), Vector3(0, 0.015, 0.004), 18).modulate = MUTED
			_label(_fit_title(", ".join(names), "", 1.04, 16), Vector3(0, -0.06, 0.004), 16).modulate = MUTED
		_pill(CANCEL, "Cancel", Vector2(-0.25, -0.24), 0.40)
		_pill(CONFIRM, "Delete", Vector2(0.25, -0.24), 0.40)
		_buttons.back().node.get_child(0).modulate = Color(1, 0.48, 0.46); return
	if modal == "add_source":
		_text_action(FROM_LIBRARY, "From audio library", 0.12)
		_text_action(ADD_FILES, "Import audio", -0.01)
		_pill(CANCEL, "Cancel", Vector2(0, -0.25), 0.40)
		_storage_labels = StorageView.draw(self, _state, Vector2(0, -0.325), 1.04, true); return
	if modal == "playlist":
		_text_action(RENAME, "Rename", 0.12)
		_text_action(DELETE_LIST, "Delete playlist", -0.01)
		_buttons.back().node.get_child(0).modulate = Color(1, 0.48, 0.46)
		_pill(CANCEL, "Cancel", Vector2(0, -0.25), 0.40); return
	_text_action(ADD_TO_LIST, "Add to playlist", 0.12)
	var custom: Dictionary = audio.library.playlist(target_playlist)
	if not custom.is_empty() and not custom.builtin: _text_action(REMOVE_TRACK, "Remove from playlist", -0.01)
	if target_track.begins_with("import_"):
		_text_action(DELETE_FILE, "Delete local audio", -0.14)
		_buttons.back().node.get_child(0).modulate = Color(1, 0.48, 0.46)
	_pill(CANCEL, "Cancel", Vector2(0, -0.29), 0.40)

func _activate(id: int) -> void:
	if choices.action(id): return
	if id in [CLOSE, BACK, CANCEL]:
		if id == CLOSE or not navigate_back(): close_requested.emit()
		return
	if id == SETTINGS and modal.is_empty():
		_volume_open = false; _open_modal("settings"); refresh(); return
	if id in [PREVIOUS, NEXT]:
		offset = clampi(offset + (-_capacity() if id == PREVIOUS else _capacity()), 0, maxi(0, _rows.size() - _capacity())); refresh(); return
	if modal == "name":
		if id >= KEY and id < KEY + 40:
			var ch: String = KEYS[(id - KEY) / 10][(id - KEY) % 10]; name_text = (name_text + (ch.to_upper() if shift else ch)).left(80)
		elif id == ERASE: name_text = name_text.left(-1)
		elif id == SHIFT: shift = not shift
		elif id == SPACE: name_text = (name_text + " ").left(80)
		elif id == SAVE_NAME:
			if target_playlist.is_empty():
				var created: String = audio.library.create_playlist(name_text, [target_track] if not target_track.is_empty() else [])
				if not created.is_empty():
					if not target_track.is_empty(): _close_modal(true)
					else: _modal_history.clear(); playlist_id = created; view = "tracks"; modal = ""; editing = false; offset = 0
			elif audio.rename_playlist(target_playlist, name_text): _close_modal(true)
		refresh(); return
	if id == NEW_LIST:
		if modal != "choose_list": target_track = ""
		target_playlist = ""; name_text = I18n.t("Playlist") + " %d" % (audio.library.playlists.size() + 1); _open_modal("name"); refresh(); return
	if modal == "choose_list" and id >= ROW and id < ROW + LIST_ROWS:
		if offset + id - ROW < _rows.size() and audio.library.add_track(str(_rows[offset + id - ROW].id), target_track): _close_modal(true)
		refresh(); return
	if modal == "add_source":
		if id == FROM_LIBRARY:
			_close_modal(true); _add_return_offset = offset
			selected_tracks.assign(audio.library.playlist(playlist_id).tracks); view = "add"; offset = 0; refresh()
		elif id == ADD_FILES:
			_close_modal(true); refresh(); import_requested.emit(playlist_id)
		return
	if not modal.is_empty():
		match id:
			RENAME: name_text = str(audio.library.playlist(target_playlist).label); _open_modal("name")
			DELETE_LIST: _open_modal("confirm_list")
			DELETE_FILE: _open_modal("confirm_file")
			ADD_TO_LIST: _open_modal("choose_list")
			REMOVE_TRACK:
				if audio.library.remove_track(target_playlist, target_track): _close_modal(true)
			CONFIRM:
				if modal == "confirm_file":
					if audio.remove_import(target_track): _close_modal(true)
				elif audio.library.delete_playlist(target_playlist):
					_close_modal(true)
					if view == "tracks" and playlist_id == target_playlist: view = "lists"; offset = _list_offset; editing = false
		refresh(); return
	if editing:
		for base in [INLINE_UP, INLINE_DOWN, INLINE_REMOVE]:
			if id >= base and id < base + LIST_ROWS:
				var index: int = offset + id - base
				if index < _rows.size():
					var track: String = str(_rows[index].id)
					if base == INLINE_REMOVE: audio.library.remove_track(playlist_id, track)
					else: audio.library.move_track(playlist_id, track, -1 if base == INLINE_UP else 1)
				refresh(); return
	if id >= TAB and id < TAB + 3:
		if view == "lists": _list_offset = offset
		view = ["lists", "all", "queue"][id - TAB]; offset = _list_offset if view == "lists" else 0; editing = false
	elif id == SOURCE:
		compact = false; _volume_open = false; editing = false
		if not audio.library.playlist(audio.queue_source).is_empty():
			playlist_id = audio.queue_source; view = "tracks"
			offset = maxi(0, audio.library.playlist(playlist_id).tracks.find(audio.current) - 2)
		else: view = "lists" if audio.queue.is_empty() else "queue"; offset = 0
	elif id == QUEUE:
		view = "lists" if audio.queue.is_empty() else "queue"; compact = false; offset = 0; _volume_open = false; editing = false
		if view == "queue": offset = maxi(0, audio.queue.find(audio.current) - 2)
	elif id in [MINIMIZE, DOCK]:
		if view == "add": view = "tracks"; selected_tracks.clear(); offset = _add_return_offset
		compact = true; editing = false; _volume_open = false
	elif id == VOLUME: _volume_open = not _volume_open
	elif id == MUTE:
		if audio.volume > 0: _unmuted_volume = audio.volume; audio.set_volume(0)
		else: audio.set_volume(_unmuted_volume)
	elif id == MODE: audio.set_mode(audio.MODES[(audio.MODES.find(audio.mode) + 1) % audio.MODES.size()])
	elif id == PREV_TRACK: audio.adjacent(-1)
	elif id == NEXT_TRACK: audio.adjacent(1)
	elif id == PLAY_LIST: audio.play_playlist(playlist_id)
	elif id == PLAY: audio.toggle_pause()
	elif id == ADD_FILES:
		view = "all"; filter = "imported"; offset = 0; import_requested.emit("")
	elif id == ADD_TRACKS: _open_modal("add_source")
	elif id == EDIT_LIST: editing = not editing
	elif id == LIST_OPTIONS:
		target_playlist = playlist_id; target_track = ""; _open_modal("playlist")
	elif id == DONE and view == "add":
		if audio.library.set_tracks(playlist_id, selected_tracks): view = "tracks"; offset = _add_return_offset; selected_tracks.clear()
	elif id == CANCEL_IMPORT: audio.cancel_imports()
	elif id == RETRY_IMPORT: audio.retry_imports()
	elif (id >= ROW and id < ROW + _capacity()) or (id >= MORE and id < MORE + _capacity()):
		var more := id >= MORE; var index := offset + id - (MORE if more else ROW)
		if index >= _rows.size(): return
		var row: Dictionary = _rows[index]
		if view == "lists":
			if more: target_playlist = str(row.id); target_track = ""; _open_modal("playlist")
			else: _list_offset = offset; playlist_id = str(row.id); view = "tracks"; editing = false; offset = 0
		elif more:
			target_track = str(row.id); target_playlist = playlist_id if view == "tracks" else ""; _open_modal("track")
		elif view == "add":
			if selected_tracks.has(str(row.id)): selected_tracks.erase(str(row.id))
			else: selected_tracks.append(str(row.id))
		elif view == "tracks" and not editing: audio.play_playlist(playlist_id, str(row.id))
		elif view == "queue": audio.select_track(str(row.id))
		elif view == "all": audio.play_tracks(_rows.map(func(entry): return str(entry.id)), str(row.id), "Audio library", "", "single" if row.get("kind", "") == "ambience" else "sequence")
	refresh()

func _choice_changed(key: String, value: Variant) -> void:
	if key == "audio_volume": audio.set_volume(value)
	elif key == "audio_play_during_video": audio.set_play_during_video(bool(value))
	elif key == "audio_seek" and value is Dictionary and value.source_uri == audio.current: audio.seek(value.value)
	elif key == "audio_filter": filter = str(value); offset = 0
	refresh()

func _choice_previewed(key: String, value: Variant) -> void:
	if key == "audio_volume": audio.set_volume(value)
	elif key == "audio_seek": refresh_values()

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if has_pointer_capture(): return true
	var hit := ray_hit(origin, direction) if tracked else {}
	var id := int(hit.get("target", NONE))
	if _volume_open and tracked and id not in [VOLUME, MUTE, SETTINGS] and choices.targets.get(id, {}).get("key", "") != "audio_volume":
		_volume_open = false; refresh(); return true
	if choices.press(hand, origin, direction, tracked): return true
	if not compact and modal in ["", "choose_list"] and not hit.is_empty() and (id in range(ROW, ROW + _capacity()) or (id == NONE and hit.point.y < 0.20 and hit.point.y > -0.30)):
		_drag = {"hand": hand, "target": id, "id": str(_rows[offset + id - ROW].id) if id >= ROW and offset + id - ROW < _rows.size() else "", "y": hit.point.y, "offset": offset, "moved": false}
		return true
	return super(hand, origin, direction, tracked)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand, origin, direction, tracked); choices.update(hand, origin, direction, tracked)
	if _drag.get("hand", "") != hand: return
	if not tracked: _drag.clear(); return
	var point: Variant = project_pointer(origin, direction, Transform3D.IDENTITY)
	if point == null: return
	if absf(float(point.y) - float(_drag.y)) > 0.025: _drag.moved = true
	if _drag.moved:
		var next := clampi(int(_drag.offset) + roundi((float(point.y) - float(_drag.y)) / (0.16 if view == "lists" and modal.is_empty() else 0.1)) * (2 if view == "lists" and modal.is_empty() else 1), 0, maxi(0, _rows.size() - _capacity()))
		if next != offset: offset = next; refresh()

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if choices.capture.get("hand", "") == hand: choices.release(hand, origin, direction, tracked); return
	if _drag.get("hand", "") != hand: return
	var drag := _drag.duplicate(); _drag.clear()
	var hit := ray_hit(origin, direction) if tracked else {}
	var index := offset + int(drag.target) - ROW
	if not drag.moved and int(hit.get("target", NONE)) == int(drag.target) and index >= 0 and index < _rows.size() and str(_rows[index].id) == str(drag.id): _activate(int(drag.target))

func cancel_pointer(hand: String) -> void:
	choices.cancel(hand)
	if _drag.get("hand", "") == hand: _drag.clear()
	super(hand)

func stick_scroll(y: float, delta: float) -> void:
	if choices.stick_scroll(y, delta) or has_pointer_capture() or _volume_open or compact or (not modal.is_empty() and modal != "choose_list"): return
	if not is_finite(y) or absf(y) < 0.3: _scroll = 0; return
	_scroll -= y * delta * 7
	if absf(_scroll) >= 1:
		offset = clampi(offset + int(_scroll), 0, maxi(0, _rows.size() - _capacity())); _scroll -= int(_scroll); refresh()
