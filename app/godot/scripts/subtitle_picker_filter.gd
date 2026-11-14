extends RefCounted
## Shared temporary filename filter for subtitles and SMB/DLNA directories.
## Complete directories stay local;
## incomplete cloud directories use the existing search/resolve protocol.
const OPEN := 985100
const INPUT := 985101
const CLEAR := 985102
const DesktopFiles := preload("res://scripts/environments/cinema_desktop_files.gd")
var menu: Node
var enabled := false
var seed := ""
var query := ""
var draft := ""
var context := ""
var anchor := {}
var remote_key := ""
var generation := 0
var directory_mode := false
const DIRECTORY_HINT := "Current folder · No subfolders"

func title() -> String: return "Filter current folder" if directory_mode or not menu.subtitle_picker_mode else "Filter subtitles"

func _init(owner: Node) -> void: menu = owner

static func default_query(filename: String) -> String:
	var name := filename.strip_edges()
	if name.contains("://"): return ""
	name = name.get_file()
	if name.get_extension().to_lower() in DesktopFiles.VIDEO_EXTENSIONS + ["iso"]:
		name = name.get_basename()
	return preload("res://scripts/system_text_input.gd").clean(name.strip_edges(), 128)

func reset(filename: String = "") -> void:
	close(false)
	seed = default_query(filename); query = ""; draft = ""; context = ""; anchor = {}
	directory_mode = false

func available() -> bool:
	if menu.archives.browsing or menu.account_panel.active() or not menu._editor.is_empty(): return false
	if not menu.subtitle_picker_mode:
		if menu.audio_import_mode or menu.voice_picker_mode or menu.image_picker_mode: return false
		return (menu.section == menu.Section.SMB and not menu._smb_server.is_empty() and not menu._smb_path.is_empty()) or (menu.section == menu.Section.DLNA and not menu._dlna_server.is_empty())
	match menu.section:
		menu.Section.LOCAL: return not menu._local_stack.is_empty()
		menu.Section.SMB: return not menu._smb_server.is_empty()
		menu.Section.CLOUD: return not menu._cloud_stack.is_empty() and menu.cloud_accounts.mode.is_empty()
	return false

func active() -> bool: return enabled and available()

func close(redraw: bool = true) -> void:
	menu.system_text_input.cancel("subtitle_filter")
	generation += 1; remote_key = ""
	if menu.cloud_search.subtitle_context: menu.cloud_search.close()
	var restore: bool = enabled and context == menu._filter_location()
	enabled = false
	if restore: menu._position_to_restore = anchor.duplicate(true)
	if redraw: menu.status = ""; menu.refresh()

func action(target: int) -> bool:
	if target == OPEN and available():
		if enabled: close()
		else:
			directory_mode = not menu.subtitle_picker_mode
			menu._save_folder_position()
			anchor = menu.capture_position(); context = menu._filter_location()
			enabled = true; query = "" if directory_mode else seed; draft = query
			menu._reset_navigation(); menu.refresh()
		return true
	if not active(): return false
	if target == menu.BACK: close(); return true
	if target == INPUT:
		draft = query
		menu.system_text_input.begin("subtitle_filter", draft, 128, _changed, _submitted, _cancelled)
		menu._draw(); return true
	if target == CLEAR:
		menu.system_text_input.cancel("subtitle_filter")
		apply(""); return true
	return false

func _changed(value: String) -> void: draft = value; menu._draw()
func _submitted(value: String) -> void: apply(value)
func _cancelled(value: String) -> void: draft = value; menu._draw()

func apply(value: String) -> void:
	query = menu.SystemTextInput.clean(value, 128).strip_edges(); draft = query
	generation += 1; remote_key = ""
	if menu.cloud_search.subtitle_context: menu.cloud_search.close()
	menu.status = ""; menu._reset_navigation(); menu.refresh()

func cloud_complete() -> bool:
	if menu._cloud_busy or menu._pending.values().has("cloud"): return false
	var paging = menu.cloud_pagination
	if paging.scope == paging._scope() and paging.mode == "all" and not paging.limited and paging.next_offset < 0 and paging.batch.is_empty(): return true
	var page: Dictionary = menu._subtitle_cloud_listing
	if menu._cloud_page != 0: return false
	if page.get("path", "!") != menu._cloud_path() or int(page.get("offset", -1)) != 0 or not page.has("next_offset") or int(page.next_offset) != -1: return false
	if page.get("limited", false) or page.get("truncated", false): return false
	var total := int(page.get("total", -1))
	var raw := int(page.get("raw_count", -1))
	var size := int(page.get("page_size", 48))
	var entries: Array = page.get("entries", [])
	if total < -1 or size <= 0 or entries.size() > size: return false
	if raw >= 0: return raw >= entries.size() and raw <= size and (total < 0 or raw == total)
	return total < 0 or (total >= entries.size() and total <= size)

func prepare() -> void:
	if not enabled: return
	var current: String = menu._filter_location()
	if directory_mode and (context != current or not available() or menu.subtitle_picker_mode):
		reset(); return
	if context != current:
		menu.system_text_input.cancel("subtitle_filter")
		if menu.cloud_search.subtitle_context: menu.cloud_search.close()
		context = current; anchor = {}; remote_key = ""; generation += 1
	if not active() or query.is_empty() or menu.section != menu.Section.CLOUD or cloud_complete():
		if menu.cloud_search.subtitle_context: menu.cloud_search.close()
		remote_key = ""; return
	if menu._cloud_busy or menu._pending.values().has("cloud") or menu.cloud_error.opened: return
	var key := str([context, query])
	if remote_key == key: return
	remote_key = key; generation += 1
	_search.call_deferred(generation, key)

func _search(id: int, key: String) -> void:
	if id != generation or key != remote_key or not active() or menu.section != menu.Section.CLOUD: return
	if not menu.cloud_search.supported():
		menu.status = "Cloud search failed"; menu.refresh(); return
	menu.cloud_search.open_subtitles(query)

func filter_rows() -> void:
	if not active() or query.is_empty() or menu.cloud_search.subtitle_context: return
	var needle := query.to_lower()
	menu.rows.assign(menu.rows.filter(func(row): return (not directory_mode and (row.get("folder", false) or not row.has("uri"))) or str(row.get("title", "")).to_lower().contains(needle)))
	menu.scroll = clampf(menu.scroll, 0, menu._max_scroll())

func status_text() -> String:
	if active() and not query.is_empty() and menu.status.is_empty() and not menu.cloud_search.subtitle_context and remote_key.is_empty() and not menu.rows.any(func(row): return directory_mode or (row.has("uri") and not row.get("folder", false))):
		return "No matching files"
	return menu.status

func draw() -> void:
	if not active(): return
	var text := draft if menu.system_text_input.active("subtitle_filter") else query
	var compact: bool = menu.compact
	var y := 0.215 if compact else 0.335
	var width := 0.88 if compact else 1.13
	menu._button(INPUT, menu._fit_title(text if not text.is_empty() else menu.I18n.t(title()), "", width - 0.15, 20), Vector2(-0.04 if compact else 0.10, y), Vector2(width, 0.075), true, "", menu.system_text_input.active("subtitle_filter"))
	var button: Node3D = menu._buttons.back().node
	var label: Label3D = button.get_child(0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.position = Vector3(-width * 0.5 + 0.105, 0, 0.004)
	menu._icon("search", Vector3(-width * 0.5 + 0.055, 0, 0.006), 0.026, menu.MUTED, button)
	menu._tips[INPUT] = text
	menu._button(CLEAR, "", Vector2(0.47 if compact else 0.75, y), Vector2(0.075, 0.075), not text.is_empty(), "close")
	menu._tips[CLEAR] = menu.I18n.t("Clear")
	if directory_mode:
		menu._label(menu.I18n.t(DIRECTORY_HINT), Vector3(0 if compact else 0.13, y - 0.07, 0.004), 15).modulate = menu.MUTED

func draw_paging(y: float) -> bool:
	if not active() or query.is_empty(): return false
	if not menu.cloud_search.subtitle_context: return true
	var search = menu.cloud_search
	menu._button(search.PREVIOUS, "‹", Vector2(-0.45, y), Vector2(0.09, 0.07), search.pending == 0 and search.page > 0)
	menu._label(str(search.page + 1), Vector3(-0.27, y, 0.004), 18)
	menu._button(search.NEXT, "›", Vector2(-0.09, y), Vector2(0.09, 0.07), search.pending == 0 and not search.next_cursor.is_empty())
	return true
