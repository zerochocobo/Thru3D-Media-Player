extends RefCounted
## Browse tasks have one outstanding request and commit whole batches only.
## Rows are prepared in small frame budgets; drawing still uses LibraryMenu's viewport.
const Methods := preload("res://scripts/platform_methods.gd")
const Preferences := preload("res://scripts/cloud_paging_preferences.gd")
const DEFAULTS := {"115_open": 200, "baidu": 1000, "aliyun_open": 200, "quark_open": 100, "onedrive": 200, "webdav": 200}
const NAMES := {"115_open": "115", "baidu": "Baidu", "aliyun_open": "Aliyun", "quark_open": "Quark", "onedrive": "OneDrive", "webdav": "WebDAV"}
const MAX_RAW := 12000
const MAX_BYTES := 12 * 1024 * 1024
const MAX_PAGE := 100000
const OPEN := 9300
const CLOSE := 9301
const GO := 9302
const FIRST := 9303
const LAST := 9304
const ALL := 9305
const STOP := 9306
const RESUME := 9307
const PAGED := 9308
const CONFIRM := 9309
const DIGIT := 9320
const CLEAR := 9330
const ERASE := 9331
var menu: Node
var preferences := Preferences.new()
var opened := false
var warning := false
var input := ""
var fresh_input := true
var settings_expanded := false
var mode := "paged" # paged / loading / partial / all
var task := "" # jump / all
var pending := -1
var request := {}
var scope := ""
var location := ""
var directory_key := ""
var offsets := {0: 0}
var target := 0
var at_page := 0
var next_offset := 0
var raw_count := 0
var byte_count := 0
var batches := 0
var limited := false
var complete := false
var restarted := false
var accumulated: Array = []
var visible_rows: Array[Dictionary] = []
var seen := {}
var batch: Dictionary = {}
var build_index := 0
var queued := false
var queue_at := 0
var saved_scroll := 0.0
var row_filter := ""
var rebuilding := false
var restore_size := 0
var page_rows_active := false
var row_index_dirty := true
var row_index_enabled := false
var order_change_pending := false

func _init(owner: Node) -> void: menu = owner

static func choices(provider: String) -> Array:
	var result: Array = [{"value": 0, "label": "Auto (%d)" % int(DEFAULTS.get(provider, 200))}]
	var cap := 1000 if provider in ["baidu", "webdav"] else (100 if provider == "quark_open" else 200)
	for value in [48, 100, 200, 500, 1000]:
		if value <= cap: result.append({"value": value, "label": str(value)})
	return result

static func choice_label(provider: String, value: int) -> String:
	return "Auto (%d)" % int(DEFAULTS.get(provider, 200)) if value == 0 else str(value)

func settings_rows(settings: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = [{"title": menu.I18n.t("Cloud page sizes"), "group_header": true,
		"cloud_paging_group": true, "icon": "chevron_down" if settings_expanded else "next"}]
	if not settings_expanded: return rows
	for name in DEFAULTS:
		var key := "cloud_page_size/" + str(name)
		var value := int(settings.get("cloud_page_sizes", {}).get(name, 0))
		# Collapsed fields carry only their selected caption. Only the one opened
		# field materializes its options; ChoiceFields creates just its popup nodes.
		var options := choices(name) if menu.choices.opened == key else [{"value": value, "label": choice_label(name, value)}]
		rows.append({"title": menu.I18n.t(NAMES[name]), "key": key, "value": value, "choices": options, "dropdown": true})
	return rows

func provider() -> String:
	return str(menu._cloud_stack[0].get("provider", "")) if not menu._cloud_stack.is_empty() else ""

func supported() -> bool:
	return not menu._cloud_stack.is_empty() and Methods.supports(menu.platform, "media_cloud_page_options")

func page_size() -> int:
	return int(menu._cloud_page_size)

func desired_size() -> int:
	if not supported(): return 48
	var settings: Dictionary = menu.settings_provider.call() if menu.settings_provider.is_valid() else {}
	var value := int(settings.get("cloud_page_sizes", {}).get(provider(), 0))
	for option in choices(provider()):
		if int(option.value) == value: return int(DEFAULTS.get(provider(), 200)) if value == 0 else value
	return int(DEFAULTS.get(provider(), 200))

func _scope() -> String:
	return str([menu._cloud_path(), menu.file_actions.cloud_order(), page_size(), menu.subtitle_picker_mode, menu.audio_import_mode])

func _key() -> String:
	return preferences.key(menu._cloud_path(), str(menu._cloud_stack.back().get("cloud_id", "")))

func before_load(reset: bool, force: bool) -> bool:
	if not supported(): mode = "paged"; page_rows_active = false; return false
	if restore_size > 0:
		menu._cloud_page_size = restore_size; restore_size = 0
	elif reset or location != menu._cloud_path():
		menu._cloud_page_size = desired_size()
	var changed := scope != _scope()
	if changed or reset or force:
		offsets = {0: 0}
		mode = "paged"; accumulated = []; visible_rows = []; complete = false; page_rows_active = false
		scope = _scope(); location = menu._cloud_path(); directory_key = _key()
		# The remembered choice is independent of sort and visible file-type filters.
		if preferences.contains(directory_key):
			if preferences.forget(directory_key): start_all(); return true
			menu.status = "Folder preference could not be saved"
	mode = "paged"
	return false

func cancel() -> void:
	if pending >= 0 and Methods.supports(menu.platform, "media_cloud_cancel"):
		menu.platform.media_cloud_cancel(pending)
	pending = -1; queued = false; task = ""; opened = false; warning = false; order_change_pending = false
	if not batch.is_empty() and not rebuilding:
		accumulated.resize(int(batch.get("base_entries", accumulated.size())))
		visible_rows.resize(int(batch.get("base_rows", visible_rows.size())))
	if rebuilding: row_filter = ""
	batch = {}; rebuilding = false; build_index = 0
	if mode == "loading": mode = "partial"
	menu._cloud_busy = false

func page_received(result: Dictionary) -> void:
	if not supported(): return
	scope = _scope(); directory_key = _key(); mode = "paged"
	var page: int = menu._cloud_page
	offsets[page] = int(result.get("offset", 0))
	if menu._cloud_next >= 0: offsets[page + 1] = menu._cloud_next
	_trim_offsets(page)
	prepare_page_rows()

func prepare_page_rows() -> void:
	# A 1,000-row provider page needs the same frame budget as a full listing.
	page_rows_active = supported() and menu._cloud_entries.size() > 64
	if not page_rows_active: return
	visible_rows = []; build_index = 0; row_filter = _filter(); row_index_dirty = true
	batch = {"entries": menu._cloud_entries}; rebuilding = true
	menu._cloud_busy = true

func _trim_offsets(page: int) -> void:
	for value in offsets.keys():
		if int(value) != 0 and absi(int(value) - page) > 63: offsets.erase(value)

func jump(page: int) -> void:
	if not supported() or menu._cloud_busy: return
	if page < 0 or page >= MAX_PAGE: return
	var pages := page_count()
	if pages > 0 and page >= pages: return
	menu._browse_activity()
	cancel(); mode = "paged"; scope = _scope(); directory_key = _key()
	menu.file_actions.selection.clear(); menu.cloud_error.clear(); menu.status = ""
	target = page; task = "jump"; restarted = false
	if provider() in ["115_open", "baidu", "webdav"]:
		at_page = page; next_offset = int(offsets.get(page, page * page_size()))
	else:
		at_page = 0
		for known in offsets:
			if int(known) <= page and int(known) > at_page: at_page = int(known)
		next_offset = int(offsets.get(at_page, 0))
		opened = at_page != target
	_send(false); menu.refresh()

func page_count() -> int:
	return ceili(float(menu._cloud_total) / page_size()) if menu._cloud_total > 0 else (1 if menu._cloud_total == 0 else -1)

func start_all() -> void:
	if not supported(): return
	menu._cancel_cloud()
	mode = "loading"; task = "all"; opened = true; warning = false
	scope = _scope(); directory_key = _key()
	preferences.forget(directory_key)
	accumulated = []; visible_rows = []; seen = {}; offsets = {0: 0}; row_index_dirty = true
	batch = {}; build_index = 0; row_filter = _filter()
	raw_count = 0; byte_count = 0; batches = 0; limited = false; complete = false
	next_offset = 0; at_page = 0; restarted = false
	menu.file_actions.selection.clear(); menu.cloud_error.clear(); menu.status = ""
	menu._cloud_entries = []; menu.rows.clear(); menu._cloud_page_size = page_size()
	menu._cloud_location = menu._cloud_path(); menu._cloud_page = 0
	menu._cloud_total = -1
	menu.scroll = 0.0
	_send(true); menu.refresh()

func _send(force: bool) -> void:
	if scope != _scope(): cancel(); return
	queued = false; menu._cloud_busy = true
	request = {"path": menu._cloud_path(), "offset": next_offset, "order": menu.file_actions.cloud_order(), "page_size": page_size()}
	pending = menu.platform.media_cloud_page_options(request.path, next_offset, force, request.order,
		str(menu._cloud_stack.back().get("cloud_id", "")), page_size(), menu.subtitle_picker_mode)
	if pending < 0: _fail({"error": "Cloud connection failed"})

func _queue() -> void:
	queued = true
	# Respect existing provider limiters and avoid tight unbounded request chains.
	queue_at = Time.get_ticks_msec() + (1000 if provider() == "115_open" else 250)

func receive(id: int, payload: String) -> bool:
	if id != pending or pending < 0: return false
	pending = -1
	if scope != _scope() or menu.section != menu.Section.CLOUD: cancel(); return true
	var parsed: Variant = JSON.parse_string(payload)
	if not parsed is Dictionary: _fail({"error": "Cloud connection failed"}); return true
	var result: Dictionary = parsed
	if result.get("state", "error") != "ready":
		if result.get("error_reason", "") == "cloud_page_expired" and task == "jump" and not restarted:
			restarted = true; at_page = 0; next_offset = 0; offsets = {0: 0}; opened = true
			menu.status = "Rebuilding page index…"; _queue(); menu.refresh(); return true
		_fail(result); return true
	var fallback: bool = int(request.offset) == 0 and (task == "jump" or batches == 0) and bool(result.get("order_fallback", false)) and \
		result.get("sort_orders", []) is Array and str(result.get("order", "")) in result.get("sort_orders", [])
	if str(result.get("path", "")) != str(request.path) or int(result.get("offset", -1)) != int(request.offset) or \
		(str(result.get("order", "")) != str(request.order) and not fallback) or int(result.get("page_size", -1)) != int(request.page_size):
		_fail({"error": "Cloud connection failed", "error_detail": "cloud.paging: mismatched page"}); return true
	var entries: Variant = result.get("entries", [])
	var count := int(result.get("raw_count", -1))
	var next := int(result.get("next_offset", -1))
	if not entries is Array or count < 0 or count > page_size() or entries.size() > count or (next != -1 and next <= int(request.offset)):
		_fail({"error": "Cloud connection failed", "error_detail": "cloud.paging: invalid count or continuation"}); return true
	if next >= 0: offsets[at_page + 1] = next
	offsets[at_page] = int(request.offset); _trim_offsets(at_page)
	menu._cloud_total = int(result.get("total", -1))
	if task == "jump":
		if at_page < target and next >= 0:
			if fallback: _commit_order(result)
			at_page += 1; next_offset = next; _queue(); menu.refresh(); return true
		# Empty random offsets do not establish the actual end of an unknown directory.
		if at_page > 0 and count == 0 and next < 0:
			_fail({"error": "Page unavailable"}); return true
		menu._cloud_entries = entries
		menu._cloud_page = at_page; menu._cloud_requested_page = at_page
		menu._cloud_page_size = page_size(); menu._cloud_next = next
		menu._cloud_offsets.resize(at_page + 1); menu._cloud_offsets[at_page] = int(request.offset)
		_commit_order(result)
		menu.scroll = 0.0; menu._position_to_restore = {}
		task = ""; opened = false; menu._cloud_busy = false; menu.status = ""
		prepare_page_rows()
		_finish_view(); return true
	if raw_count + count > MAX_RAW or byte_count + payload.to_utf8_buffer().size() > MAX_BYTES or batches >= 2000:
		limited = true; _fail({"error": "Directory limit reached"}); return true
	# Raw identities include formats hidden by the UI, so a repeated filtered-out
	# record cannot make an incomplete directory appear successful.
	var raw_ids: Variant = result.get("raw_ids", [])
	if not raw_ids is Array or raw_ids.size() != count:
		_fail({"error": "Cloud connection failed", "error_detail": "cloud.paging: missing raw identities"}); return true
	var keys := {}
	for identity in raw_ids:
		var key := str(identity)
		if key.is_empty() or seen.has(key) or keys.has(key):
			_fail({"error": "Directory changed; reload"}); return true
		keys[key] = true
	for entry in entries:
		if not entry is Dictionary:
			_fail({"error": "Cloud connection failed"}); return true
	if batches == 0: _commit_order(result)
	batch = result; batch["payload_bytes"] = payload.to_utf8_buffer().size(); build_index = 0
	batch["identities"] = keys; batch["base_entries"] = accumulated.size(); batch["base_rows"] = visible_rows.size()
	return true

func _commit_order(result: Dictionary) -> void:
	var changed: bool = not menu.file_actions.cloud_requested_order.is_empty()
	if result.get("sort_orders") is Array: menu._cloud_stack[0]["sort_orders"] = result.sort_orders.duplicate()
	menu.file_actions.commit_cloud(str(result.order)); menu.cloud_search.observe(result)
	scope = _scope()
	order_change_pending = order_change_pending or changed

func _finish_view() -> void:
	menu.refresh()
	if order_change_pending and batch.is_empty():
		order_change_pending = false
		menu.directory_order_changed.emit()

func _filter() -> String: return str([menu.media_filter, menu.audio_import_mode, menu.subtitle_picker_mode])

func _append_row(entry: Dictionary) -> void:
	var row: Dictionary = menu._entry_row(entry)
	if not row.has("container"):
		if menu.audio_import_mode and row.get("kind", "") != "audio": return
		if not menu.audio_import_mode and row.get("kind", "") == "audio": return
		if not menu.subtitle_picker_mode and not menu.audio_import_mode and menu.media_filter > 0 and row.get("kind", "video") != ("image" if menu.media_filter == 2 else "video"): return
	visible_rows.append(row)
	row_index_dirty = true

func tick() -> void:
	if task != "" and scope != _scope(): cancel(); return
	if not batch.is_empty():
		var start := Time.get_ticks_usec()
		var entries: Array = batch.entries
		var count := 0
		while build_index < entries.size() and count < 32 and Time.get_ticks_usec() - start < 2000:
			if not rebuilding: accumulated.append(entries[build_index])
			_append_row(entries[build_index]); build_index += 1; count += 1
		if build_index < entries.size(): return
		if rebuilding:
			batch = {}; rebuilding = false
			if mode == "paged" and task.is_empty() and pending < 0: menu._cloud_busy = false
			_finish_view()
			if mode == "paged" and not menu._return_uri.is_empty() and menu.rows.any(func(row): return str(row.get("uri", "")) == menu._return_uri):
				menu.remember_playback_context(menu._return_uri)
			return
		raw_count += int(batch.raw_count); byte_count += int(batch.payload_bytes); batches += 1
		seen.merge(batch.identities)
		next_offset = int(batch.next_offset); menu._cloud_entries = accumulated; menu._cloud_next = next_offset
		batch = {}; at_page += 1
		if next_offset < 0:
			if menu._cloud_total >= 0 and raw_count != menu._cloud_total:
				_fail({"error": "Directory changed; reload"}); return
			var was_loading := task == "all"
			complete = true; mode = "all"; task = ""; opened = false; menu._cloud_busy = false
			if was_loading and not preferences.remember(directory_key): menu.status = "Folder preference could not be saved"
			_finish_view(); return
		if raw_count >= MAX_RAW or byte_count >= MAX_BYTES:
			limited = true; _fail({"error": "Directory limit reached"}); return
		if task == "all": _queue()
		_finish_view()
	if queued and Time.get_ticks_msec() >= queue_at: _send(false)

func use_rows() -> bool:
	if (mode == "paged" and not page_rows_active) or scope != _scope() or menu.cloud_search.active: return false
	if row_filter != _filter() and rebuilding:
		batch = {}; rebuilding = false
	if row_filter != _filter() and batch.is_empty():
		row_filter = _filter(); visible_rows = []; build_index = 0
		row_index_dirty = true
		batch = {"entries": menu._cloud_entries if mode == "paged" else accumulated}; rebuilding = true
	menu.rows.assign(visible_rows)
	if row_index_dirty or row_index_enabled != menu.file_actions.enabled:
		menu.file_actions.reconcile()
		row_index_dirty = false; row_index_enabled = menu.file_actions.enabled
	# Loading/page modals have different columns; restore only once the directory layout is visible.
	if not opened and not menu._position_to_restore.is_empty() and batch.is_empty() and (mode == "paged" or complete or (mode == "partial" and task.is_empty()) or menu.Presentation.anchor_index(menu.rows, menu._position_to_restore) >= 0):
		menu.scroll = menu.Presentation.position(menu.rows, menu._position_to_restore, menu._cols())
		menu._position_to_restore = {}
	menu.scroll = clampf(menu.scroll, 0.0, menu._max_scroll())
	return true

func _fail(result: Dictionary) -> void:
	if result.get("error_reason", "") == "cloud_metadata_limit": limited = true
	menu._cloud_busy = false; queued = false; pending = -1
	if task == "all": mode = "partial"
	task = ""; opened = false; complete = false
	menu.file_actions.cloud_failed(); scope = _scope(); row_index_dirty = true
	menu.status = str(result.get("error", "Cloud connection failed"))
	menu.cloud_error.receive(result); menu.refresh()

func files_changed(removed: int) -> void:
	if scope != _scope() or (mode == "paged" and not page_rows_active): return
	visible_rows.assign(menu.rows)
	if mode != "paged":
		accumulated = menu._cloud_entries; raw_count = maxi(0, raw_count - removed)
	row_index_dirty = true

func stop() -> void:
	# Finish preparing an already accepted batch, but issue no more requests.
	var accepted := batch
	var changed_order := order_change_pending
	cancel()
	menu.file_actions.cloud_failed(); scope = _scope(); row_index_dirty = true
	batch = accepted
	order_change_pending = changed_order
	_finish_view()

func restore_paged() -> void:
	preferences.forget(_key()); cancel(); mode = "paged"; accumulated = []; visible_rows = []
	menu._cloud_positions.erase(menu._cloud_position_key()); menu._cloud_offsets.assign([0])
	menu._load_cloud(true, false, 0); menu.refresh()

func snapshot() -> Dictionary:
	if mode == "paged" or scope != _scope(): return {}
	return {"mode": mode, "raw_count": raw_count, "byte_count": byte_count, "batches": batches,
		"next_offset": next_offset, "at_page": at_page, "limited": limited, "seen": seen.duplicate(), "scope": scope}

func restore(value: Dictionary) -> void:
	cancel()
	if value.is_empty() or str(value.get("scope", "")) != _scope():
		mode = "paged"; scope = _scope(); prepare_page_rows(); return
	scope = _scope(); location = menu._cloud_path(); directory_key = _key()
	mode = "all" if value.get("mode") == "all" else "partial"
	raw_count = int(value.raw_count); byte_count = int(value.byte_count); batches = int(value.batches)
	next_offset = int(value.next_offset); at_page = int(value.at_page); limited = bool(value.limited)
	seen = value.seen.duplicate(); accumulated = menu._cloud_entries; visible_rows = []; row_filter = ""

func action(value: int) -> bool:
	if value == OPEN and supported():
		opened = true; warning = false; input = str(menu._cloud_page + 1); fresh_input = true; saved_scroll = menu.scroll
		menu._drag = {}; menu._fling = 0.0; menu._draw(); return true
	if not opened and value not in [STOP, RESUME, PAGED]: return false
	if value == STOP: stop(); return true
	if value == PAGED: restore_paged(); return true
	if value == RESUME:
		if mode == "partial" and not limited and batch.is_empty():
			if menu.cloud_error.reason == "cloud_page_expired" or menu.status == "Directory changed; reload": start_all()
			else:
				mode = "loading"; task = "all"; opened = true; menu.cloud_error.clear(); menu.status = ""; _send(false); menu.refresh()
		return true
	if not opened: return false
	if value in [CLOSE, menu.BACK, menu.CLOSE]:
		if task != "": stop()
		else: opened = false; warning = false; menu._draw()
	elif task != "": return true
	elif value >= DIGIT and value < DIGIT + 10:
		if fresh_input: input = ""; fresh_input = false
		if input.length() < 6: input += str(value - DIGIT)
		menu._draw()
	elif value == CLEAR: input = ""; fresh_input = false; menu._draw()
	elif value == ERASE: input = input.left(-1); fresh_input = false; menu._draw()
	elif value == GO: jump(int(input) - 1)
	elif value == FIRST: jump(0)
	elif value == LAST and page_count() > 0: jump(page_count() - 1)
	elif value == ALL:
		warning = menu._cloud_total < 0 or menu._cloud_total > 2000
		if not warning: start_all()
		else: menu._draw()
	elif value == CONFIRM: start_all()
	return true

func draw_footer(y: float, compact: bool) -> bool:
	if not supported() or menu.cloud_search.active: return false
	var x := -0.32 if compact else -0.27
	if mode in ["all", "partial", "loading"]:
		var text: String = menu.I18n.t("All %d items" if mode == "all" else "Loaded %d items") % raw_count
		menu._label(text, Vector3(x - 0.06, y, 0.004), 16)
		menu._button(PAGED, "", Vector2(x + 0.16, y), Vector2(0.065, 0.065), true, "list")
		menu._tips[PAGED] = menu.I18n.t("Restore paging")
		if mode == "partial" and not limited:
			menu._button(RESUME, "", Vector2(x + 0.24, y), Vector2(0.065, 0.065), batch.is_empty(), "refresh")
			menu._tips[RESUME] = menu.I18n.t("Continue loading")
		return true
	var count := page_count()
	var text: String = "%d / %d" % [menu._cloud_page + 1, count] if count > 0 else menu.I18n.t("Page %d") % (menu._cloud_page + 1)
	menu._button(menu.CLOUD_PREVIOUS, "‹", Vector2(x - 0.18, y), Vector2(0.075, 0.065), not menu._cloud_busy and menu._cloud_page > 0)
	menu._button(OPEN, text, Vector2(x, y), Vector2(0.26, 0.065), not menu._cloud_busy)
	menu._button(menu.CLOUD_NEXT, "›", Vector2(x + 0.18, y), Vector2(0.075, 0.065), not menu._cloud_busy and menu._cloud_next >= 0)
	return true

func draw() -> void:
	menu._side.visible = false
	menu._set_backdrop(Vector2(1.1, 0.84))
	menu._block_rays(menu._backdrop, Vector2(1.1, 0.84))
	menu._button(CLOSE, "", Vector2(0.47, 0.35), Vector2(0.075, 0.065), true, "close")
	var title := "Load all" if warning or task == "all" else "Go to page"
	menu._label(menu.I18n.t(title), Vector3(0, 0.35, 0.004), 22)
	if task != "":
		var progress: String = menu.I18n.t("Loaded %d items") % raw_count if task == "all" else "%d → %d" % [at_page + 1, target + 1]
		menu._label(progress, Vector3(0, 0.1, 0.004), 25)
		menu._label(menu.I18n.t("Loading…"), Vector3(0, -0.02, 0.004), 18)
		menu._button(STOP, menu.I18n.t("Stop"), Vector2(0, -0.22), Vector2(0.32, 0.085))
		return
	if warning:
		menu._label(menu.I18n.t("Large folders may slow down the headset."), Vector3(0, 0.12, 0.004), 18)
		menu._label(menu.I18n.t("Loading stops at the safety limit."), Vector3(0, 0.02, 0.004), 18)
		menu._button(CONFIRM, menu.I18n.t("Load all"), Vector2(0, -0.2), Vector2(0.36, 0.085))
		return
	menu._label(input if not input.is_empty() else "—", Vector3(-0.19, 0.23, 0.004), 28)
	for digit in range(1, 10):
		menu._button(DIGIT + digit, str(digit), Vector2(-0.36 + ((digit - 1) % 3) * 0.17, 0.11 - ((digit - 1) / 3) * 0.1), Vector2(0.15, 0.085))
	for item in [[CLEAR, "C"], [DIGIT, "0"], [ERASE, ""]]:
		menu._button(int(item[0]), str(item[1]), Vector2(-0.36 + (0 if item[0] == CLEAR else 1 if item[0] == DIGIT else 2) * 0.17, -0.19), Vector2(0.15, 0.085), true, "backspace" if item[0] == ERASE else "")
	menu._button(FIRST, menu.I18n.t("First page"), Vector2(0.28, 0.16), Vector2(0.32, 0.075))
	if page_count() > 0: menu._button(LAST, menu.I18n.t("Last page"), Vector2(0.28, 0.055), Vector2(0.32, 0.075), page_count() <= MAX_PAGE)
	var valid := int(input) > 0 and int(input) <= MAX_PAGE and (page_count() < 0 or int(input) <= page_count())
	menu._button(GO, menu.I18n.t("Go"), Vector2(0.28, -0.12), Vector2(0.32, 0.1), valid)
	menu._lit(valid)
	menu._button(ALL, menu.I18n.t("Load all"), Vector2(0, -0.33), Vector2(0.76, 0.075))
