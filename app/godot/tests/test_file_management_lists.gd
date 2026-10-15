extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
var checks := 0
var failures: Array[String] = []

class Harness extends "res://scripts/main.gd":
	func _ready() -> void: set_process(false)
class Reader extends Node3D:
	var local_uri := ""
	var queue: Array[Dictionary] = []
	var closed := 0
	func close_video() -> void: closed += 1; local_uri = ""
	func close_image() -> void: closed += 1; local_uri = ""; queue.clear()
class Platform extends Object:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var before_write := Callable()
	func media_file_management_enabled(_value: bool) -> void: pass
	func send(operation: String, json: String) -> int:
		if operation == "delete" and before_write.is_valid(): before_write.call()
		calls.append({"operation": operation, "target": JSON.parse_string(json)}); return calls.size()
	func media_file_delete(json: String) -> int: return send("delete", json)
	func media_file_delete_prepare(json: String) -> int: return send("prepare", json)
	func media_file_delete_status(json: String) -> int: return send("check", json)
	func media_file_rename_prepare(json: String) -> int: return send("rename_prepare", json)
	func media_file_rename(json: String) -> int: return send("rename", json)
	func respond(state: String, values: Dictionary = {}) -> void:
		var result := {"state": state, "uri": calls.back().target.uri}
		result.merge(values, true); media_list.emit(calls.size(), JSON.stringify(result))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func has(menu: Node3D, id: int) -> bool:
	return menu._buttons.any(func(item): return item.target == id)
func button(menu: Node3D, id: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == id: return item
	return {}
func pick(menu: Node3D, index: int) -> void:
	menu.file_actions.toggle(menu.rows[index])
func fixture(menu: Node3D) -> void:
	menu.section = Menu.Section.LOCAL; menu._local_all_files = true; menu.view_mode = "list"; menu.visible = true
	menu._local_stack = [{"id": "/disk", "title": "Disk"}]
	menu._local_entries = []
	for name in ["a.mp4", "b.mp4", "c.mp4"]:
		menu._local_entries.append({"title": name, "uri": "file:///disk/" + name, "kind": "video", "size": 12, "modified": 10, "can_delete": true, "can_rename": true})
	menu.refresh()
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	Menu.I18n.use("en")
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); fixture(menu)
	var baseline: Rect2 = button(menu, Menu.ROW_BASE).rect
	check(not has(menu, Actions.SELECT_BASE), "Default lists have no checkboxes")
	menu.file_actions.set_enabled(true); menu.refresh()
	check(has(menu, Actions.SELECT_BASE) and not has(menu, Actions.EDIT_MODE), "Opted-in list provides checkboxes without another edit-mode step")
	check(not has(menu, Actions.DELETE_FILE) and not has(menu, Actions.Rename.OPEN), "No operation buttons before selection")
	var box: Node3D = button(menu, Actions.SELECT_BASE).node
	var origin := box.global_position + box.global_basis.z * 0.3
	var direction := -box.global_basis.z
	menu.press_pointer("left_hand", origin, direction, true)
	check(not menu.file_actions.has_selection(), "Checkbox selects on release")
	menu.release_pointer("left_hand", origin, direction, true)
	check(menu.file_actions.selected == "file:///disk/a.mp4", "Physical ray checkbox selects the intended item")
	check(has(menu, Actions.DELETE_FILE) and has(menu, Actions.Rename.OPEN), "Single capable item offers both operations")
	pick(menu, 1); pick(menu, 2)
	check(menu.file_actions.selected_rows().size() == 3 and not has(menu, Actions.Rename.OPEN), "Multiple selected files offer deletion without batch rename")
	var stopped: Array = []
	menu.file_delete_preparing.connect(func(uri): stopped.append(uri))
	menu._activate(Actions.DELETE_FILE)
	check(menu.text_snapshot().contains("Delete 3 items?") and platform.calls.is_empty() and stopped.is_empty(), "Batch opens an explicit confirmation without writing or closing playback")
	menu._activate(Menu.VIEW_GRID)
	check(menu.view_mode == "list", "Confirmation blocks view switches behind it")
	menu._activate(Actions.CANCEL)
	check(menu.file_actions.selected_rows().size() == 3 and stopped.is_empty(), "Cancel preserves selection and playback")
	menu._activate(Actions.DELETE_FILE); menu._activate(Actions.CONFIRM); menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 1 and stopped == ["file:///disk/a.mp4"], "A confirmed batch starts one write and ignores duplicate confirm presses")
	platform.respond("ready", {"deleted": true})
	check(platform.calls.size() == 2 and platform.calls.back().target.uri == "file:///disk/b.mp4" and menu._local_entries.size() == 2, "Successful first item advances serially and removes only that row")
	platform.respond("uncertain")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 2 and menu.file_actions.uncertain and menu.file_actions.selected_rows().size() == 2, "Uncertain result stops the batch and preserves remaining items")
	menu._activate(Actions.CHECK_STATUS); platform.respond("ready", {"exists": false})
	check(platform.calls.size() == 3 and menu._local_entries.size() == 1 and menu.file_actions.selected_rows().size() == 1, "Read-only status resolves one deletion without blindly continuing the stopped batch")
	menu._activate(Actions.DELETE_FILE); menu._activate(Actions.CONFIRM); platform.respond("ready", {"deleted": true})
	check(menu.rows.is_empty() and menu.scroll == 0, "Final deletion repairs an empty list and scroll range")
	fixture(menu); pick(menu, 0); pick(menu, 1)
	menu._activate(Actions.DELETE_FILE); menu._activate(Actions.CONFIRM)
	var count := platform.calls.size()
	menu.file_actions.set_enabled(false); platform.respond("ready", {"deleted": true})
	check(platform.calls.size() == count and menu._local_entries.size() == 2, "Turning management off during a request prevents subsequent batch writes")
	fixture(menu); menu.file_actions.set_enabled(false); menu.refresh()
	check(button(menu, Menu.ROW_BASE).rect == baseline and not has(menu, Actions.SELECT_BASE), "Disabling management restores the original row geometry")
	menu.file_actions.set_enabled(true); menu.refresh(); pick(menu, 0)
	menu._activate(Actions.Rename.OPEN)
	check(menu.file_actions.rename.name == "a" and not menu.file_actions.rename.selected_all, "Rename retains the basename and starts editing at the end")
	menu._activate(Menu.KEY_BASE)
	check(menu.file_actions.rename.name == "a1", "Typing appends instead of replacing the original name")
	check(menu.text_snapshot().contains(".mp4") and has(menu, Actions.Rename.SAME_NAME), "Extension is read-only and video offers same-basename companions")
	menu.file_actions.rename.name = "a".repeat(150) + "tail"; menu._activate(Menu.KEY_BASE)
	check(menu.text_snapshot().contains("tail1│"), "Long names keep the edited end and cursor visible")
	menu.file_actions.rename.name = "a1"
	menu._activate(Actions.Rename.SAME_NAME); menu._activate(Actions.Rename.PREVIEW)
	check(platform.calls.back().target.new_name == "a1" and not platform.calls.back().target.include_same_name, "Companion opt-out is carried into the immutable preview plan")
	platform.respond("ready", {"preview": true, "plan": "name-plan", "moves": [{"from":"a.mp4", "to":"a1.mp4"}]})
	menu._activate(Actions.CANCEL)
	menu.file_actions.reset(); fixture(menu)
	menu._local_entries[0].can_delete = false; menu._local_entries[0].can_rename = false; menu.refresh()
	check(not button(menu, Actions.SELECT_BASE).enabled, "Unsupported items cannot be accidentally selected")
	# Rename-only cloud objects must not inherit deletion permission.
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account", "title":"115"}]
	menu._cloud_entries = [{"id":"/account/old.folder", "title":"old.folder", "container":true,
		"delete_uri":"cloud://account/old.folder", "cloud_id":"9007199254740993", "can_delete":false, "can_rename":true}]
	menu.refresh(); pick(menu, 0)
	check(has(menu, Actions.Rename.OPEN) and not has(menu, Actions.DELETE_FILE), "Cloud folder rename permission is independent from delete permission")
	menu._activate(Actions.Rename.OPEN)
	check(menu.file_actions.rename.name == "old.folder" and not has(menu, Actions.Rename.SAME_NAME), "Folder rename edits its whole name without treating dots as extensions")
	menu.file_actions.rename.name = "new.folder"; menu._activate(Actions.Rename.PREVIEW)
	check(platform.calls.back().target.cloud_id == "9007199254740993" and platform.calls.back().target.folder, "Cloud folder preview retains the exact provider identity")
	platform.respond("ready", {"preview":true, "plan":"folder-plan", "moves":[{"from":"old.folder", "to":"new.folder"}]})
	menu._activate(Actions.CANCEL)
	menu.file_actions.reset(); fixture(menu)
	menu._local_entries = [{"id":"/disk/dir1", "title":"dir1", "container":true, "delete_uri":"file:///disk/dir1", "can_delete":true},
		{"id":"/disk/dir2", "title":"dir2", "container":true, "delete_uri":"file:///disk/dir2", "can_delete":true},
		{"title":"z.mp4", "uri":"file:///disk/z.mp4", "can_delete":true, "size":1, "modified":1}]
	menu.refresh(); pick(menu, 0); pick(menu, 1); pick(menu, 2)
	var before := platform.calls.size()
	menu._activate(Actions.DELETE_FILE)
	check(platform.calls.back().operation == "prepare" and platform.calls.back().target.uri.ends_with("dir1"), "Mixed batch preflights its first directory before any write")
	platform.respond("ready", {"preview":true, "plan":"dir1-plan", "files":3, "folders":0})
	check(platform.calls.back().operation == "prepare" and platform.calls.back().target.uri.ends_with("dir2"), "All selected folders receive independent preflight plans")
	platform.respond("ready", {"preview":true, "plan":"dir2-plan", "files":2, "folders":1})
	check(platform.calls.size() == before + 2 and menu.file_actions.plan_ready, "Completing batch inspection still requires a separate final confirmation")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.back().target.plan == "dir1-plan", "First directory uses its own confirmed snapshot")
	platform.respond("ready", {"deleted":true})
	check(platform.calls.back().target.plan == "dir2-plan", "Second directory keeps its distinct snapshot after the first completes")
	platform.respond("ready", {"deleted":true}); platform.respond("ready", {"deleted":true})
	check(menu.rows.is_empty(), "Mixed folder and file batch completes without losing an item")
	fixture(menu)
	menu._local_entries = [{"title":"old(1).mp4", "uri":"file:///disk/old(1).mp4", "can_delete":true, "can_rename":true, "size":12, "modified":10},
		{"title":"old(1).jpg", "uri":"file:///disk/old(1).jpg", "kind":"image", "can_delete":true, "size":6, "modified":10}]
	menu.refresh(); menu.file_actions.toggle(menu.rows.filter(func(row): return row.uri.ends_with(".mp4"))[0])
	menu._activate(Actions.Rename.OPEN); menu.file_actions.rename.name = "new(1)"; menu._activate(Actions.Rename.PREVIEW)
	platform.respond("ready", {"preview":true, "plan":"exact-uris", "moves":[
		{"from":"old(1).mp4", "to":"new(1).mp4", "old_uri":"file:///disk/old(1).mp4", "new_uri":"file:///disk/new(1).mp4", "size":12},
		{"from":"old(1).jpg", "to":"new(1).jpg", "old_uri":"file:///disk/old(1).jpg", "new_uri":"file:///disk/new(1).jpg", "size":6}]})
	var closed_before := stopped.size(); menu._activate(Actions.Rename.APPLY)
	check(stopped.slice(closed_before) == ["file:///disk/old(1).mp4", "file:///disk/old(1).jpg"], "Companion close requests use the backend's exact URI encoding")
	check(platform.calls.back().target.related_uris == ["file:///disk/old(1).mp4", "file:///disk/old(1).jpg"], "Native mutation waits for every previewed media reader")
	platform.respond("ready", {"renamed":true, "new_uri":"file:///disk/new(1).mp4", "new_title":"new(1).mp4"})
	check(menu._local_entries.any(func(entry): return entry.uri == "file:///disk/new(1).jpg"), "Companion image rows keep the backend's canonical destination URI")
	fixture(menu)
	# Production Main closes the current reader synchronously before the write is dispatched.
	var main := Harness.new(); root.add_child(main)
	main.video = Reader.new(); main.photo = Reader.new(); main.add_child(main.video); main.add_child(main.photo)
	main.video.local_uri = "file:///disk/a.mp4"; main.recent_menu = menu
	menu.current_file_provider = func(): return main.video.local_uri
	menu.file_delete_preparing.connect(main._prepare_file_delete)
	platform.before_write = func(): check(main.video.local_uri.is_empty(), "Current playback is closed before the platform delete call")
	menu.compact = true; menu.refresh(); pick(menu, 0)
	check(menu._lines() == 4 and has(menu, Actions.DELETE_FILE), "Compact selection reserves a row for operations")
	var opener: Rect2 = button(menu, Actions.DELETE_FILE).rect
	menu._activate(Actions.DELETE_FILE)
	check(not opener.intersects(button(menu, Actions.CONFIRM).rect), "Compact confirmation is spatially separate from the delete opener")
	check(menu.text_snapshot().contains("Playback will stop") and main.video.closed == 0, "Compact confirmation explains stopping playback without closing early")
	menu._activate(Actions.CONFIRM)
	check(main.video.closed == 1 and menu.visible, "Deleting the currently playing file keeps the compact operation visible")
	menu._activate(Actions.CANCEL); platform.respond("uncertain")
	check(has(menu, Actions.CHECK_STATUS) and menu.file_actions.modal.is_empty(), "Hidden compact operation keeps a status-check entry after an uncertain response")
	menu._activate(Actions.CHECK_STATUS); menu._activate(Actions.CHECK_STATUS); platform.respond("ready", {"exists":false})
	check(menu._local_entries.size() == 2 and menu._lines() == 5, "Compact list returns to its normal height after deletion")
	menu.current_file_provider = Callable(); menu.file_actions.reset(); fixture(menu)
	var played: Array = []
	menu.chosen.connect(func(uri, _title): played.append(uri))
	menu._choose(menu.rows[1])
	check(played == ["file:///disk/b.mp4"] and not menu.file_actions.has_selection(), "File-name clicks still play normally when checkboxes are enabled")
	menu.visible = true; menu.refresh()
	box = button(menu, Actions.SELECT_BASE).node; origin = box.global_position + box.global_basis.z * 0.3; direction = -box.global_basis.z
	menu.press_pointer("left_hand", origin, direction, true)
	menu.update_pointer("left_hand", origin + Vector3(0, 0.06, 0), direction, true)
	menu.release_pointer("left_hand", origin, direction, true)
	check(not menu.file_actions.has_selection(), "Dragging from a checkbox scrolls or cancels without toggling selection")
	main.free(); menu.queue_free(); await process_frame; platform.free()
	print("File management lists: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
