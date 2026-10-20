extends RefCounted
const TextInput := preload("res://scripts/system_text_input.gd")
const VoiceStatus := preload("res://scripts/narration_voice_status.gd")
const Languages := preload("res://scripts/narration_languages.gd")
const BASE := 62000
const COUNT := 8
const ROW_PITCH := 0.078
var menu: Node3D
var editor: RefCounted
var opened := false
var library := false
var offset := 0
var scroll := 0.0
var actions := {}
var naming := {}
var draft := ""
var confirm_delete := ""
var saving := false
var source := ""

func _init(owner: Node3D) -> void:
	menu = owner; editor = TextInput.new(owner)

func command(value: Dictionary) -> void:
	if menu._state.get("global_voice_manager", false): menu.setting_changed.emit("narration_voice_manager", value)
	else: menu.setting_requested.emit("narration_clone", value)

func open(show_library: bool = false) -> void:
	opened = true; library = show_library; offset = 0; naming.clear(); confirm_delete = ""
	source = str(menu._state.get("source_uri", "")); menu.choices.reset()
	command({"operation": "list", "pause": true} if library else {"operation": "open"}); menu.refresh()

func close() -> void:
	editor.cancel(); naming.clear(); opened = false; confirm_delete = ""
	command({"operation": "close"}); menu.refresh()

func back() -> void:
	if editor.active(): editor.cancel(); menu.refresh()
	elif not naming.is_empty(): naming.clear(); menu.refresh()
	elif not confirm_delete.is_empty(): confirm_delete = ""; menu.refresh()
	else: close()

func rows() -> Array:
	return menu._state.get("narration_personal_voices", []) if library else menu._state.get("narration_clone_state", {}).get("candidates", [])

static func status_text(state: Dictionary) -> String:
	return VoiceStatus.label(state)

func move(amount: int) -> void:
	var next := clampi(offset + amount, 0, maxi(0, rows().size() - COUNT))
	if offset != next: offset = next; menu.refresh()

func stick(value: float, delta: float) -> void:
	if not naming.is_empty() or absf(value) < 0.4: scroll = 0; return
	scroll -= value * delta * 7.0
	if absf(scroll) >= 1: var amount := int(scroll); scroll -= amount; move(amount)

func button(label: String, point: Vector2, width: float, action: Dictionary, enabled: bool = true) -> void:
	if menu._state.get("global_voice_manager", false): point.y -= 0.75
	var id := BASE + actions.size(); actions[id] = action
	var text: String = label if action.get("operation", "") == "edit_name" else menu.I18n.t(label)
	menu._button(id, menu._fit_title(text, "", width - 0.018, menu.TEXT_BODY), point, Vector2(width, 0.065), enabled)
	menu.set_label_size(menu._buttons.back().node.get_child(0), menu.TEXT_BODY)

func icon(glyph: String, point: Vector2, action: Dictionary, tip: String, enabled: bool = true, selected: bool = false) -> void:
	if menu._state.get("global_voice_manager", false): point.y -= 0.75
	var id := BASE + actions.size(); actions[id] = action
	menu._glyph(id, glyph, point, 0.062, enabled, menu.I18n.t(tip))
	var item: Dictionary = menu._buttons.back()
	item.hover_disabled = not enabled
	if selected:
		item.foreground = menu.ACCENT
		item.node.get_child(1).material_override.albedo_color = menu.ACCENT

func text_cell(text: String, point: Vector2, width: float, action: Dictionary, tip: String) -> void:
	if menu._state.get("global_voice_manager", false): point.y -= 0.75
	var id := BASE + actions.size(); actions[id] = action
	menu._text_button(id, menu._fit_title(text.replace("\n", " / "), "", width - 0.025, 18), point, Vector2(width, 0.068))
	var node: Label3D = menu._buttons.back().node.get_child(0)
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; node.position.x = -width / 2 + 0.012
	menu._tips[id] = tip

func stripe(y: float, index: int) -> void:
	if menu._state.get("global_voice_manager", false): y -= 0.75
	var tile: MeshInstance3D = menu._quad(Vector2(1.34, ROW_PITCH - 0.004), Vector3(0, y, 0.0012), Color(menu.TILE, 0.42 if index % 2 == 0 else 0.12), 10)
	menu.add_child(tile); menu._decorations.append(tile)

func label(text: String, point: Vector2, size: int = 18) -> Label3D:
	if menu._state.get("global_voice_manager", false): point.y -= 0.75
	var node: Label3D = menu._label(text, Vector3(point.x, point.y, 0.005), size)
	node.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return node

func _audio_label(track: Dictionary) -> String:
	var id := int(track.get("id", 0))
	# Reuse the playback menu's localized labels without changing native track IDs.
	for option in menu._state.get("audio_options", []):
		if int(option.get("value", -1)) == id: return str(option.label)
	var title := str(track.get("title", "")).replace("\n", " ").replace("\r", " ").strip_edges()
	if title.is_empty(): title = menu.I18n.t("Track %d") % id
	var language := Languages.canonical(str(track.get("language", "")))
	return title + (" · " + menu.I18n.t(Languages.NAMES[language]) if not language.is_empty() else "")

func draw() -> void:
	if source != str(menu._state.get("source_uri", "")):
		opened = false; editor.cancel(); return
	var backend: Dictionary = menu._state.get("narration_clone_state", {})
	if not library and backend.has("opened") and not backend.opened:
		opened = false; editor.cancel(); return
	actions.clear()
	if saving and menu._state.get("narration_clone_state", {}).get("state", "") == "saved":
		saving = false; naming.clear()
	var items := rows(); offset = clampi(offset, 0, maxi(0, items.size() - COUNT))
	var first := 1.22 if library else 1.00
	var last := first - (maxi(1, mini(COUNT, items.size())) - 1) * ROW_PITCH
	var footer := last - 0.13
	var bottom := 0.80 if not naming.is_empty() else (0.84 if not confirm_delete.is_empty() else footer - 0.055)
	var height := 1.425 - bottom
	var centre := (1.425 + bottom) / 2 - (0.75 if menu._state.get("global_voice_manager", false) else 0.0)
	var panel: MeshInstance3D = menu._quad(Vector2(1.46, height), Vector3(0, centre, 0.001), Color(menu.PANEL, 0.98), 10)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, Vector2(1.46, height))
	button("‹", Vector2(-0.65, 1.36), 0.07, {"operation": "back"})
	label(menu.I18n.t("My voices" if library else "Clone voice"), Vector2(-0.56, 1.36), menu.TEXT_TITLE).font = menu.ui_bold_font()
	if library and naming.is_empty() and confirm_delete.is_empty() and not menu._state.get("global_voice_manager", false): button("Start cloning", Vector2(0.25, 1.36), 0.34, {"operation": "start"}, bool(menu._state.get("narration_available", false)))
	button("Close", Vector2(0.58, 1.36), 0.20, {"operation": "close"})
	if not naming.is_empty(): _draw_name(); return
	if not confirm_delete.is_empty():
		label(menu.I18n.t("Delete this voice?"), Vector2(-0.65, 1.20), 20)
		for voice in menu._state.get("narration_personal_voices", []):
			if voice.id == confirm_delete: label(menu._fit_title(str(voice.name), "", 1.20, 18), Vector2(-0.64, 1.06), 18)
		button("Cancel", Vector2(-0.30, 0.94), 0.34, {"operation": "cancel_delete"})
		button("Delete", Vector2(0.30, 0.94), 0.34, {"operation": "delete", "id": confirm_delete})
		return
	var state: Dictionary = menu._state.get("narration_clone_state", {})
	if not library:
		var choices: Array = []
		for track in state.get("audio_options", []):
			choices.append({"value": int(track.get("id", 0)), "label": _audio_label(track), "literal": true})
		label(menu.I18n.t("Sample track"), Vector2(-0.65, 1.235), menu.TEXT_BODY)
		if choices.size() == 1:
			label(menu._fit_title(str(choices[0].label), "", 1.08, menu.TEXT_BODY), Vector2(-0.42, 1.235), menu.TEXT_BODY)
		elif choices.size() > 1:
			var audio_id := int(state.get("audio_id", 0))
			menu.choices.field(null, {"key": "narration_clone_audio", "value": audio_id, "choices": choices, "dropdown": true,
				"display_value": menu.I18n.t("Auto") if audio_id <= 0 else menu.I18n.t("Track %d") % audio_id}, Vector2(0.12, 1.235), 1.08, 0.065)
		button("Video position", Vector2(-0.34, 1.125), 0.60, {"operation": "nearby"})
		menu._tips[BASE + actions.size() - 1] = menu.I18n.t("Find 3–10 second subtitles, starting about 20 seconds before the current video position.")
		button("All subtitles", Vector2(0.34, 1.125), 0.60, {"operation": "candidates", "all": true})
		menu._tips[BASE + actions.size() - 1] = menu.I18n.t("Find matching subtitles from the beginning of the video.")
	label(menu.I18n.t("Voice name" if library else "Subtitles"), Vector2(-0.65, first + 0.064), menu.TEXT_AUX).modulate = menu.MUTED
	if not library:
		var hint := label(menu.I18n.t("Choose a clear 3–10 second voice clip without background noise for cloning."), Vector2(0.65, first + 0.064), menu.TEXT_BODY)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hint.font = menu.ui_bold_font(); hint.modulate = menu.ACCENT
	var y := first
	for index in range(offset, mini(items.size(), offset + COUNT)):
		var row: Dictionary = items[index]
		stripe(y, index)
		if library:
			var selected: bool = menu._state.get("narration_voice_kind", "preset") == "custom" and menu._state.get("narration_custom_voice", "") == row.id
			text_cell(str(row.name), Vector2(-0.285, y), 0.76, {"operation": "use", "id": row.id}, str(row.name))
			var busy: bool = VoiceStatus.preview_busy(state) and state.get("preview_id", "") == row.id
			icon("stop" if busy else "sound", Vector2(0.26, y), {"operation": "stop"} if busy else {"operation": "preview", "id": row.id}, "Stop preview" if busy else "Preview voice")
			icon("check" if selected else "circle", Vector2(0.38, y), {"operation": "use", "id": row.id}, "Set default" if menu._state.get("global_voice_manager", false) else "Use", true, selected)
			icon("edit", Vector2(0.50, y), {"operation": "rename_name", "id": row.id, "name": row.name}, "Rename")
			icon("trash", Vector2(0.62, y), {"operation": "confirm_delete", "id": row.id}, "Delete")
		else:
			var tip := "%s – %s · %.1f s\n%s" % [time(float(row.start)), time(float(row.end)), float(row.end) - float(row.start), str(row.text)]
			text_cell(str(row.text), Vector2(-0.185, y), 0.96, {"operation": "caption", "key": row.key}, tip)
			var original_busy: bool = state.get("active_key", "") == row.key and state.get("operation", "") == "original" and state.get("state", "") in ["preparing", "extracting", "playing_original"]
			var clone_busy: bool = state.get("active_key", "") == row.key and state.get("operation", "") == "clone" and state.get("state", "") in VoiceStatus.BUSY
			icon("stop" if original_busy else "sound", Vector2(0.38, y), {"operation": "stop"} if original_busy else {"operation": "original", "key": row.key}, "Stop preview" if original_busy else "Reference audio")
			icon("stop" if clone_busy else "subtitle_voice", Vector2(0.50, y), {"operation": "stop"} if clone_busy else {"operation": "clone", "key": row.key}, "Stop preview" if clone_busy else "Clone preview")
			icon("save", Vector2(0.62, y), {"operation": "save_name", "key": row.key}, "Save", state.get("ready_key", "") == row.key)
		y -= ROW_PITCH
	var message := status_text(state)
	if items.is_empty():
		var empty_message := "No saved voices" if library else "No matching subtitles in this range"
		if not library and state.get("state", "") in ["pausing", "reading", "preparing", "error"]:
			empty_message = message; message = ""
		label(menu._fit_title(menu.I18n.t(empty_message), "", 1.28, menu.TEXT_BODY), Vector2(0, first), menu.TEXT_BODY).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button("↑", Vector2(-0.58, footer), 0.12, {"operation": "up"}, offset > 0)
	button("↓", Vector2(-0.42, footer), 0.12, {"operation": "down"}, offset + COUNT < items.size())
	label("%d–%d / %d" % [0 if items.is_empty() else offset + 1, mini(offset + COUNT, items.size()), items.size()], Vector2(-0.30, footer), menu.TEXT_AUX).modulate = menu.MUTED
	if not library: button("Load more", Vector2(0.43, footer), 0.44, {"operation": "candidates"}, not state.get("eof", false) and state.get("state", "") != "reading")
	if not message.is_empty(): label(menu._fit_title(menu.I18n.t(message), "", 1.28, menu.TEXT_AUX), Vector2(0, footer + 0.06), menu.TEXT_AUX).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu.choices.bounds = Vector2(0.285, 1.34); menu.choices.finish()

func _draw_name() -> void:
	label(menu.I18n.t("Voice name"), Vector2(-0.64, 1.23), menu.TEXT_BODY)
	button(menu._fit_title(draft, "", 1.20, menu.TEXT_BODY), Vector2(0, 1.10), 1.28, {"operation": "edit_name"})
	button("Cancel", Vector2(-0.36, 0.96), 0.48, {"operation": "cancel_name"})
	button("Save and use" if naming.operation == "save" else "Save", Vector2(0.30, 0.96), 0.62, {"operation": "submit_name"}, not draft.strip_edges().is_empty())
	var state: Dictionary = menu._state.get("narration_clone_state", {})
	var message := "Unable to save voice. Check the name and storage." if state.get("state") == "error" else status_text(state)
	if not message.is_empty(): label(menu.I18n.t(message), Vector2(0, 0.85), menu.TEXT_AUX).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func edit() -> void:
	editor.begin("voice-name", draft, 32, func(value: String): draft = value; menu.refresh(), func(value: String): draft = value; submit())

func submit() -> void:
	draft = editor.finish("voice-name", draft).strip_edges()
	if draft.is_empty(): return
	var value := naming.duplicate(true); value.name = draft; command(value)
	saving = value.operation == "save"
	if value.operation == "rename": naming.clear()
	menu.refresh()

func activate(target: int) -> bool:
	if not actions.has(target): return false
	var value: Dictionary = actions[target].duplicate(true)
	match str(value.operation):
		"back": back()
		"close": close()
		"start": open(false)
		"up": move(-COUNT)
		"down": move(COUNT)
		"nearby": command({"operation": "candidates", "start": maxf(0, float(menu._state.get("position_ms", 0)) / 1000.0 - 20)}); offset = 0
		"save_name": naming = {"operation": "save", "key": value.key}; draft = menu.I18n.t("My voice") + " %d" % (menu._state.get("narration_personal_voices", []).size() + 1); edit()
		"rename_name": naming = {"operation": "rename", "id": value.id}; draft = value.name; edit()
		"edit_name": edit()
		"submit_name": submit()
		"cancel_name": editor.cancel(); naming.clear()
		"confirm_delete": confirm_delete = value.id
		"cancel_delete": confirm_delete = ""
		"delete": confirm_delete = ""; command(value)
		"preview": value.language = menu._state.get("narration_resolved_language", "zh"); command(value)
		"caption": pass
		_: command(value)
	menu.refresh(); return true

static func time(seconds: float) -> String:
	var ms := roundi(seconds * 1000)
	return "%02d:%02d:%02d.%03d" % [ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000]
