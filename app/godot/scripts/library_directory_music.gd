extends RefCounted

const MULTI := 21800
const CANCEL := 21801
const ALL := 21802
const ADD := 21803
const RETRY := 21804
const ROW_ADD := 21820
var menu: Node
var selecting := false
var selection := {}
var location := ""
var playing_uri := ""
var report := {}
var notice_until := 0
var playback_message := ""
var importing_list := ""

func _init(owner: Node) -> void:
	menu = owner

func directory() -> bool:
	return menu.section in [menu.Section.LOCAL, menu.Section.SMB, menu.Section.DLNA, menu.Section.CLOUD] \
		and not (menu.experience_open() or menu.archives.browsing or menu.image_picker_mode or menu.voice_picker_mode or menu.subtitle_picker_mode or menu.audio_import_mode or menu.cloud_search.active)

## Songs are listed in folders and in the favourites; both play them and add them to playlists.
func listed() -> bool:
	return directory() or menu._favorite_folder_filter()

func song(row: Dictionary) -> bool:
	return row.get("kind") == "audio" and not str(row.get("uri", "")).is_empty() and listed()

func can_select() -> bool:
	return menu.media_filter == menu.MUSIC_FILTER and directory() and not menu.compact and not menu.file_actions.editing and not menu.file_actions.has_selection()

func import_file(row: Dictionary) -> Dictionary:
	var title := str(row.get("audio_import_title", row.title))
	return {"uri": row.uri, "title": title} if menu.AudioCatalog.supported(title) else {}

func cancel_selection() -> void:
	selecting = false; selection.clear(); location = ""

func reconcile() -> void:
	if selecting and (not can_select() or location != menu._filter_location()):
		cancel_selection()

func draw_entry() -> void:
	if selecting or not can_select() or not menu.browser_content() or not menu.rows.any(song): return
	menu._button(MULTI, menu.I18n.t("Select music"), menu._action_position(0.0), Vector2(0.22, 0.066))

func draw_selection_footer() -> void:
	var paged: bool = menu.section == menu.Section.CLOUD and (menu.cloud_pagination.mode == "partial" or (menu.cloud_pagination.mode == "paged" and (menu._cloud_page > 0 or menu._cloud_next >= 0)))
	var label: String = "Select loaded" if paged and menu.cloud_pagination.mode == "partial" else "Select this page" if paged else "Select all"
	menu._button(CANCEL, menu.I18n.t("Cancel"), Vector2(-0.29, -0.515), Vector2(0.22, 0.065))
	menu._button(ALL, menu.I18n.t(label), Vector2(0.02, -0.515), Vector2(0.34, 0.065), not menu._cloud_busy or menu.section != menu.Section.CLOUD)
	menu._button(ADD, menu.I18n.t("Add to playlist") + " (%d)" % selection.size(), Vector2(0.52, -0.515), Vector2(0.58, 0.065), not selection.is_empty())

func action(target: int) -> bool:
	if target == MULTI and can_select():
		selecting = true; location = menu._filter_location(); menu.refresh_file_selection(); return true
	if target == CANCEL and selecting:
		cancel_selection(); menu.refresh_file_selection(); return true
	if target == ALL and selecting:
		for row in menu.rows:
			if song(row):
				var file := import_file(row)
				if not file.is_empty(): selection[row.uri] = file
		menu.refresh_file_selection(); return true
	if target == ADD and selecting and not selection.is_empty():
		menu.directory_playlist_requested.emit(selection.values()); return true
	if target == RETRY and not report.is_empty():
		var previous := report; report = {}; menu.refresh_file_selection()
		menu.directory_retry_requested.emit(previous); return true
	if add_target(target) and not selecting:
		var index: int = menu._row_index(target - ROW_ADD)
		if index >= 0 and index < menu.rows.size() and song(menu.rows[index]):
			var row: Dictionary = menu.rows[index]
			var file := import_file(row)
			if not file.is_empty(): menu.directory_playlist_requested.emit([file])
		return true
	return false

func add_target(target: int) -> bool:
	return target >= ROW_ADD and target < ROW_ADD + menu._drawn_slots()

func choose(row: Dictionary) -> bool:
	if selecting and not song(row): return true
	if not song(row) or menu.file_actions.editing: return false
	if selecting:
		if selection.has(row.uri): selection.erase(row.uri)
		else:
			var file := import_file(row)
			if file.is_empty(): return true
			selection[row.uri] = file
		menu.refresh_file_selection()
	else:
		menu.directory_song_requested.emit(str(row.uri), str(row.title))
	return true

func decorate(button: Dictionary, row: Dictionary) -> void:
	if not song(row) or menu.file_actions.editing: return
	var node: MeshInstance3D = button.node
	var grid: bool = menu._grid()
	var x: float = node.mesh.size.x * 0.5 - 0.05
	var y := -0.085 if grid else 0.0
	if grid:
		var name_label: Label3D = node.get_child(0)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.position.x = -node.mesh.size.x * 0.5 + 0.015
		name_label.width = (node.mesh.size.x - 0.107) / name_label.pixel_size
	if selecting:
		if import_file(row).is_empty(): return
		var checked := selection.has(row.uri)
		menu._icon("check" if checked else "checkbox", Vector3(x, y, 0.012), 0.044, menu.ACCENT if checked else menu.MUTED, node).material_override.render_priority = 15
		return
	var marker: MeshInstance3D = menu._icon("volume_low", Vector3(-x if grid else x - 0.09, 0.08 if grid else y, 0.013), 0.045, menu.ACCENT, node)
	marker.material_override.render_priority = 15
	marker.visible = playing_uri == row.uri
	button.music_uri = row.uri; button.music_marker = marker
	if import_file(row).is_empty(): return
	var target: int = ROW_ADD + button.target - menu.ROW_BASE
	menu._round(target, "plus", Vector2.ZERO, 0.072, true, false, menu.I18n.t("Add to playlist"))
	var add: MeshInstance3D = menu._buttons.back().node
	add.reparent(node, false); add.position = Vector3(x, y, 0.013)
	add.material_override.render_priority = 15
	for child in add.get_children():
		if child is MeshInstance3D: child.material_override.render_priority = 16

func sync_playback(state: Dictionary, update_controls: bool = true) -> void:
	var current := str(state.get("audio_directory_uri", ""))
	var message := ""
	if not current.is_empty():
		if state.get("audio_blocked", false): message = "Audio suspended"
		elif state.get("audio_paused", false): message = str(state.get("audio_playback_error", ""))
	var destination := str(state.get("audio_directory_import_name", ""))
	if message != playback_message or destination != importing_list:
		importing_list = destination
		playback_message = message
		if update_controls and menu.visible and listed(): menu.refresh_file_selection()
	var uri := current if state.get("audio_active", false) else ""
	if playing_uri == uri: return
	playing_uri = uri
	if not update_controls: return
	for button in menu._buttons:
		if button.has("music_marker"): button.music_marker.visible = button.music_uri == uri
	menu.composition_changed.emit()

func import_finished(result: Dictionary) -> void:
	report = result
	notice_until = Time.get_ticks_msec() + 7000
	if menu.visible and listed(): menu.refresh_file_selection()

func draw_notice() -> void:
	if not listed(): return
	var message: String = menu.I18n.t(playback_message) if not playback_message.is_empty() else ""
	var retry := false
	if not importing_list.is_empty():
		message = menu.I18n.t("Saving to device") + " · " + importing_list
	elif not report.is_empty():
		message = menu.I18n.t("Added to %s: %d") % [report.label, report.added]
		if report.existing: message += " · " + menu.I18n.t("%d already in playlist") % report.existing
		if report.failed: message += " · " + menu.I18n.t("%d failed") % report.failed; retry = true
	if message.is_empty(): return
	var board_width := 1.02 if menu.compact else 1.25
	var centre := Vector2(0, 0.485) if menu.compact else Vector2(0.14, 0.63)
	var board: MeshInstance3D = menu._decoration(Vector2(board_width, 0.09), centre, menu.PANEL)
	var width := board_width - (0.32 if retry else 0.07)
	var notice: Label3D = menu._label(menu._fit_title(message, "", width, 17), Vector3(-0.08 if retry else 0.0, 0, 0.005), 17, board)
	notice.modulate = menu.ACCENT
	if retry:
		menu._button(RETRY, menu.I18n.t("Retry"), centre + Vector2(board_width * 0.5 - 0.145, 0), Vector2(0.24, 0.065))
		menu._buttons.back().node.position.z = 0.012
		menu._buttons.back().node.material_override.render_priority = 13

func tick() -> void:
	if notice_until == 0 or Time.get_ticks_msec() < notice_until or menu.has_pointer_capture(): return
	notice_until = 0
	if report.get("failed", 0) > 0: return
	report = {}
	if menu.visible and listed(): menu.refresh_file_selection()
