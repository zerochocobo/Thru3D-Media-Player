extends "res://scripts/ray_menu.gd"

const Distribution := preload("res://scripts/distribution_channel.gd")

## Library: left navigation (recent, local disk, SMB, DLNA, settings), right content with sub-tabs,
## breadcrumbs and a scrolling list (ray drag anywhere on the list, or either thumbstick). Sources answer
## asynchronously through the platform's media_list(id, json) signal. Selection is controller ray + trigger only.

signal chosen(uri: String, title: String)
signal browser_opened
signal cast_requested(action: String)
var cast_state := {}
func text_entry_active() -> bool: return system_text_input.active() or (visible and not _editor.is_empty())
const CastPanel := preload("res://scripts/cast_panel.gd")
signal directory_order_changed
signal audio_import_cancelled
signal image_picker_cancelled
signal image_selected(uri: String, title: String)
var image_picker_mode := false
var selected_pdf := {}
var voice_picker_mode := false
var _image_picker_dlna_retry := {}
signal subtitle_picker_cancelled
signal subtitle_selected(uri: String, title: String, location: Dictionary)
var subtitle_picker_mode := false
const SubtitleSources := preload("res://scripts/subtitle_sources.gd")
signal music_requested
signal online_panoramas_requested
const ONLINE_PANORAMAS := 985002
signal music_toggle_requested
signal audio_preview_requested(uri: String, title: String)
signal audio_preview_stopped
signal audio_preview_scrubbed(token: int, position_seconds: float, active: bool)
var audio_preview_seek := preload("res://scripts/audio_preview_seek.gd").new(self)
const AUDIO_PREVIEW_BASE := 5400
var _audio_preview_rows := {}
## Inline subtitle task buttons: target -> {"operation", "id"}; up to four per drawn row.
const SUBTITLE_TASK_BASE := 5500
var _subtitle_task_buttons := {}
var _audio_preview_scope := ""
var _audio_preview_state := {}
var _audio_preview_dirty := false
signal audio_import_selected(files: Array)
var background_audio_provider: Callable
const MUSIC_OPEN := 5300
const AUDIO_IMPORT_DONE := 5301
const AUDIO_IMPORT_CANCEL := 5302
var audio_selection := {}
var audio_import_mode := false
var _audio_import_context := {}
const AudioCatalog := preload("res://scripts/background_audio_catalog.gd")
const CinemaFeature := preload("res://scripts/environments/cinema_feature.gd")
const AudioStorageView := preload("res://scripts/audio_storage_view.gd")
var _audio_storage_labels: Array[Label3D] = []
var _audio_storage_refresh := 0
signal layout_requested
signal setting_changed(key: String, value: Variant)
signal setting_previewed(key: String, value: Variant)
signal storage_eject_requested(volume: Dictionary)
signal storage_removed(volume: Dictionary)
signal file_delete_preparing(uri: String)
signal file_deleted(uri: String)
signal file_renamed(old_uri: String, new_uri: String, title: String)
var current_file_provider: Callable
const Collections := preload("res://scripts/collection_menu.gd")
var collections := Collections.new(self)
var archives := preload("res://scripts/archive_panel.gd").new(self)
const FileActions := preload("res://scripts/library_file_actions.gd")
var file_actions := FileActions.new(self)

enum Section { RECENT, LOCAL, SMB, DLNA, CLOUD, SETTINGS, MEDIA_SERVER, WEB }
const NAV := ["Home", "Local files", "SMB network", "DLNA network", "Cloud drives", "Settings", "Media servers", "Web videos"]
const NAV_ICONS := ["history", "device", "server", "cast", "cloud", "settings", "media_library", "globe"]
const NAV_ORDER := [Section.RECENT, Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD, Section.WEB, Section.MEDIA_SERVER, Section.SETTINGS]
var web_video := preload("res://scripts/web_video_panel.gd").new(self)
var web_browser := preload("res://scripts/web_browser_panel.gd").new(self)
const ServerBrowser := preload("res://scripts/media_server_browser.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const SystemTextInput := preload("res://scripts/system_text_input.gd")
var system_text_input := SystemTextInput.new(self)
const StorageVolume := preload("res://scripts/storage_volume.gd")
var server_browser: RefCounted = ServerBrowser.new(self)
const CloudAccountActions := preload("res://scripts/cloud_account_actions.gd")
var cloud_accounts: RefCounted = CloudAccountActions.new(self)
const CloudSearch := preload("res://scripts/cloud_search.gd")
var cloud_search: RefCounted = CloudSearch.new(self)
const CloudPagination := preload("res://scripts/cloud_pagination.gd")
var cloud_pagination := CloudPagination.new(self)
const CloudBrowseError := preload("res://scripts/cloud_browse_error.gd")
var cloud_error := CloudBrowseError.new(self)
const AccountPanel := preload("res://scripts/account_panel.gd")
var account_panel: RefCounted = AccountPanel.new(self)
const Quality := preload("res://scripts/display_quality.gd")
const WatchPalette := preload("res://scripts/watch_palette.gd")
const PlaybackMenuDepth := preload("res://scripts/playback_menu_depth.gd")
const SeekPolicy := preload("res://scripts/seek_policy.gd")
const ChoiceFields := preload("res://scripts/choice_fields.gd")
var choices := ChoiceFields.new(self)
const VoiceManagerPanel := preload("res://scripts/narration_clone_panel.gd")
var voice_manager := VoiceManagerPanel.new(self)
var subtitle_queue_open := false
var _subtitle_queue_poll := 0
var _subtitle_queue_signature := ""
var _state := {}
var _voice_revision := -1
var _voice_drag := {}
const ControlsPage := preload("res://scripts/controls_page.gd")
var controls_page := ControlsPage.new(self)
const SETTING_TABS := ["Video", "VR subtitles", "Background", "About", "Display", "General", "Controls"]
const GENERAL_TAB := 5
const SETTING_ORDER := [GENERAL_TAB, DISPLAY_TAB, 0, 2, 6, 3]
const CONTROLS_TAB := 6
const DISPLAY_TAB := 4
const VIDEO_TAB := 0
const SUBTITLES_TAB := 1
const BACKGROUND_TAB := 2
const ABOUT_TAB := 3
const ABOUT_HOME := 36
var _about_page := 0 # app, credits
var _video_settings_expanded := {}
var _subtitle_settings_expanded := ""
## VR subtitle distances (metres); the text keeps its angular size at any distance.
const SubtitleDepth := preload("res://scripts/subtitle_depth.gd")
const SubtitleStyle := preload("res://scripts/subtitle_style.gd")
## Language rows in About: each language named in itself.
const LANGUAGE_NAMES := I18n.NAMES
const VISIBLE_ROWS := 7
const DRAG_START := 0.015          # metres of ray travel on the panel before a press becomes a drag
const STICK_DEADZONE := 0.2
const STICK_SPEED := 1.5           # visible pages per second at full deflection
const LIST_TOP := 0.33
const ROW_PITCH := 0.112
const SCROLL_HINT_PERIOD := 3.2
const SCROLL_HINT_AMPLITUDE := 0.0025
const SCROLL_HINT_GAP := 0.005
const FIELDS := ["name", "host", "user", "password"]
const FIELD_NAMES := ["Name", "Address", "User", "Password"]
const KEYS := [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", "."], ["z", "x", "c", "v", "b", "n", "m", "-", "_", "@"]]
const SYMBOLS := [["!", "#", "$", "%", "&", "*", "(", ")", "+", "="], ["/", "\\", ":", ";", "'", "\"", ",", "?", "~", "|"],
	["[", "]", "{", "}", "<", ">", "^", "`", ".", "@"], ["-", "_", "0", "1", "2", "3", "4", "5", "6", "7"]]

# Targets (ray_menu reserves negatives).
const NAV_BASE := 10
const TAB_BASE := 20
const BACK := 30
const ADD := 31
const REFRESH := 32
const EDIT := 33
const SAVE := 40
const CANCEL := 41
const DELETE := 42
const SHIFT := 43
const BACKSPACE := 44
const SPACE := 45
const SYMBOL_LAYER := 46
const GRANT := 47
const CLEAR_HISTORY := 49
const ALL_FILES := 34
const CLOUD_ACCOUNTS := 35
const CLOUD_PREVIOUS := 80
const CLOUD_NEXT := 81
const RESTART_APP := 82
const QUIT_APP := 83
const RECENT_PREVIOUS := 84
const RECENT_NEXT := 85
const USB_STORAGE := 86
const EJECT_STORAGE := 87
const SCROLLBAR := 48
const CRUMB_BASE := 50
const FILTER_BASE := 70
const MEDIA_FILTERS := ["All", "Video", "Images"]
const ImageInfo := preload("res://scripts/image_info.gd")
const Presentation := preload("res://scripts/library_presentation.gd")
const VIEW_LIST := 88
const VIEW_GRID := 89
const EXPAND_LIBRARY := 90
var view_mode := "grid"
var _position_to_restore := {}
var _return_uri := ""
var _cloud_requested_position := {}
## File content shares one grid/list preference; settings and entry pages keep their own layout.
const COLS := 4
const GRID_LINES := 3
const RECENT_PAGE_SIZE := COLS * GRID_LINES
const TILE_SIZE := Vector2(0.3, 0.27)
const GRID_PITCH := Vector2(0.33, 0.29)
const GRID_TOP := 0.375
const SELECTED := Color(0.16, 0.31, 0.27)
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const COVER_BYTES := 2 * 1024 * 1024
const FOLDER := Color(0.98, 0.78, 0.36)
const ROW_BASE := 100
const FIELD_BASE := 200
const KEY_BASE := 300

var catalog: RefCounted            # recent files
var platform: Object               # QuestPlayer singleton or a test double
var settings_provider: Callable    # -> {"profile", "profiles", "output_width", "version"}

var section := Section.RECENT
var tab := 0
var scroll := 0.0                  # first visible line; fractional while moving, settles on a whole line
var _drag := {}                    # hand, target, start_y, start_scroll, moved, last, at_us, velocity
var _fling := 0.0                  # lines per second left by a released drag
var _stick_ms := -1000             # last thumbstick scroll; the list settles once the stick is released
var _list: Node3D                  # drawn rows; moved for fractional scrolling
var _bar_thumb: MeshInstance3D
var _settings_scroll_hint: MeshInstance3D
var _settings_scroll_hint_y := 0.0
var _settings_scroll_hint_time := 0.0
var focus_index := 0 # Desktop keyboard preview only.
var rows: Array[Dictionary] = []
var _media_filter_location := ""
var media_browse_intent := 0
var media_filter := 0:
	set(value):
		media_filter=clampi(value,0,2)
		_media_filter_location=_filter_location()
var status := ""                   # English; shown through I18n
var _pending := {}                 # request id -> kind
var _local_entries: Array = []
var _local_stack: Array = []       # [{id, title}] from a storage volume down to the open folder
var _local_all_files := true       # the last listing could read the whole disk
var _local_grant_pending := false
var _local_volumes: Array = []
var _local_eject_pending := ""
var _local_release_notice := ""
var _storage_stop_pending := {}
var _storage_stop_targets: Array = []
var _storage_stop_failures: Array[String] = []
var _smb_servers: Array = []
var _smb_found: Array = []
var _smb_server := ""
var _smb_path := ""
var _smb_entries: Array = []
var _dlna_servers: Array = []
var _dlna_stack: Array = []        # [{id, title}] containers from the server root
var _dlna_server := ""
var _dlna_entries: Array = []
var _cloud_stack: Array = []
var _cloud_entries: Array = []
var _cloud_setup := false
var _cloud_page := 0 # zero-based, committed only after a successful response
var _recent_page := 0
var _recent_count := 0
var _recent_all_rows: Array[Dictionary] = []
var _cloud_requested_page := 0
var _cloud_offsets: Array[int] = [0]
var _cloud_next := -1
var _cloud_total := -1
var _cloud_page_size := 48
var _cloud_busy := false
var _cloud_location := ""
var _cloud_positions := {}
var _cloud_requested_scroll := 0.0
var _folder_positions := {}
const BrowseMemory := preload("res://scripts/directory_browse_memory.gd")
var browse_memory := BrowseMemory.new()
var _browse_revision := 0
var _browse_save_at := 0
var _browse_save_scope := ""
var _browse_loaded_scope := ""
var _browse_focus := {}
var _browse_cloud_restore := {}
var _browse_expired_page := false
var restore_directory_position := true
var _browse_return_restore := false
var _browse_parent_filters := {}
const BROWSE_POSITION_HINT := "Resume where you left off, separately for each folder and file type filter. When off, folders open at the top; returning to a parent keeps its position. Position memory follows history privacy settings."
var _restore_folder_key := ""
var _editor := {}                  # SMB or DLNA server; empty when not editing
var _field := 1
var _shift := false
var _symbols := false
var _side: Node3D                  # navigation column, angled towards the viewer
var _covers := {}                  # DLNA cover URL -> HTTPRequest while it downloads

## The browser stays a child of the transport while expanded. Data and requests remain shared.
var compact := false
var playback_expanded := false
var playback_controls_pose: Variant = null
var _compact_server_context := {}
var _compact_server_entries: Array = []
var _layout_anchor := {}
var _layout_scroll := 0.0
var _playback_context := {}
const COMPACT_SIZE := Vector2(1.16, 0.84)
const CONTEXT_FIELDS := ["section", "media_filter", "media_browse_intent", "_local_stack", "_local_entries", "_smb_server", "_smb_path", "_smb_entries",
	"_dlna_server", "_dlna_stack", "_dlna_entries", "_cloud_stack", "_cloud_entries", "_cloud_page", "_cloud_offsets", "_cloud_next", "_cloud_total", "_cloud_page_size", "_cloud_location", "_recent_page"]
const SEARCH_FIELDS := ["active", "editing", "query", "scope", "kind", "path", "entries", "cursors", "page", "next_cursor", "committed_request", "limited"]

func remember_playback_context(uri: String = "") -> void:
	_playback_context = {"anchor": capture_position(), "search": {}, "uri":uri, "location":_filter_location(), "photo_directory":photo_directory_context(), "cloud_paging": cloud_pagination.snapshot()}
	for key in CONTEXT_FIELDS:
		var value: Variant = get(key)
		_playback_context[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	if cloud_search.active:
		for key in SEARCH_FIELDS:
			var value: Variant = cloud_search.get(key)
			_playback_context.search[key] = value.duplicate(true) if value is Array or value is Dictionary else value

func set_compact(value: bool, restore_playback: bool = false) -> void:
	# A resumed layout may reapply the current mode while authentication is open.
	if account_panel.view == "web" and value == compact and not restore_playback: return
	if archives.browsing: restore_playback = false
	if restore_playback and browse_memory.locked(): _playback_context = {}
	if value: server_browser.sort_query.clear()
	var keep_current_visible := _current_file_visible()
	var anchor := _position_to_restore.duplicate(true) if not _position_to_restore.is_empty() else capture_position()
	if restore_playback:
		if _playback_context.is_empty():
			section = Section.RECENT
		else:
			for key in CONTEXT_FIELDS:
				var stored: Variant = _playback_context[key]
				set(key, stored.duplicate(true) if stored is Array or stored is Dictionary else stored)
			cloud_pagination.restore(_playback_context.get("cloud_paging", {}))
			anchor = _playback_context.anchor.duplicate(true)
			for key in _playback_context.search:
				var stored: Variant = _playback_context.search[key]
				cloud_search.set(key, stored.duplicate(true) if stored is Array or stored is Dictionary else stored)
			_media_filter_location = _filter_location()
	compact = value
	_drag = {}; _fling = 0.0; _hover.clear()
	file_actions.reset(); choices.reset(); controls_page.reset(); account_panel.close(); _editor = {}; cloud_accounts.mode = ""
	if compact and section == Section.MEDIA_SERVER and server_browser.view == "detail":
		_compact_server_context = server_browser.context_state()
		server_browser.entries = server_browser.playback_entries().duplicate(true)
		_compact_server_entries = server_browser.entries.map(func(item): return str(item.get("id", "")))
		server_browser.view = "scenes"; server_browser.keyboard = ""
	elif not compact and not _compact_server_context.is_empty():
		if section == Section.MEDIA_SERVER and server_browser.view == "scenes" and server_browser.query == _compact_server_context.query and server_browser.entries.map(func(item): return str(item.get("id", ""))) == _compact_server_entries:
			server_browser.restore_context(_compact_server_context)
			anchor = _compact_server_context.position
		_compact_server_context = {}; _compact_server_entries = []
	_position_to_restore = anchor
	refresh()
	if keep_current_visible and not _current_file_visible():
		_reveal_current_file(false)
		anchor = capture_position()
	_layout_anchor = anchor; _layout_scroll = scroll
	# Search resolution can open a file before its containing folder has ever been listed.
	if not archives.browsing and compact and platform and rows.is_empty() and section == Section.CLOUD and not cloud_search.active and not _cloud_stack.is_empty() and cloud_pagination.mode == "paged":
		_load_cloud(false, false, _cloud_page)
		refresh()

func show_playback_files(restore_playback: bool = false, cursor: Dictionary = {}) -> void:
	_return_uri = str(current_file_provider.call()) if current_file_provider.is_valid() else _return_uri
	if preload("res://scripts/pdf_pages.gd").container_page(_return_uri): archives.resume(_return_uri)
	set_compact(true, restore_playback)
	if archives.browsing:
		_reveal_current_file(false)
		_layout_anchor = capture_position(); _layout_scroll = scroll
		return
	if section == Section.RECENT:
		var index := _current_file_index(_recent_all_rows)
		if index >= 0 and _recent_page != index / RECENT_PAGE_SIZE:
			_recent_page = index / RECENT_PAGE_SIZE
			_position_to_restore = {}
			refresh()
	# Only move the viewport when navigation has carried the current item off screen.
	_reveal_current_file(false)
	if section == Section.CLOUD and cloud_pagination.mode == "paged" and _current_file_index(rows) < 0 and not cursor.is_empty() \
		and str(cursor.get("path", "")) == _cloud_path() and str(cursor.get("order", "")) == file_actions.cloud_order():
		var offsets: Array = cursor.get("offsets", [])
		var page := offsets.find(int(cursor.get("offset", -1)))
		if page >= 0:
			_cloud_offsets.assign(offsets)
			cloud_pagination.restore_size = int(cursor.get("page_size", 48))
			_load_cloud(false, false, page)
			_cloud_requested_position = {"key":_return_uri,"index":0}
			refresh()
	# An unlisted cloud folder finishes loading after the playback list opens.
	if section == Section.CLOUD and _cloud_busy and current_file_provider.is_valid():
		var uri := str(current_file_provider.call())
		if not uri.is_empty():
			_cloud_requested_position = {"key": uri, "index": _first_line() * _cols()}
	_layout_anchor = capture_position(); _layout_scroll = scroll
	if not _playback_context.is_empty():
		_playback_context.anchor = _layout_anchor.duplicate(true)
		_playback_context._recent_page = _recent_page

func _current_file_index(entries: Array) -> int:
	var uri := str(current_file_provider.call()) if current_file_provider.is_valid() else ""
	if uri.is_empty(): return -1
	for index in entries.size():
		var row: Dictionary = entries[index]
		if str(row.get("uri", row.get("scene", {}).get("uri", ""))) == uri: return index
	return -1

func _current_file_visible() -> bool:
	if not browser_content(): return false
	var index := _current_file_index(rows)
	return index >= _first_line() * _cols() and index < (_first_line() + _lines()) * _cols()

func _reveal_current_file(at_top: bool = true) -> void:
	if not browser_content(): return
	var index := _current_file_index(rows)
	if index < 0: return
	var line := float(index / _cols())
	_position_to_restore = {}
	_drag = {}; _fling = 0.0
	_set_scroll(line if at_top else clampf(scroll, line - _lines() + 1, line), false)

func hide_for_layout() -> void:
	_position_to_restore = capture_position() if browser_content() else {}
	if browser_content() and is_equal_approx(scroll, _layout_scroll) and rows.slice(_first_line() * _cols(), (_first_line() + 1) * _cols()).any(func(row): return Presentation.key(row) == str(_layout_anchor.get("key", ""))):
		_position_to_restore = _layout_anchor.duplicate(true)
	_save_folder_position()
	_drag = {}; _fling = 0.0; server_browser.gallery.capture.clear()
	super.dismiss()

func composition_root() -> Node3D:
	return get_parent() as Node3D if compact or playback_expanded else self

func _align_playback_panel() -> void:
	if not (compact or playback_expanded) or not get_parent().has_method("has_expanded_library"): return
	var controls: Node3D = get_parent()
	if controls._layout_eye != null and controls.arrange_library(self, panel_bounds()): return
	if compact:
		transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.72, 0))
		return
	var top: float = controls._backdrop.position.y + controls._backdrop.mesh.size.y * 0.5
	for button in controls._buttons:
		if button.node.visible:
			top = maxf(top, controls.to_local(button.node.global_position).y + button.rect.size.y * 0.5)
	# Keep the library's floating actions clear of the transport; its status row is shared.
	var bottom: float = _backdrop.position.y - _backdrop.mesh.size.y * 0.5 - 0.14
	transform = Transform3D(Basis.IDENTITY, Vector3(0, top + 0.08 - bottom, 0))

func has_pointer_capture() -> bool:
	return not web_browser.hand.is_empty() or not _voice_drag.is_empty() or not audio_preview_seek.capture.is_empty() or not _drag.is_empty() or not choices.capture.is_empty() or not account_panel.web_hand.is_empty()

func _place_device_status(centre: Vector2) -> void:
	if compact or playback_expanded:
		if device_status: device_status.visible = false
		return
	super(centre)
	device_status.visible = true

func refresh_session_controls(force: bool = false) -> void:
	if web_browser.active(): return
	if not compact and not playback_expanded: super(force)

func refresh_background_audio() -> void:
	if audio_import_mode:
		if has_pointer_capture(): _audio_preview_dirty = true
		else: refresh_music_quick_controls()
		return
	if music_quick and music_quick.expanded:
		refresh_music_quick_controls(); return
	var state: Dictionary = background_audio_provider.call() if background_audio_provider.is_valid() else {}
	for button in _buttons:
		if button.target == MUSIC_OPEN:
			button.base_color = SELECTED if state.get("audio_active", false) else TILE
			button.node.material_override.set_shader_parameter("surface_color", button.base_color)
			_tips[MUSIC_OPEN] = I18n.t("Music")

func toggle() -> void:
	if visible:
		dismiss()
	else:
		_browse_return_restore = false
		var anchor := (_position_to_restore.duplicate(true) if not _position_to_restore.is_empty() else capture_position()) if restore_directory_position or compact else {}
		var scoped := not compact and not _browse_scope().is_empty()
		var saved: Dictionary = browse_memory.lookup(_browse_scope(), _browse_network()) if scoped and restore_directory_position else {}
		if scoped: anchor = saved.get("position", {}) if section == Section.CLOUD and not archives.browsing else saved
		var recent_page := _recent_page
		visible = true; _reset_navigation(); _recent_page = recent_page; _position_to_restore = anchor; refresh()
		if not archives.browsing and scoped and section == Section.CLOUD and platform and cloud_pagination.mode == "paged" and int(saved.get("page", 0)) != _cloud_page:
			_load_cloud(); refresh()

func dismiss() -> void:
	# Website authentication is a modal workflow. Losing focus, an outside ray or
	# another controls toggle must not discard a phone/MFA step in progress.
	if account_panel.view == "web":
		account_panel.web_cancel()
		return
	web_browser.close()
	if voice_picker_mode: finish_voice_picker(); return
	archives.hide()
	cloud_pagination.settings_expanded = false
	_video_settings_expanded.clear()
	_subtitle_settings_expanded = ""
	file_actions.return_from_settings(false)
	if voice_manager.opened: voice_manager.close()
	_voice_drag.clear()
	system_text_input.cancel()
	_stop_audio_preview()
	var cancel_audio := audio_import_mode
	var cancel_subtitle := subtitle_picker_mode
	var cancel_image := image_picker_mode
	collections.selection.clear()
	if cloud_error.opened: cloud_error.close(); _rebuild_rows()
	var anchor := capture_position() if browser_content() else {}
	if visible and browser_content() and _playback_context.get("location", "") == _filter_location():
		remember_playback_context(str(_playback_context.get("uri", "")))
	_save_folder_position()
	# Manual filters belong to this visit, not the next browser session.
	if not archives.browsing: media_browse_intent=0; media_filter=0
	cloud_search.close()
	controls_page.reset()
	file_actions.reset()
	choices.reset()
	account_panel.close()
	server_browser.cancel()
	_cancel_cloud()
	_position_to_restore = anchor
	super()
	if cancel_audio or cancel_subtitle or cancel_image:
		_restore_audio_import_context()
		if cancel_audio: audio_import_cancelled.emit()
		elif cancel_subtitle: subtitle_picker_cancelled.emit()
		else: image_picker_cancelled.emit()
	composition_layout_changed.emit()

func _voice_sample_source(row: Dictionary) -> bool:
	return row.get("kind", "video") in ["video", "audio"]

func begin_voice_picker() -> void:
	if audio_import_mode or subtitle_picker_mode or image_picker_mode or voice_picker_mode: return
	_capture_file_picker_context()
	voice_picker_mode = true; voice_manager.opened = false
	_start_file_picker()

func finish_voice_picker(uri: String = "", title: String = "") -> void:
	_restore_audio_import_context()
	voice_manager.opened = true
	if not uri.is_empty(): voice_manager.sample.selected(uri, title)
	else: voice_manager.sample.reset(); voice_manager.library = true; voice_manager.command({"operation": "list"})
	refresh()

func begin_audio_import() -> void:
	if audio_import_mode or subtitle_picker_mode or image_picker_mode or voice_picker_mode: return
	_capture_file_picker_context()
	audio_import_mode = true
	_start_file_picker()

func _capture_file_picker_context() -> void:
	_audio_import_context = {"anchor": capture_position(), "editing": file_actions.enabled, "view_mode": view_mode}
	for key in CONTEXT_FIELDS:
		var value: Variant = get(key)
		_audio_import_context[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	_cancel_cloud()
	for id in _pending.keys():
		if _pending[id] in ["local", "smb_browse", "smb_servers", "dlna_browse", "dlna_servers", "dlna_discover", "dlna_picker_resume"]: _pending.erase(id)

func begin_image_picker() -> void:
	if subtitle_picker_mode or audio_import_mode or image_picker_mode or voice_picker_mode: return
	_capture_file_picker_context()
	image_picker_mode = true
	_image_picker_dlna_retry.clear()
	var saved := browse_memory.lookup(ImagePickerLocation.SCOPE, false)
	if saved.is_empty(): saved = browse_memory.lookup(ImagePickerLocation.SCOPE, true)
	var location := ImagePickerLocation.clean(saved.get("picker_location"))
	if not location.is_empty():
		section = {"local": Section.LOCAL, "smb": Section.SMB, "dlna": Section.DLNA, "cloud": Section.CLOUD}[location.source]
		match section:
			Section.LOCAL: _local_stack.assign(location.folders)
			Section.SMB: _smb_server = location.server; _smb_path = location.path
			Section.DLNA:
				_dlna_server = location.server; _dlna_stack.assign(location.folders)
				_image_picker_dlna_retry = {"server": _dlna_server, "object": str(_dlna_stack.back().id) if not _dlna_stack.is_empty() else "0", "attempted": false}
			Section.CLOUD: _cloud_stack.assign(location.folders)
	# Reload the saved route, not cached rows from the underlying video browser.
	_local_entries = []; _smb_entries = []; _dlna_entries = []; _cloud_entries = []
	_position_to_restore = {}; _layout_anchor = {}; _return_uri = ""; _restore_folder_key = ""
	_start_file_picker()

const ImagePickerLocation := preload("res://scripts/image_picker_location.gd")

func _image_picker_dlna_matches() -> bool:
	return image_picker_mode and section == Section.DLNA and _image_picker_dlna_retry.get("server", "!") == _dlna_server \
		and _image_picker_dlna_retry.get("object", "!") == (str(_dlna_stack.back().id) if not _dlna_stack.is_empty() else "0")

func _remember_image_picker_location() -> void:
	var location := {}
	match section:
		Section.LOCAL: location = {"source": "local", "folders": _local_stack}
		Section.SMB: location = {"source": "smb", "server": _smb_server, "path": _smb_path}
		Section.DLNA: location = {"source": "dlna", "server": _dlna_server, "folders": _dlna_stack}
		Section.CLOUD: location = {"source": "cloud", "folders": _cloud_stack}
	location = ImagePickerLocation.clean(location)
	if not location.is_empty():
		browse_memory.remember(ImagePickerLocation.SCOPE, section != Section.LOCAL, {"picker_location": location}, _browse_revision)
		browse_memory.flush()

func begin_subtitle_picker(location: Dictionary = {}) -> void:
	if subtitle_picker_mode or audio_import_mode or image_picker_mode or voice_picker_mode: return
	_capture_file_picker_context()
	subtitle_picker_mode = true
	section = {"local": Section.LOCAL, "smb": Section.SMB, "cloud": Section.CLOUD}.get(str(location.get("source", "")), Section.LOCAL)
	_local_stack.assign(_subtitle_folders(location.get("local", [])))
	_cloud_stack.assign(_subtitle_folders(location.get("cloud", [])))
	_smb_server = str(location.get("server", "")).left(128)
	_smb_path = str(location.get("path", "")).left(4096)
	_local_entries = []; _cloud_entries = []; _smb_entries = []
	_start_file_picker()

static func _subtitle_folders(value: Variant) -> Array:
	var folders: Array = []
	if not value is Array or value.size() > 64: return folders
	for row in value:
		if not row is Dictionary or not row.get("id") is String or str(row.id).length() > 4096: return []
		folders.append({"id": str(row.id), "title": str(row.get("title", "")).left(160), "cloud_id": str(row.get("cloud_id", "")).left(128)})
	return folders

func subtitle_picker_location() -> Dictionary:
	return {"source": {Section.LOCAL: "local", Section.SMB: "smb", Section.CLOUD: "cloud"}.get(section, "local"),
		"local": _subtitle_folders(_local_stack), "cloud": _subtitle_folders(_cloud_stack), "server": _smb_server, "path": _smb_path}

func _start_file_picker() -> void:
	media_browse_intent=0
	audio_selection.clear()
	collections.selection.clear(); file_actions.reset(); file_actions.enabled = false
	cloud_search.close(); choices.reset(); account_panel.close()
	if section not in ([Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD] if image_picker_mode or voice_picker_mode else [Section.LOCAL, Section.SMB, Section.CLOUD]): section = Section.LOCAL
	media_browse_intent = 2 if image_picker_mode else 0
	media_filter = media_browse_intent; view_mode = str(_audio_import_context.get("view_mode", "grid")) if image_picker_mode else "list"; scroll = 0
	_load_section(); refresh()

func _restore_audio_import_context() -> void:
	if image_picker_mode and archives.pdf: archives.close()
	_stop_audio_preview()
	audio_import_mode = false
	subtitle_picker_mode = false
	image_picker_mode = false
	voice_picker_mode = false
	_image_picker_dlna_retry.clear()
	audio_selection.clear()
	_cancel_cloud()
	for id in _pending.keys():
		if str(_pending[id]) in ["local", "smb_browse", "smb_servers", "dlna_browse", "dlna_servers", "dlna_discover", "dlna_picker_resume"]: _pending.erase(id)
	for key in CONTEXT_FIELDS:
		if _audio_import_context.has(key): set(key, _audio_import_context[key])
	file_actions.enabled = bool(_audio_import_context.get("editing", false))
	view_mode = str(_audio_import_context.get("view_mode", "grid"))
	_position_to_restore = _audio_import_context.get("anchor", {}).duplicate(true)
	_audio_import_context.clear()
	_rebuild_rows()

func _on_choice_changed(key: String, value: Variant) -> void:
	if voice_manager.sample.choose(key, value): return
	if controls_page.choose(key, value): return
	setting_changed.emit(key, value)

func _ready() -> void:
	super()
	choices.changed.connect(_on_choice_changed)
	choices.previewed.connect(func(key, value):
		if not voice_manager.sample.preview(key, value): setting_previewed.emit(key, value))
	_side = Node3D.new()
	_side.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(24)), Vector3(-0.84, 0, 0.1))
	add_child(_side)
	if platform and platform.has_signal("media_list"):
		platform.connect("media_list", _on_media_list)

func attach_platform(value: Object) -> void:
	platform = value
	file_actions.sync_platform()
	if platform and platform.has_signal("media_list") and not platform.is_connected("media_list", _on_media_list):
		platform.connect("media_list", _on_media_list)
	if platform and platform.has_signal("android_lifecycle") and not platform.is_connected("android_lifecycle", _on_android_lifecycle):
		platform.connect("android_lifecycle", _on_android_lifecycle)
	if PlatformMethods.supports(platform, "media_local_refresh_storage"):
		platform.media_local_refresh_storage()

func _on_android_lifecycle(state: String) -> void:
	if state == "resume" and web_browser.active(): platform.web_browser_action("resume")
	if state == "resume" and _local_grant_pending:
		_local_grant_pending = false
		if section == Section.LOCAL and not account_panel.active():
			_load_section()
			refresh()
	if account_panel.active():
		account_panel.lifecycle(state)
		return
	if state == "resume" and server_browser.setup:
		server_browser.setup = false
		if section == Section.MEDIA_SERVER:
			server_browser.load_servers()
			refresh()
	if state == "resume" and _cloud_setup:
		cloud_accounts.changed()

func _reset_navigation() -> void:
	controls_page.reset()
	choices.reset()
	_recent_page = 0
	_drag = {}
	_fling = 0.0
	scroll = 0.0
	focus_index = 0

# --- scrolling: ray drag on the list, thumbsticks, fling ------------------------------------------

## Point on the panel plane (local), even outside any button; null when the ray misses the plane.
func _plane_point(origin: Vector3, direction: Vector3) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return null
	var inverse := global_transform.affine_inverse()
	var start := inverse * origin
	var delta := inverse.basis * direction.normalized()
	if delta.z >= -0.00001 or start.z <= 0.0:
		return null
	return start + delta * (-start.z / delta.z)

func _row_target(target: int) -> bool:
	return target >= ROW_BASE and target < ROW_BASE + _drawn_slots()

## The list area, gaps between tiles included: a press there can drag the list.
func _in_list(point: Vector3) -> bool:
	if cloud_pagination.opened: return false
	if collections.active() or archives.opened: return false
	if not file_actions.modal.is_empty(): return false
	if (section == Section.MEDIA_SERVER and not archives.browsing) and server_browser.modal_open(): return false
	if compact:
		var span := _bar_span()
		return not rows.is_empty() and absf(point.x) < 0.56 and point.y < span.x + 0.01 and point.y > span.x - span.y - 0.02
	if controls_page.active() and controls_page.modal(): return false
	if controls_page.active() and controls_page.mode == 1 and point.x > -0.04: return false
	var span := _bar_span()
	return file_actions.modal.is_empty() and _editor.is_empty() and not rows.is_empty() and point.x > -0.56 and point.x < 0.86 \
		and point.y < span.x + 0.01 and point.y > span.x - span.y - 0.02

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	var login_ray: Array = account_panel.web_ray(hand, origin, direction, tracked)
	origin = login_ray[0]; direction = login_ray[1]
	if web_browser.press(hand, origin, direction, tracked): return true
	if voice_manager.opened and choices.press(hand, origin, direction, tracked): return true
	if voice_manager.opened:
		if not _voice_drag.is_empty(): return true
		update_pointer(hand, origin, direction, tracked)
		var voice_hit := ray_hit(origin, direction) if tracked else {}
		if voice_hit.is_empty() or not voice_hit.get("enabled", false): return not voice_hit.is_empty()
		var voice_target := int(voice_hit.target)
		if voice_manager.actions.get(voice_target, {}).get("operation", "") in ["use", "preview", "rename_name", "original", "clone", "save_name"]:
			_voice_drag = {"hand": hand, "target": voice_target, "plane": control_plane(voice_target), "start_y": float(control_point(voice_hit).y), "offset": voice_manager.offset, "moved": false}
		else: _activate_hit(voice_hit)
		return true
	if audio_preview_seek.press(hand, origin, direction, tracked): return true
	if section == Section.SETTINGS and choices.press(hand, origin, direction, tracked):
		_fling = 0.0; return true
	if account_panel.view == "web":
		if not account_panel.web_hand.is_empty(): return true
		var web_hit := ray_hit(origin, direction) if tracked else {}
		if int(web_hit.get("target", NONE)) in [AccountPanel.WEB, AccountPanel.WEB_SCROLL]:
			if account_panel.web_gecko(): super.update_pointer(hand, origin, direction, tracked)
			if not web_hit.get("enabled", false): return true
			account_panel.web_press(hand, web_hit.point, int(web_hit.target) == AccountPanel.WEB_SCROLL)
			return true
	if not compact and section == Section.MEDIA_SERVER and not account_panel.active() and server_browser.gallery.press(hand, origin, direction, tracked):
		_fling = 0.0; return true
	if not _drag.is_empty() and _drag.hand != hand: return true
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	var target := int(hit.get("target", NONE))
	var start_y := 0.0
	if not hit.is_empty() and target not in [SCROLLBAR, NONE] and not _row_target(target) and not collections.row_target(target) and not file_actions.selection_target(target):
		_activate_hit(hit)
		return true
	if hit.is_empty() or target == NONE:
		var point: Variant = _plane_point(origin, direction) if tracked else null
		if point == null or not _in_list(point):
			return not hit.is_empty()
		start_y = float(point.y)
	else:
		start_y = float(hit.point.y)
	# Rows, gaps and the scrollbar wait for release: a press that moves becomes a scroll.
	_fling = 0.0
	_drag = {"hand": hand, "target": target, "start_y": start_y, "start_scroll": scroll, "moved": false,
		"last": scroll, "at_us": Time.get_ticks_usec(), "velocity": 0.0}
	if collections.home():
		var index: int = collections.row_index(target)
		if index >= 0 and index < rows.size() and rows[index].has("uri"): _drag.collection_uri = str(rows[index].uri)
	if target == SCROLLBAR:
		_scroll_to_bar(start_y)
		_drag.moved = true
	return true

func cancel_pointer(hand: String) -> void:
	if web_browser.hand == hand: web_browser.cancel()
	if _voice_drag.get("hand", "") == hand: _voice_drag.clear()
	audio_preview_seek.cancel(hand)
	choices.cancel(hand)
	if server_browser.gallery.capture.get("hand", "") == hand: server_browser.gallery.capture.clear()
	if account_panel.web_hand == hand: account_panel.web_cancel()
	if not _drag.is_empty() and _drag.hand == hand:
		_drag = {}
		_fling = 0.0
	super(hand)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	var login_ray: Array = account_panel.web_ray(hand, origin, direction, tracked)
	origin = login_ray[0]; direction = login_ray[1]
	super(hand, origin, direction, tracked)
	web_browser.move(hand, origin, direction, tracked)
	if web_browser.hand == hand: return
	if voice_manager.opened:
		choices.update(hand, origin, direction, tracked)
		if _voice_drag.get("hand", "") == hand:
			var projected: Variant = project_pointer(origin, direction, _voice_drag.plane) if tracked else null
			if projected == null: _voice_drag.clear(); return
			var distance := float(projected.y) - float(_voice_drag.start_y)
			if absf(distance) > DRAG_START: _voice_drag.moved = true
			if _voice_drag.moved: voice_manager.move(int(_voice_drag.offset) + roundi(distance / (voice_manager.sample.ROW_PITCH if voice_manager.sample.active else VoiceManagerPanel.ROW_PITCH)) - voice_manager.offset)
		return
	audio_preview_seek.move(hand, origin, direction, tracked)
	collections.update_hover()
	choices.update(hand, origin, direction, tracked)
	server_browser.gallery.move(hand, origin, direction, tracked)
	if account_panel.web_hand == hand:
		var point: Variant = account_panel.web_project(origin, direction) if tracked else null
		if point == null: account_panel.web_cancel()
		else: account_panel.web_move(hand, point)
		return
	if not tracked and not _drag.is_empty() and _drag.hand == hand:
		_drag = {}
		_fling = 0.0
	if _drag.is_empty() or _drag.hand != hand or not tracked:
		return
	var point: Variant = _plane_point(origin, direction)
	if point == null:
		return
	var y := float(point.y)
	if int(_drag.target) == SCROLLBAR:
		_scroll_to_bar(y)
		return
	if not _drag.moved and absf(y - float(_drag.start_y)) < DRAG_START:
		return
	_drag.moved = true
	# Content follows the ray: moving the ray up shows later rows.
	_set_scroll(float(_drag.start_scroll) + (y - float(_drag.start_y)) / _pitch())
	var now := Time.get_ticks_usec()
	var seconds := (now - int(_drag.at_us)) / 1000000.0
	if seconds > 0.004:
		_drag.velocity = lerpf(float(_drag.velocity), (scroll - float(_drag.last)) / seconds, 0.5)
		_drag.last = scroll
		_drag.at_us = now

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	var login_ray: Array = account_panel.web_ray(hand, origin, direction, tracked)
	origin = login_ray[0]; direction = login_ray[1]
	if web_browser.release(hand, origin, direction, tracked): return
	if voice_manager.opened and choices.capture.get("hand", "") == hand:
		choices.release(hand, origin, direction, tracked); return
	if voice_manager.opened:
		if _voice_drag.get("hand", "") == hand:
			var captured := _voice_drag.duplicate(); _voice_drag.clear()
			if tracked and not captured.moved and int(ray_hit(origin, direction).get("target", NONE)) == int(captured.target): voice_manager.activate(int(captured.target))
		return
	if audio_preview_seek.release(hand, origin, direction, tracked): return
	if server_browser.gallery.release(hand, origin, direction, tracked): return
	if choices.capture.get("hand", "") == hand:
		choices.release(hand, origin, direction, tracked); return
	if account_panel.web_hand == hand:
		if account_panel.web_gecko(): super.update_pointer(hand, origin, direction, tracked)
		account_panel.web_release(hand, account_panel.web_project(origin, direction) if tracked else null)
		return
	if _drag.is_empty() or _drag.hand != hand:
		return
	var drag := _drag
	_drag = {}
	if drag.moved:
		# A quick flick keeps the list moving; a drag that stopped before release does not.
		var still := Time.get_ticks_usec() - int(drag.at_us) > 80000
		_fling = 0.0 if still or absf(float(drag.velocity)) < 1.5 else clampf(float(drag.velocity), -20.0, 20.0)
		return
	if not tracked or int(drag.target) == NONE:
		return
	if drag.has("collection_uri"):
		var index: int = collections.row_index(int(drag.target))
		if index < 0 or index >= rows.size() or str(rows[index].get("uri", "")) != str(drag.collection_uri): return
	var hit := ray_hit(origin, direction)
	if not hit.is_empty() and int(hit.target) == int(drag.target):
		_activate_hit(hit)

## Thumbstick y (up positive) scrolls the list; it never selects.
func stick_scroll(y: float, delta: float) -> void:
	if web_browser.scroll(y, delta): return
	if cloud_pagination.opened: return
	if voice_manager.opened:
		if not choices.stick_scroll(y, delta): voice_manager.stick(y, delta)
		return
	if not audio_preview_seek.capture.is_empty(): return
	if collections.active() or archives.opened: return
	if not archives.browsing and section == Section.MEDIA_SERVER and server_browser.modal_open(): return
	if not archives.browsing and not compact and section == Section.MEDIA_SERVER and not account_panel.active() and server_browser.gallery.fixed():
		server_browser.gallery.vertical_scroll(y, delta); return
	if controls_page.active() and not controls_page.pending.is_empty(): return
	if not choices.capture.is_empty(): return
	if not file_actions.modal.is_empty(): return
	if section == Section.SETTINGS and choices.stick_scroll(y, delta): return
	if account_panel.view == "web":
		if visible and account_panel.web_hand.is_empty() and is_finite(y) and absf(y) >= STICK_DEADZONE:
			account_panel.web_action("scroll", Vector2(0, -y * delta * 6.0))
		return
	if not visible or not _drag.is_empty() or not _editor.is_empty() or not is_finite(y) or absf(y) < STICK_DEADZONE:
		return
	_stick_ms = Time.get_ticks_msec()
	_fling = 0.0
	var amount := pow((absf(y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 1.6)
	_set_scroll(scroll - signf(y) * amount * _lines() * STICK_SPEED * delta)

func media_picture_open() -> bool:
	return visible and not compact and section == Section.MEDIA_SERVER and server_browser.view == "picture" \
		and not account_panel.active() and file_actions.modal.is_empty() and _editor.is_empty() \
		and server_browser.keyboard.is_empty() and not server_browser.modal_open()

func stick_scroll_horizontal(x: float, delta: float) -> void:
	if archives.browsing: return
	if compact: return
	if section == Section.MEDIA_SERVER and server_browser.modal_open(): return
	if visible and section == Section.MEDIA_SERVER and not account_panel.active() and file_actions.modal.is_empty() and _editor.is_empty():
		server_browser.gallery.stick_scroll(x, delta)

func _process(delta: float) -> void:
	web_video.tick()
	web_browser.tick()
	if visible and subtitle_queue_open and section == Section.SETTINGS and tab == VIDEO_TAB and Time.get_ticks_msec() > _subtitle_queue_poll and not has_pointer_capture() and choices.opened.is_empty():
		_subtitle_queue_poll = Time.get_ticks_msec() + 800
		var queue: Dictionary = settings_provider.call().get("subtitle_defaults", {}).get("subtitle_tasks", {})
		var signature := str(queue)
		if signature != _subtitle_queue_signature: _subtitle_queue_signature = signature; refresh()
	_animate_settings_scroll_hint(delta)
	archives.tick()
	cloud_pagination.tick()
	browse_memory.tick()
	if _browse_save_at > 0 and Time.get_ticks_msec() >= _browse_save_at:
		_browse_save_at = 0
		if visible and _browse_save_scope == _browse_scope(): _save_folder_position()
	if cloud_pagination.opened: return
	server_browser.backdrop.tick(delta)
	if voice_manager.opened and visible:
		var current: Dictionary = settings_provider.call().get("voice_manager", {}) if settings_provider.is_valid() else {}
		if int(current.get("narration_clone_state", {}).get("revision", 0)) != _voice_revision and not has_pointer_capture(): refresh()
		return
	if not _audio_preview_scope.is_empty() and (not visible or not audio_import_mode or _audio_preview_scope != _audio_preview_scope_key()): _stop_audio_preview()
	audio_preview_seek.poll(delta)
	if visible and audio_import_mode and _audio_preview_dirty and not has_pointer_capture():
		_audio_preview_dirty = false; refresh_music_quick_controls()
	if visible and audio_import_mode and Time.get_ticks_msec() >= _audio_storage_refresh:
		_audio_storage_refresh = Time.get_ticks_msec() + 1000
		AudioStorageView.update(self, _audio_storage_labels, background_audio_provider.call() if background_audio_provider.is_valid() else {})
	collections.poll()
	if collections.active() or archives.opened: return
	_poll_cache_usage()
	if not archives.browsing and section == Section.MEDIA_SERVER and server_browser.modal_open(): return
	if controls_page.active() and controls_page.modal(): return
	if not file_actions.modal.is_empty(): return
	if visible: account_panel.tick(delta)
	if not visible or has_pointer_capture() or Time.get_ticks_msec() - _stick_ms < 120:
		return
	if absf(_fling) > 0.4:
		var before := scroll
		_set_scroll(scroll + _fling * delta, false)
		_fling = 0.0 if scroll == before else _fling * exp(-4.0 * delta)
		return
	_fling = 0.0
	# At rest the list sits on a whole line.
	var line := roundf(scroll)
	if scroll != line:
		_set_scroll(move_toward(scroll, line, delta * 5.0), false)

func _set_scroll(value: float, user_activity: bool = true) -> void:
	var clamped := clampf(value, 0.0, _max_scroll())
	if clamped == scroll:
		if (section == Section.MEDIA_SERVER and not archives.browsing): server_browser.scroll_changed()
		return
	var redraw := floori(clamped + 0.001) != _first_line()
	scroll = clamped
	_browse_focus = {}
	if user_activity: _browse_activity()
	else:
		_browse_save_scope = _browse_scope(); _browse_save_at = Time.get_ticks_msec() + 500
	if redraw:
		if _plain_file_grid(): _redraw_file_rows()
		else: _draw()
	else:
		_place_list()
	if (section == Section.MEDIA_SERVER and not archives.browsing): server_browser.scroll_changed()

func _scroll_to_bar(y: float) -> void:
	var span := _bar_span()
	_set_scroll((span.x - y) / span.y * (_max_scroll() + 1.0) - 0.5)

## First drawn line (float noise from dragging cannot drop a line).
func _first_line() -> int:
	return floori(scroll + 0.001)

## Drawn rows: the visible lines plus one, which shows while the list is between lines.
func _drawn_slots() -> int:
	return _cols() * (_lines() + 1)

## Shift the drawn rows by the fractional scroll; rows past the edges of the list hide.
func _place_list() -> void:
	if not is_instance_valid(_list):
		return
	var fraction := scroll - _first_line()
	_list.position.y = fraction * _pitch()
	composition_changed.emit()
	var last_row_bottom := INF
	for button in _buttons:
		var row_target := int(button.get("list_row", button.target))
		if _row_target(row_target):
			var line := float((row_target - ROW_BASE) / _cols()) - fraction
			button.node.visible = line > -0.35 and line < _lines() - 0.65
			if is_instance_valid(_settings_scroll_hint) and button.node.visible:
				last_row_bottom = minf(last_row_bottom, to_local(button.node.global_position).y - button.rect.size.y / 2)
	collections.update_hover()
	if is_instance_valid(_bar_thumb):
		var span := _bar_span()
		var thumb: float = _bar_thumb.mesh.size.y
		var travel := (span.y - thumb) * (scroll / _max_scroll() if _max_scroll() > 0 else 0.0)
		_bar_thumb.position.y = span.x - travel - thumb * 0.5
	if is_instance_valid(_settings_scroll_hint):
		_settings_scroll_hint.visible = scroll < _max_scroll() - 0.001
		if is_finite(last_row_bottom):
			_settings_scroll_hint_y = last_row_bottom - _settings_scroll_hint.mesh.size.y / 2 - SCROLL_HINT_GAP - SCROLL_HINT_AMPLITUDE
		_animate_settings_scroll_hint(0.0)

func _animate_settings_scroll_hint(delta: float) -> void:
	if not is_instance_valid(_settings_scroll_hint) or not _settings_scroll_hint.is_visible_in_tree():
		_settings_scroll_hint_time = 0.0
		return
	_settings_scroll_hint_time = fmod(_settings_scroll_hint_time + delta, SCROLL_HINT_PERIOD)
	_settings_scroll_hint.position.y = _settings_scroll_hint_y + sin(_settings_scroll_hint_time / SCROLL_HINT_PERIOD * TAU) * SCROLL_HINT_AMPLITUDE

func _grid() -> bool:
	if section == Section.WEB: return false
	if archives.browsing: return view_mode == "grid"
	if audio_import_mode or subtitle_picker_mode: return false
	if cloud_error.opened: return false
	if compact: return view_mode == "grid"
	if cloud_search.active: return not cloud_search.editing and view_mode == "grid"
	if account_panel.active(): return false
	if section == Section.CLOUD and not cloud_accounts.mode.is_empty(): return false
	if section == Section.MEDIA_SERVER: return server_browser.grid()
	if browser_content(true): return view_mode == "grid"
	return section != Section.SETTINGS

func browser_content(allow_modal: bool = false) -> bool:
	if archives.browsing: return true
	if cloud_pagination.opened: return false
	if collections.active() or archives.opened: return false
	if cloud_error.opened: return false
	if account_panel.active() or not _editor.is_empty() or (not allow_modal and not file_actions.modal.is_empty()): return false
	if cloud_search.active: return not cloud_search.editing
	match section:
		Section.RECENT: return true
		Section.LOCAL: return not _local_stack.is_empty()
		Section.SMB: return not _smb_server.is_empty()
		Section.DLNA: return not _dlna_server.is_empty()
		Section.CLOUD: return not _cloud_stack.is_empty() and cloud_accounts.mode.is_empty()
		Section.MEDIA_SERVER: return server_browser.view == "scenes" and server_browser.keyboard.is_empty()
	return false

func load_view_mode(value: Variant) -> void:
	view_mode = Presentation.mode(value)

func capture_position() -> Dictionary:
	return Presentation.anchor(rows, scroll, _cols())

func set_view_mode(value: String) -> void:
	value = Presentation.mode(value)
	if value == view_mode or (not compact and not browser_content()): return
	var keep_current_visible := _current_file_visible()
	var anchor := capture_position()
	view_mode = value
	file_actions.editing = false; file_actions.selection.clear()
	_drag = {}; _fling = 0.0; _hover.clear(); _hide_tooltip()
	_cancel_covers()
	_position_to_restore = anchor
	setting_changed.emit("library_view_mode", view_mode)
	refresh()
	if keep_current_visible and not _current_file_visible(): _reveal_current_file(false)

func draw_view_modes(y: float = 0.445, left: float = 0.69) -> void:
	for spec in [[VIEW_LIST, "list", "List view"], [VIEW_GRID, "grid", "Icon view"]]:
		_button(int(spec[0]), "", Vector2(left + (0.11 if spec[1] == "grid" else 0.0), y), Vector2(0.09, 0.065), true, str(spec[1]))
		_lit(view_mode == spec[1]); _tips[int(spec[0])] = I18n.t(str(spec[2]))
		if view_mode == spec[1]:
			var node: MeshInstance3D = _buttons.back().node
			node.material_override.set_shader_parameter("surface_color", SELECTED)
			node.add_child(_quad(Vector2(0.028, 0.003), Vector3(0, -0.025, 0.006), ACCENT, 14))

func _header_y() -> float:
	if archives.browsing: return 0.515
	return 0.515 if section != Section.RECENT and browser_content() else 0.46

## Reserve the first header slot for the collection return before the parent/path.
func _folder_header_inset() -> float:
	if collections.home_return.is_empty() or image_picker_mode: return 0.0
	if not archives.browsing and (subtitle_picker_mode or voice_picker_mode): return 0.0
	return 0.11

func _action_position(x: float) -> Vector2:
	if archives.browsing: return Vector2(x, 0.445)
	if browser_content():
		return Vector2(x - 0.22, _header_y() if section == Section.RECENT else 0.445)
	return Vector2(x, 0.46)

func _cols() -> int:
	if archives.browsing: return (3 if compact else COLS) if _grid() else 1
	if not compact and section == Section.MEDIA_SERVER and server_browser.media_content(): return server_browser.columns() if _grid() else 1
	return (3 if compact else COLS) if _grid() else 1

## Visible lines (tile rows or list rows); [scroll] counts lines.
func _lines() -> int:
	if compact: return 2 if _grid() else (4 if file_actions.needs_footer() or collections.has_selection() else 5)
	if archives.browsing: return GRID_LINES if _grid() else VISIBLE_ROWS
	if cloud_search.active: return 2 if _grid() else 5
	if controls_page.active(): return 6
	if account_panel.active(): return VISIBLE_ROWS
	if section == Section.MEDIA_SERVER: return server_browser.visible_lines()
	return GRID_LINES if _grid() else VISIBLE_ROWS

func _pitch() -> float:
	if archives.browsing: return GRID_PITCH.y if _grid() else ROW_PITCH
	if compact: return GRID_PITCH.y if _grid() else ROW_PITCH
	if controls_page.active(): return 0.10
	if account_panel.active(): return ROW_PITCH
	if section == Section.MEDIA_SERVER: return server_browser.pitch()
	return GRID_PITCH.y if _grid() else ROW_PITCH

func _line_count() -> int:
	return ceili(float(rows.size()) / _cols())

## Scrollbar track: top and height.
func _bar_span() -> Vector2:
	if compact: return Vector2(0.265, _lines() * _pitch() - 0.012)
	if archives.browsing: return Vector2(GRID_TOP if _grid() else LIST_TOP + 0.05, _lines() * _pitch() - 0.012)
	if cloud_search.active: return Vector2(0.095, 2 * GRID_PITCH.y - 0.012 if _grid() else 0.54)
	if controls_page.active(): return Vector2(0.20, 0.60)
	if section == Section.MEDIA_SERVER and not account_panel.active(): return server_browser.bar_span()
	return Vector2(GRID_TOP if _grid() else LIST_TOP + 0.05, _lines() * _pitch() - 0.012)

func _max_scroll() -> float:
	if not compact and (section == Section.MEDIA_SERVER and not archives.browsing) and not account_panel.active() and server_browser.gallery.fixed(): return 0.0
	return float(maxi(0, _line_count() - _lines()))

## External photo/video pickers can explicitly keep their purpose across folders.
func begin_media_browse(kind: int) -> void:
	media_browse_intent=clampi(kind,0,2); media_filter=media_browse_intent
	refresh()

func _filter_location() -> String:
	if archives.browsing: return str(["archive", archives.target.get("uri", ""), archives.directory])
	match section:
		Section.LOCAL: return str([section,_local_stack.map(func(item):return item.get("id",""))])
		Section.SMB: return str([section,_smb_server,_smb_path])
		Section.DLNA: return str([section,_dlna_server,_dlna_stack.map(func(item):return item.get("id",""))])
		Section.CLOUD: return str([section,_cloud_stack.map(func(item):return item.get("id",""))])
		Section.RECENT: return str([section,collections.home_tab if collections else 0])
	return str(section)

func _sync_media_filter() -> void:
	if media_browse_intent>0:
		if media_filter!=media_browse_intent: media_filter=media_browse_intent
	elif not _media_filter_location.is_empty() and _media_filter_location!=_filter_location(): media_filter=0

func _folder_key() -> String:
	if archives.browsing: return archives.position_scope()
	_sync_media_filter()
	var location := ""
	match section:
		Section.LOCAL: location = _local_path()
		Section.SMB: location = str([_smb_server, _smb_path])
		Section.DLNA: location = str([_dlna_server, str(_dlna_stack.back().id) if not _dlna_stack.is_empty() else "0"])
		_: return ""
	return ("image-picker:" if image_picker_mode else "subtitle:" if subtitle_picker_mode else "audio:" if audio_import_mode else "") + str([section, location, media_filter])

func _cloud_position_key() -> String:
	return ("image-picker:" if image_picker_mode else "subtitle:" if subtitle_picker_mode else "audio:" if audio_import_mode else "") + _cloud_path()

func _browse_scope() -> String:
	if archives.browsing: return archives.position_scope()
	if subtitle_picker_mode or audio_import_mode or voice_picker_mode: return ""
	_sync_media_filter()
	if section == Section.CLOUD:
		if _cloud_stack.is_empty(): return ""
		var directory_id := str(_cloud_stack.back().get("cloud_id", ""))
		return ("image-picker:" if image_picker_mode else "") + JSON.stringify(["cloud", _cloud_stack[0].get("id", ""), directory_id if not directory_id.is_empty() else _cloud_path(), media_filter])
	return _folder_key()

func _browse_network() -> bool:
	return archives.network() if archives.browsing else section != Section.LOCAL

func _browse_activity() -> void:
	_browse_revision = browse_memory.revision
	_browse_save_scope = _browse_scope()
	_browse_save_at = Time.get_ticks_msec() + 500

func _restore_parent_filter() -> void:
	if image_picker_mode or voice_picker_mode or subtitle_picker_mode or audio_import_mode or media_browse_intent > 0: return
	media_filter = int(_browse_parent_filters.get(file_actions.scope(), {}).get("filter", 0))

func _change_media_filter(value: int) -> void:
	if media_filter == value: return
	if archives.browsing:
		archives.save_position(); media_filter = value; archives.remembered_filter = value; scroll = 0.0
		_browse_activity()
		var route: Dictionary = browse_memory.lookup(archives.route_scope(), archives.network()) if restore_directory_position else {}
		var directory := str(route.get("archive_directory", archives.directory))
		if archives.directory_exists(directory): archives.directory = directory
		_position_to_restore = browse_memory.lookup(archives.position_scope(), archives.network()) if restore_directory_position else {}
		refresh(); return
	_save_folder_position()
	media_browse_intent = 0; media_filter = value; _browse_return_restore = false
	_browse_activity(); _reset_navigation(); _position_to_restore = {}
	if not _browse_scope().is_empty():
		if section == Section.CLOUD and platform and cloud_pagination.mode == "paged": _load_cloud()
		elif restore_directory_position:
			var saved := browse_memory.lookup(_browse_scope(), _browse_network())
			_position_to_restore = saved.get("position", {}) if section == Section.CLOUD else saved
	refresh()

func checkpoint_browse() -> void:
	if visible: _save_folder_position()
	browse_memory.flush()

func browse_policy_changed() -> void:
	browse_memory.policy_changed()
	_browse_save_at = 0

func clear_browse_history(network_only: bool) -> bool:
	var ok := browse_memory.clear_history(network_only)
	_browse_save_at = 0
	_fling = 0.0
	_cloud_positions.clear()
	for key in _browse_parent_filters.keys():
		if not network_only or _browse_parent_filters[key].network: _browse_parent_filters.erase(key)
	for key in _folder_positions.keys():
		if not network_only or not str(key).begins_with(str([Section.LOCAL]).trim_suffix("]")): _folder_positions.erase(key)
	# Invalidate affected deferred restores; loaded rows cannot resurrect cleared history.
	_cloud_requested_position = {}; _cloud_requested_scroll = 0.0
	_browse_cloud_restore = {}
	_browse_expired_page = false
	if not network_only or section != Section.LOCAL:
		_restore_folder_key = ""; _position_to_restore = {}; _layout_anchor = {}; _browse_focus = {}; _return_uri = ""
	else: _browse_revision = browse_memory.revision
	if not network_only or int(_playback_context.get("section", -1)) != Section.LOCAL: _playback_context = {}
	return ok

func _saved_cloud_position() -> Dictionary:
	if _browse_scope().is_empty(): return _cloud_positions.get(_cloud_position_key(), {}).duplicate(true)
	if not restore_directory_position and not _browse_return_restore: return {}
	var saved := browse_memory.lookup(_browse_scope(), true)
	if saved.is_empty(): return {}
	if saved.get("offsets") is Array: return saved
	# Persist an offset hint, not a provider cursor chain. Only offset-based APIs can reuse it.
	if cloud_pagination.provider() not in ["115_open", "baidu", "webdav"]:
		if int(saved.get("page", 0)) > 0:
			saved.expired_page = true; saved.position = {}; saved.scroll = 0.0
		saved.page = 0; saved.offset = 0
	var page := clampi(int(saved.get("page", 0)), 0, cloud_pagination.MAX_PAGE - 1)
	var offsets: Array[int] = []; offsets.resize(page + 1)
	for i in offsets.size(): offsets[i] = i * maxi(1, int(saved.get("page_size", 48)))
	offsets[page] = maxi(0, int(saved.get("offset", 0)))
	saved.offsets = offsets
	return saved

func _save_folder_position(opened_folder: Dictionary = {}) -> void:
	if archives.browsing: archives.save_position(opened_folder); return
	if cloud_search.active or account_panel.active() or not _editor.is_empty(): return
	if cloud_pagination.opened or cloud_error.opened or collections.active() or archives.opened or not file_actions.modal.is_empty(): return
	if section == Section.CLOUD and not cloud_pagination.batch.is_empty(): return
	if browse_memory.locked(): return
	if not _browse_scope().is_empty() and _browse_revision == browse_memory.revision:
		_browse_parent_filters[file_actions.scope()] = {"filter": media_filter, "network": section != Section.LOCAL}
		while _browse_parent_filters.size() > BrowseMemory.LIMIT: _browse_parent_filters.erase(_browse_parent_filters.keys()[0])
	var anchor := capture_position() if opened_folder.is_empty() else Presentation.folder_anchor(rows, scroll, _cols(), opened_folder)
	if not _browse_scope().is_empty():
		if not opened_folder.is_empty(): _browse_focus = {"scope": _browse_scope(), "scroll": scroll, "anchor": anchor}
		elif _browse_focus.get("scope", "!") == _browse_scope() and is_equal_approx(float(_browse_focus.get("scroll", -1)), scroll): anchor = _browse_focus.anchor
	if not rows.is_empty() and not _browse_scope().is_empty() and not anchor.get("browse", false):
		anchor.browse = true
		anchor.key = Presentation.browse_key(rows[clampi(int(anchor.index), 0, rows.size() - 1)])
	if section == Section.CLOUD:
		if _cloud_busy or not cloud_accounts.mode.is_empty() or _cloud_location != _cloud_path(): return
		_cloud_positions[_cloud_position_key()] = {"page": _cloud_page, "offsets": _cloud_offsets.duplicate(),
			"scroll": scroll, "position": anchor, "filter": media_filter, "order": file_actions.cloud_order(), "page_size": _cloud_page_size}
		var saved: Dictionary = _cloud_positions[_cloud_position_key()].duplicate(true)
		saved.offset = int(_cloud_offsets[_cloud_page]) if _cloud_page < _cloud_offsets.size() else 0
		if cloud_pagination.mode != "paged":
			# A visible index in accumulated pages is not an offset into one remote page.
			saved.page = 0; saved.offset = 0
		if not rows.is_empty(): browse_memory.remember(_browse_scope(), true, saved, _browse_revision)
		while _cloud_positions.size() > 32: _cloud_positions.erase(_cloud_positions.keys()[0])
	else:
		var key := _folder_key()
		if key.is_empty(): return
		_folder_positions[key] = anchor
		if not rows.is_empty(): browse_memory.remember(_browse_scope(), _browse_network(), anchor, _browse_revision)
		while _folder_positions.size() > 64: _folder_positions.erase(_folder_positions.keys()[0])

func _restore_folder_position() -> void:
	if not _restore_folder_key.is_empty() and _restore_folder_key == _folder_key():
		var saved: Variant = _folder_positions.get(_restore_folder_key, {}) if _browse_scope().is_empty() else browse_memory.lookup(_browse_scope(), _browse_network())
		if not _browse_scope().is_empty() and not restore_directory_position and not _browse_return_restore: saved = {}
		if saved is Dictionary: _position_to_restore = saved.duplicate(true)
		else: scroll = float(saved)
		_restore_folder_key = ""

func _plain_file_grid() -> bool:
	if archives.browsing: return is_instance_valid(_list)
	return section in [Section.RECENT, Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD] \
		and _editor.is_empty() and not account_panel.active() and not cloud_search.active \
		and cloud_accounts.mode.is_empty() and file_actions.modal.is_empty() and is_instance_valid(_list)

## Scrolling replaces only visible rows. Keep navigation, header, footer and their textures alive.
func _redraw_file_rows() -> void:
	_hide_tooltip()
	composition_layout_changed.emit()
	# Inline controls (audio audition, its seek rail, and future row widgets) have
	# their own target IDs but are freed with the list. Unregister by ownership,
	# not just the main row's numeric target range, before destroying that subtree.
	audio_preview_seek.clear_layout()
	_audio_preview_rows.clear(); _subtitle_task_buttons.clear()
	var removed := {}
	for index in range(_buttons.size() - 1, -1, -1):
		var button: Dictionary = _buttons[index]
		var in_list: bool = is_instance_valid(button.node) and _list.is_ancestor_of(button.node)
		if in_list or _row_target(button.target) or collections.row_target(button.target) or file_actions.selection_target(button.target) or button.target == SCROLLBAR:
			removed[button.target] = true
			_tips.erase(button.target)
			if button.target == SCROLLBAR: button.node.free()
			_buttons.remove_at(index)
	for hand in _hover:
		if removed.has(_hover[hand]): _hover[hand] = NONE
	_decorations.erase(_list); _list.free()
	if is_instance_valid(_bar_thumb):
		_decorations.erase(_bar_thumb); _bar_thumb.free()
	_draw_rows()
	composition_layout_changed.emit()

func refresh() -> void:
	if section == Section.WEB and not Distribution.web_browser_enabled():
		web_browser.close()
		section = Section.RECENT
	if not voice_manager.opened: _rebuild_rows()
	_draw()
	_align_playback_panel()

func _update_highlights() -> void:
	# Keep captions and selected/favorite ink stable; image cards leave their plate quiet.
	var media := section == Section.MEDIA_SERVER
	for button in _buttons:
		if media and button.has("hover_picture"): button["hover_color"] = button.base_color
		elif media and button.base_color != ACCENT: button["hover_color"] = Color(0.09, 0.17, 0.18)
		else: button.erase("hover_color")
	super._update_highlights()
	var changed := false
	for button in _buttons:
		var hovered: bool = media and button.enabled and _hover.values().has(button.target)
		if button.get("media_hovered", false) == hovered: continue
		if button.has("hover_picture"):
			button.media_hovered = hovered
			button.hover_picture.material_override.set_shader_parameter("hovered", hovered)
			changed = true; continue
		if not button.node is MeshInstance3D: continue # Text-only dismiss regions have no frame.
		var material = button.node.material_override
		if not material is ShaderMaterial: continue
		var shader: Shader = button.node.get_meta("menu_original_shader", material.shader)
		if shader != SURFACE and shader != server_browser.gallery.BUTTON_OUTLINE: continue
		button["media_hovered"] = hovered
		if material.get_shader_parameter("hovered") != hovered:
			material.set_shader_parameter("hovered", hovered); changed = true
	if changed: composition_changed.emit()

func refresh_music_quick_controls() -> void:
	if web_browser.active(): return
	if not audio_import_mode and music_quick and music_quick.active:
		music_quick.redraw(background_audio_provider.call() if background_audio_provider.is_valid() else {})
		return
	_draw(); _align_playback_panel()

## Editing and checkmarks change visible controls only; directory rows/order stay intact.
func refresh_file_selection() -> void:
	scroll = clampf(scroll, 0.0, _max_scroll())
	_draw()
	_align_playback_panel()

func file_entry_snapshots() -> Array:
	var snapshots: Array = [_local_entries, _smb_entries, _cloud_entries]
	for field in ["_local_entries", "_smb_entries", "_cloud_entries"]:
		if _playback_context.get(field) is Array: snapshots.append(_playback_context[field])
	return snapshots

## Confirmed mutations patch existing data. Preserve the surrounding files even if a renamed
## item sorts elsewhere; a removed top item falls back to the neighboring index.
func remove_file_rows(target: Dictionary) -> void:
	var anchor := capture_position()
	var uri := str(target.uri); var cloud_id := str(target.get("cloud_id", ""))
	var cloud_count := 0
	for entry in _cloud_entries:
		if str(entry.get("uri", entry.get("delete_uri", ""))) == uri and str(entry.get("cloud_id", "")) == cloud_id: cloud_count += 1
	var playback_cloud_count := 0
	for entry in _playback_context.get("_cloud_entries", []):
		if str(entry.get("uri", entry.get("delete_uri", ""))) == uri and str(entry.get("cloud_id", "")) == cloud_id: playback_cloud_count += 1
	for entries in file_entry_snapshots():
		for index in range(entries.size() - 1, -1, -1):
			var entry: Dictionary = entries[index]
			if str(entry.get("uri", entry.get("delete_uri", ""))) == uri and str(entry.get("cloud_id", "")) == cloud_id: entries.remove_at(index)
	for index in range(rows.size() - 1, -1, -1):
		if file_actions.row_uri(rows[index]) == uri and str(rows[index].get("cloud_id", "")) == cloud_id: rows.remove_at(index)
	if cloud_count > 0:
		if _cloud_total >= 0: _cloud_total = maxi(0, _cloud_total - cloud_count)
		if _cloud_next >= 0: _cloud_next = maxi(0, _cloud_next - cloud_count)
	if playback_cloud_count > 0:
		for field in ["_cloud_total", "_cloud_next"]:
			if int(_playback_context.get(field, -1)) >= 0: _playback_context[field] = maxi(0, int(_playback_context[field]) - playback_cloud_count)
		var saved_paging: Dictionary = _playback_context.get("cloud_paging", {})
		if not saved_paging.is_empty(): saved_paging.raw_count = maxi(0, int(saved_paging.raw_count) - playback_cloud_count)
	_finish_file_rows_change(anchor, cloud_count)

func rename_file_rows(updates: Dictionary, anchor: Dictionary) -> void:
	var sorted := file_actions.sortable() and section != Section.CLOUD
	var changed: Array[Dictionary] = []
	for index in range(rows.size() - 1, -1, -1):
		var key := file_actions.row_key(rows[index])
		if not updates.has(key): continue
		var row := _entry_row(updates[key])
		if sorted:
			rows.remove_at(index); changed.append(row)
		else: rows[index] = row
	if not changed.is_empty():
		var order := file_actions.order()
		var grouped := file_actions.folders_first()
		for row in changed:
			var left := 0; var right := rows.size()
			while left < right:
				var middle := (left + right) / 2
				if FileActions.Order.before(rows[middle], row, order, grouped): left = middle + 1
				else: right = middle
			rows.insert(left, row)
	_finish_file_rows_change(anchor)

func _finish_file_rows_change(anchor: Dictionary, removed_cloud: int = 0) -> void:
	if section == Section.CLOUD: cloud_pagination.files_changed(removed_cloud)
	file_actions.reconcile()
	_position_to_restore = {}
	scroll = clampf(Presentation.position(rows, anchor, _cols()), 0.0, _max_scroll())
	focus_index = clampi(focus_index, 0, maxi(0, rows.size() - 1))
	_drag = {}; _fling = 0.0

## Pagination is invalidated after a mutation, but the current offset remains usable.
func refresh_cloud_mutation() -> void:
	if section != Section.CLOUD or _cloud_stack.is_empty(): return
	_cloud_positions.erase(_cloud_position_key())
	var page := _cloud_page
	if _cloud_entries.is_empty() and page > 0: page -= 1
	_cloud_offsets.resize(page + 1)
	_load_cloud(false, true, page)
	if page < _cloud_page:
		_cloud_requested_position = {"index": maxi(0, _cloud_page_size - 1)}

# --- requests -------------------------------------------------------------------------------

func _request(kind: String, id: Variant) -> void:
	if id is int and id > 0:
		if kind in ["local", "smb_browse", "dlna_browse"] and (_browse_loaded_scope != _browse_scope() or \
			(kind == "local" and _local_entries.is_empty()) or (kind == "smb_browse" and _smb_entries.is_empty()) or (kind == "dlna_browse" and _dlna_entries.is_empty())):
			_browse_loaded_scope = _browse_scope()
			_restore_folder_key = _folder_key()
		if kind == "cloud":
			for previous in _pending.keys():
				if _pending[previous] == "cloud":
					_pending.erase(previous)
		if kind.begins_with("dlna") and kind not in ["dlna_save", "dlna_remove"]:
			for previous in _pending.keys():
				if _pending[previous] == kind: _pending.erase(previous)
		_pending[id] = kind
		if kind == "local":
			for previous in _pending.keys():
				if previous != id and _pending[previous] == "local": _pending.erase(previous)
		status = "Loading…"
	else:
		status = "Unavailable"

func _on_media_list(id: int, payload: String) -> void:
	if cloud_search.receive(id, payload): return
	if file_actions.receive(id, payload): return
	if cloud_accounts.receive(id, payload): return
	# Unsolicited store notifications also work when Quest does not pause/resume VR.
	if id == 0:
		var event: Variant = JSON.parse_string(payload)
		if event is Dictionary and event.get("source") == "local_storage":
			if event.get("state") == "error":
				if section == Section.LOCAL: status = "Storage device unavailable"; refresh()
				return
			var volumes: Array = event.get("volumes", [])
			if volumes == _local_volumes: return
			var removed := _external_volumes().filter(func(volume): return not volumes.any(func(current): return str(current.id) == str(volume.id)))
			_local_volumes = volumes
			for volume in removed: storage_removed.emit(volume.duplicate(true))
			if not _local_stack.is_empty() and not _local_volumes.any(func(volume): return str(volume.id) == str(_local_stack[0].id)):
				_local_stack.clear(); _local_entries = []
			if section == Section.LOCAL and not account_panel.active() and _storage_stop_pending.is_empty():
				_load_section()
			if visible: refresh()
			return
		if event is Dictionary and event.get("source") == "local_access":
			var access_state := str(event.get("state", "error"))
			_local_grant_pending = access_state in ["requested", "settings_opened"]
			if section != Section.LOCAL or account_panel.active(): return
			if not str(event.get("path", "")).is_empty() and str(event.path) != _local_path(): return
			if access_state == "granted": _load_section()
			elif access_state == "settings_opened": status = "Allow access in system settings"
			elif access_state == "requested": status = "Choose a folder" if _local_access_mode() == "directory" else "Media access needed"
			else: status = str(event.get("error", "Permission settings unavailable"))
			if visible: refresh()
			return
		if event is Dictionary and event.get("source") == "medialib" and event.get("state") == "accounts_changed":
			server_browser.setup = false
			if section == Section.MEDIA_SERVER:
				# Let a VR deletion finish its saved-filter cleanup before reloading.
				if server_browser.pending.values().any(func(request): return request.action == "remove"): return
				server_browser.load_servers()
				refresh()
			return
	if cloud_pagination.receive(id, payload): return
	if server_browser.receive(id, payload): return
	if not _pending.has(id):
		return
	var kind: String = _pending[id]
	_pending.erase(id)
	if kind.begins_with("dlna") and section != Section.DLNA: return
	if kind == "cloud": _cloud_busy = false
	if kind == "cloud" and section != Section.CLOUD:
		return
	var parser := JSON.new()
	var parsed: Variant = parser.data if parser.parse(payload) == OK else null
	if not parsed is Dictionary:
		if kind == "cloud":
			file_actions.cloud_failed()
			status = "Cloud connection failed"
			cloud_error.receive({"error": status, "error_detail": "cloud.response: invalid JSON", "offset": _cloud_offsets[_cloud_requested_page]})
			refresh()
		return
	var result: Dictionary = parsed
	if kind == "local" and result.has("path") and str(result.path) != _local_path(): return
	if kind == "local" and result.get("state") == "loading":
		_pending[id] = kind
		status = str(result.get("error", "Loading…"))
		if visible: refresh()
		return
	if kind == "local_eject":
		var volume_id := str(result.get("volume_id", ""))
		if not _storage_stop_pending.has(volume_id): return
		_storage_stop_pending.erase(volume_id)
		if str(result.get("state", "")) not in ["stopped", "released"]:
			_storage_stop_failures.append(str(result.get("error", "Storage stop failed")))
		if _storage_stop_pending.is_empty(): finish_storage_release(_local_eject_pending)
		return
	var accepted_order_fallback: bool = kind == "cloud" and bool(result.get("order_fallback", false)) and \
		result.get("sort_orders", []) is Array and str(result.get("order", "")) in result.get("sort_orders", [])
	var changed_order := kind == "cloud" and not file_actions.cloud_requested_order.is_empty()
	if kind == "cloud" and (str(result.get("path", "")) != _cloud_path() or \
		int(result.get("offset", 0)) != _cloud_offsets[_cloud_requested_page] or
		(not _cloud_path().is_empty() and (PlatformMethods.supports(platform, "media_cloud_sorted_page") or PlatformMethods.supports(platform, "media_cloud_directory_page") or cloud_pagination.supported()) and str(result.get("order", "")) != file_actions.cloud_order() and not accepted_order_fallback) or
		(cloud_pagination.supported() and result.get("state") == "ready" and int(result.get("page_size", -1)) != _cloud_page_size)):
		# A matching request ID with the wrong page is a protocol failure, not pending work.
		file_actions.cloud_failed()
		status = "Cloud connection failed"
		cloud_error.receive({"error": status, "error_detail": "cloud.response: path, offset or sort order did not match the requested page", "offset": _cloud_offsets[_cloud_requested_page]})
		if visible: refresh()
		return
	status = ""
	if kind == "cloud" and not _browse_cloud_restore.is_empty():
		result = _continue_browse_restore(result)
		if result.is_empty(): return
	var state := str(result.get("state", "error"))
	# Auto-discovered DLNA servers are session-only in the backend. Discover once
	# on cold resume, then retry the same saved directory, never a media resource URL.
	if kind == "dlna_picker_resume":
		if not _image_picker_dlna_matches(): return
		if state == "ready":
			_dlna_servers = result.get("servers", [])
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, _image_picker_dlna_retry.object))
			if visible: refresh()
			return
	if kind == "dlna_browse" and state == "error" and result.get("error") == "DLNA server unavailable" \
		and _image_picker_dlna_matches() and not _image_picker_dlna_retry.attempted and PlatformMethods.supports(platform, "media_dlna_discover"):
		_image_picker_dlna_retry.attempted = true
		_request("dlna_picker_resume", platform.media_dlna_discover())
		if visible: refresh()
		return
	if kind == "cloud" and state == "ready" and _browse_expired_page:
		status = "Previous page expired; showing first page"; _browse_expired_page = false
	if state == "denied":
		match str(result.get("error", "")):
			"ALL_FILES_ACCESS_NEEDED": status = "All files access needed"
			"STORAGE_FOLDER_ACCESS_NEEDED": status = "Folder access needed"
			_: status = "Media access needed"
	elif state != "ready":
		if kind == "cloud": file_actions.cloud_failed()
		status = str(result.get("error", "Error")).left(80)
		if kind == "cloud": cloud_error.receive(result)
	else:
		match kind:
			"cloud":
				cloud_error.clear()
				if not _cloud_stack.is_empty() and result.get("sort_orders") is Array:
					_cloud_stack[0]["sort_orders"] = result.sort_orders.duplicate()
				cloud_search.observe(result)
				file_actions.commit_cloud(str(result.get("order", "")))
				_cloud_entries = result.get("entries", [])
				_cloud_page = _cloud_requested_page
				_cloud_next = int(result.get("next_offset", -1))
				_cloud_total = int(result.get("total", -1))
				_cloud_page_size = maxi(1, int(result.get("page_size", 48)))
				cloud_pagination.page_received(result)
				_reset_navigation()
				scroll = _cloud_requested_scroll
				_position_to_restore = {} if browse_memory.locked() else _cloud_requested_position.duplicate(true)
			"local":
				if str(result.get("path", "")) == _local_path():
					_local_entries = result.get("entries", [])
					_local_volumes = result.get("volumes", _local_entries.filter(func(entry): return entry.get("volume",false)) if _local_path().is_empty() else _local_volumes)
					_local_all_files = bool(result.get("all_files", true))
					_restore_folder_position()
					if not _local_release_notice.is_empty() and section == Section.LOCAL: status = _local_release_notice
			"smb_servers":
				_smb_servers = result.get("servers", [])
			"smb_found":
				_smb_found = result.get("discovered", [])
			"smb_browse":
				if str(result.get("server_id")) == _smb_server and str(result.get("path")) == _smb_path:
					_smb_entries = result.get("entries", [])
					_restore_folder_position()
			"dlna_servers", "dlna_discover", "dlna_save", "dlna_remove":
				_dlna_servers = result.get("servers", [])
				if kind in ["dlna_save", "dlna_remove"] and int(_editor.get("request_id", -1)) == id:
					_editor = {}
					_dlna_server = ""; _dlna_stack.clear(); _dlna_entries.clear(); scroll = 0.0
			"dlna_browse":
				var current_object := str(_dlna_stack.back().id) if not _dlna_stack.is_empty() else "0"
				if str(result.get("server_id")) == _dlna_server and str(result.get("object_id", current_object)) == current_object:
					_dlna_entries = result.get("entries", [])
					_restore_folder_position()
	if visible:
		refresh()
		if kind == "cloud" and state == "ready" and not _return_uri.is_empty() and rows.any(func(row):return str(row.get("uri", "")) == _return_uri):
			remember_playback_context(_return_uri)
	if changed_order and state == "ready": directory_order_changed.emit()

func _grant_local_access() -> void:
	if _local_grant_pending: return
	var mode := _local_access_mode()
	if mode == "none": return
	if mode == "directory":
		if PlatformMethods.supports(platform, "media_local_grant_directory"):
			_local_grant_pending = true
			status = "Choose a folder"
			platform.media_local_grant_directory(_local_path())
		else: status = "Folder picker unavailable"
	elif not PlatformMethods.supports(platform, "media_local_grant_all_files"):
		status = "Permission settings unavailable"
	else:
		_local_grant_pending = true
		status = "Loading…"
		platform.media_local_grant_all_files()
	refresh()

func _local_volume() -> Dictionary:
	var path := _local_path()
	if path.is_empty(): return {}
	for volume in _local_volumes:
		var root := str(volume.get("id", "")).trim_suffix("/")
		if path == root or path.begins_with(root + "/") or StorageVolume.contains_uri(volume, path): return volume
	return _local_stack[0] if not _local_stack.is_empty() else {}

func _local_access_mode() -> String:
	var path := _local_path()
	if path.is_empty() or path.begins_with("usb://"): return "none"
	var volume := _local_volume()
	if bool(volume.get("removable", false)) or path.begins_with("content://com.android.externalstorage.documents/"): return "directory"
	return "none" if _local_all_files else "all_files"

func _local_grant_needed() -> bool:
	return section == Section.LOCAL and status in ["Video access needed", "Media access needed", "All files access needed", "Folder access needed", "Select a folder on this storage device"] and _local_access_mode() != "none"

func _external_volumes() -> Array:
	return _local_volumes.filter(func(volume): return bool(volume.get("removable",false)))

func _quick_usb_storage() -> void:
	file_actions.reset()
	var external := _external_volumes()
	if external.is_empty(): return
	_local_stack.clear(); _local_entries = []; scroll = 0
	if external.size() == 1: _local_stack.append(external[0].duplicate(true))
	_load_section(); refresh()

func _eject_volume() -> Dictionary:
	if not _local_stack.is_empty():
		var volume := _local_volume()
		return volume if bool(volume.get("removable",false)) else {}
	var external := _external_volumes()
	return external[0] if external.size() == 1 else {}

func _request_storage_eject() -> void:
	var volumes := _external_volumes()
	if volumes.is_empty() or not _storage_stop_pending.is_empty(): return
	_begin_storage_stop(volumes)
	storage_eject_requested.emit({"id":"usb-all", "removable":true, "volumes":_storage_stop_targets.duplicate(true)})
	refresh()

func _begin_storage_stop(volumes: Array) -> void:
	_local_eject_pending = "usb-all"
	_local_release_notice = ""
	_storage_stop_targets = []; _storage_stop_pending = {}; _storage_stop_failures.clear()
	for volume in volumes:
		var id := str(volume.get("id", ""))
		if id.is_empty() or _storage_stop_pending.has(id): continue
		_storage_stop_targets.append(volume.duplicate(true)); _storage_stop_pending[id] = true
	for id in _pending.keys():
		if _pending[id] == "local": _pending.erase(id)
	_cancel_covers()
	status = "Stopping storage…"

func finish_storage_release(path: String) -> void:
	if path != _local_eject_pending: return
	_local_eject_pending = ""
	_storage_stop_pending.clear()
	if not _storage_stop_failures.is_empty():
		status = _storage_stop_failures[0]; _storage_stop_targets.clear(); refresh(); return
	var current := str(_local_volume().get("id", ""))
	_local_release_notice = "Storage access stopped"
	if _storage_stop_targets.any(func(volume): return str(volume.id) == current):
		_local_stack.clear(); _local_entries = []; scroll = 0
	_storage_stop_targets.clear()
	status = _local_release_notice
	if section == Section.LOCAL:
		_load_section()
	refresh()

func stop_storage(volume: Dictionary) -> void:
	var volumes: Array = volume.get("volumes", [volume])
	if _storage_stop_pending.is_empty(): _begin_storage_stop(volumes)
	if not PlatformMethods.supports(platform, "media_local_stop_storage"):
		_storage_stop_failures.append("Storage stop unavailable")
		finish_storage_release(_local_eject_pending); return
	for target in volumes:
		var id: int = platform.media_local_stop_storage(str(target.get("id", "")))
		if id > 0: _request("local_eject", id)
		else:
			_storage_stop_pending.erase(str(target.get("id", "")))
			_storage_stop_failures.append("Storage stop failed")
	if _storage_stop_pending.is_empty(): finish_storage_release(_local_eject_pending)
	else: status = "Stopping storage…"; refresh()

func _draw_storage_stop(centre: Vector2) -> void:
	if _external_volumes().is_empty(): return
	_button(EJECT_STORAGE, "", centre, Vector2(0.075, 0.065), _storage_stop_pending.is_empty(), "eject")
	_tips[EJECT_STORAGE] = I18n.t("Stop using all USB storage")

func _browse_local() -> int:
	return platform.media_subtitle_local_browse(_local_path()) if subtitle_picker_mode else platform.media_local_browse(_local_path())

func _browse_smb(server: String, path: String) -> int:
	return platform.media_subtitle_smb_browse(server, path) if subtitle_picker_mode else platform.media_smb_browse(server, path)

func _load_section() -> void:
	if section == Section.MEDIA_SERVER:
		server_browser.load_servers()
		return
	if not platform:
		status = "Headset only" if section in [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD] else ""
		return
	match section:
		Section.CLOUD:
			_load_cloud()
		Section.LOCAL:
			# Always read again: files change, and access may have just been granted in settings.
			_request("local", _browse_local())
		Section.SMB:
			if _smb_server.is_empty():
				_request("smb_servers", platform.media_smb_servers())
			elif subtitle_picker_mode or image_picker_mode or voice_picker_mode:
				_request("smb_browse", _browse_smb(_smb_server, _smb_path))
		Section.DLNA:
			if _dlna_server.is_empty():
				if PlatformMethods.supports(platform, "media_dlna_servers"):
					_request("dlna_servers", platform.media_dlna_servers())
				if _dlna_servers.is_empty(): _request("dlna_discover", platform.media_dlna_discover())
			elif image_picker_mode or voice_picker_mode:
				_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if not _dlna_stack.is_empty() else "0"))

# --- rows -----------------------------------------------------------------------------------

func _rebuild_rows() -> void:
	if subtitle_queue_open and section == Section.SETTINGS and tab == VIDEO_TAB:
		rows.assign(preload("res://scripts/subtitle_task_rows.gd").rows(settings_provider.call().get("subtitle_defaults", {}).get("subtitle_tasks", {})))
		scroll = clampf(scroll, 0, _max_scroll()); return
	if archives.browsing:
		rows.assign(archives.directory_rows())
		if not _position_to_restore.is_empty():
			scroll = Presentation.position(rows, _position_to_restore, _cols()); _position_to_restore = {}
		focus_index = clampi(focus_index, 0, maxi(0, rows.size()-1))
		scroll = clampf(scroll, 0.0, _max_scroll()); return
	_sync_media_filter()
	rows.clear()
	if cloud_error.opened:
		rows.assign(cloud_error.rows()); scroll = clampf(scroll, 0.0, _max_scroll()); return
	if section == Section.CLOUD and not cloud_error.opened and not account_panel.active() and cloud_pagination.use_rows(): return
	if account_panel.active():
		rows.assign(account_panel.rows())
		scroll = clampf(scroll, 0.0, _max_scroll())
		return
	match section:
		Section.RECENT:
			rows.assign(collections.home_rows())
		Section.LOCAL:
			for entry in _local_entries:
				var row := _entry_row(entry)
				if bool(entry.get("volume", false)):
					row.icon = "usb" if bool(entry.get("removable", false)) else "device"
					if bool(entry.get("removable", false)):
						row.detail = str(Presentation.info(row).subtitle)
				rows.append(row)
		Section.SMB:
			if _smb_server.is_empty():
				for server in _smb_servers:
					rows.append({"title": str(server.name), "detail": str(server.host), "icon": "server", "smb_server": str(server.id)})
				for found in _smb_found:
					if _smb_servers.any(func(s): return str(s.host) == str(found.host)):
						continue
					rows.append({"title": str(found.name), "detail": str(found.host), "icon": "plus", "smb_found": found})
			else:
				for entry in _smb_entries:
					rows.append(_entry_row(entry))
		Section.DLNA:
			if _dlna_server.is_empty():
				for server in _dlna_servers:
					rows.append({"title": str(server.name), "detail": "", "icon": "cast", "dlna_server": str(server.id)})
			else:
				for entry in _dlna_entries:
					rows.append(_entry_row(entry))
		Section.SETTINGS:
			var settings: Dictionary = settings_provider.call() if settings_provider.is_valid() else {}
			if tab == CONTROLS_TAB:
				rows.assign(controls_page.items())
			elif tab == VIDEO_TAB or tab == SUBTITLES_TAB:
				var seek: String = SeekPolicy.normalize(settings.get("seek_mode", SeekPolicy.SPEED))
				rows.append(_choice_row("Video time positioning", "seek_mode", seek,
					[{"value": SeekPolicy.SPEED, "label": "Speed", "hint": "Faster jumps, less precise"},
					{"value": SeekPolicy.EXACT, "label": "Precise", "hint": "Accurate jumps, may take longer"}], false,
					"Faster jumps, less precise" if seek == SeekPolicy.SPEED else "Accurate jumps, may take longer"))
				rows.append(_choice_row("2D to 3D effect", "depth_render", str(settings.get("depth_render", "stretch")),
					[{"value": "fill", "label": "Fill gaps", "hint": "Fills the background behind moving edges"},
					{"value": "stretch", "label": "Stretch edges", "hint": "Stretches edges, like spatial photos"}], true))
				var outputs: Array = []
				for option in [[Quality.AUTO_OUTPUT, "Auto"], [0, "Original size"], [5760, "6K"], [4096, "4K"]]:
					outputs.append({"value": option[0], "label": option[1], "hint": Quality.OUTPUT_HINTS[option[0]]})
				var output_row := _choice_row("Output resolution", "output_width", int(settings.get("output_width", Quality.AUTO_OUTPUT)), outputs, true)
				output_row.info = Quality.OUTPUT_INFO; rows.append(output_row)
				var memories: Array = []
				for option in [[Quality.MEMORY_AUTO, "Auto"], [Quality.MEMORY_STANDARD, "Standard"], [Quality.MEMORY_SAVER, "Saver"]]:
					memories.append({"value": option[0], "label": option[1], "hint": Quality.MEMORY_HINTS[option[0]]})
				var memory_row := _choice_row("Memory", "memory_mode", int(settings.get("memory_mode", Quality.MEMORY_AUTO)), memories, true)
				memory_row.info = Quality.MEMORY_INFO; rows.append(memory_row)
				rows.append(_choice_row("Keep background during passthrough", "alpha_keep_background", bool(settings.get("alpha_keep_background", false)),
					[{"value": false, "label": "Off"}, {"value": true, "label": "On"}]))
				rows.append(_video_settings_group("alpha", "AI portrait passthrough (Alpha)"))
				if _video_settings_expanded.get("alpha", false):
					rows.append(_alpha_size_row(settings))
					rows.append({"title": I18n.t("Alpha passthrough FPS limit"), "key": "alpha_fps", "value": int(settings.get("alpha_fps", 30)),
						"slider": true, "span": Vector3(10, 40, 1), "unit": " FPS", "reset_value": float(settings.get("alpha_fps_default", 30)), "hint": "Headset performance limits keep the cut-out a little behind the picture"})
					# The same Alpha edge as the player settings (AlphaEdge defaults).
					rows.append({"title": I18n.t("Alpha feather"), "key": "alpha_feather", "value": int(settings.get("alpha_feather", 100)),
						"slider": true, "span": Vector3(0, 100, 1), "unit": "%", "reset_value": 100.0})
					rows.append({"title": I18n.t("Alpha edge shrink"), "key": "alpha_shrink", "value": int(settings.get("alpha_shrink", 40)),
						"slider": true, "span": Vector3(0, 100, 1), "unit": "%", "reset_value": 40.0})
					if Quality.ALPHA_PRECISION_SHOWN:
						var precisions: Array = []
						for option in [[Quality.ALPHA_PRECISION_AUTO, "Auto"], [Quality.ALPHA_PRECISION_FAST, "Fast"], [Quality.ALPHA_PRECISION_PRECISE, "Precise"]]:
							precisions.append({"value": option[0], "label": option[1], "hint": Quality.ALPHA_PRECISION_HINTS[option[0]]})
						var precision_row := _choice_row("AI precision", "alpha_precision", int(settings.get("alpha_precision", Quality.ALPHA_PRECISION_AUTO)), precisions, true)
						precision_row.info = Quality.ALPHA_PRECISION_INFO; rows.append(precision_row)
				rows.append(_video_settings_group("subtitles", "Subtitles"))
				if _video_settings_expanded.get("subtitles", false):
					rows.append_array(_subtitle_rows(settings))
			elif tab == GENERAL_TAB:
				var languages: Array = []
				for value in I18n.CHOICES: languages.append({"value": value, "label": LANGUAGE_NAMES[value]})
				rows.append(_choice_row("Language", "language", I18n.choice, languages))
				var management_hint := "Delete or rename files in supported library sections. Managing files is easier in list view. Available actions depend on the source and permissions."
				rows.append(_choice_row("Allow file management", "file_editing", file_actions.enabled,
					[{"value": false, "label": "Off", "hint": management_hint}, {"value": true, "label": "On", "hint": management_hint}]))
				rows.append_array(cloud_pagination.settings_rows(settings))
				rows.append_array(file_actions.settings_rows())
				rows.append(_choice_row("Restore folder position", "library_restore_position", restore_directory_position,
					[{"value": false, "label": "Off", "hint": BROWSE_POSITION_HINT}, {"value": true, "label": "On", "hint": BROWSE_POSITION_HINT}], false, BROWSE_POSITION_HINT))
				# Library thumbnails plus Android photo/depth/SBS files.
				# Scanned off the main thread (one file open per thumbnail); the size shows once known.
				if _cache_usage == null: _scan_cache_usage()
				var cache: Vector2i = _cache_usage if _cache_usage is Vector2i else Vector2i(-1, 0)
				var armed := _confirm == "clear_cache"
				rows.append({"title": I18n.t("Clear cache"), "detail": _bytes(cache.y) if cache.x > 0 else "", "icon": "check" if armed else "trash",
					"selected": armed, "clear_cache": true, "empty": cache.x == 0})
				rows.append({"title": I18n.t("Privacy settings"), "group_header": true, "icon": "chevron_down" if collections.privacy_expanded else "next"})
				if collections.privacy_expanded:
					rows.append({"title": I18n.t("Archive password book"), "icon": "lock", "archive_password_book": true})
					rows.append(_choice_row("Playback and browsing history", "privacy_mode", settings.get("privacy_mode", "all"),
						[{"value": "all", "label": "Record all"}, {"value": "local", "label": "Local only"}, {"value": "none", "label": "Do not record"}]))
					rows.append(_choice_row("Per-file settings", "file_settings_memory", settings.get("file_settings_memory", "all"),
						[{"value": "all", "label": "Remember all"}, {"value": "local", "label": "Local only"}, {"value": "none", "label": "Do not remember"}]))
					var favorite_store: RefCounted = collections.store
					if favorite_store:
						rows.append({"title": I18n.t("Unlock favorites" if favorite_store.locked else ("Change favorites password" if favorite_store.protected else "Set favorites password")), "icon": "lock", "privacy_action": "unlock" if favorite_store.locked else ("change_verify" if favorite_store.protected else "enable")})
						if favorite_store.protected:
							if favorite_store.locked: rows.append({"title": I18n.t("Reset locked favorites"), "icon": "trash", "privacy_action": "reset"})
							rows.append(_choice_row("Auto-lock favorites", "favorites_lock_level", settings.get("favorites_lock_level", "relaxed"),
								[{"value": "relaxed", "label": "Relaxed · 15 min"}, {"value": "balanced", "label": "Standard · 2 min"}, {"value": "strict", "label": "Strict · immediately"}, {"value": "manual", "label": "Manual · until exit"}]))
							if not favorite_store.locked:
								rows.append({"title": I18n.t("Lock favorites"), "icon": "lock", "privacy_action": "lock"})
								rows.append({"title": I18n.t("Remove favorites password"), "icon": "unlock", "privacy_action": "disable"})
					rows.append({"title": I18n.t("Confirm clearing history" if _confirm == str(["privacy_clear", "all"]) else "Clear existing history"), "icon": "check" if _confirm == str(["privacy_clear", "all"]) else "trash", "selected": _confirm == str(["privacy_clear", "all"]), "setting": ["privacy_clear", "all"]})
					rows.append({"title": I18n.t("Confirm clearing network history" if _confirm == str(["privacy_clear", "network"]) else "Clear network history"), "icon": "check" if _confirm == str(["privacy_clear", "network"]) else "trash", "selected": _confirm == str(["privacy_clear", "network"]), "setting": ["privacy_clear", "network"]})
					rows.append({"title": I18n.t("Confirm clearing file settings" if _confirm == str(["file_settings_clear", "all"]) else "Clear file settings"), "icon": "check" if _confirm == str(["file_settings_clear", "all"]) else "trash", "selected": _confirm == str(["file_settings_clear", "all"]), "setting": ["file_settings_clear", "all"]})
					rows.append({"title": I18n.t("Confirm clearing network file settings" if _confirm == str(["file_settings_clear", "network"]) else "Clear network file settings"), "icon": "check" if _confirm == str(["file_settings_clear", "network"]) else "trash", "selected": _confirm == str(["file_settings_clear", "network"]), "setting": ["file_settings_clear", "network"]})
				rows.append_array(_diagnostic_rows(settings.get("diagnostic_log", {})))
			elif tab == DISPLAY_TAB:
				rows.append({"title": I18n.t("Control bar transparency"), "icon": "settings", "setting": ["bar_transparency", true]})
				var quality_choices: Array = [{"value": Quality.AUTO, "label": "Auto", "hint": Quality.SCALE_AUTO_HINT}]
				for i in Quality.SCALES.size():
					quality_choices.append({"value": i, "label": Quality.NAMES[i], "hint": Quality.SCALE_HINTS[i]})
				var scale_row := _choice_row("Render scale", "display_quality", int(settings.get("display_quality", Quality.DEFAULT)),
					quality_choices, true, "Restart to apply" if settings.get("display_quality_pending", false) else "")
				scale_row.info = Quality.SCALE_INFO; rows.append(scale_row)
				var refresh_choices: Array = []
				for cap in Quality.refresh_choices(bool(settings.get("low_end_gpu", false))):
					refresh_choices.append({"value": cap, "label": Quality.REFRESH_NAMES[cap], "hint": Quality.REFRESH_HINTS[cap]})
				var refresh_row := _choice_row("Playback refresh rate", "refresh_cap", int(settings.get("refresh_cap", Quality.DEFAULT_REFRESH_CAP)), refresh_choices, true)
				refresh_row.info = Quality.REFRESH_INFO; rows.append(refresh_row)
				var supersampling_choices: Array = []
				for i in Quality.SUPERSAMPLING_NAMES.size():
					supersampling_choices.append({"value": i, "label": Quality.SUPERSAMPLING_NAMES[i], "hint": Quality.SUPERSAMPLING_HINTS[i]})
				var supersampling_row := _choice_row("Supersampling", "supersampling", int(settings.get("supersampling", Quality.DEFAULT_SUPERSAMPLING)), supersampling_choices, true)
				supersampling_row.info = Quality.SUPERSAMPLING_INFO; rows.append(supersampling_row)
				var sharpness_choices: Array = []
				for i in Quality.SHARPNESS.size():
					sharpness_choices.append({"value": Quality.SHARPNESS[i], "label": Quality.SHARPNESS_NAMES[i], "hint": Quality.SHARPNESS_HINTS[i]})
				var sharpness_row := _choice_row("Sharpness", "sharpness", float(settings.get("sharpness", Quality.DEFAULT_VIDEO_SHARPNESS)), sharpness_choices, true)
				sharpness_row.info = Quality.SHARPNESS_INFO; rows.append(sharpness_row)
				rows.append(_choice_row("Show FPS", "show_fps", bool(settings.get("show_fps", false)),
					[{"value": false, "label": "Off"}, {"value": true, "label": "On"}]))
				var watch_row := WatchPalette.row(settings.get("watch_color", WatchPalette.DEFAULT))
				watch_row.title = I18n.t(watch_row.title); rows.append(watch_row)
				rows.append(_choice_row(PlaybackMenuDepth.TITLE, PlaybackMenuDepth.KEY,
					str(settings.get(PlaybackMenuDepth.KEY, PlaybackMenuDepth.DEFAULT)), PlaybackMenuDepth.choices(), true))
				var seek_row := _choice_row("Thumbstick progress bar", "stick_seek_overlay", bool(settings.get("stick_seek_overlay", true)),
					[{"value": false, "label": "Off"}, {"value": true, "label": "On"}])
				seek_row.info = "Show a progress bar when seeking with the thumbstick. Turn off for greater immersion."
				for option in seek_row.choices: option.hint = seek_row.info
				rows.append(seek_row)
			elif tab == BACKGROUND_TAB:
				var selected := CinemaFeature.normalize_background(str(settings.get("background", "cinema")))
				var backgrounds: Array = []
				for option in [["belfast", "Belfast sunset", "image"], ["morning", "Morning sky", "image"], ["night", "Milky Way panorama", "image"], ["cinema", "Grand cinema", "video"], ["dark", "Dark background", "circle"], ["passthrough", "Passthrough", "eyes"]]:
					if option[0] == "cinema" and not CinemaFeature.enabled(): continue
					backgrounds.append({"value": option[0], "label": option[1]})
				if settings.get("background_custom", false):
					backgrounds.append({"value": "custom", "label": "Custom panorama"})
				var background_row := _choice_row("Background", "background", selected, backgrounds)
				background_row.info = "Photo mode saves its background separately. Change it from the photo toolbar."
				rows.append(background_row)
				if selected in ["belfast", "morning", "night", "custom"]:
					var directions: Array = []
					for angle in range(0, 360, 45): directions.append({"value": angle, "label": str(angle) + "°"})
					rows.append(_choice_row("Direction", "background_yaw", int(settings.get("background_yaw", 0)), directions))
					rows.append(_choice_row("Brightness", "background_brightness", float(settings.get("background_brightness", 1.0)),
						[{"value": 0.5, "label": "50%"}, {"value": 0.75, "label": "75%"}, {"value": 1.0, "label": "100%"}, {"value": 1.25, "label": "125%"}], true))
				if settings.get("background_custom", false):
					var armed := _confirm == str(["background_remove", true])
					rows.append({"title": I18n.t("Confirm deleting custom background" if armed else "Delete custom background"),
						"icon": "check" if armed else "trash", "selected": armed, "setting": ["background_remove", true],
						"enabled": not settings.get("background_loading", false)})
				if selected == "cinema":
					var ready := bool(settings.get("cinema_ready", false))
					var interaction := str(settings.get("cinema_interaction", "watch"))
					if interaction not in ["watch", "move"]: interaction = "watch"
					var interaction_row := _choice_row("Cinema interaction", "cinema_interaction", interaction,
						[{"value": "watch", "label": "Watch"}, {"value": "move", "label": "Free movement"}], true)
					interaction_row.enabled = ready
					rows.append(interaction_row)
					rows.append({"title": I18n.t("Return to start"),
						"icon": "refresh", "setting": ["cinema_home", true], "enabled": ready})
					rows.append(_choice_row("Cinema lighting", "cinema_lights", str(settings.get("cinema_lights", "auto")),
						[{"value": "auto", "label": "Auto lights"}, {"value": "on", "label": "Lights on"}, {"value": "off", "label": "Lights off"}], true))
					rows.append(_choice_row("Viewing brightness", "cinema_viewing_brightness", str(settings.get("cinema_viewing_brightness", "low")),
						[{"value": "soft", "label": "Soft light"}, {"value": "dim", "label": "Dim"}, {"value": "low", "label": "Low light"}], true))
					rows.append(_choice_row("Screen ambient light", "cinema_screen_light", bool(settings.get("cinema_screen_light", true)),
						[{"value": true, "label": "On"}, {"value": false, "label": "Off"}], true))
					status = "Loading cinema…" if settings.get("cinema_loading", false) else str(settings.get("cinema_error", ""))
					if not ready and status.is_empty(): status = "Cinema unavailable"
				else:
					status = "Loading…" if settings.get("background_loading", false) else str(settings.get("background_error", ""))
			elif tab == ABOUT_TAB:
				if _about_page in [2, 3]:
					var licenses: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/licenses.json"))
					if licenses is Array:
						for license in licenses:
							if _about_page == 3:
								rows.append({"title": str(license.name), "detail": str(license.license), "icon": "info", "license_id": str(license.id)})
							else:
								rows.append(_about_info(I18n.t(str(license.name)), str(license.get("credit", license.license))))
				else:
					rows.append(_about_info("Thru3D Media Player", str(settings.get("version", ""))))
					rows.append(_about_info("FFSky Studio", "© 2026 FFSky Studio"))
					rows.append(_about_info(I18n.t("Support"), "ffskyteam@gmail.com"))
					rows.append(_about_info(I18n.t("Official website"), "https://thru3d.com"))
					rows.append(_about_info(I18n.t("Source code"), "https://github.com/zerochocobo/Thru3D-Media-Player"))
					rows.append({"title": I18n.t("Credits"), "icon": "info", "about_page": 2})
					rows.append({"title": I18n.t("Open source licenses"), "icon": "info", "open_licenses": true})
		Section.CLOUD:
			if cloud_search.active: rows = cloud_search.rows()
			elif not cloud_accounts.mode.is_empty(): rows = cloud_accounts.rows()
			else:
				for entry in _cloud_entries:
					rows.append(_entry_row(entry))
	if section == Section.MEDIA_SERVER:
		rows = server_browser.rows()
	elif section == Section.WEB:
		rows.assign(web_video.rows())
	if compact:
		if section == Section.MEDIA_SERVER:
			rows.assign(rows.filter(func(row): return row.has("scene") or row.has("container_node") or row.has("library") or row.has("server_account") or row.has("open_libraries")))
		else:
			rows.assign(rows.filter(func(row): return not row.has("smb_found")))
	if subtitle_picker_mode:
		rows.assign(rows.filter(func(row): return row.get("folder", false) or not row.has("uri") or SubtitleSources.supported(str(row.get("title", "")))))
	elif audio_import_mode:
		rows.assign(rows.filter(func(row): return not row.has("uri") or str(row.get("uri", "")).is_empty() or row.get("kind", "") == "folder" or AudioCatalog.supported(str(row.get("title", "")))))
	elif voice_picker_mode:
		rows.assign(rows.filter(func(row): return not row.has("uri") or row.get("folder", false) or row.get("kind", "") == "folder" or _voice_sample_source(row)))
	else:
		rows.assign(rows.filter(func(row): return row.get("kind", "") != "audio"))
	if not audio_import_mode and not subtitle_picker_mode and not voice_picker_mode and media_filter > 0 and section not in [Section.SETTINGS, Section.MEDIA_SERVER]:
		rows.assign(rows.filter(func(row): return not row.has("uri") or row.get("kind", "") == "folder" or row.get("kind", "video") in (["image", "archive", "pdf"] if media_filter == 2 and not image_picker_mode else ["image", "pdf"] if media_filter == 2 else ["video"])))
	file_actions.sort_rows()
	file_actions.reconcile()
	if section == Section.RECENT:
		_recent_all_rows.assign(rows)
		_recent_count = rows.size()
		_recent_page = clampi(_recent_page, 0, _recent_page_count() - 1)
		rows.assign(_recent_all_rows.slice(_recent_page * RECENT_PAGE_SIZE, (_recent_page + 1) * RECENT_PAGE_SIZE))
	collections.reconcile()
	focus_index = clampi(focus_index, 0, maxi(0, rows.size() - 1))
	collections.reveal(rows)
	if not _position_to_restore.is_empty():
		scroll = Presentation.position(rows, _position_to_restore, _cols())
		_position_to_restore = {}
	scroll = clampf(scroll, 0.0, _max_scroll())

## The open local folder's path ("" lists the storage volumes).
func _local_path() -> String:
	return "" if _local_stack.is_empty() else str(_local_stack.back().id)

func _cloud_path() -> String:
	return "" if _cloud_stack.is_empty() else str(_cloud_stack.back().id)

func _cancel_cloud() -> void:
	cloud_pagination.cancel()
	for id in _pending.keys():
		if _pending[id] == "cloud":
			if PlatformMethods.supports(platform, "media_cloud_cancel"):
				platform.media_cloud_cancel(int(id))
			_pending.erase(id)
	_cloud_busy = false

func _load_cloud(reset: bool = true, force: bool = false, page: int = 0, restoring: bool = false) -> void:
	_cancel_cloud()
	if reset: _cloud_location = _cloud_path()
	if not restoring: _browse_cloud_restore = {}
	if cloud_pagination.before_load(reset, force):
		if reset: _position_to_restore = _saved_cloud_position().get("position", {}).duplicate(true)
		return
	if force and cloud_error.reason in ["cloud_page_expired", "cloud_location_expired"]:
		if cloud_error.reason == "cloud_location_expired" and _cloud_stack.size() > 1:
			_cloud_stack.resize(1); _cloud_location = _cloud_path()
		_cloud_offsets.assign([0]); page = 0
	cloud_error.clear()
	if reset:
		cloud_search.scopes = ["current"]
		_cloud_location = _cloud_path()
		var saved_page: Dictionary = _saved_cloud_position()
		_browse_expired_page = bool(saved_page.get("expired_page", false))
		if int(saved_page.get("filter", media_filter)) != media_filter or str(saved_page.get("order", file_actions.cloud_order())) != file_actions.cloud_order() or int(saved_page.get("page_size", _cloud_page_size)) != _cloud_page_size: saved_page = {}
		_cloud_entries = []
		_cloud_page = 0
		_cloud_offsets.assign(saved_page.get("offsets", [0]))
		page = int(saved_page.get("page", 0))
		_cloud_next = -1
		_cloud_total = -1
		_cloud_requested_scroll = float(saved_page.get("scroll", 0.0))
		_cloud_requested_position = saved_page.get("position", {}).duplicate(true)
		if not _cloud_requested_position.is_empty() and cloud_pagination.provider() in ["115_open", "baidu", "webdav"]:
			_browse_cloud_restore = {"anchor": _cloud_requested_position.duplicate(true), "origin": page, "tried": [page], "fallback": {}, "scope": _browse_scope(), "revision": browse_memory.revision, "started": Time.get_ticks_msec()}
	else:
		_cloud_requested_scroll = scroll if page == _cloud_page else 0.0
		_cloud_requested_position = capture_position() if page == _cloud_page else {}
	if restoring and not _browse_cloud_restore.is_empty(): _cloud_requested_position = _browse_cloud_restore.anchor.duplicate(true)
	if not platform or page < 0 or page >= _cloud_offsets.size(): return
	_cloud_requested_page = page
	_cloud_busy = true
	if cloud_pagination.supported():
		_request("cloud", platform.media_cloud_page_options(_cloud_path(), _cloud_offsets[page], force, file_actions.cloud_order(), str(_cloud_stack.back().get("cloud_id", "")), _cloud_page_size, subtitle_picker_mode))
	elif subtitle_picker_mode:
		_request("cloud", platform.media_subtitle_cloud_page(_cloud_path(), _cloud_offsets[page], force, file_actions.cloud_order(), str(_cloud_stack.back().get("cloud_id", "")) if not _cloud_stack.is_empty() else ""))
	elif PlatformMethods.supports(platform, "media_cloud_directory_page") and not _cloud_path().is_empty():
		_request("cloud", platform.media_cloud_directory_page(_cloud_path(), _cloud_offsets[page], force, file_actions.cloud_order(), str(_cloud_stack.back().get("cloud_id", ""))))
	elif PlatformMethods.supports(platform, "media_cloud_sorted_page") and not _cloud_path().is_empty():
		_request("cloud", platform.media_cloud_sorted_page(_cloud_path(), _cloud_offsets[page], force, file_actions.cloud_order()))
	elif PlatformMethods.supports(platform, "media_cloud_page"):
		_request("cloud", platform.media_cloud_page(_cloud_path(), _cloud_offsets[page], force))
	elif page == 0:
		_request("cloud", platform.media_cloud_browse(_cloud_path(), force))
	else:
		status = "Unavailable"
	if not _pending.values().has("cloud"): _cloud_busy = false

## Offset hints are verified against identity. Probe at most two pages in either direction.
func _continue_browse_restore(result: Dictionary) -> Dictionary:
	var resume := _browse_cloud_restore
	if resume.scope != _browse_scope() or resume.revision != browse_memory.revision or browse_memory.locked():
		_browse_cloud_restore = {}; _cloud_requested_position = {}; return result
	if result.get("state") == "ready":
		var candidates: Array = result.get("entries", []).map(func(entry): return _entry_row(entry))
		if Presentation.anchor_index(candidates, resume.anchor) >= 0:
			_browse_cloud_restore = {}; return result
		if resume.fallback.is_empty(): resume.fallback = result.duplicate(true); resume.fallback_page = _cloud_requested_page
	elif result.get("error_reason", "") != "cloud_page_expired" and not (cloud_pagination.provider() == "115_open" and str(result.get("error_detail", "")).contains("invalid directory page response")):
		_browse_cloud_restore = {}; return result # Authentication/network failures are not missing anchors.
	var total := int(result.get("total", -1))
	var next := -1
	if Time.get_ticks_msec() - int(resume.started) < 4000:
		for candidate in [int(resume.origin) + 1, int(resume.origin) - 1, int(resume.origin) + 2, int(resume.origin) - 2]:
			if candidate < 0 or candidate >= cloud_pagination.MAX_PAGE or resume.tried.has(candidate): continue
			if total >= 0 and candidate * _cloud_page_size >= total: continue
			next = candidate; break
	if next >= 0:
		resume.tried.append(next)
		if _cloud_offsets.size() <= next: _cloud_offsets.resize(next + 1)
		_cloud_offsets[next] = next * _cloud_page_size
		_load_cloud(false, false, next, true)
		return {}
	_browse_cloud_restore = {}
	if not resume.fallback.is_empty():
		_cloud_requested_page = int(resume.fallback_page)
		status = "Previous item unavailable; showing nearby position"
		return resume.fallback
	# The directory may have shrunk past the saved offset. One fresh first-page read is sufficient.
	_cloud_offsets.assign([0]); _load_cloud(false, false, 0)
	_cloud_requested_position = {}; _cloud_requested_scroll = 0.0
	return {}

func _turn_cloud_page(step: int) -> void:
	if cloud_pagination.supported():
		if step < 0 or _cloud_next >= 0: cloud_pagination.jump(_cloud_page + step)
		return
	if _cloud_busy or _cloud_stack.is_empty(): return
	var page := _cloud_page + step
	if page < 0 or (step > 0 and _cloud_next < 0): return
	if step > 0:
		_cloud_offsets.resize(page + 1)
		_cloud_offsets[page] = _cloud_next
	file_actions.selection.clear()
	_load_cloud(false, false, page)
	refresh()

func _entry_row(entry: Dictionary) -> Dictionary:
	if bool(entry.get("container", false)):
		var folder_row := {"title": str(entry.title), "detail": "", "icon": "folder", "container": entry, "folder": true,
			"delete_uri": str(entry.get("delete_uri", "")), "can_delete": bool(entry.get("can_delete", false)), "delete_reason": str(entry.get("delete_reason", "File deletion unavailable for this source"))}
		if section == Section.CLOUD and _cloud_stack.is_empty() and not cloud_search.active:
			folder_row.icon = Icons.provider(str(entry.get("provider", "")))
		for field in ["size", "modified", "cloud_id", "delete_effect", "child_count", "type", "can_rename"]:
			if entry.has(field): folder_row[field] = entry[field]
		return folder_row
	var subtitle: bool = subtitle_picker_mode and SubtitleSources.supported(str(entry.title))
	var photo: bool = not subtitle and (entry.get("kind", "") == "image" or ImageInfo.is_image(str(entry.get("uri", "")), str(entry.title)))
	var row := {"title": str(entry.title), "detail": _size(entry), "kind": "image" if photo else "video", "icon": "image" if photo else "video", "uri": str(entry.get("uri", ""))}
	if archives.named(str(entry.get("uri", "")), str(entry.title)):
		row.kind = "pdf" if preload("res://scripts/pdf_pages.gd").named(str(entry.get("uri", "")), str(entry.title)) else "archive"; row.icon = "folder"
	if entry.get("kind", "") == "audio" or AudioCatalog.supported(str(entry.title)):
		row.kind = "audio"; row.icon = "music"
	if subtitle:
		row.kind = "subtitle"; row.icon = "subtitle"
	for field in ["size", "modified", "can_delete", "can_rename", "delete_reason", "id", "cloud_id", "delete_effect", "duration_ms", "width", "height"]:
		if entry.has(field): row[field] = entry[field]
	if not str(entry.get("cover", "")).is_empty():
		row["cover"] = str(entry.cover)
	if section == Section.DLNA and row.has("id") and not _dlna_server.is_empty():
		row.uri = "dlna://" + _dlna_server.uri_encode() + "/" + str(row.id).uri_encode()
	row.location = preload("res://scripts/media_location.gd").capture(self, row)
	return row

func photo_directory_context() -> Dictionary:
	if archives.browsing: return {}
	if section == Section.MEDIA_SERVER: return server_browser.photo_directory_context()
	if section == Section.CLOUD and not _cloud_stack.is_empty() and not cloud_search.active:
		return {"path": _cloud_path(), "order": file_actions.cloud_order()}
	return {}

func image_queue() -> Array[Dictionary]:
	if archives.browsing: return archives.image_queue()
	var result: Array[Dictionary] = []
	if section == Section.MEDIA_SERVER:
		result.assign(server_browser.image_entries()); return result
	for row in (_recent_all_rows if section == Section.RECENT and not _recent_all_rows.is_empty() else rows):
		if row.get("kind") == "image" and row.has("uri"): result.append(row.duplicate(true))
	return result

## Capture browsing order at selection time; later history updates must not reorder playback.
## Paged sources include the loaded page only, without fetching across folders or filters.
func video_queue() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var source: Array = server_browser.playback_entries() if section == Section.MEDIA_SERVER else (_recent_all_rows if section == Section.RECENT and not _recent_all_rows.is_empty() else rows)
	for row in source:
		var uri := str(row.get("uri", ""))
		var title := str(row.get("title", ""))
		if uri.is_empty() or row.get("kind", "") in ["image", "archive", "pdf", "audio", "subtitle"] or ImageInfo.is_image(uri, title): continue
		if row.get("container", false) or row.has("folder") or row.get("kind", "") == "folder": continue
		var metadata: Dictionary = row.duplicate(true)
		metadata.location = preload("res://scripts/media_location.gd").capture(self, row)
		result.append({"uri": uri, "title": title, "metadata": metadata})
	return result

func is_image_uri(uri: String) -> bool:
	return rows.any(func(row): return row.get("uri", "") == uri and row.get("kind") == "image")

static func _leaf(path: String) -> String:
	var parts := path.trim_suffix("/").split("/")
	return parts[parts.size() - 1] if parts.size() > 0 else path

static func _bytes(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	return "%d KB" % maxi(1, bytes / 1024)

static func _size(entry: Dictionary) -> String:
	var bytes := float(entry.get("size", 0))
	if bytes <= 0:
		return ""
	return "%.1f GB" % (bytes / 1073741824.0) if bytes >= 1073741824.0 else "%d MB" % int(bytes / 1048576.0)

# --- activation -----------------------------------------------------------------------------

## Cold Alpha profile awaiting its confirming second press.
var _confirm := ""
var _cache_usage: Variant = null   # thumbnail and photo files/bytes, read on opening settings
var _cache_task := -1
var _cache_result := Vector2i.ZERO
var _cache_rescan := false

func _scan_cache_usage() -> void:
	_cache_usage = false # scanning
	if _cache_task >= 0: _cache_rescan = true; return
	_cache_task = WorkerThreadPool.add_task(func(): _cache_result = _read_cache_usage())

## Applies a finished scan; a scan requested meanwhile (the cache was cleared) runs again first.
func _poll_cache_usage() -> void:
	if _cache_task < 0 or not WorkerThreadPool.is_task_completed(_cache_task): return
	WorkerThreadPool.wait_for_task_completion(_cache_task)
	_cache_task = -1
	if _cache_rescan:
		_cache_rescan = false; _scan_cache_usage(); return
	if not _cache_usage is bool: return # reset, or applied
	_cache_usage = _cache_result
	if visible and section == Section.SETTINGS and tab == GENERAL_TAB: refresh()

func _exit_tree() -> void:
	account_panel.close()
	if is_instance_valid(account_panel.web_surface): account_panel.web_surface.queue_free()
	web_browser.close()
	web_video.close()
	archives.close()
	checkpoint_browse()
	system_text_input.cancel()
	if _cache_task >= 0: WorkerThreadPool.wait_for_task_completion(_cache_task); _cache_task = -1

func _read_cache_usage() -> Vector2i:
	var usage := Thumbnails.usage() + preload("res://scripts/photo_preview_cache.gd").disk_usage()
	if is_instance_valid(platform) and PlatformMethods.supports(platform, "photo_cache_usage"):
		var photo_usage: Variant = JSON.parse_string(str(platform.photo_cache_usage()))
		if photo_usage is Dictionary:
			usage += Vector2i(maxi(0, int(photo_usage.get("files", 0))), maxi(0, int(photo_usage.get("bytes", 0))))
	return usage

## Video state changes arrive several times a second: redraw only when the Alpha profiles
## (current, compiling, cold) shown on the Alpha tab change.
func _activate(target: int) -> void:
	if web_browser.action(target): return
	if web_video.home.action(target): return
	var cast_action := CastPanel.action(target)
	if not cast_action.is_empty(): cast_requested.emit(cast_action); return
	if (image_picker_mode or voice_picker_mode) and target == CLOSE: dismiss(); return
	if cloud_pagination.action(target): return
	if voice_manager.opened: voice_manager.activate(target); return
	if target==ONLINE_PANORAMAS: online_panoramas_requested.emit(); return
	if _subtitle_task_buttons.has(target):
		setting_changed.emit("subtitle_task_command", _subtitle_task_buttons[target].duplicate()); return
	if _audio_preview_rows.has(target):
		var row: Dictionary = _audio_preview_rows[target]
		_audio_preview_scope = _audio_preview_scope_key()
		audio_preview_requested.emit(str(row.uri), str(row.title)); return
	if target == MUSIC_OPEN: music_requested.emit(); return
	if target == AUDIO_IMPORT_CANCEL: dismiss(); return
	if target == AUDIO_IMPORT_DONE:
		var files: Array = audio_selection.values().duplicate(true)
		if files.is_empty(): return
		_restore_audio_import_context(); dismiss(); audio_import_selected.emit(files); return
	_local_release_notice = ""
	if archives.action(target): return
	if collections.action(target): return
	if _activate_footer(target): return
	if cloud_error.action(target): return
	if file_actions.action(target): return
	if target == EXPAND_LIBRARY:
		layout_requested.emit(); return
	if target in [VIEW_LIST, VIEW_GRID]:
		set_view_mode("list" if target == VIEW_LIST else "grid"); return
	if controls_page.action(target): return
	if choices.action(target): return
	if account_panel.action(target): return
	if section == Section.CLOUD and cloud_search.action(target): return
	if section == Section.CLOUD and cloud_accounts.action(target): return
	if section == Section.MEDIA_SERVER and server_browser.action(target): return
	if not _row_target(target) and target != CLEAR_HISTORY:
		_confirm = ""
	if target == CLOSE:
		account_panel.close()
		dismiss()
	elif target == RESTART_APP:
		setting_changed.emit("restart_app", true)
	elif target == QUIT_APP:
		setting_changed.emit("quit_app", true)
	elif target >= NAV_BASE and target < NAV_BASE + NAV.size():
		if target == NAV_BASE + Section.WEB and not Distribution.web_browser_enabled(): return
		web_video.close()
		web_browser.close()
		subtitle_queue_open = false
		_browse_return_restore = false
		cloud_pagination.settings_expanded = false
		_video_settings_expanded.clear()
		_subtitle_settings_expanded = ""
		file_actions.settings_return.clear()
		_save_folder_position()
		archives.suspended = true
		_browse_activity()
		cloud_search.close()
		controls_page.reset()
		file_actions.reset()
		account_panel.close()
		cloud_accounts.reset()
		server_browser.cancel()
		_cancel_cloud()
		section = target - NAV_BASE
		tab = GENERAL_TAB if section == Section.SETTINGS else 0
		scroll = 0.0
		status = ""
		cloud_error.clear()
		_editor = {}
		_cache_usage = null
		_restore_folder_key = _folder_key()
		if section in [Section.SMB, Section.DLNA]: _restore_folder_position()
		_load_section()
		refresh()
	elif target >= TAB_BASE and target < TAB_BASE + SETTING_TABS.size():
		subtitle_queue_open = false
		cloud_pagination.settings_expanded = false
		_video_settings_expanded.clear()
		_subtitle_settings_expanded = ""
		controls_page.reset()
		tab = VIDEO_TAB if target == TAB_BASE + SUBTITLES_TAB else target - TAB_BASE
		scroll = 0.0
		_load_section()
		refresh()
	elif target == BACK:
		_go_back()
	elif target == ABOUT_HOME:
		_about_page = 0
		scroll = 0.0
		refresh()
	elif target == REFRESH:
		_refresh_source()
	elif target == CLOUD_PREVIOUS:
		_turn_cloud_page(-1)
	elif target == CLOUD_NEXT:
		_turn_cloud_page(1)
	elif target == RECENT_PREVIOUS:
		_turn_recent_page(-1)
	elif target == RECENT_NEXT:
		_turn_recent_page(1)
	elif target == ADD:
		_open_editor({})
	elif target == CLOUD_ACCOUNTS and platform:
		file_actions.reset()
		_cancel_cloud()
		account_panel.open("cloud")
	elif target == EDIT:
		var current: Array = _dlna_servers.filter(func(s): return str(s.id) == _dlna_server) if section == Section.DLNA else _smb_servers.filter(func(s): return str(s.id) == _smb_server)
		_open_editor(current[0] if current.size() > 0 else {})
	elif target == GRANT:
		_grant_local_access()
	elif target == ALL_FILES:
		_grant_local_access()
	elif target == USB_STORAGE:
		_quick_usb_storage()
	elif target == EJECT_STORAGE:
		_request_storage_eject()
	elif target == CLEAR_HISTORY:
		collections._remove_rows(catalog.list_recent(), true)
	elif target >= CRUMB_BASE and target < CRUMB_BASE + 10:
		_go_to(target - CRUMB_BASE)
	elif target >= FILTER_BASE and target < FILTER_BASE + MEDIA_FILTERS.size():
		if image_picker_mode or voice_picker_mode: return
		_change_media_filter(target - FILTER_BASE)
	elif _row_target(target):
		var index := _first_line() * _cols() + target - ROW_BASE
		if index < rows.size():
			_choose(rows[index])
	elif not _editor.is_empty():
		_editor_input(target)

func _choose(row: Dictionary) -> void:
	if web_browser.choose(row): return
	if web_video.choose(row): return
	if not bool(row.get("enabled", true)): return
	if archives.browsing: archives.choose(row); return
	if row.get("archive_password_book", false): archives.manage(); return
	if (not image_picker_mode or preload("res://scripts/pdf_pages.gd").named(str(row.get("uri", "")), str(row.get("title", "")))) and not voice_picker_mode and not audio_import_mode and not subtitle_picker_mode and not row.get("folder", false) and row.get("kind", "") != "folder" and row.has("uri") and (row.get("kind", "") in ["archive", "pdf"] or archives.named(str(row.uri), str(row.get("title", "")))):
		_save_folder_position(row); archives.open(row); return
	_browse_return_restore = false
	_browse_activity()
	if not bool(row.get("enabled", true)): return
	if voice_picker_mode and row.has("uri") and not str(row.uri).is_empty() and not row.get("folder", false) and row.get("kind", "") != "folder":
		if not _voice_sample_source(row): return
		finish_voice_picker(str(row.uri), str(row.get("title", ""))); return
	if image_picker_mode and row.has("uri") and not str(row.uri).is_empty() and not row.get("folder", false) and row.get("kind", "") != "folder":
		if row.get("kind", "") != "image" and not ImageInfo.is_image(str(row.uri), str(row.get("title", ""))): return
		var uri := str(row.uri); var title := str(row.get("title", ""))
		_save_folder_position(row)
		_remember_image_picker_location()
		_restore_audio_import_context(); dismiss(); image_selected.emit(uri, title)
		return
	if row.get("cloud_paging_group", false):
		cloud_pagination.settings_expanded = not cloud_pagination.settings_expanded
		choices.reset(); refresh(); return
	if row.get("diagnostic_group", false):
		_diagnostic_expanded = not _diagnostic_expanded
		if _diagnostic_expanded:
			scroll = float(maxi(0, rows.find(row)))
			setting_changed.emit("diagnostic_log", "recent")
		choices.reset(); refresh(); return
	if row.has("subtitle_settings_group"):
		var group := str(row.subtitle_settings_group)
		choices.reset()
		_subtitle_settings_expanded = "" if _subtitle_settings_expanded == group else group
		_rebuild_rows()
		for index in rows.size():
			if rows[index].get("subtitle_settings_group", "") == group:
				scroll = minf(float(index), _max_scroll())
				break
		_drag.clear(); _fling = 0.0
		refresh(); return
	if row.has("video_settings_group"):
		var group := str(row.video_settings_group)
		var expanded := not bool(_video_settings_expanded.get(group, false))
		choices.reset()
		_video_settings_expanded[group] = expanded
		var index := maxi(0, rows.find(row))
		scroll = float(index) if expanded else minf(scroll, float(index))
		_drag.clear(); _fling = 0.0
		refresh(); return
	if not bool(row.get("enabled", true)): return
	if subtitle_picker_mode and row.has("uri") and not str(row.uri).is_empty() and not row.get("folder", false):
		var uri := str(row.uri)
		if not SubtitleSources.valid_uri(uri): return
		var location := subtitle_picker_location()
		_restore_audio_import_context(); dismiss()
		subtitle_selected.emit(uri, str(row.title), location)
		return
	if audio_import_mode and row.has("uri") and not str(row.uri).is_empty():
		if not AudioCatalog.supported(str(row.get("title", ""))): return
		var uri := str(row.uri)
		if audio_selection.has(uri): audio_selection.erase(uri)
		else: audio_selection[uri] = {"uri": uri, "title": str(row.title)}
		refresh()
		return
	if collections.choose(row): return
	if cloud_search.choose(row): return
	if file_actions.select(row): return
	if account_panel.choose(row): return
	if row.has("open_licenses"):
		_open_licenses()
		return
	if row.has("license_id"):
		var id := str(row.license_id)
		var text := ""
		if id == "godot": text = Engine.get_license_text()
		elif id == "godot-third-party": text = _engine_notices()
		else: text = str(platform.license_text(id)) if PlatformMethods.supports(platform, "license_text") else _desktop_license_text(id)
		account_panel.show_license(str(row.title), text if not text.is_empty() else I18n.t("License unavailable"))
		return
	if section == Section.CLOUD and cloud_accounts.choose(row): return
	if row.has("about_page"):
		_about_page = int(row.about_page)
		scroll = 0.0
		refresh()
		return
	if section == Section.MEDIA_SERVER:
		if compact and row.has("scene"):
			server_browser._play(row.scene, int(row.scene.get("position_ms", -1)))
			return
		server_browser.choose(row)
		return
	if row.has("uri") and not str(row.uri).is_empty():
		_save_folder_position(row)
		collections.selected_location = preload("res://scripts/media_location.gd").capture(self, row)
		collections.selected_entry = row.duplicate(true)
		remember_playback_context(str(row.uri))
		dismiss()
		chosen.emit(str(row.uri), str(row.title))
	elif row.has("smb_server"):
		_save_folder_position()
		_smb_server = str(row.smb_server)
		_smb_path = ""
		_smb_entries = []
		_request("smb_browse", _browse_smb(_smb_server, ""))
		scroll = 0.0
		refresh()
	elif row.has("smb_found"):
		_open_editor({"name": str(row.smb_found.name), "host": str(row.smb_found.host)})
	elif row.has("dlna_server"):
		_save_folder_position()
		_dlna_server = str(row.dlna_server)
		_dlna_stack = []
		_dlna_entries = []
		_request("dlna_browse", platform.media_dlna_browse(_dlna_server, "0"))
		scroll = 0.0
		refresh()
	elif row.has("container"):
		var container: Dictionary = row.container
		_save_folder_position(row)
		scroll = 0.0
		if section == Section.LOCAL:
			_local_stack.append(container.duplicate(true))
			_local_entries = []
			_load_section()
		elif section == Section.SMB:
			_smb_path = str(container.id)
			_smb_entries = []
			_request("smb_browse", _browse_smb(_smb_server, _smb_path))
		elif section == Section.CLOUD:
			_cloud_stack.append(container.duplicate(true))
			_cloud_entries = []
			_load_section()
		else:
			_dlna_stack.append({"id": str(container.id), "title": str(container.title)})
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(container.id)))
		_restore_folder_key = _folder_key()
		refresh()
	elif row.has("clear_cache"):
		if bool(row.get("empty", false)):
			return
		if _confirm != "clear_cache":
			_confirm = "clear_cache"
			refresh()
			return
		_confirm = ""
		_cancel_covers()
		Thumbnails.clear()
		preload("res://scripts/photo_preview_cache.gd").clear_disk()
		if PlatformMethods.supports(platform, "clear_photo_cache"): platform.clear_photo_cache()
		_cache_usage = null
		refresh()
	elif row.get("subtitle_queue", false):
		subtitle_queue_open = true; scroll = 0; choices.reset(); refresh()
	elif row.get("voice_manager", false):
		_state = settings_provider.call().get("voice_manager", {})
		voice_manager.open(true)
	elif row.has("setting"):
		if row.setting[0] in ["privacy_clear", "file_settings_clear", "background_remove"] and _confirm != str(row.setting):
			_confirm = str(row.setting); refresh(); return
		if bool(row.get("cold", false)) and _confirm != str(row.setting[1]):
			_confirm = str(row.setting[1])
			refresh()
			return
		_confirm = ""
		setting_changed.emit(str(row.setting[0]), row.setting[1])
		refresh()

## True when a child layer was consumed; false means the source's top-level list.
func navigate_back() -> bool:
	if subtitle_queue_open and section == Section.SETTINGS and tab == VIDEO_TAB:
		if not choices.opened.is_empty(): choices.reset(); refresh(); return true
		subtitle_queue_open = false; scroll = 0; refresh(); return true
	if archives.browsing: archives.back(); return true
	if archives.opened: archives.close(); refresh(); return true
	if cloud_pagination.opened: cloud_pagination.action(CloudPagination.CLOSE); return true
	if section == Section.SETTINGS and tab == GENERAL_TAB and cloud_pagination.settings_expanded:
		if not choices.opened.is_empty(): choices.reset(); refresh(); return true
		cloud_pagination.settings_expanded = false; refresh(); return true
	if voice_manager.opened: voice_manager.back(); return true
	if system_text_input.active(): system_text_input.cancel("", true); return true
	if web_browser.active():
		if web_browser.tabs_open: web_browser.tabs_open = false; web_browser.refresh_windows()
		elif web_browser.data.get("editing", false): platform.web_browser_input("close", "")
		else: web_browser.close(); refresh()
		return true
	if web_browser.library.back(): return true
	if collections.active(): collections.close(); return true
	if section == Section.SETTINGS and tab == GENERAL_TAB and collections.privacy_expanded:
		collections.privacy_expanded = false; choices.reset(); refresh(); return true
	if section == Section.SETTINGS and tab == GENERAL_TAB and _diagnostic_expanded:
		_diagnostic_expanded = false; choices.reset(); refresh(); return true
	if collections.has_selection(): collections.selection.clear(); refresh(); return true
	if has_pointer_capture() or not server_browser.gallery.capture.is_empty():
		for hand in ["left_hand", "right_hand"]: cancel_pointer(hand)
		return true
	if cloud_error.opened:
		cloud_error.action(CloudBrowseError.BACK)
	elif not file_actions.modal.is_empty():
		file_actions.action(FileActions.CANCEL)
	elif not choices.opened.is_empty():
		choices.reset(); controls_page.selection.clear(); refresh()
	elif not controls_page.pending.is_empty() or not controls_page.notice.is_empty():
		controls_page.action(ControlsPage.CANCEL)
	elif account_panel.active():
		if account_panel.view == "web" and account_panel.data.get("web", {}).get("editing", false):
			account_panel.web_action("keyboard_close")
		else: account_panel.action(AccountPanel.BASE)
	elif file_actions.editing:
		file_actions.editing = false; file_actions.selected = ""; refresh()
	elif file_actions.has_selection():
		file_actions.selection.clear(); refresh()
	elif cloud_search.active or not _editor.is_empty() or (section == Section.CLOUD and not cloud_accounts.mode.is_empty()):
		_go_back()
	elif section == Section.MEDIA_SERVER:
		if not server_browser.keyboard.is_empty():
			server_browser.action(ServerBrowser.ACTION + 25); refresh()
		elif server_browser.sources_open:
			server_browser.sources_open = false; refresh()
		elif server_browser.view != "servers" or not server_browser.history.is_empty():
			server_browser.back()
		else: return false
	elif not _crumbs().is_empty():
		_go_back()
	elif section == Section.SETTINGS:
		if file_actions.return_from_settings(): pass
		elif _about_page > 0:
			_about_page = 0; scroll = 0.0; refresh()
		else: _activate(NAV_BASE + Section.RECENT)
	else:
		return false
	return true

func _retire_directory_reads() -> void:
	var reads: Array = {Section.LOCAL: ["local"], Section.SMB: ["smb_browse"], Section.DLNA: ["dlna_browse"]}.get(section, [])
	for id in _pending.keys():
		if _pending[id] in reads: _pending.erase(id)

func _go_back() -> void:
	if archives.browsing: archives.back(); return
	if cloud_pagination.opened:
		cloud_pagination.action(CloudPagination.CLOSE); return
	if file_actions.return_from_settings(): return
	if cloud_search.active: cloud_search.close(true); return
	_save_folder_position()
	_browse_activity(); _browse_return_restore = true
	file_actions.reset()
	if section == Section.CLOUD and not cloud_accounts.mode.is_empty():
		cloud_accounts.action(CloudAccountActions.BACK)
		return
	# Retire old directory reads before changing the path. In particular, late errors
	# must not replace the parent listing/status. Server lists/discovery and save/delete
	# jobs only refresh the server list, so their responses stay wanted.
	_retire_directory_reads()
	scroll = 0.0
	status = ""
	if not _editor.is_empty():
		_editor = {}
	elif section == Section.CLOUD:
		_cloud_stack.pop_back()
		_restore_parent_filter()
		_cloud_entries = []
		_load_section()
	elif section == Section.LOCAL:
		_local_stack.pop_back()
		_restore_parent_filter()
		_local_entries = []
		_load_section()
	elif section == Section.SMB:
		if _smb_path.is_empty():
			_smb_server = ""
			_request("smb_servers", platform.media_smb_servers())
		else:
			_smb_path = _smb_path.get_base_dir() if _smb_path.contains("/") else ""
			_restore_parent_filter()
			_smb_entries = []
			_request("smb_browse", _browse_smb(_smb_server, _smb_path))
	elif section == Section.DLNA:
		if _dlna_stack.is_empty():
			_dlna_server = ""
		else:
			_dlna_stack.pop_back()
			_restore_parent_filter()
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
	_restore_folder_key = _folder_key()
	refresh()

## Path segments of the current folder, the server (or library) first.
func _crumbs() -> Array:
	if archives.browsing: return archives.crumbs()
	match section:
		Section.CLOUD:
			return [] if _cloud_stack.is_empty() else [I18n.t("Cloud drives")] + _cloud_stack.map(func(c): return str(c.title))
		Section.LOCAL:
			return [] if _local_stack.is_empty() else [I18n.t(NAV[Section.LOCAL])] + _local_stack.map(func(c): return str(c.title))
		Section.SMB:
			if _smb_server.is_empty():
				return []
			var names: Array = _smb_servers.filter(func(s): return str(s.id) == _smb_server).map(func(s): return str(s.name))
			var parts: Array = [str(names[0]) if names.size() > 0 else "SMB"]
			for part in _smb_path.split("/", false):
				parts.append(part)
			return parts
		Section.DLNA:
			if _dlna_server.is_empty():
				return []
			var names: Array = _dlna_servers.filter(func(s): return str(s.id) == _dlna_server).map(func(s): return str(s.name))
			var parts: Array = [str(names[0]) if names.size() > 0 else "DLNA"]
			for container in _dlna_stack:
				parts.append(str(container.title))
			return parts
	return []

## Jump to path segment [level] (0: the server or library root).
func _go_to(level: int) -> void:
	if archives.browsing: archives.go_to(level); return
	file_actions.reset()
	var depth := _crumbs().size() - 1
	if level < 0 or level >= depth:
		return
	_save_folder_position()
	_browse_activity(); _browse_return_restore = true
	_retire_directory_reads()
	scroll = 0.0
	status = ""
	match section:
		Section.CLOUD:
			_cloud_stack.resize(level)
			_restore_parent_filter()
			_cloud_entries = []
			_load_section()
		Section.LOCAL:
			_local_stack.resize(level)
			_restore_parent_filter()
			_local_entries = []
			_load_section()
		Section.SMB:
			_smb_path = "/".join(_smb_path.split("/", false).slice(0, level))
			_restore_parent_filter()
			_smb_entries = []
			_request("smb_browse", _browse_smb(_smb_server, _smb_path))
		Section.DLNA:
			_dlna_stack.resize(level)
			_restore_parent_filter()
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
	_restore_folder_key = _folder_key()
	refresh()

func _refresh_source() -> void:
	if not platform:
		return
	if section == Section.CLOUD:
		_load_cloud(false, true, _cloud_page)
		refresh()
		return
	match section:
		Section.LOCAL:
			_local_grant_pending = false # Also recovers when a VR settings overlay sends no resume.
			_local_eject_pending = ""
		Section.SMB:
			if _smb_server.is_empty():
				_request("smb_found", platform.media_smb_discover())
			else:
				_request("smb_browse", _browse_smb(_smb_server, _smb_path))
		Section.DLNA:
			if _dlna_server.is_empty():
				_request("dlna_discover", platform.media_dlna_discover())
			else:
				_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
			refresh()
			return
	_load_section()
	refresh()

# --- Network server editor with a ray keyboard --------------------------------------------------

func _open_editor(server: Dictionary) -> void:
	system_text_input.cancel()
	file_actions.reset()
	_editor = {"id": str(server.get("id", "")), "name": str(server.get("name", "")), "host": str(server.get("host", "")),
		"user": str(server.get("user", "")), "password": "", "has_password": bool(server.get("has_password", false))}
	if section == Section.DLNA:
		var location := str(server.get("location", ""))
		var authority := location.get_slice("://", 1).get_slice("/", 0).get_slice("?", 0) if location.contains("://") else location
		var scheme := location.get_slice("://", 0) if location.contains("://") else "http"
		var host := authority.get_slice(":", 0)
		var port := "443" if scheme == "https" else "80"
		if authority.begins_with("["):
			host = authority.get_slice("]", 0).trim_prefix("[")
			if authority.contains("]:"): port = authority.get_slice("]:", 1)
		elif authority.contains(":"):
			port = authority.get_slice(":", 1)
		if location.is_empty(): port = "8200"
		_editor = {"id": str(server.get("id", "")), "location": location, "host": host, "port": port,
			"initial_host": host, "initial_port": port, "scheme": scheme}
		_field = 0
	else:
		_field = 1 if str(_editor.host).is_empty() else 2
	status = ""
	_shift = false
	_symbols = false
	refresh()

func _editor_fields() -> Array:
	return ["host", "port"] if section == Section.DLNA else FIELDS

func _editor_busy() -> bool:
	return _pending.has(int(_editor.get("request_id", -1)))

func _editor_input(target: int) -> void:
	if _editor_busy() and target != CANCEL: return
	var fields := _editor_fields()
	var key: String = fields[_field]
	if target >= FIELD_BASE and target < FIELD_BASE + fields.size():
		_field = target - FIELD_BASE
	elif target >= KEY_BASE and target < KEY_BASE + 40:
		var layer: Array = SYMBOLS if _symbols else KEYS
		var character: String = layer[(target - KEY_BASE) / 10][(target - KEY_BASE) % 10]
		_editor[key] = str(_editor[key]) + (character.to_upper() if _shift else character)
		_shift = false
	elif target == SHIFT:
		_shift = not _shift
	elif target == SYMBOL_LAYER:
		_symbols = not _symbols
	elif target == SPACE:
		_editor[key] = str(_editor[key]) + " "
	elif target == BACKSPACE:
		_editor[key] = str(_editor[key]).left(-1)
	elif target == CANCEL:
		_editor = {}
	elif target == DELETE and section == Section.DLNA:
		if PlatformMethods.supports(platform, "media_dlna_remove") and not str(_editor.id).is_empty():
			var id: int = platform.media_dlna_remove(str(_editor.id))
			_request("dlna_remove", id)
			_editor.request_id = id
	elif target == SAVE and section == Section.DLNA:
		if str(_editor.host).strip_edges().is_empty() or str(_editor.port).strip_edges().is_empty():
			_field = 0 if str(_editor.host).strip_edges().is_empty() else 1
		elif PlatformMethods.supports(platform, "media_dlna_save"):
			var request := {"id": _editor.id, "host": _editor.host, "port": _editor.port, "scheme": _editor.scheme}
			if _editor.host == _editor.initial_host and _editor.port == _editor.initial_port and not str(_editor.location).is_empty():
				request.location = _editor.location
			var id: int = platform.media_dlna_save(JSON.stringify(request))
			_request("dlna_save", id)
			_editor.request_id = id
	elif target == DELETE:
		if platform and not str(_editor.id).is_empty():
			_request("smb_servers", platform.media_smb_remove(str(_editor.id)))
			if _smb_server == str(_editor.id):
				_smb_server = ""
		_editor = {}
	elif target == SAVE:
		if str(_editor.host).strip_edges().is_empty():
			_field = 1
		elif platform:
			var request := {"id": _editor.id, "name": _editor.name, "host": _editor.host, "user": _editor.user,
				"password": _editor.password}
			_request("smb_servers", platform.media_smb_save(JSON.stringify(request)))
			_smb_server = ""
			_editor = {}
	refresh()

# --- drawing --------------------------------------------------------------------------------

func _is_current_row(row: Dictionary) -> bool:
	var uri := str(row.get("uri", row.get("scene", {}).get("uri", "")))
	return current_file_provider.is_valid() and not uri.is_empty() and uri == str(current_file_provider.call())

func _draw_compact() -> void:
	_set_backdrop(COMPACT_SIZE)
	_block_rays(_backdrop, COMPACT_SIZE)
	var crumbs := _crumbs()
	_button(BACK, "", Vector2(-0.51, 0.36), Vector2(0.075, 0.065), not crumbs.is_empty() or section == Section.MEDIA_SERVER or (cloud_search.active and not archives.browsing), "up")
	var heading: String = cloud_search.query if (cloud_search.active and not archives.browsing) else (_header_title() if not _header_title().is_empty() else I18n.t(NAV[section]))
	if not archives.browsing and section == Section.RECENT:
		for i in 2:
			_button(Collections.HOME_TAB + i, I18n.t("Recent" if i == 0 else "Favorites"), Vector2(-0.20 + i * 0.30, 0.36), Vector2(0.28, 0.065))
			_lit(collections.home_tab == i)
	else:
		var usb := not archives.browsing and not _external_volumes().is_empty()
		var title_x := -0.32 if usb else -0.45
		var title_width := 0.53 if usb else 0.65
		var provider_icon := _header_provider_icon()
		if not provider_icon.is_empty():
			_icon(provider_icon, Vector3(title_x + 0.022, 0.36, 0.004), 0.048, Color(0.9, 0.9, 0.9))
			title_x += 0.060; title_width -= 0.060
		var title := _label(_fit_title(heading, "", title_width, 19), Vector3(title_x, 0.36, 0.004), 19)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if not archives.browsing: _draw_storage_stop(Vector2(-0.40, 0.36))
	_button(CLOSE, "", Vector2(0.51, 0.36), Vector2(0.075, 0.065), true, "close")
	_tips[CLOSE] = I18n.t("Close")
	if archives.browsing or section != Section.RECENT:
		_button(REFRESH, "", Vector2(0.27, 0.36), Vector2(0.075, 0.065), platform != null and not _cloud_busy, "refresh")
		_tips[REFRESH] = I18n.t("Refresh")
	if not archives.browsing and section == Section.LOCAL and _local_grant_needed():
		_button(GRANT, "", Vector2(-0.49, -0.365), Vector2(0.075, 0.065), not _local_grant_pending, "unlock")
		_tips[GRANT] = I18n.t("Choose a folder" if _local_access_mode() == "directory" else "Grant")
	_button(EXPAND_LIBRARY, "", Vector2(0.28, -0.365), Vector2(0.09, 0.065), true, "expand")
	_tips[EXPAND_LIBRARY] = I18n.t("Expand library")
	_decoration(Vector2(1.04, 0.002), Vector2(0, 0.305), Color(0.17, 0.2, 0.24))
	if not image_picker_mode and (archives.browsing or section != Section.RECENT): collections.draw_folder_header(true)
	file_actions.draw_entry(Vector2(0.0, -0.365))
	_draw_rows()
	file_actions.draw_footer()
	collections.draw_footer()
	for spec in [[VIEW_LIST, "list", "List view"], [VIEW_GRID, "grid", "Icon view"]]:
		_button(int(spec[0]), "", Vector2(0.39 + (0.11 if spec[1] == "grid" else 0), -0.365), Vector2(0.09, 0.065), true, str(spec[1]), view_mode == spec[1])
		_tips[int(spec[0])] = I18n.t(str(spec[2]))
	var previous := RECENT_PREVIOUS if section == Section.RECENT else CLOUD_PREVIOUS
	var next := RECENT_NEXT if section == Section.RECENT else CLOUD_NEXT
	var page := _recent_page if section == Section.RECENT else _cloud_page
	var count := str(_recent_page_count()) if section == Section.RECENT else (str(maxi(1, ceili(float(_cloud_total) / _cloud_page_size))) if _cloud_total >= 0 else "…")
	var paging := not archives.browsing and (section == Section.RECENT or (section == Section.CLOUD and not _cloud_stack.is_empty()))
	var can_next := page + 1 < _recent_page_count() if section == Section.RECENT else _cloud_next >= 0
	var busy := _cloud_busy if section == Section.CLOUD else false
	if (cloud_search.active and not archives.browsing):
		previous = CloudSearch.PREVIOUS; next = CloudSearch.NEXT; page = cloud_search.page; count = "…"; paging = true
		can_next = not cloud_search.next_cursor.is_empty(); busy = cloud_search.pending > 0
	if paging and not (section == Section.CLOUD and cloud_pagination.draw_footer(-0.365, true)):
		_button(previous, "", Vector2(-0.49, -0.365), Vector2(0.075, 0.065), not busy and page > 0, "previous")
		_label("%d / %s" % [page + 1, count], Vector3(-0.32, -0.365, 0.004), 16)
		_button(next, "", Vector2(-0.15, -0.365), Vector2(0.075, 0.065), not busy and can_next, "next")
	if not status.is_empty():
		var message := _label(_fit_title(cloud_error.summary_text() if section == Section.CLOUD else I18n.t(status), "", 0.94, 14), Vector3(0, 0.278, 0.004), 14)
		message.modulate = MUTED
		if section == Section.CLOUD and not cloud_error.detail.is_empty():
			_button(CloudBrowseError.OPEN, "", Vector2(0.39, 0.36), Vector2(0.065, 0.065), true, "info")
			_tips[CloudBrowseError.OPEN] = I18n.t("Error details")

func _draw_compact_rows() -> void:
	_list = Node3D.new(); add_child(_list); _decorations.append(_list); _bar_thumb = null
	var first := _first_line() * _cols()
	for i in range(first, mini(rows.size(), first + _drawn_slots())):
		var row: Dictionary = rows[i]
		var k := i - first
		if _grid():
			var center := Vector2(-0.34 + (k % 3) * 0.34, 0.13 - (k / 3) * _pitch())
			_tile(ROW_BASE + k, row, center)
			if not archives.browsing: collections.decorate_row(k, row, center, true, _list)
		else:
			var centre := Vector2(0, 0.215 - k * _pitch())
			if not archives.browsing and collections.managed(row):
				collections.draw_list_row(k, row, centre, _list)
				if not archives.browsing: collections.decorate_row(k, row, centre, false, _list)
				continue
			var managing := not archives.browsing and file_actions.list_management()
			_button(ROW_BASE + k, _fit_title(str(row.title), "", 0.72 if managing else 0.83, 20), centre + Vector2(0.055 if managing else 0.0, 0), Vector2(0.92 if managing else 1.03, 0.098), bool(row.get("enabled", true)), "", false, _list)
			var button: Dictionary = _buttons.back()
			var node: MeshInstance3D = button.node
			if _is_current_row(row):
				button.base_color = SELECTED; node.material_override.set_shader_parameter("surface_color", SELECTED)
			var name: Label3D = node.get_child(0)
			name.position = Vector3(-0.345 if managing else -0.40, 0.021, 0.004); name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			set_label_size(name, 20)
			if name.text != str(row.title): _tips[ROW_BASE + k] = str(row.title)
			_icon(str(row.get("icon", "video")), Vector3(-0.405 if managing else -0.46, 0, 0.005), 0.04, FOLDER if row.has("container") else MUTED, node)
			var detail := _label(_fit_title(str(Presentation.info(row, catalog, section == Section.RECENT).subtitle), "", 0.72 if managing else 0.83, 15), Vector3(-0.345 if managing else -0.40, -0.025, 0.004), 15, node)
			detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; detail.modulate = MUTED
			if not archives.browsing: file_actions.draw_checkbox(ROW_BASE + k, row, centre + Vector2(-0.48, 0))
			if not archives.browsing: collections.decorate_row(k, row, centre + Vector2(-0.10, 0), false, _list)
	if _max_scroll() > 0:
		var span := _bar_span()
		_button(SCROLLBAR, "", Vector2(0.55, span.x - span.y * 0.5), Vector2(0.035, span.y))
		var thumb := span.y * float(_lines()) / _line_count()
		_bar_thumb = _decoration(Vector2(0.01, thumb), Vector2(0.55, span.x - thumb * 0.5), MUTED)
		_bar_thumb.material_override.render_priority = 13
	elif rows.is_empty() and status.is_empty():
		_label("—", Vector3(0, 0, 0.004), 26).modulate = MUTED
	_place_list()

func _draw() -> void:
	# Reuse the compositor's region key to retire login bounds when returning to the library.
	# Same-page redraws keep grow-only bounds and all existing swapchains.
	var login_region := ""
	if account_panel.view == "web":
		var web: Dictionary = account_panel.data.get("web", {})
		login_region = "account-login-%s-%s" % [web.get("renderer", "legacy"), str(web.get("desktop", true))]
	set_meta("menu_capture_region", login_region)
	server_browser.backdrop.clear_surface()
	_audio_storage_labels.clear()
	_audio_preview_rows.clear(); _subtitle_task_buttons.clear()
	audio_preview_seek.clear_layout()
	_audio_preview_state = background_audio_provider.call() if audio_import_mode and background_audio_provider.is_valid() else {}
	_clear_layout()
	_settings_scroll_hint = null
	if web_browser.active():
		_side.visible = false; _backdrop.visible = false
		if is_instance_valid(device_status): device_status.visible = false
		web_browser.refresh_windows(); return
	if is_instance_valid(device_status): device_status.visible = true
	if not cast_state.get("pending", {}).is_empty() or cast_state.get("return_available", false):
		_side.visible = false; _backdrop.visible = true
		_set_backdrop(Vector2(1.16, 0.34), Vector2.ZERO)
		CastPanel.draw(self, cast_state, 0.0)
		return
	if voice_manager.opened:
		_state = settings_provider.call().get("voice_manager", {}) if settings_provider.is_valid() else {}
		_voice_revision = int(_state.get("narration_clone_state", {}).get("revision", 0))
		_side.visible = false; _backdrop.visible = false; voice_manager.draw(); return
	_backdrop.visible = true
	if cloud_pagination.opened:
		cloud_pagination.draw(); return
	if archives.opened:
		_side.visible = false; archives.draw(); return
	if collections.active():
		_side.visible = false; collections.draw(); return
	if cloud_error.opened: cloud_error.draw(); return
	_side.visible = not compact
	if web_browser.library.draw_modal(): return
	if not file_actions.modal.is_empty():
		file_actions.draw_modal()
		return
	if compact:
		_draw_compact()
		return
	if not archives.browsing and account_panel.view == "web":
		account_panel.draw(); return
	# Like common VR players: a navigation column angled towards the viewer, the browser beside
	# it, and round actions floating under the browser.
	_set_backdrop(Vector2(1.46, 1.27) if image_picker_mode else Vector2(1.46, 1.12), Vector2(0.13, -0.075 if image_picker_mode else 0))
	if (section == Section.MEDIA_SERVER and not archives.browsing) and server_browser.focused():
		_side.visible = server_browser.sources_open
		_set_backdrop(Vector2(1.68, 1.44), Vector2(0.13, 0.015))
	if _side.visible:
		var column := _quad(Vector2(0.42, 1.12), Vector3.ZERO, PANEL, 10)
		_side.add_child(column)
		_decorations.append(column)
		var logo := preload("res://scripts/main_logo.gd").new(0.16)
		logo.position = Vector3(0, 0.49, 0.006)
		logo.align_navigation(-0.13, -0.08)
		column.add_child(logo)
		# A tap on the column between its buttons is inside the menu, not a tap away.
		_block_rays(column, Vector2(0.42, 1.12))
		var navigation: Array = [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD] if image_picker_mode or voice_picker_mode else [Section.LOCAL, Section.SMB, Section.CLOUD] if audio_import_mode or subtitle_picker_mode else NAV_ORDER
		if not Distribution.web_browser_enabled(): navigation = navigation.filter(func(item): return item != Section.WEB)
		for position in navigation.size():
			var i: int = navigation[position]
			_nav_button(NAV_BASE + i, I18n.t(NAV[i]), NAV_ICONS[i], Vector2(0, 0.36 - position * minf(0.13, 0.80 / maxf(1, navigation.size() - 1))), i == section, "Beta" if i == Section.WEB else "")
	if not controls_page.active():
		var footer_y := -0.80 if (section == Section.MEDIA_SERVER and not archives.browsing) and server_browser.focused() else -0.65
		if web_video.home.active(): footer_y = web_video.home.footer_y()
		if not audio_import_mode and not subtitle_picker_mode and not image_picker_mode and not voice_picker_mode:
			if not music_quick: music_quick = preload("res://scripts/music_quick_controls.gd").new(self, func(): music_toggle_requested.emit())
			music_quick.draw(MUSIC_OPEN, Vector2(-0.48, footer_y), background_audio_provider.call() if background_audio_provider.is_valid() else {})
		# Closing the menu is the shared footer's job and recentering the player's; only collapse floats here.
		if playback_expanded: _round(EXPAND_LIBRARY, "collapse", Vector2(0.13, footer_y), 0.08, true, false, I18n.t("Collapse library"))
		# With no floating row left, the footer takes its place right under the browser.
		if image_picker_mode or voice_picker_mode:
			_button(CLOSE, I18n.t("Cancel" if voice_picker_mode else "Close"), Vector2(0.13, -0.65), Vector2(0.30, 0.075))
			_place_device_status(Vector2(0.13, -0.79))
		else:
			_place_device_status(Vector2(0.13, footer_y + 0.025))
	if not archives.browsing and account_panel.active():
		account_panel.draw()
		return
	if web_browser.active():
		web_browser.draw(); return
	if web_video.home.draw(): return
	if not archives.browsing and cloud_search.active:
		cloud_search.draw()
		return
	if not archives.browsing and not _editor.is_empty():
		_draw_editor()
		return
	if (section == Section.MEDIA_SERVER and not archives.browsing):
		server_browser.draw()
		_update_highlights()
		return
	# Keep the global stop alongside the upper actions, clear of Home's undo and Settings tabs.
	if not archives.browsing and not subtitle_picker_mode: _draw_storage_stop(_action_position(0.36) if not archives.browsing and section == Section.RECENT else Vector2(0.80, 0.46) if section == Section.SETTINGS else _action_position(0.47))
	# Right header: sub-tabs at the top level, otherwise a clickable path with back.
	var crumbs := _crumbs()
	var cloud_managing: bool = not archives.browsing and section == Section.CLOUD and not cloud_accounts.mode.is_empty()
	if cloud_managing:
		pass # Account actions draw their own title and back target below.
	elif subtitle_queue_open and section == Section.SETTINGS and tab == VIDEO_TAB:
		_button(BACK, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), true, "back")
		_label(I18n.t("Subtitle pre-generation tasks"), Vector3(0.13, 0.46, 0.004), 24)
	elif crumbs.is_empty():
		var tabs: Array = SETTING_TABS if section == Section.SETTINGS else []
		if section == Section.SETTINGS and tab == ABOUT_TAB and _about_page != 0:
			tabs = []
			_label(I18n.t("Open source licenses" if _about_page == 3 else "Credits"), Vector3(0.13, 0.46, 0.004), 24)
		for position in (SETTING_ORDER.size() if not tabs.is_empty() else 0):
			var i: int = SETTING_ORDER[position]
			_button(TAB_BASE + i, I18n.t(tabs[i]), Vector2(-0.43 + position * 0.20, 0.46), Vector2(0.19, 0.07))
			set_label_size(_buttons.back().node.get_child(0), 18)
			_lit(i == tab)
		if controls_page.active():
			controls_page.draw()
			return
		if section in [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD, Section.WEB]:
			var title := _label(web_browser.library.title() if web_browser.library.active() else I18n.t(NAV[section]), Vector3(-0.42, _header_y(), 0.004), 24)
			title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:
		_button(BACK, "", Vector2(-0.52 + _folder_header_inset(), _header_y()), Vector2(0.09, 0.07), true, "up")
		_draw_crumbs(crumbs)
	if (archives.browsing or section in [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD]) and not cloud_managing:
		_button(REFRESH, "", _action_position(0.80), Vector2(0.09, 0.065), platform != null, "refresh")
	if not archives.browsing and section == Section.CLOUD:
		cloud_accounts.draw()
		if not audio_import_mode and not subtitle_picker_mode and cloud_accounts.mode.is_empty() and not _cloud_stack.is_empty() and cloud_search.supported():
			_button(CloudSearch.OPEN, "", _action_position(0.69), Vector2(0.09, 0.065), not _cloud_busy, "search")
			_tips[CloudSearch.OPEN] = I18n.t("Search")
		if not cloud_managing and _cloud_stack.is_empty():
			_button(CLOUD_ACCOUNTS, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), platform != null, "plus")
			_tips[CLOUD_ACCOUNTS] = I18n.t("Cloud accounts")
	if not archives.browsing and section == Section.LOCAL and _local_access_mode() != "none" and platform:
		_button(ALL_FILES, "", _action_position(0.69), Vector2(0.09, 0.065), not _local_grant_pending, "unlock")
		_tips[ALL_FILES] = I18n.t("Choose a folder" if _local_access_mode() == "directory" else "Allow access to all files")
	if not archives.browsing and section == Section.LOCAL and not _external_volumes().is_empty():
		_button(USB_STORAGE,"",_action_position(0.58),Vector2(0.09,0.065),true,"usb")
		_tips[USB_STORAGE] = I18n.t("USB storage")
	if not archives.browsing and section != Section.SETTINGS and not subtitle_picker_mode and not image_picker_mode and not voice_picker_mode: collections.draw_header()
	elif archives.browsing and not image_picker_mode: collections.draw_folder_header(false)
	if not archives.browsing and section == Section.RECENT and collections.home_tab == 0 and not rows.is_empty():
		_button(CLEAR_HISTORY, "", _action_position(0.80), Vector2(0.09, 0.065), true, "trash")
		_tips[CLEAR_HISTORY] = I18n.t("Clear history")
	if not archives.browsing and section == Section.DLNA:
		if not subtitle_picker_mode and not image_picker_mode and not audio_import_mode and not voice_picker_mode and PlatformMethods.supports(platform, "dlna_receiver_enable"):
			var receiving: bool = cast_state.get("enabled", false)
			_button(CastPanel.TOGGLE, I18n.t("Receiving casts" if receiving else "Receive video"), _action_position(0.43), Vector2(0.32, 0.07), true, "", receiving)
			_tips[CastPanel.TOGGLE] = I18n.t("Cast reception is on.\nChoose %s from your phone's cast list. Click to turn off." if receiving else "Enable cast reception, then choose %s from your phone's cast list.") % str(cast_state.get("name", "Thru3D"))
			CastPanel.draw(self, cast_state, -0.79)
		if _dlna_server.is_empty():
			_button(ADD, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), PlatformMethods.supports(platform, "media_dlna_save"), "plus")
			_tips[ADD] = I18n.t("Add server")
		elif _dlna_stack.is_empty() and _dlna_servers.any(func(server): return str(server.id) == _dlna_server and bool(server.get("manual", false))):
			_button(EDIT, "", _action_position(0.69), Vector2(0.09, 0.065), true, "edit")
	if not archives.browsing and section == Section.SMB and _smb_server.is_empty():
		_button(ADD, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), platform != null, "plus")
	if not archives.browsing and section == Section.SMB and not _smb_server.is_empty() and _smb_path.is_empty():
		_button(EDIT, "", _action_position(0.69), Vector2(0.09, 0.065), true, "edit")
	file_actions.draw_header()
	web_browser.library.draw_header()
	if browser_content() and not subtitle_picker_mode: draw_view_modes(_action_position(0.80).y)
	_align_folder_tools()
	if not archives.browsing and preload("res://scripts/online_panorama_panel.gd").AVAILABLE and media_filter==2 and section!=Section.SETTINGS and not audio_import_mode and not image_picker_mode:
		_round(ONLINE_PANORAMAS,"globe",Vector2(0.80,0.58),0.08,true,false,I18n.t("Online panoramas"))
	_decoration(Vector2(1.28, 0.002), Vector2(0.19, 0.405), Color(0.17, 0.2, 0.24))
	_draw_rows()
	web_browser.library.draw_footer()
	if section == Section.SETTINGS and tab == ABOUT_TAB:
		_draw_about()
	var background_settings: Dictionary = settings_provider.call() if settings_provider.is_valid() else {}
	if section == Section.SETTINGS and tab == BACKGROUND_TAB and CinemaFeature.normalize_background(str(background_settings.get("background", "belfast"))) != "cinema":
		var hint_text := I18n.t("Photo mode saves its background separately. Change it from the photo toolbar.")
		if background_settings.get("background", "belfast") == "night": hint_text += "\nESO/S. Brunier · CC BY 4.0"
		var hint := _label(hint_text, Vector3(-0.38, -0.10, 0.004), 16)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.width = 1.16 / hint.pixel_size
		hint.modulate = MUTED
	if section == Section.SETTINGS:
		if not file_actions.settings_return.is_empty():
			_button(BACK, "", Vector2(-0.48, -0.515), Vector2(0.09, 0.07), true, "previous")
			_tips[BACK] = I18n.t("Back")
		_button(RESTART_APP, I18n.t("Restart app"), Vector2(0.10, -0.515), Vector2(0.42, 0.07), true, "refresh")
		_button(QUIT_APP, I18n.t("Close app"), Vector2(0.59, -0.515), Vector2(0.42, 0.07), true, "close")
	if not archives.browsing and _local_grant_needed():
		_button(GRANT, I18n.t("Grant"), Vector2(0.19, -0.34), Vector2(0.3, 0.07), not _local_grant_pending, "", true)
	if collections.has_selection():
		collections.draw_footer()
	elif file_actions.has_selection():
		file_actions.draw_footer()
	elif audio_import_mode:
		_button(AUDIO_IMPORT_CANCEL, I18n.t("Cancel"), Vector2(0.18, -0.515), Vector2(0.26, 0.065))
		_button(AUDIO_IMPORT_DONE, I18n.t("Add audio") + " (%d)" % audio_selection.size(), Vector2(0.61, -0.515), Vector2(0.50, 0.065), not audio_selection.is_empty(), "plus")
		set_label_size(_buttons.back().node.get_child(0), 18)
		var storage_panel := _quad(Vector2(1.46, 0.14), Vector3(0.13, -0.635, 0), PANEL, 10)
		add_child(storage_panel); _decorations.append(storage_panel); _block_rays(storage_panel, Vector2(1.46, 0.14))
		_audio_storage_labels = AudioStorageView.draw(self, background_audio_provider.call() if background_audio_provider.is_valid() else {}, Vector2(0.13, -0.61), 1.26, true)
		_place_device_status(Vector2(0.13, -0.79))
	elif section not in [Section.SETTINGS, Section.WEB] and not cloud_managing and not subtitle_picker_mode and not image_picker_mode and not voice_picker_mode:
		for i in MEDIA_FILTERS.size():
			_button(FILTER_BASE + i, I18n.t(MEDIA_FILTERS[i]), Vector2(0.36 + i * 0.18, -0.515), Vector2(0.17, 0.06), true, "", media_filter == i)
			set_label_size(_buttons.back().node.get_child(0), 17)
	var cloud_paging := not archives.browsing and section == Section.CLOUD and not _cloud_stack.is_empty()
	var cloud_page_y := -0.59 if file_actions.has_selection() else -0.515
	if not archives.browsing and section == Section.RECENT:
		_button(RECENT_PREVIOUS, "‹", Vector2(-0.45, -0.515), Vector2(0.09, 0.07), _recent_page > 0)
		_label("%d / %d" % [_recent_page + 1, _recent_page_count()], Vector3(-0.27, -0.515, 0.004), 18)
		_button(RECENT_NEXT, "›", Vector2(-0.09, -0.515), Vector2(0.09, 0.07), _recent_page + 1 < _recent_page_count())
	if cloud_paging:
		if not cloud_pagination.draw_footer(cloud_page_y, false):
			_button(CLOUD_PREVIOUS, "‹", Vector2(-0.45, cloud_page_y), Vector2(0.09, 0.07), not _cloud_busy and _cloud_page > 0)
			var pages := str(maxi(_cloud_page + 1, maxi(1, ceili(float(_cloud_total) / _cloud_page_size)))) if _cloud_total >= 0 else ("…" if _cloud_next >= 0 else str(_cloud_page + 1))
			_label("%d / %s" % [_cloud_page + 1, pages], Vector3(-0.27, cloud_page_y, 0.004), 18)
			_button(CLOUD_NEXT, "›", Vector2(-0.09, cloud_page_y), Vector2(0.09, 0.07), not _cloud_busy and _cloud_next >= 0)
	var footer_status := cloud_error.summary_text() if not archives.browsing and section == Section.CLOUD else I18n.t(status)
	if audio_import_mode and not str(_audio_preview_state.get("audio_preview_error", "")).is_empty(): footer_status = I18n.t(str(_audio_preview_state.audio_preview_error))
	elif audio_import_mode and _audio_preview_state.get("audio_preview_loading", false): footer_status = I18n.t("Loading preview")
	var line := _label(_fit_title(footer_status, "", 0.46 if audio_import_mode else 0.67, 17), Vector3(-0.45, -0.66 if cloud_paging and file_actions.has_selection() else -0.58 if cloud_paging or file_actions.folder() else -0.52, 0.004), 17)
	if not archives.browsing and section == Section.CLOUD and not cloud_error.detail.is_empty():
		_button(CloudBrowseError.OPEN, "", Vector2(0.30, line.position.y), Vector2(0.07, 0.065), true, "info")
		_tips[CloudBrowseError.OPEN] = I18n.t("Error details")
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	line.modulate = MUTED
	if file_actions.uncertain or file_actions.pending > 0:
		_button(FileActions.CHECK_STATUS, I18n.t(file_actions.pending_text()), Vector2(0.66, -0.59), Vector2(0.30, 0.06), file_actions.pending == 0, "refresh")

## Pack the visible folder actions against the view buttons, without gaps for absent actions.
func _align_folder_tools() -> void:
	if not browser_content() or (section == Section.RECENT and not archives.browsing): return
	var tools: Array[Dictionary] = []
	for target in [CastPanel.TOGGLE, FileActions.SORT, FileActions.EDIT_MODE, EJECT_STORAGE, USB_STORAGE, ALL_FILES, CloudSearch.OPEN, EDIT, REFRESH, VIEW_LIST, VIEW_GRID]:
		for button in _buttons:
			if button.target == target and is_equal_approx(button.rect.get_center().y, 0.445): tools.append(button)
	var right := 0.845
	for i in range(tools.size() - 1, -1, -1):
		var width: float = tools[i].rect.size.x
		var x := right - width * 0.5
		tools[i].node.position.x = x
		tools[i].rect.position.x = x - width * 0.5
		right -= width + 0.02

func _header_provider_icon() -> String:
	if archives.browsing: return ""
	if section == Section.CLOUD and not _cloud_stack.is_empty(): return Icons.provider(cloud_pagination.provider())
	if section == Section.MEDIA_SERVER and not server_browser.server.is_empty(): return Icons.provider(str(server_browser.server.get("provider", "")), "media_library")
	return ""

## Path pills (last four segments); every segment but the current one jumps there.
func _draw_crumbs(crumbs: Array, base: int = CRUMB_BASE) -> void:
	if archives.browsing: base = archives.CRUMB
	var x := -0.455 + _folder_header_inset()
	# Leave room for account actions; the up button still exposes every parent.
	var first := maxi(0, crumbs.size() - (2 if section in [Section.CLOUD, Section.LOCAL] or file_actions.sortable() else 4))
	for i in range(first, crumbs.size()):
		if not archives.browsing and section == Section.CLOUD and not _cloud_stack.is_empty() and i == maxi(1, first):
			_icon(Icons.provider(cloud_pagination.provider()), Vector3(x + 0.025, _header_y(), 0.004), 0.055, Color(0.9, 0.9, 0.9))
			x += 0.070
		var text := _fit_title(str(crumbs[i]), "", 0.24, 19)
		var width := text_width(text, 19) + 0.05
		var current := i == crumbs.size() - 1
		_button(base + i, text, Vector2(x + width * 0.5, _header_y()), Vector2(width, 0.065), not current)
		var label: Label3D = _buttons.back().node.get_child(0)
		set_label_size(label, 19)
		label.modulate = ACCENT if current else MUTED
		if current:
			_buttons.back().base_color = Color(TILE, 0.0)
		x += width + 0.035
		if not current:
			_label("›", Vector3(x - 0.0175, _header_y(), 0.004), 19).modulate = MUTED

func _header_title() -> String:
	if archives.browsing: return " / ".join(archives.crumbs())
	if voice_picker_mode: return I18n.t("Choose audio or video")
	if image_picker_mode: return I18n.t("Choose image")
	if audio_import_mode: return I18n.t("Import audio")
	match section:
		Section.CLOUD:
			return " / ".join(_cloud_stack.map(func(c): return str(c.title)))
		Section.MEDIA_SERVER:
			return str(server_browser.server.get("name", I18n.t("Media servers")))
		Section.LOCAL:
			return " / ".join(_local_stack.map(func(c): return str(c.title)))
		Section.SMB:
			if _smb_server.is_empty():
				return ""
			var names: Array = _smb_servers.filter(func(s): return str(s.id) == _smb_server).map(func(s): return str(s.name))
			return (str(names[0]) if names.size() > 0 else "SMB") + ("" if _smb_path.is_empty() else " / " + _smb_path)
		Section.DLNA:
			if _dlna_server.is_empty():
				return ""
			var names: Array = _dlna_servers.filter(func(s): return str(s.id) == _dlna_server).map(func(s): return str(s.name))
			var path := " / ".join(_dlna_stack.map(func(c): return str(c.title)))
			return (str(names[0]) if names.size() > 0 else "DLNA") + ("" if path.is_empty() else " / " + path)
	return ""

func _draw_rows() -> void:
	if cloud_error.opened: cloud_error.draw_rows(); return
	if compact:
		_draw_compact_rows()
		return
	choices.begin(str([section, tab]))
	_list = Node3D.new()
	add_child(_list)
	_decorations.append(_list)
	_bar_thumb = null
	var first := _first_line() * _cols()
	var row_top: float = 0.045 if (cloud_search.active and not archives.browsing) else (server_browser.list_top() if (section == Section.MEDIA_SERVER and not archives.browsing) and not account_panel.active() else LIST_TOP)
	for i in range(first, mini(rows.size(), first + _drawn_slots())):
		var row: Dictionary = rows[i]
		var k := i - first
		if _grid():
			if (section == Section.MEDIA_SERVER and not archives.browsing):
				var cols := _cols()
				var size: Vector2 = server_browser.tile_size() if server_browser.media_content() else TILE_SIZE
				var step: float = size.x + 0.025 if server_browser.media_content() else GRID_PITCH.x
				var left: float = -0.53 + size.x / 2 if server_browser.media_content() else -0.36
				server_browser.tile(ROW_BASE + k, row, Vector2(left + (k % cols) * step, server_browser.list_top() - size.y / 2 - (k / cols) * _pitch()))
			else:
				var center := Vector2(-0.36 + (k % COLS) * GRID_PITCH.x, (0.095 if (cloud_search.active and not archives.browsing) else GRID_TOP) - TILE_SIZE.y * 0.5 - (k / COLS) * GRID_PITCH.y)
				_tile(ROW_BASE + k, row, center)
				if not archives.browsing: collections.decorate_row(k, row, center, true, _list)
		else:
			if (section == Section.MEDIA_SERVER and not archives.browsing) and server_browser.media_content():
				server_browser.media_row(ROW_BASE + k, row, Vector2(0.17, row_top - k * _pitch())); continue
			if browser_content():
				var center := Vector2(0.17, row_top - k * _pitch())
				_media_row_button(ROW_BASE + k, row, center)
				_decorate_audio_selection(row)
				if not archives.browsing: collections.decorate_row(k, row, center, false, _list)
				continue
			if row.get("voice_manager", false):
				_voice_manager_entry(row, Vector2(0.17, row_top - k * _pitch()), ROW_BASE + k)
				continue
			if row.has("task_actions"):
				_subtitle_task_entry(row, Vector2(0.17, row_top - k * _pitch()), ROW_BASE + k)
				continue
			if row.has("choices") or row.get("slider", false):
				_setting_field(row, Vector2(0.17, row_top - k * _pitch()), ROW_BASE + k)
				continue
			_row_button(ROW_BASE + k, str(row.title), "" if row.get("about_info", false) else str(row.get("detail", "")), str(row.get("icon", "video")),
				Vector2(0.17, row_top - k * _pitch()), bool(row.get("selected", false)), section == Section.WEB)
			if row.has("tip"): _tips[ROW_BASE + k] = I18n.t(str(row.tip))
			if not bool(row.get("enabled", true)):
				_buttons.back().enabled = false
				_buttons.back().foreground = MUTED
				_buttons.back().node.get_child(0).modulate = MUTED
			_decorate_audio_selection(row)
			if row.get("group_header", false):
				var heading: Dictionary = _buttons.back()
				heading.enabled = true; heading.base_color = Color(TILE, 0)
				heading.node.material_override.set_shader_parameter("surface_color", Color(TILE, 0))
				set_label_size(heading.node.get_child(0), TEXT_TITLE)
				heading.node.get_child(0).font = ui_bold_font()
				if row.get("subgroup", false):
					# Nested sections step in and drop to body weight beneath their parent heading.
					set_label_size(heading.node.get_child(0), TEXT_BODY)
					heading.node.get_child(0).font = ui_font()
					for child in heading.node.get_children():
						if child is Node3D: child.position.x += 0.05
			if bool(row.get("about_info", false)):
				_buttons.back().enabled = false
				var node: MeshInstance3D = _buttons.back().node
				var title: Label3D = node.get_child(0)
				title.position.y = 0.023
				title.text = _fit_title(str(row.title), "", 1.08, 21)
				set_label_size(title, 21)
				# Informational rows use two lines, leaving long contacts and credits readable.
				var detail := _label(_fit_title(str(row.detail), "", 1.08, 17), Vector3(-0.48, -0.024, 0.004), 17, node)
				detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				detail.modulate = MUTED
				if account_panel.view == "license":
					_buttons.back().base_color = Color(0, 0, 0, 0)
					node.material_override.set_shader_parameter("surface_color", Color(0, 0, 0, 0))
					node.get_child(1).visible = false
					title.position.x = -0.58; detail.position.x = -0.58
					set_label_size(title, 19); set_label_size(detail, 19); detail.modulate = Color.WHITE
					title.text = str(row.title); detail.text = str(row.detail)
	if _max_scroll() > 0:
		# Scrollbar: the thumb shows position and length; pointing at the track jumps there.
		var top := _bar_span().x
		var height := _bar_span().y
		var bar_x := 0.925 if (section == Section.MEDIA_SERVER and not archives.browsing) and server_browser.media_content() else 0.835
		_button(SCROLLBAR, "", Vector2(bar_x, top - height * 0.5), Vector2(0.04, height))
		var thumb := height * float(_lines()) / _line_count()
		_bar_thumb = _decoration(Vector2(0.012, thumb), Vector2(bar_x, top - thumb * 0.5), MUTED)
		_bar_thumb.material_override.render_priority = 13
		if section == Section.SETTINGS:
			# Follow the last visible row, reserving clearance for the entire bob cycle.
			# Decorative only: no registered button or ray blocker can steal its input.
			_settings_scroll_hint = _icon("scroll_more", Vector3(0.17, -0.451, 0.006), 0.038, ACCENT)
			# Same path as gesture_demo: animation must not repaint the menu's XR layers.
			_settings_scroll_hint.set_meta("menu_eye_buffer", true)
			_settings_scroll_hint.mesh.size = Vector2(0.088, 0.038)
			for side in [-1, 1]:
				var rail := _quad(Vector2(0.065, 0.0015), Vector3(side * 0.085, 0, 0), Color(ACCENT, 0.25), 12)
				_settings_scroll_hint.add_child(rail)
	elif rows.is_empty() and status.is_empty():
		var empty := _label("—", Vector3(0.19, 0.0, 0.004), 30)
		empty.modulate = MUTED
	_place_list()
	choices.finish()

func _decorate_audio_selection(row: Dictionary) -> void:
	if not audio_import_mode or not row.has("uri") or not AudioCatalog.supported(str(row.get("title", ""))): return
	var selected := audio_selection.has(str(row.uri))
	var button: Dictionary = _buttons.back()
	if selected:
		button.base_color = SELECTED
		button.node.material_override.set_shader_parameter("surface_color", SELECTED)
	_icon("check" if selected else "circle", Vector3(0.53, 0, 0.006), 0.035, ACCENT if selected else MUTED, button.node)
	var target := AUDIO_PREVIEW_BASE + int(button.target) - ROW_BASE
	_audio_preview_rows[target] = row
	var playing := str(_audio_preview_state.get("audio_preview_uri", "")) == str(row.uri)
	_round(target, "stop" if playing else "play", Vector2.ZERO, 0.073, bool(_audio_preview_state.get("audio_preview_available", false)), playing, I18n.t("Stop audio preview" if playing else "Preview audio (30 s)"))
	var preview: MeshInstance3D = _buttons.back().node
	preview.reparent(button.node, false); preview.position = Vector3(0.405, 0, 0.012)
	preview.material_override.render_priority = 13
	for child in preview.get_children():
		if child is MeshInstance3D: child.material_override.render_priority = 14
		elif child is Label3D: child.render_priority = 14
	var title: Label3D = button.node.get_child(0)
	title.text = _fit_title(title.text, "", 0.76, title.font_size / TEXT_RASTER_SCALE)
	if playing: audio_preview_seek.draw(button.node, _audio_preview_state)

func _audio_preview_scope_key() -> String:
	return str([section, _folder_key(), _cloud_location, _cloud_path(), _cloud_page, cloud_accounts.mode, account_panel.view])

func _stop_audio_preview() -> void:
	if _audio_preview_scope.is_empty(): return
	_audio_preview_scope = ""; audio_preview_stopped.emit()
	audio_preview_seek.cancel(str(audio_preview_seek.capture.get("hand", "")))

func _voice_manager_entry(row: Dictionary, centre: Vector2, target: int) -> void:
	var title := _label(_fit_title(str(row.title), "", 0.43, TEXT_BODY), Vector3(centre.x - 0.55, centre.y, 0.004), TEXT_BODY, _list)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_button(target, _fit_title(I18n.t("My cloned voices"), "", 0.68, TEXT_BODY), centre + Vector2(0.225, 0), Vector2(0.72, 0.065), true, "", false, _list)
	set_label_size(_buttons.back().node.get_child(0), TEXT_BODY)

func _setting_field(row: Dictionary, centre: Vector2, target: int) -> void:
	_row_button(target, str(row.title), "", "", centre, false)
	var button: Dictionary = _buttons.back()
	button.enabled = false
	var node: MeshInstance3D = button.node
	if node.get_child_count() > 1: node.get_child(1).visible = false
	var title: Label3D = node.get_child(0)
	var inline_hint: bool = not str(row.get("hint", "")).is_empty() and not row.get("switch", false)
	title.position = Vector3(-0.55, 0.014 if inline_hint else 0, 0.004)
	set_label_size(title, 18); title.text = _fit_title(str(row.title), "", 0.43, 18)
	if row.get("key", "") == "file_editing" and not file_actions.settings_return.is_empty():
		title.modulate = ACCENT
		node.add_child(_quad(Vector2(0.004, 0.065), Vector3(-0.60, 0, 0.004), ACCENT, 14))
	if inline_hint:
		var hint := _label(_fit_title(I18n.t(row.hint), "", 0.43, TEXT_AUX), Vector3(-0.55, -0.022, 0.004), TEXT_AUX, node)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; hint.modulate = MUTED
	if not str(row.get("info", "")).is_empty():
		# Pointing at the title explains the setting; the row itself stays inert.
		button.hover_disabled = true; _tips[target] = I18n.t(row.info)
		_icon("info", Vector3(-0.55 + minf(text_width(title.text, 18), 0.43) + 0.022, title.position.y, 0.004), 0.026, MUTED, node)
	if row.has("task_progress"): _progress_on(node, float(row.task_progress), Vector2(0, -0.038), 1.1)
	var first_field := _buttons.size()
	choices.field(node, row, Vector2(0.54, 0) if row.get("switch", false) else Vector2(0.225, 0), 0.09 if row.get("switch", false) else 0.72)
	for index in range(first_field, _buttons.size()):
		_buttons[index]["list_row"] = target
		if not bool(row.get("enabled", true)):
			_buttons[index].enabled = false
			_buttons[index].foreground = MUTED
			_buttons[index].node.get_child(0).modulate = MUTED

## A queued subtitle task: name, state and progress, with its actions as icon buttons on the right.
func _subtitle_task_entry(row: Dictionary, centre: Vector2, target: int) -> void:
	_row_button(target, str(row.title), "", "", centre, false)
	var button: Dictionary = _buttons.back()
	button.enabled = false
	var node: MeshInstance3D = button.node
	if node.get_child_count() > 1: node.get_child(1).visible = false
	var title: Label3D = node.get_child(0)
	title.position = Vector3(-0.55, 0.014, 0.004)
	set_label_size(title, 18); title.text = _fit_title(str(row.title), "", 0.62, 18)
	var hint := _label(_fit_title(str(row.get("hint", "")), "", 0.66, TEXT_AUX), Vector3(-0.55, -0.016, 0.004), TEXT_AUX, node)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; hint.modulate = MUTED
	if not str(row.get("info", "")).is_empty():
		button.hover_disabled = true; _tips[target] = I18n.t(row.info)
	_progress_on(node, float(row.get("task_progress", -1.0)), Vector2(-0.18, -0.036), 0.74)
	var actions: Array = row.get("task_actions", [])
	for index in actions.size():
		var action: Dictionary = actions[index]
		var id := SUBTITLE_TASK_BASE + (target - ROW_BASE) * 4 + index
		_subtitle_task_buttons[id] = {"operation": str(action.operation), "id": str(row.task_id)}
		_round(id, str(action.icon), Vector2.ZERO, 0.056, true, false, I18n.t(str(action.get("tip", ""))))
		var icon: MeshInstance3D = _buttons.back().node
		icon.reparent(node, false); icon.position = Vector3(0.53 - (actions.size() - 1 - index) * 0.07, 0, 0.012)
		icon.material_override.render_priority = 13
		for child in icon.get_children():
			if child is MeshInstance3D: child.material_override.render_priority = 14
			elif child is Label3D: child.render_priority = 14

## Alpha model size: larger inputs cut out finer and cost RVM more time. The trade-off is a tooltip (info
## mark and each option), no line of text; a size not compiled yet says so on its own option instead.
const ALPHA_SIZE_HINT := "Larger sizes are slower; smaller sizes cut out less precisely"
static func _alpha_size_row(settings: Dictionary) -> Dictionary:
	var options: Array = []
	for value in ["256x256", "320x320", "384x384", "512x512"]:
		var label: String = value.get_slice("x", 0)
		# Marked so a changed size can be put back.
		if value == str(settings.get("alpha_profile_default", "320x320")): label += " " + I18n.t("Default")
		var option := {"value": value, "label": label, "hint": ALPHA_SIZE_HINT}
		if value in settings.get("alpha_warming", []): option.hint = "Preparing the model"
		elif value in settings.get("alpha_cold", []): option.hint = "First use prepares the model, about 1 minute"
		options.append(option)
	var row := {"title": I18n.t("Alpha model size"), "key": "alpha_profile", "value": str(settings.get("alpha_profile", settings.get("alpha_profile_default", "320x320"))),
		"choices": options, "compact": true}
	row.info = ALPHA_SIZE_HINT
	return row

## Compile progress of the Alpha model sizes arrives with video state changes, several times a
## second: redraw the video settings only when the sizes' states change.
var _alpha_sizes_shown := ""
func refresh_alpha_sizes() -> void:
	if not visible or section != Section.SETTINGS or tab != VIDEO_TAB or not settings_provider.is_valid() \
		or not _video_settings_expanded.get("alpha", false) \
		or not choices.opened.is_empty() or not choices.capture.is_empty():
		return
	var settings: Dictionary = settings_provider.call()
	var shown := str([settings.get("alpha_profile"), settings.get("alpha_warming", []), settings.get("alpha_cold", [])])
	if shown != _alpha_sizes_shown:
		_alpha_sizes_shown = shown
		refresh()

func _choice_row(title: String, key: String, value: Variant, options: Array, compact: bool = false, hint: String = "") -> Dictionary:
	return {"title": I18n.t(title), "key": key, "value": value, "choices": options, "compact": compact, "hint": hint}

## Diagnostic log, last in General: save it to Download/Thru3D/logs, or serve it on the headset's
## Wi-Fi address (a headset has no share target to a phone), and read recent warnings in place.
var _diagnostic_expanded := false
const DIAGNOSTIC_SAVE_TIP := "Saved in the headset's Download/Thru3D/logs folder. Copy it with a USB cable to a computer, or send it from the headset's file manager."
const DIAGNOSTIC_COMPACT_HINT := "Frame-rate lines every 10 s and whenever playback struggles; warnings and errors all kept"
func _diagnostic_rows(state: Dictionary) -> Array:
	var header := {"title": I18n.t("Diagnostic log"), "group_header": true, "diagnostic_group": true,
		"icon": "chevron_down" if _diagnostic_expanded else "next"}
	if not _diagnostic_expanded: return [header]
	var busy := str(state.get("busy", ""))
	var rows: Array = [header]
	rows.append(_choice_row("Log detail", "diagnostic_detail", bool(state.get("full", false)),
		[{"value": false, "label": "Compact", "hint": DIAGNOSTIC_COMPACT_HINT}, {"value": true, "label": "Full", "hint": "Every line"}]))
	var saved := str(state.get("path", ""))
	if busy == "save":
		rows.append({"title": I18n.t("Saving…"), "icon": "save", "enabled": false})
	elif saved.is_empty():
		rows.append({"title": I18n.t("Save log"), "icon": "save", "detail": str(state.get("save_error", "")),
			"setting": ["diagnostic_log", "save"], "tip": DIAGNOSTIC_SAVE_TIP})
	else:
		# Saved: say where, and how it leaves the headset; choosing it again saves a new file.
		rows.append({"title": I18n.t("Saved to %s") % saved.get_base_dir(), "icon": "check", "selected": true,
			"detail": saved.get_file(), "setting": ["diagnostic_log", "save"], "tip": DIAGNOSTIC_SAVE_TIP})
	var url := str(state.get("url", ""))
	if url.is_empty():
		rows.append({"title": I18n.t("Preparing…" if busy == "share" else "Share on Wi-Fi"), "icon": "globe",
			"detail": str(state.get("share_error", "")), "setting": ["diagnostic_log", "share"], "enabled": busy != "share"})
	else:
		# The address is the title: it is read in the headset and typed on a phone or computer.
		rows.append({"title": url, "icon": "stop", "detail": I18n.t("Until %s · tap to stop") % str(state.get("until", "")),
			"setting": ["diagnostic_log", "stop"], "diagnostic_url": true})
	rows.append({"title": I18n.t("Recent warnings and errors"), "icon": "refresh", "setting": ["diagnostic_log", "recent"]})
	for line in state.get("lines", []):
		rows.append({"title": str(line).left(96), "icon": "info", "enabled": false, "diagnostic_line": true})
	return rows

func _video_settings_group(group: String, title: String) -> Dictionary:
	return {"title": I18n.t(title), "group_header": true, "video_settings_group": group,
		"icon": "chevron_down" if _video_settings_expanded.get(group, false) else "next"}

func _subtitle_rows(settings: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var groups := [{"id": "listening", "title": "Live captions"}]
	if settings.get("voice_manager", {}).get("narration_clone_supported", false):
		groups.append({"id": "narration", "title": "Subtitle narration"})
	groups.append({"id": "appearance", "title": "Subtitle adjustments"})
	for group in groups:
		var expanded: bool = _subtitle_settings_expanded == group.id
		result.append({"title": I18n.t(group.title), "group_header": true, "subgroup": true, "subtitle_settings_group": group.id,
			"icon": "chevron_down" if expanded else "next"})
		if not expanded: continue
		if group.id == "narration": result.append({"title": I18n.t("Subtitle narration"), "voice_manager": true})
		else: result.append_array(_subtitle_group_rows(settings, str(group.id)))
	return result

func _subtitle_group_rows(settings: Dictionary, group: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var defaults: Dictionary = settings.get("subtitle_defaults", {})
	if group == "listening":
		result.append(_choice_row("Original language", "listening_source", defaults.get("listening_source", "ja"), [{"value": "ja", "label": "Japanese"}, {"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}]))
		var translation := _choice_row("Translation", "listening_target", defaults.get("listening_target", ""), [{"value": "", "label": "No translation"}] + preload("res://scripts/comic_translation_protocol.gd").target_choices())
		translation.info = "Recognized text is sent to Microsoft"; result.append(translation)
		result.append(_choice_row("Pre-generate", "subtitle_task_mode", defaults.get("subtitle_task_mode", "original"), [{"value": "original", "label": "Original subtitles"}, {"value": "translated", "label": "Original and translation"}]))
		result.append(_choice_row("Background processing", "subtitle_task_policy", defaults.get("subtitle_task_policy", "playback"), [{"value": "playback", "label": "Playback first"}, {"value": "idle", "label": "Only while idle"}]))
		# The task manager closes the section, matching the player column.
		result.append({"title": I18n.t("Subtitle pre-generation tasks"), "icon": "subtitle", "subtitle_queue": true})
		return result

	var size_row := SubtitleStyle.size_row(float(settings.get("subtitle_size", 100.0)))
	size_row.title = I18n.t("Subtitle size"); result.append(size_row)
	var style_row := SubtitleStyle.style_row(settings.get("subtitle_style", SubtitleStyle.DEFAULT))
	style_row.title = I18n.t("Subtitle color style"); result.append(style_row)
	var line_row := SubtitleStyle.line_row(settings.get("subtitle_line", 0))
	line_row.title = I18n.t("Subtitle display"); result.append(line_row)
	for key in ["subtitle_distance", "subtitle_direction", "subtitle_horizontal_position", "subtitle_vertical_position"]:
		if key == "subtitle_direction":
			var row := SubtitleDepth.direction_row(int(settings.get(key, 0)))
			row.title = I18n.t("Subtitle direction"); result.append(row)
		else:
			var row := SubtitleDepth.slider_row(key, float(settings.get(key, SubtitleDepth.DEFAULT if key == "subtitle_distance" else SubtitleDepth.DEFAULT_POSITION)))
			row.title = I18n.t("Subtitle distance" if key == "subtitle_distance" else ("Horizontal position" if key == "subtitle_horizontal_position" else "Vertical position"))
			result.append(row)
	return result

## A folder, video or server as a tile: a large glyph (videos keep a dark picture area with the
## length or size in the corner), the name in up to two lines below.
func _tile(target: int, row: Dictionary, centre: Vector2) -> void:
	var icon := str(row.get("icon", "video"))
	_button(target, _fit_title(str(row.title), "", 0.5, 18), centre, TILE_SIZE, true, "", false, _list)
	var button: Dictionary = _buttons.back()
	button.base_color = SELECTED if file_actions.editing and file_actions.is_selected(row) else Color(TILE, 0.0)
	if (compact and _is_current_row(row)) or (str(row.get("uri", "")) == collections.reveal_uri and not collections.reveal_uri.is_empty()): button.base_color = SELECTED
	button.enabled = bool(row.get("enabled", true)) and (not file_actions.editing or not file_actions.row_uri(row).is_empty())
	button.node.material_override.set_shader_parameter("surface_color", button.base_color)
	var node: MeshInstance3D = button.node
	var name: Label3D = node.get_child(0)
	if name.text != str(row.title): _tips[target] = str(row.title)
	set_label_size(name, 18)
	name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name.width = (TILE_SIZE.x - 0.03) / name.pixel_size
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	name.position = Vector3(0, -0.06, 0.004)
	var picture := icon in ["video", "image"]
	var area := _quad(Vector2(TILE_SIZE.x - 0.02, 0.165), Vector3(0, 0.04, 0.003), Color(0.13, 0.15, 0.18) if picture else Color(TILE, 0.0), 12)
	node.add_child(area)
	var shown: Texture2D = _picture(row) if picture else null
	if shown:
		var frame := _material(Color.WHITE, 12)
		frame.albedo_texture = shown
		area.material_override = frame
	else:
		var glyph := _icon(icon, Vector3(0, 0.04, 0.005), 0.065 if picture else 0.1, MUTED if picture else (FOLDER if icon == "folder" else Color(0.93, 0.95, 0.98)), node)
		glyph.material_override.render_priority = 13
	if file_actions.editing and not file_actions.row_uri(row).is_empty():
		var marker := _icon("check" if file_actions.is_selected(row) else "circle", Vector3(-0.115, 0.095, 0.009), 0.035, ACCENT, node)
		marker.material_override.render_priority = 14
	var detail := str(row.get("detail", ""))
	if browser_content():
		var info := Presentation.info(row, catalog, section == Section.RECENT)
		detail = str(info.badge)
		_progress_on(node, float(info.ratio), Vector2(0, -0.046), TILE_SIZE.x - 0.035)
	if not detail.is_empty():
		var badge := _label(detail, Vector3(TILE_SIZE.x * 0.5 - 0.02, -0.03, 0.006), 13, node)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.render_priority = 14
		badge.modulate = MUTED

## The current choice is lit by colour (dark green tile, accent text), not a solid accent fill.
func _lit(selected: bool) -> void:
	if not selected:
		return
	var button: Dictionary = _buttons.back()
	button.base_color = SELECTED
	button.foreground = ACCENT
	button.node.get_child(0).modulate = ACCENT

## A played video's frame, or the cover a DLNA server offers (fetched once, then cached).
## Never reads a video to make one.
func _picture(row: Dictionary) -> Texture2D:
	if row.has("thumbnail_key"): return Thumbnails.texture(str(row.thumbnail_key))
	if row.has("scene"):
		var server_picture: Texture2D = server_browser.cover(row)
		return server_picture if server_picture else Thumbnails.texture(str(row.get("uri", "")))
	var cover := str(row.get("cover", ""))
	var played := Thumbnails.texture(str(row.get("uri", "")))
	if cover.is_empty():
		return played
	var cached := Thumbnails.texture(cover)
	if cached:
		_cache_cover_for_rows(cover, cached.get_image() if not played else null)
	if not cached and not _covers.has(cover) and _covers.size() < 4:
		_fetch_cover(cover)
	return cached if cached else played

func _cache_cover_for_rows(cover: String, image: Image) -> void:
	for row in rows:
		if row.get("cover", "") != cover or str(row.get("uri", "")).is_empty(): continue
		var uri := str(row.uri)
		if image and not Thumbnails.has(uri): Thumbnails.store(uri, image)
		if catalog and catalog.has_method("set_cover") and catalog.set_cover(uri, cover): catalog.save()

func _fetch_cover(url: String) -> void:
	var request := HTTPRequest.new()
	request.body_size_limit = COVER_BYTES
	request.timeout = 10.0
	add_child(request)
	_covers[url] = request
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
		_covers.erase(url)
		request.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var image := Image.new()
		if image.load_jpg_from_buffer(body) != OK and image.load_png_from_buffer(body) != OK and image.load_webp_from_buffer(body) != OK:
			return
		if Thumbnails.store(url, image):
			_cache_cover_for_rows(url, image)
			if visible: _draw())
	if request.request(url) != OK:
		_covers.erase(url)
		request.queue_free()

func _cancel_covers() -> void:
	for request in _covers.values():
		request.cancel_request()
		request.queue_free()
	_covers.clear()

func _recent_page_count() -> int:
	return maxi(1, ceili(float(_recent_count) / RECENT_PAGE_SIZE))

func _turn_recent_page(step: int) -> void:
	_recent_page = clampi(_recent_page + step, 0, _recent_page_count() - 1)
	scroll = 0.0
	_drag = {}
	_fling = 0.0
	refresh()

func _progress_on(parent: Node3D, ratio: float, center: Vector2, width: float) -> void:
	if ratio < 0.0: return
	var track := _quad(Vector2(width, 0.003), Vector3(center.x, center.y, 0.008), Color(0.22, 0.29, 0.30), 14)
	parent.add_child(track)
	if ratio <= 0.0: return
	var filled := width * ratio
	parent.add_child(_quad(Vector2(filled, 0.003), Vector3(center.x - width * 0.5 + filled * 0.5, center.y, 0.009), ACCENT, 15))

func _media_row_button(target: int, row: Dictionary, centre: Vector2) -> void:
	if not archives.browsing and collections.managed(row):
		collections.draw_list_row(target - ROW_BASE, row, centre, _list); return
	var info := Presentation.info(row, catalog, section == Section.RECENT)
	var managing := not archives.browsing and file_actions.list_management()
	var status_text := str(info.status)
	var title_width := (0.76 if not status_text.is_empty() else 1.0) - (0.11 if managing else 0.0)
	if audio_import_mode: title_width = minf(title_width, 0.90)
	var body := centre + Vector2(0.055 if managing else 0.0, 0)
	_button(target, _fit_title(str(row.title), "", title_width, 22), body, Vector2(1.13 if managing else 1.24, 0.098), bool(row.get("enabled", true)), "", false, _list)
	var selected := file_actions.is_selected(row) or (str(row.get("uri", "")) == collections.reveal_uri and not collections.reveal_uri.is_empty())
	_lit(selected)
	var node: MeshInstance3D = _buttons.back().node
	var label: Label3D = node.get_child(0)
	var text_x := -0.435 if managing else -0.48
	label.position = Vector3(text_x, 0.023, 0.004)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if label.text != str(row.title): _tips[target] = str(row.title)
	_icon(str(row.get("icon", "video")), Vector3(-0.51 if managing else -0.565, 0, 0.004), 0.045, FOLDER if info.folder else _buttons.back().foreground, node)
	var subtitle_width := (0.76 if float(info.ratio) >= 0 else 1.02) - (0.11 if managing else 0.0)
	var subtitle := _label(_fit_title(str(info.subtitle), "", subtitle_width, 16), Vector3(text_x, -0.025, 0.004), 16, node)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; subtitle.modulate = MUTED
	if not status_text.is_empty():
		var status_label := _label(_fit_title(status_text, "", 0.28, 14), Vector3(0.525 if managing else 0.58, 0.022, 0.004), 14, node)
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; status_label.modulate = ACCENT
	if info.folder: _icon("next", Vector3(0.51 if managing else 0.565, 0, 0.004), 0.028, MUTED, node)
	_progress_on(node, float(info.ratio), Vector2(0.405 if managing else 0.46, -0.025), 0.24)
	if not archives.browsing: file_actions.draw_checkbox(target, row, centre + Vector2(-0.575, 0))

func _row_button(target: int, title: String, detail: String, icon: String, centre: Vector2, selected: bool, two_lines: bool = false) -> void:
	_button(target, _fit_title(title, "", 0.9, TEXT_BODY), centre, Vector2(1.24, 0.098), true, "", false, _list)
	_lit(selected)
	var node: MeshInstance3D = _buttons.back().node
	var label: Label3D = node.get_child(0)
	label.position.x = -0.48
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	set_label_size(label, TEXT_BODY)
	_icon(icon, Vector3(-0.565, 0, 0.004), 0.045, _buttons.back().foreground, node)
	if not detail.is_empty():
		if two_lines: label.position.y = 0.022
		var info := _label(_fit_title(detail, "", 1.04, TEXT_AUX) if two_lines else detail,
			Vector3(-0.48, -0.025, 0.004) if two_lines else Vector3(0.58, 0, 0.004), TEXT_AUX, node)
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if two_lines else HORIZONTAL_ALIGNMENT_RIGHT
		info.modulate = MUTED

## Navigation entry on the angled column: the current one is lit by colour, not a solid fill.
func _nav_button(target: int, text: String, icon: String, centre: Vector2, selected: bool, badge: String = "") -> void:
	_button(target, text, centre, Vector2(0.36, 0.11), true, "", false, _side)
	var button: Dictionary = _buttons.back()
	button.base_color = SELECTED if selected else Color(TILE, 0.0)
	var node: MeshInstance3D = button.node
	var label: Label3D = node.get_child(0)
	label.position.x = -0.08
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.modulate = ACCENT if selected else button.foreground
	if not badge.is_empty():
		label.position.y = 0.018
		var status := _label(badge, Vector3(-0.08, -0.025, 0.004), 14, node)
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		status.modulate = MUTED
	_icon(icon, Vector3(-0.13, 0, 0.004), 0.05, ACCENT if selected else button.foreground, node)

func _draw_about() -> void:
	if _about_page != 0:
		_button(ABOUT_HOME, "", Vector2(0.80, 0.46), Vector2(0.09, 0.07), true, "up")

func _about_info(title: String, detail: String) -> Dictionary:
	return {"title": title, "detail": detail, "icon": "info", "about_info": true}

func _open_licenses() -> void:
	_about_page = 3
	scroll = 0.0
	refresh()

func _desktop_license_text(id: String) -> String:
	if id == "cjk-brackets": return FileAccess.get_file_as_string("res://assets/fonts/LICENSE.txt")
	var index: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/licenses.json"))
	if not index is Array: return ""
	for item in index:
		if item.id == id:
			var text := ""
			for asset in item.get("assets", []):
				var path := ProjectSettings.globalize_path("res://../../third_party/" + str(asset))
				if FileAccess.file_exists(path): text += FileAccess.get_file_as_string(path) + "\n\n"
			return text
	return ""

func _engine_notices() -> String:
	var text := ""
	for component in Engine.get_copyright_info():
		text += str(component.get("name", "")) + "\n"
		for part in component.get("parts", []):
			text += "\n".join(part.get("copyright", [])) + "\n" + str(part.get("license", "")) + "\n\n"
	var licenses := Engine.get_license_info()
	for name in licenses:
		text += str(name) + "\n\n" + str(licenses[name]) + "\n\n"
	return text

func _draw_editor() -> void:
	var dlna_editor := section == Section.DLNA
	var fields := _editor_fields()
	var title := _label("DLNA" if dlna_editor else "SMB", Vector3(-0.42, 0.46, 0.004), 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	for i in fields.size():
		var value := str(_editor[fields[i]])
		if fields[i] == "password":
			value = "•".repeat(value.length()) if not value.is_empty() else ("••••" if bool(_editor.has_password) else "")
		var centre := Vector2(0.025 if i == 0 else 0.665, 0.30) if dlna_editor else Vector2(-0.12 + (i % 2) * 0.64, 0.36 - (i / 2) * 0.115)
		if dlna_editor and i == 0 and value.is_empty(): value = "192.168.1.10"
		var field_width := (0.91 if i == 0 else 0.31) if dlna_editor else 0.62
		_button(FIELD_BASE + i, _fit_title(value, "", field_width - 0.10 if dlna_editor else 0.42, 21), centre, Vector2(field_width, 0.1), not _editor_busy(), "", i == _field)
		var node: MeshInstance3D = _buttons.back().node
		var label: Label3D = node.get_child(0)
		label.position = Vector3(-field_width * 0.5 + 0.04 if dlna_editor else -0.17, -0.012, 0.004)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var name := _label(I18n.t("IP address" if i == 0 else "Port") if dlna_editor else I18n.t(FIELD_NAMES[i]), Vector3(-field_width * 0.5 + 0.03 if dlna_editor else -0.28, 0.02 if dlna_editor else 0.0, 0.004), 17, node)
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name.modulate = Color(0.06, 0.18, 0.14) if dlna_editor and i == _field else MUTED
	var layer: Array = SYMBOLS if _symbols else KEYS
	for r in layer.size():
		for c in 10:
			var character: String = layer[r][c]
			_button(KEY_BASE + r * 10 + c, character.to_upper() if _shift else character,
				Vector2(-0.38 + c * 0.126, 0.1 - r * 0.098), Vector2(0.115, 0.085))
	var y := 0.1 - 4 * 0.098
	_button(SHIFT, "⇧", Vector2(-0.32, y), Vector2(0.18, 0.085), true, "", _shift)
	_button(SYMBOL_LAYER, "#+=" if not _symbols else "abc", Vector2(-0.13, y), Vector2(0.18, 0.085), true, "", _symbols)
	_button(SPACE, "␣", Vector2(0.15, y), Vector2(0.34, 0.085))
	_button(BACKSPACE, "", Vector2(0.43, y), Vector2(0.18, 0.085), true, "backspace")
	var actions := -0.44
	_button(SAVE, "", Vector2(0.73, actions), Vector2(0.18, 0.08), not _editor_busy() and not str(_editor.get("host", "")).strip_edges().is_empty() and (not dlna_editor or not str(_editor.port).strip_edges().is_empty()), "check", true)
	_button(CANCEL, "", Vector2(0.52, actions), Vector2(0.18, 0.08), true, "close")
	if not str(_editor.id).is_empty():
		_button(DELETE, I18n.t("Delete"), Vector2(0.24, actions), Vector2(0.24, 0.08), not _editor_busy())
	if dlna_editor and not status.is_empty():
		_label(I18n.t(status), Vector3(0.13, -0.54, 0.004), 18)

# --- desktop preview helpers ----------------------------------------------------------------

func _activate_hit(hit: Dictionary) -> void:
	if int(hit.target) == SCROLLBAR:
		_scroll_to_bar(float(hit.point.y))
	else:
		super(hit)

func move_focus(direction: int) -> void:
	if rows.is_empty():
		return
	focus_index = posmod(focus_index + direction, rows.size())
	var line := focus_index / _cols()
	scroll = clampf(float(line - _lines() + 1) if line >= _first_line() + _lines() else minf(_first_line(), line), 0.0, _max_scroll())
	_draw()

func activate_desktop() -> void:
	if visible and focus_index < rows.size():
		_choose(rows[focus_index])
