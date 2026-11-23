extends Node
## Debug-only Quest acceptance through the active production ray menu.

const Library := preload("res://scripts/library_menu.gd")
const PathMenu := Library.PathMenu
const FIXTURE := "/storage/emulated/0/Movies/Thru3D_Folder_Path_QA"
const DEPTH := 12
const HAND := "right_hand"
const HOVER_HAND := "library_path_qa"
const CLIP := "path_preview_2D.mp4"

var _host: Node
var _library: Node3D
var _fixture: Array[Dictionary] = []

func run(host: Node, request_key: String) -> void:
	if not OS.is_debug_build(): return
	_host = host
	_library = host.recent_menu
	var folder := FIXTURE
	_fixture.append({"id": folder, "title": "Folder Path QA"})
	for level in range(2, DEPTH + 1):
		var name := "level_%02d" % level
		folder = folder.path_join(name)
		_fixture.append({"id": folder, "title": name})
	var clip := folder.path_join(CLIP)
	var xr := XRServer.find_interface("OpenXR")
	var report := {"request": request_key, "accepted": false, "openxr": xr != null and xr.is_initialized(),
		"pointer": "Synthetic aim through the active production ray menu on Quest; no physical controller tracking test.",
		"layouts": {}}
	if not FileAccess.file_exists(clip):
		report.error = "Fixture clip is missing"
		_write_report(report)
		return

	var original_settings: ConfigFile = host.settings
	var original_path: String = host.settings_path
	var original_history: bool = host.video.history_enabled
	var original_stack: Array = _library._local_stack.duplicate(true)
	var original_entries: Array = _library._local_entries.duplicate(true)
	var scratch := ConfigFile.new()
	for section in original_settings.get_sections():
		for key in original_settings.get_section_keys(section): scratch.set_value(section, key, original_settings.get_value(section, key))
	host.settings = scratch
	host.settings_path = "user://diagnostics/library_path_settings.cfg"
	host.video.history_enabled = false
	host._show_full_library()
	report.layouts.full = await _exercise(false)

	host._on_library_chosen("file://" + clip, CLIP)
	await get_tree().process_frame
	if host._has_open_media():
		host.video.pause_playback()
		if _library.visible: _library.dismiss()
		host._show_recent_menu()
		report.layouts.compact = await _exercise(true)
	else:
		report.layouts.compact = {"error": "Playback fixture did not open", "accepted": false}

	host._close_current_media()
	_library.section = Library.Section.RECENT
	_library._local_stack.assign(original_stack)
	_library._local_entries = original_entries
	host._show_full_library()
	host.video.history_enabled = original_history
	host.settings = original_settings
	host.settings_path = original_path
	report.accepted = report.openxr and report.layouts.full.accepted and report.layouts.compact.accepted
	_write_report(report)

func _exercise(compact: bool) -> Dictionary:
	var input: Node3D = _host._active_menu()
	var layout := {"accepted": false, "compact": compact, "jumps": []}
	if not is_instance_valid(input) or not _library.visible or _library.compact != compact or (compact and input != _host.player_menu):
		layout.error = "Did not enter the requested production layout"
		return layout
	for level in range(DEPTH - 1, -1, -1):
		_library.section = Library.Section.LOCAL
		_library._local_stack.assign(_fixture)
		_library._local_entries = []
		_library.scroll = 0.0
		_library._load_section()
		_library.refresh()
		if not await _wait_for_directory(DEPTH):
			layout.error = "The Android library did not list the 12-level fixture"
			layout.status = _library.status
			layout.depth = _library._local_stack.size()
			layout.entries = _library._local_entries.size()
			layout.pending_local = _library._pending.values().has("local")
			return layout
		var elapsed := await _hover(input)
		if elapsed < PathMenu.OPEN_MS:
			layout.error = "The recorded ray dwell did not open the tree"
			layout.hover_ms = elapsed
			layout.tree_present = _library.path_menu.present
			layout.hover_target = int(_library._hover.get(HOVER_HAND, -1))
			return layout
		var target := PathMenu.ROOT
		if level > 0:
			var start_offset := DEPTH - PathMenu.VISIBLE_ROWS
			var offset := mini(start_offset, level - 1)
			if offset < start_offset:
				input.stick_scroll(1.0, float(start_offset - offset) / PathMenu.SCROLL_SPEED)
			target = PathMenu.ROW + level - 1 - offset
		var accepted := _tap(input, target)
		input.update_pointer(HOVER_HAND, Vector3.ZERO, Vector3.ZERO, false)
		var reached := await _wait_for_directory(level) if accepted else false
		layout.jumps.append({"level": level, "hover_ms": elapsed, "single_trigger": accepted, "directory_ready": reached,
			"actual_depth": _library._local_stack.size(), "tree_closed": not _library.path_menu.open})
		if not reached or _library.path_menu.open:
			layout.error = "The one-click jump did not reach the requested ancestor"
			layout.status = _library.status
			return layout
	layout.compositor = _host.menu_composition.snapshot()
	layout.accepted = true
	return layout

func _wait_for_directory(depth: int) -> bool:
	var deadline := Time.get_ticks_msec() + 3500
	while _library._pending.values().has("local") and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if _library._pending.values().has("local") or _library._local_stack.size() != depth or not _library.status.is_empty():
		return false
	if depth > 0 and _library._local_path() != str(_fixture[depth - 1].id):
		return false
	return not _library._local_entries.is_empty()

func _hover(input: Node3D) -> int:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 1400:
		var ray := _aim(PathMenu.TOGGLE)
		if ray.is_empty(): return -1
		input.update_pointer(HOVER_HAND, ray[0], ray[1], true)
		if _library.path_menu.open: return Time.get_ticks_msec() - start
		await get_tree().process_frame
	return -1

func _tap(input: Node3D, target: int) -> bool:
	var ray := _aim(target)
	if ray.is_empty(): return false
	var hit: Dictionary = _library.ray_hit(ray[0], ray[1])
	if int(hit.get("target", -1)) != target or not hit.get("enabled", false): return false
	# PlayerMenu exposes the child surface as a single hit. The library owns
	# the actual row target, while the trigger must still enter through its host.
	if input != _library and not input.ray_hit(ray[0], ray[1]).get("library", false): return false
	if not input.press_pointer(HAND, ray[0], ray[1], true): return false
	input.release_pointer(HAND, ray[0], ray[1], true)
	return true

func _aim(target: int) -> Array[Vector3]:
	for button in _library._buttons:
		if button.target != target or not button.enabled or not button.node.is_visible_in_tree(): continue
		var eye := _library._mono_pointer_projection().get("eye") as Node3D
		if is_instance_valid(eye):
			return [eye.global_position, (button.node.global_position - eye.global_position).normalized()]
		var axis: Vector3 = button.node.global_basis.z.normalized()
		return [button.node.global_position + axis * 0.3, -axis]
	return []

func _write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute("user://diagnostics")
	var file := FileAccess.open("user://diagnostics/library_path_device.json", FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report))
	queue_free()
