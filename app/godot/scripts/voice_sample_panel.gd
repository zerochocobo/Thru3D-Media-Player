extends RefCounted
## Independent audio sampling UI; all commands use the existing clone controller.
const ROW_COUNT := 4
const ROW_PITCH := 0.175
const Languages := preload("res://scripts/narration_languages.gd")
var _owner: WeakRef
var panel: RefCounted:
	get: return _owner.get_ref()
var active := false
var page := "setup"
var scan_seconds := 120.0
var search_start := 0.0
var start := 0.0
var finish := 120.0
var duration := 0.0
var audio_id := 0
var language := "zh"
var title := ""
var _source_pending := false
var pending_crop := {}
var crop_preview_key := ""
var crop_labels := {}
var start_label: Label3D

func _init(owner: RefCounted) -> void: _owner = weakref(owner)
func state() -> Dictionary: return panel.menu._state.get("narration_clone_state", {})
func global_manager() -> bool: return bool(panel.menu._state.get("global_voice_manager", false))
func reset() -> void: active = false; _source_pending = false; pending_crop.clear(); crop_preview_key = ""; panel.menu.choices.capture.clear(); panel.menu.choices.reset()

func begin() -> void:
	if not global_manager():
		panel.close(); panel.menu.setting_requested.emit("narration_add_voice", true); return
	active = true; page = "setup"; panel.offset = 0
	language = str(panel.menu._state.get("narration_resolved_language", "zh"))
	if not Languages.NAMES.has(language): language = "zh"
	panel.menu.choices.reset()
	panel.command({"operation": "close"}); panel.menu.begin_voice_picker()

func selected(uri: String, name: String = "") -> void:
	active = true; page = "setup"; title = name; audio_id = 0; duration = 0; start = 0; scan_seconds = 120; finish = 120; search_start = 0; _source_pending = true
	panel.library = false; panel.offset = 0; pending_crop.clear(); crop_preview_key = ""
	panel.command({"operation": "open_source", "uri": uri, "mode": "speech", "language": language})

func setup() -> void:
	panel.menu.choices.capture.clear()
	pending_crop.clear(); crop_preview_key = ""; panel.command({"operation": "stop"}); page = "setup"; start = search_start; _clamp_range()

func back() -> void:
	panel.editor.cancel(); panel.menu.choices.reset()
	if page == "results": setup()
	else: begin()
	panel.menu.refresh()

func _button(label: String, x: float, y: float, width: float, operation: String, extra: Dictionary = {}, enabled: bool = true) -> void:
	var action := {"operation": "sample_" + operation}; action.merge(extra)
	panel.button(label, Vector2(x, y), width, action, enabled)
	if operation == "preset" and is_equal_approx(float(extra.get("seconds", 0)), scan_seconds):
		var button: Dictionary = panel.menu._buttons.back()
		button.base_color = panel.menu.SELECTED
		button.node.material_override.set_shader_parameter("surface_color", button.base_color)

func _field(row: Dictionary, y: float, width: float = 0.92, x: float = 0.16) -> void:
	panel.menu.choices.field(null, row, Vector2(x, y - (0.75 if global_manager() else 0.0)), width, 0.065)

func _start_row(y: float) -> void:
	panel.label(panel.menu.I18n.t("Start position"), Vector2(-0.64, y), 18)
	start_label = panel.label(panel.time(start).left(8), Vector2(0.0, y), 20)
	start_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button("−", -0.59, y - 0.11, 0.09, "step", {"amount": -30.0})
	_button("+", 0.59, y - 0.11, 0.09, "step", {"amount": 30.0})

func _options(y: float) -> void:
	var tracks: Array = []
	for track in state().get("audio_options", []): tracks.append({"value": int(track.id), "label": panel._audio_label(track), "literal": true})
	panel.label(panel.menu.I18n.t("Sample track"), Vector2(-0.64, y), 18)
	_field({"key": "voice_sample_track", "value": audio_id, "choices": tracks, "dropdown": true}, y)
	panel.label(panel.menu.I18n.t("Preview language"), Vector2(-0.64, y - 0.12), 18)
	_field({"key": "voice_sample_language", "value": language, "choices": Languages.choices().filter(func(row): return row.value != "auto"), "dropdown": true}, y - 0.12)

func draw() -> void:
	var menu: Node3D = panel.menu
	var backend := state()
	if _source_pending and backend.get("source_ready", false) and backend.get("state", "") == "ready":
		_source_pending = false; duration = maxf(0, float(backend.get("duration", 0)))
		audio_id = int(backend.get("audio_id", 0)); _clamp_range()
	_sync_crop(backend)
	panel.actions.clear(); crop_labels.clear()
	menu.choices.begin("voice-sample-" + page, Vector2(-0.45, 0.52) if global_manager() else Vector2(0.30, 1.27))
	var bottom := 0.06 if page == "results" else 0.18
	var height := 1.435 - bottom
	var centre := (1.435 + bottom) / 2 - (0.75 if global_manager() else 0.0)
	var tile: MeshInstance3D = menu._quad(Vector2(1.46, height), Vector3(0, centre, 0.001), Color(menu.PANEL, 0.98), 10)
	menu.add_child(tile); menu._decorations.append(tile); menu._block_rays(tile, Vector2(1.46, height))
	panel.button("‹", Vector2(-0.65, 1.36), 0.07, {"operation": "back"})
	panel.label(menu.I18n.t("Add voice"), Vector2(-0.55, 1.36), menu.TEXT_TITLE)
	panel.button("Close", Vector2(0.58, 1.36), 0.20, {"operation": "close"})
	if not panel.naming.is_empty(): panel._draw_name(); return
	panel.label(menu._fit_title(title, "", 1.28, 18), Vector2(-0.64, 1.24), 18)
	if page == "setup":
		_start_row(1.09)
		if duration > 3:
			_field({"key": "voice_sample_start", "value": start, "slider": true, "span": Vector3(0, duration - 3, 1), "unit": " s", "hide_value": true}, 0.98, 1.02, 0.0)
		panel.label(menu.I18n.t("Search duration"), Vector2(-0.64, 0.85), 18)
		for i in 3: _button(["2 min", "5 min", "10 min"][i], -0.44 + i * 0.44, 0.74, 0.40, "preset", {"seconds": [120, 300, 600][i]})
		_options(0.60)
		var ready := not _source_pending and bool(backend.get("source_ready", false)) and audio_id > 0
		_button("Find clips", 0, 0.30, 1.28, "run", {}, ready and valid_range())
	else:
		_button("Adjust range", -0.43, 1.12, 0.42, "setup")
		var scanning: bool = backend.get("operation", "") == "scan" and backend.get("state", "") in ["scanning", "model_verifying", "preparing"]
		if scanning: _button("Stop", 0.47, 1.12, 0.30, "stop")
		var items: Array = backend.get("candidates", [])
		panel.offset = clampi(panel.offset, 0, maxi(0, items.size() - ROW_COUNT))
		for i in range(panel.offset, mini(items.size(), panel.offset + ROW_COUNT)):
			var row: Dictionary = items[i]; var y: float = 0.99 - (i - panel.offset) * ROW_PITCH
			var key := str(row.key)
			var bounds := original_range(row)
			var selected := Vector2(float(row.start), float(row.end))
			if pending_crop.get("key", "") == key: selected = pending_crop.value
			var idle := pending_crop.is_empty()
			var busy: bool = backend.get("active_key", "") == key and backend.get("state", "") in panel.VoiceStatus.BUSY
			var original_busy: bool = busy and backend.get("operation", "") == "original"
			var original_action := {"operation": "stop"} if original_busy else {"operation": "original", "key": key}
			panel.button(range_text(selected), Vector2(-0.23, y + 0.015), 0.82, original_action, idle)
			crop_labels[key] = menu._buttons.back().node.get_child(0)
			panel.icon("stop" if original_busy else "sound", Vector2(0.30, y + 0.015), original_action, "Reference audio", idle)
			panel.icon("stop" if busy and backend.get("operation") == "clone" else "subtitle_voice", Vector2(0.45, y + 0.015), {"operation": "stop"} if busy and backend.get("operation") == "clone" else {"operation": "clone", "key": key}, "Clone preview", idle)
			panel.icon("save", Vector2(0.60, y + 0.015), {"operation": "save_name", "key": key}, "Save", idle and backend.get("ready_key", "") == key)
			menu.choices.field(null, {"key": "voice_sample_crop:" + key, "range_slider": true, "value": selected,
				"span": Vector3(bounds.x, bounds.y, 0.01), "gap": 3.0, "disabled": not idle,
				"waveform": row.get("original_waveform", row.get("waveform", []))}, Vector2(-0.215, y - 0.055 - (0.75 if global_manager() else 0.0)), 0.87, 0.065)
			if not same_range(selected, bounds):
				panel.icon("refresh", Vector2(0.60, y - 0.055), {"operation": "sample_reset_clip", "key": key}, "Reset clip", idle)
		_button("↑", -0.55, 0.30, 0.12, "page", {"amount": -ROW_COUNT}, panel.offset > 0 and pending_crop.is_empty())
		_button("↓", -0.39, 0.30, 0.12, "page", {"amount": ROW_COUNT}, panel.offset + ROW_COUNT < items.size() and pending_crop.is_empty())
		panel.label("%d / %d" % [mini(panel.offset + ROW_COUNT, items.size()), items.size()], Vector2(-0.25, 0.30), 18)
		if backend.get("scan_end", 0) > backend.get("scan_start", 0):
			var progress := clampf((float(backend.get("next", 0)) - float(backend.scan_start)) / (float(backend.scan_end) - float(backend.scan_start)), 0, 1)
			if backend.get("eof", false): progress = 1.0
			panel.label("%d%%" % roundi(progress * 100), Vector2(0.50, 0.20), 18)
			for part in [false, true]:
				var width: float = 1.04 * progress if part else 1.04
				var bar: MeshInstance3D = menu._quad(Vector2(maxf(0.001, width), 0.008), Vector3(-0.64 + width / 2, 0.20 - (0.75 if global_manager() else 0.0), 0.005), menu.ACCENT if part else menu.MUTED, 13 if part else 12)
				menu.add_child(bar); menu._decorations.append(bar)
	var message: String = panel.status_text(backend)
	if message.is_empty(): message = str(backend.get("notice", ""))
	panel.label(menu._fit_title(menu.I18n.t(message), "", 1.28, 16), Vector2(0, bottom + 0.04), 16).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu.choices.finish()

static func original_range(row: Dictionary) -> Vector2:
	return Vector2(float(row.get("original_start", row.start)), float(row.get("original_end", row.end)))

static func same_range(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) < 0.001 and absf(a.y - b.y) < 0.001

func range_text(value: Vector2) -> String:
	return "%s – %s · %.1f s" % [panel.time(value.x).left(10), panel.time(value.y).left(10), value.y - value.x]

func _row(key: String) -> Dictionary:
	for row in state().get("candidates", []):
		if row.get("key", "") == key: return row
	return {}

func _sync_crop(backend: Dictionary) -> void:
	if pending_crop.is_empty(): return
	var row := _row(str(pending_crop.key))
	if row.is_empty() or backend.get("state", "") == "error" or same_range(Vector2(float(row.start), float(row.end)), pending_crop.value): pending_crop.clear()

func preview(key: String, value: Variant) -> bool:
	if active and key == "voice_sample_start":
		if is_instance_valid(start_label): start_label.text = panel.time(float(value)).left(8)
		return true
	if not active or not key.begins_with("voice_sample_crop:"): return false
	var id := key.trim_prefix("voice_sample_crop:")
	if crop_preview_key != key:
		crop_preview_key = key; panel.command({"operation": "stop"})
	if crop_labels.has(id) and is_instance_valid(crop_labels[id]): crop_labels[id].text = range_text(value)
	return true

func crop(key: String, value: Vector2) -> void:
	var row := _row(key)
	if row.is_empty() or not pending_crop.is_empty(): return
	var bounds := original_range(row)
	value.x = clampf(value.x, bounds.x, bounds.y - 3.0)
	value.y = clampf(value.y, value.x + 3.0, bounds.y)
	crop_preview_key = ""
	if same_range(value, Vector2(float(row.start), float(row.end))): panel.menu.refresh(); return
	pending_crop = {"key": key, "value": value}
	panel.command({"operation": "trim", "key": key, "start": value.x, "end": value.y})
	panel.menu.refresh()

func valid_range() -> bool:
	return is_finite(start) and is_finite(finish) and start >= 0 and finish - start >= 2.999 and finish - start <= 600.001 and (duration <= 0 or finish <= duration + 0.001)

func _clamp_range() -> void:
	start = maxf(0, start)
	if duration > 0: start = minf(start, maxf(0, duration - 3))
	finish = start + scan_seconds
	if duration > 0: finish = minf(finish, duration)

func choose(key: String, value: Variant) -> bool:
	if not active or not key.begins_with("voice_sample_"): return false
	if key.begins_with("voice_sample_crop:"): crop(key.trim_prefix("voice_sample_crop:"), value); return true
	match key:
		"voice_sample_track": audio_id = int(value); panel.command({"operation": "stop"})
		"voice_sample_language": language = str(value)
		"voice_sample_start": start = float(value)
	_clamp_range(); panel.menu.refresh(); return true

func action(value: Dictionary) -> bool:
	if not str(value.operation).begins_with("sample_"): return false
	match str(value.operation):
		"sample_back": back()
		"sample_preset": scan_seconds = float(value.seconds); _clamp_range()
		"sample_step": start = maxf(0, start + float(value.amount)); _clamp_range()
		"sample_setup": setup()
		"sample_reset_clip":
			var row := _row(str(value.key))
			if not row.is_empty(): crop(str(value.key), original_range(row))
		"sample_stop": panel.command({"operation": "stop"})
		"sample_page": panel.offset = maxi(0, panel.offset + int(value.amount))
		"sample_run":
			if valid_range():
				search_start = start; pending_crop.clear(); crop_preview_key = ""
				panel.command({"operation": "scan", "start": start, "end": finish, "audio_id": audio_id, "language": language})
				page = "results"; panel.offset = 0
	panel.menu.refresh(); return true
