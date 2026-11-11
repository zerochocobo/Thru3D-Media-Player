extends RefCounted
const OPEN := 9160
const PREVIEW := 9161
const APPLY := 9162
const PREVIOUS := 9163
const NEXT := 9164
const SAME_NAME := 9165
const NAME_FIELD := 9190
var menu: Node3D
var phase := ""
var name := ""
var moves: Array = []
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
	menu._position_to_restore = menu.capture_position()
	if menu.section == menu.Section.LOCAL and menu.PlatformMethods.supports(menu.platform, "media_local_browse"):
		menu._request("local", menu.platform.media_local_browse(menu._local_path()))
	elif menu.section == menu.Section.SMB and menu.PlatformMethods.supports(menu.platform, "media_smb_browse"):
		menu._request("smb_browse", menu.platform.media_smb_browse(menu._smb_server, menu._smb_path))
	elif menu.section == menu.Section.CLOUD:
		menu.refresh_cloud_mutation()
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
	var shown := name
	if menu.text_width(shown, 22) <= width: return shown
	while not shown.is_empty() and menu.text_width("…" + shown, 22) > width: shown = shown.substr(1)
	return "…" + shown

func edit_name(select_all: bool = true) -> void:
	if phase != "input" or menu.file_actions.pending > 0: return
	var editor: RefCounted = menu.system_text_input
	var update := func(value):
		name = value
		menu.refresh_file_selection()
	name = editor.finish("file_rename", name)
	editor.begin("file_rename", name, 160, update,
		func(value): name = value; action(PREVIEW), update,
		func(): return menu.visible and menu.file_actions.modal == "rename" and phase == "input" and menu.file_actions.pending == 0 and context() == location)
	if select_all or editor.custom: editor.editor.select_all()

func open(row: Dictionary) -> void:
	menu.system_text_input.cancel("file_rename")
	menu.file_actions.target = row.duplicate(true)
	menu.file_actions.target.uri = menu.file_actions.row_uri(row)
	location = context(); result_error = ""
	phase = "input"; moves = []; page = 0; name = original_name(); include_same_name = true
	menu.file_actions.modal = "rename"; menu.refresh_file_selection()
	edit_name(false)
func action(id: int) -> void:
	var actions: RefCounted = menu.file_actions
	if id == actions.CANCEL:
		menu.system_text_input.cancel("file_rename")
		if phase == "result" and actions.pending == 0: refresh_source()
		if actions.pending == 0: phase = ""
		actions.modal = ""; menu.refresh_file_selection(); return
	if actions.pending > 0: return
	if id == PREVIOUS: page = maxi(0, page - 1)
	if id == NEXT: page = mini(maxi(0, ceili(moves.size() / 5.0) - 1), page + 1)
	if phase == "input":
		if id == NAME_FIELD: edit_name()
		elif id == SAME_NAME and companions_allowed(): include_same_name = not include_same_name
		elif id == PREVIEW:
			name = menu.system_text_input.finish("file_rename", name)
			if not name.is_empty() and name != original_name(): dispatch(true)
	elif phase == "preview" and id == APPLY and actions.enabled: dispatch(false)
	menu.refresh_file_selection()
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
		var anchor: Dictionary = menu.capture_position()
		var updates := {}
		migration_failed = false
		menu.file_renamed.emit(old_uri, new_uri, title)
		for entries in menu.file_entry_snapshots():
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
				var key := JSON.stringify([uri, str(entry.get("cloud_id", ""))])
				if entry.get("container", false): entry.delete_uri = destination
				else: entry.uri = destination
				entry.title = renamed_title
				entry.id = str(entry.get("id", "")).get_base_dir().path_join(renamed_title)
				if not updates.has(key): updates[key] = entry
		actions.selection.clear(); actions.target = {}; actions.modal = ""; phase = ""
		menu.rename_file_rows(updates, anchor)
		menu.status = "Files renamed; playback records could not be saved" if migration_failed else "Files renamed"
	else:
		moves = result.get("remaining", [])
		moves.append_array(result.get("unknown_moves", [])); page = 0; phase = "result"
		result_error = str(result.get("error", "Rename failed; check the folder")); menu.status = result_error
	if not (result is Dictionary and result.get("preview", false)) and menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty(): refresh_source()
	if menu.visible: menu.refresh_file_selection()
	return true
func draw() -> void:
	var actions: RefCounted = menu.file_actions
	var compact := phase == "input"
	var footer := 0.11 if compact else -0.50
	menu._set_backdrop(Vector2(1.46, 0.56 if compact else 1.28), Vector2(0.13, 0.32 if compact else 0.0))
	var heading := "Rename folder" if actions.target.get("folder", false) else "Rename file"
	menu._label(menu.I18n.t(heading), Vector3(0.13, 0.53, 0.004), 25)
	menu._label(menu._fit_title(str(actions.target.get("title", "")), "", 1.20, 18), Vector3(0.13, 0.43, 0.004), 18).modulate = menu.MUTED
	if phase == "input":
		var extension := str(actions.target.get("title", "")).get_extension() if not actions.target.get("folder", false) else ""
		menu._button(NAME_FIELD, input_text(1.0 if not extension.is_empty() else 1.18), Vector2(0.02 if not extension.is_empty() else 0.13, 0.32), Vector2(1.02 if not extension.is_empty() else 1.24, 0.095), actions.pending == 0)
		if not extension.is_empty():
			menu._label("." + extension, Vector3(0.64, 0.32, 0.004), 18).modulate = menu.MUTED
		if companions_allowed():
			menu._button(SAME_NAME, "", Vector2(-0.43, 0.205), Vector2(0.075, 0.075), actions.pending == 0, "check" if include_same_name else "checkbox", include_same_name)
			var same_name_label: Label3D = menu._label(menu.I18n.t("Also rename files with the same basename"), Vector3(-0.36, 0.205, 0.004), 19)
			same_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		menu._button(PREVIEW, menu.I18n.t("Check changes"), Vector2(0.60, footer), Vector2(0.38, 0.08), actions.pending == 0 and not name.is_empty() and name != original_name())
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
	menu._button(actions.CANCEL, menu.I18n.t("Hide" if actions.pending > 0 else "Cancel" if phase in ["input", "preview"] else "Close"), Vector2(0.13, footer), Vector2(0.38, 0.08))
	if actions.pending > 0: menu._label(menu.I18n.t("Checking…" if phase == "input" else "Renaming…"), Vector3(-0.33, footer, 0.004), 16)
