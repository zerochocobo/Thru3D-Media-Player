extends RefCounted
const OPEN := 9160
const PREVIEW := 9161
const APPLY := 9162
const PREVIOUS := 9163
const NEXT := 9164
const SAME_NAME := 9165
var menu: Node3D
var phase := ""
var name := ""
var moves: Array = []
var shifted := false
var symbols := false
var selected_all := false
var include_same_name := true
var request_id := 0
var page := 0
var migration_failed := false
var result_error := ""
var location := ""

func _init(owner: Node3D) -> void: menu = owner
func context() -> String:
	return str([menu.section, menu._local_path(), menu._smb_server, menu._smb_path, menu._cloud_path()])

func refresh_source() -> void:
	if context() != location: return
	if menu.section == menu.Section.LOCAL and menu.PlatformMethods.supports(menu.platform, "media_local_browse"):
		menu._request("local", menu.platform.media_local_browse(menu._local_path()))
	elif menu.section == menu.Section.SMB and menu.PlatformMethods.supports(menu.platform, "media_smb_browse"):
		menu._request("smb_browse", menu.platform.media_smb_browse(menu._smb_server, menu._smb_path))
	elif menu.section == menu.Section.CLOUD:
		menu._cloud_positions.clear(); menu._cloud_offsets.assign([0]); menu._load_cloud(false, true, 0)
func supported(row: Dictionary) -> bool:
	var uri: String = menu.file_actions.row_uri(row)
	var local_video: bool = (uri.begins_with("file://") or uri.begins_with("smb://")) and row.get("kind", "") == "video" and not row.get("folder", false)
	return row.get("can_rename", row.get("can_delete", false) if local_video else false) and menu.PlatformMethods.supports(menu.platform, "media_file_rename_prepare") and menu.PlatformMethods.supports(menu.platform, "media_file_rename")

func can_rename(row: Dictionary) -> bool:
	return menu.file_actions.idle() and supported(row)

func original_name() -> String:
	var target: Dictionary = menu.file_actions.target
	return str(target.get("title", "")) if target.get("folder", false) else str(target.get("title", "")).get_basename()

func companions_allowed() -> bool:
	return menu.file_actions.target.get("kind", "") == "video" and not menu.file_actions.target.get("folder", false)

func input_text(width: float) -> String:
	if selected_all: return menu._fit_title(name, "", width, 22)
	var shown := name
	if menu.text_width(shown + "│", 22) <= width: return shown + "│"
	while not shown.is_empty() and menu.text_width("…" + shown + "│", 22) > width: shown = shown.substr(1)
	return "…" + shown + "│"
func open(row: Dictionary) -> void:
	menu.file_actions.target = row.duplicate(true)
	menu.file_actions.target.uri = menu.file_actions.row_uri(row)
	location = context(); result_error = ""
	phase = "input"; moves = []; page = 0; name = original_name(); shifted = false; symbols = false; selected_all = false; include_same_name = true
	menu.file_actions.modal = "rename"; menu.refresh()
func action(id: int) -> void:
	var actions: RefCounted = menu.file_actions
	if id == actions.CANCEL:
		if phase == "result" and actions.pending == 0: refresh_source()
		if actions.pending == 0: phase = ""
		actions.modal = ""; menu.refresh(); return
	if actions.pending > 0: return
	if id == PREVIOUS: page = maxi(0, page - 1)
	if id == NEXT: page = mini(maxi(0, ceili(moves.size() / 5.0) - 1), page + 1)
	if phase == "input":
		if id >= menu.KEY_BASE and id < menu.KEY_BASE + 40:
			if selected_all: name = ""; selected_all = false
			var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
			var character: String = layer[(id - menu.KEY_BASE) / 10][(id - menu.KEY_BASE) % 10]
			if name.length() < 160: name += character.to_upper() if shifted else character
			shifted = false
		elif id == menu.BACKSPACE:
			name = "" if selected_all else name.left(-1); selected_all = false
		elif id == menu.SPACE:
			if selected_all: name = ""; selected_all = false
			name += " "
		elif id == menu.SHIFT: shifted = not shifted
		elif id == menu.SYMBOL_LAYER: symbols = not symbols
		elif id == 9190: selected_all = not selected_all
		elif id == SAME_NAME and companions_allowed(): include_same_name = not include_same_name
		elif id == PREVIEW and not name.is_empty() and name != original_name(): dispatch(true)
	elif phase == "preview" and id == APPLY and actions.enabled: dispatch(false)
	menu.refresh()
func dispatch(prepare: bool) -> void:
	var actions: RefCounted = menu.file_actions
	actions.target["new_name"] = name
	actions.target["include_same_name"] = include_same_name and companions_allowed()
	if not prepare:
		actions.target["related_uris"] = []
		menu.file_delete_preparing.emit(str(actions.target.uri))
		if not actions.target.get("folder", false):
			for move in moves:
				var related := str(move.get("old_uri", str(actions.target.uri).get_base_dir() + "/" + str(move.from).uri_encode()))
				actions.target.related_uris.append(related)
				if related != str(actions.target.uri): menu.file_delete_preparing.emit(related)
	request_id = int(menu.platform.call("media_file_rename_prepare" if prepare else "media_file_rename", JSON.stringify(actions.target)))
	actions.pending = request_id
	if request_id <= 0:
		request_id = 0; actions.pending = 0; phase = "result"; result_error = "Rename failed; check the folder"; menu.status = result_error
func receive(id: int, payload: String) -> bool:
	if request_id <= 0 or id != request_id: return false
	request_id = 0
	var actions: RefCounted = menu.file_actions
	actions.pending = 0
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("uri", "") != actions.target.get("uri", ""):
		phase = "result"; result_error = "Rename failed; check the folder"; menu.status = result_error
	elif result.get("state") == "ready" and result.get("preview", false):
		actions.target["plan"] = result.get("plan", "")
		moves = result.get("moves", []); phase = "preview"
	elif result.get("state") == "ready" and result.get("renamed", false):
		var old_uri := str(actions.target.uri)
		var new_uri := str(result.get("new_uri", ""))
		var title := str(result.get("new_title", ""))
		migration_failed = false
		menu.file_renamed.emit(old_uri, new_uri, title)
		for entries in [menu._local_entries, menu._smb_entries, menu._cloud_entries]:
			for entry in entries:
				var uri := str(entry.get("uri", entry.get("delete_uri", "")))
				var destination := ""; var renamed_title := ""
				if uri == old_uri and str(entry.get("cloud_id", "")) == str(actions.target.get("cloud_id", "")):
					destination = new_uri; renamed_title = title
				elif not entry.get("container", false) and uri.get_base_dir() == old_uri.get_base_dir():
					for move in moves:
						if str(entry.get("title", "")) == str(move.from):
							destination = str(move.get("new_uri", new_uri.get_base_dir() + "/" + str(move.to).uri_encode())); renamed_title = str(move.to)
				if destination.is_empty(): continue
				if entry.get("container", false): entry.delete_uri = destination
				else: entry.uri = destination
				entry.title = renamed_title
				entry.id = str(entry.get("id", "")).get_base_dir().path_join(renamed_title)
		actions.selection.clear(); actions.target = {}; actions.modal = ""; phase = ""
		menu.status = "Files renamed; playback records could not be saved" if migration_failed else "Files renamed"
	else:
		moves = result.get("remaining", [])
		moves.append_array(result.get("unknown_moves", [])); page = 0; phase = "result"
		result_error = str(result.get("error", "Rename failed; check the folder")); menu.status = result_error
	if not (result is Dictionary and result.get("preview", false)) and menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty(): refresh_source()
	if menu.visible: menu.refresh()
	return true
func draw() -> void:
	var actions: RefCounted = menu.file_actions
	menu._set_backdrop(Vector2(1.46, 1.28), Vector2(0.13, 0))
	var heading := "Rename folder" if actions.target.get("folder", false) else "Rename file"
	menu._label(menu.I18n.t(heading), Vector3(0.13, 0.53, 0.004), 25)
	menu._label(menu._fit_title(str(actions.target.get("title", "")), "", 1.20, 18), Vector3(0.13, 0.43, 0.004), 18).modulate = menu.MUTED
	if phase == "input":
		var extension := str(actions.target.get("title", "")).get_extension() if not actions.target.get("folder", false) else ""
		menu._button(9190, input_text(1.0 if not extension.is_empty() else 1.18), Vector2(0.02 if not extension.is_empty() else 0.13, 0.32), Vector2(1.02 if not extension.is_empty() else 1.24, 0.095), actions.pending == 0, "", selected_all)
		if not extension.is_empty():
			menu._label("." + extension, Vector3(0.64, 0.32, 0.004), 18).modulate = menu.MUTED
		if companions_allowed():
			menu._button(SAME_NAME, "", Vector2(-0.43, 0.205), Vector2(0.075, 0.075), actions.pending == 0, "check" if include_same_name else "checkbox", include_same_name)
			var same_name_label: Label3D = menu._label(menu.I18n.t("Also rename files with the same basename"), Vector3(-0.36, 0.205, 0.004), 19)
			same_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
		for r in layer.size():
			for c in 10:
				var character: String = layer[r][c]
				menu._button(menu.KEY_BASE + r * 10 + c, character.to_upper() if shifted else character, Vector2(-0.38 + c * 0.126, 0.075 - r * 0.098), Vector2(0.115, 0.085), actions.pending == 0)
		menu._button(menu.SHIFT, "⇧", Vector2(-0.32, -0.32), Vector2(0.18, 0.085), actions.pending == 0, "", shifted)
		menu._button(menu.SYMBOL_LAYER, "abc" if symbols else "#+=", Vector2(-0.13, -0.32), Vector2(0.18, 0.085), actions.pending == 0, "", symbols)
		menu._button(menu.SPACE, "␣", Vector2(0.15, -0.32), Vector2(0.34, 0.085), actions.pending == 0)
		menu._button(menu.BACKSPACE, "", Vector2(0.43, -0.32), Vector2(0.18, 0.085), actions.pending == 0, "backspace")
		menu._button(PREVIEW, menu.I18n.t("Check changes"), Vector2(0.60, -0.50), Vector2(0.38, 0.08), actions.pending == 0 and not name.is_empty() and name != original_name())
	else:
		menu._label(menu.I18n.t("%d items will be renamed") % moves.size() if phase == "preview" else menu.I18n.t(result_error), Vector3(0.13, 0.30, 0.004), 19)
		for i in mini(maxi(0, moves.size() - page * 5), 5):
			var move: Dictionary = moves[page * 5 + i]
			menu._label(menu._fit_title(str(move.from) + " → " + str(move.to), "", 1.22, 17), Vector3(0.13, 0.17 - i * 0.083, 0.004), 17)
		if moves.size() > 5:
			menu._button(PREVIOUS, "‹", Vector2(-0.06, -0.32), Vector2(0.09, 0.065), actions.pending == 0 and page > 0)
			menu._label("%d / %d" % [page + 1, ceili(moves.size() / 5.0)], Vector3(0.13, -0.32, 0.004), 17)
			menu._button(NEXT, "›", Vector2(0.32, -0.32), Vector2(0.09, 0.065), actions.pending == 0 and (page + 1) * 5 < moves.size())
		if phase == "preview": menu._button(APPLY, menu.I18n.t("Rename"), Vector2(0.60, -0.50), Vector2(0.38, 0.08), actions.pending == 0 and actions.enabled)
	menu._button(actions.CANCEL, menu.I18n.t("Hide" if actions.pending > 0 else "Cancel" if phase in ["input", "preview"] else "Close"), Vector2(0.13, -0.50), Vector2(0.38, 0.08))
	if actions.pending > 0: menu._label(menu.I18n.t("Checking…" if phase == "input" else "Renaming…"), Vector3(-0.33, -0.50, 0.004), 16)
