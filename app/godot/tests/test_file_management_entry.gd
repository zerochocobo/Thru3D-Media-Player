extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends "res://tests/test_library_file_actions.gd".Platform:
	var reads: Array[Dictionary] = []
	func media_local_browse(path: String) -> int:
		reads.append({"path": path, "id": 10000 + reads.size()}); return reads.back().id

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func button(menu: Node3D, id: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == id: return item
	return {}

func point(menu: Node3D, id: int, hand: String, click: bool = false) -> void:
	var item := button(menu, id)
	check(not item.is_empty(), "Ray target exists: %d" % id)
	if item.is_empty(): return
	var node: Node3D = item.node
	var origin := node.to_global(Vector3(0, 0, 0.3))
	var direction := -node.global_basis.z.normalized()
	menu.update_pointer(hand, origin, direction, true)
	if click:
		menu.press_pointer(hand, origin, direction, true)
		menu.release_pointer(hand, origin, direction, true)

func fixture(menu: Node3D, source: int, compact: bool, view: String) -> void:
	menu.file_actions.settings_return.clear(); menu.file_actions.set_enabled(false)
	menu.section = source; menu.compact = compact; menu.view_mode = view; menu.visible = true
	menu._pending.clear(); menu._cloud_busy = false; menu.status = ""
	menu._local_volumes = []; menu._local_all_files = true
	menu._local_stack = [{"id": "/disk", "title": "Movies"}]
	menu._smb_server = "server"; menu._smb_path = "Movies"
	menu._cloud_stack = [{"id": "/account/Movies", "title": "Movies"}]
	menu._cloud_page = 2; menu._cloud_offsets.assign([0, 48, 96]); menu._cloud_next = 144; menu._cloud_total = 200
	menu.audio_import_mode = false; menu.subtitle_picker_mode = false; menu.cloud_search.close()
	menu._local_entries = []; menu._smb_entries = []; menu._cloud_entries = []
	for i in 50:
		var entry := {"title": "%02d.mp4" % i, "kind": "video", "size": 10, "modified": 1,
			"management_available": true, "can_delete": source != Menu.Section.LOCAL, "can_rename": false}
		entry.uri = "file:///disk/%02d.mp4" % i; menu._local_entries.append(entry.duplicate(true))
		entry.uri = "smb://server/Movies/%02d.mp4" % i; menu._smb_entries.append(entry.duplicate(true))
		entry.uri = "cloud://account/Movies/%02d.mp4" % i; menu._cloud_entries.append(entry.duplicate(true))
	menu.scroll = 2.25; menu.refresh()

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.set_process(false)
	var changes: Array = []
	menu.setting_changed.connect(func(key, value):
		changes.append([key, value])
		if key == "file_editing": menu.file_actions.set_enabled(bool(value)))
	for language in ["en", "zh", "zh_Hant", "ja"]:
		Menu.I18n.use(language)
		for compact in [false, true]:
			for view in ["list", "grid"]:
				for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.CLOUD]:
					fixture(menu, source, compact, view)
					var context := "%s/%s/%s/%s" % [language, compact, view, source]
					var hand := "left_hand" if compact else "right_hand"
					check(button(menu, Actions.EDIT_MODE).get("enabled", false), context + " locked editing can open settings")
					check(button(menu, Actions.SELECT_BASE).is_empty() and not menu.file_actions.editing, context + " no editing before opt-in")
					check(not menu.text_snapshot().contains(Menu.I18n.t("File management is off")), context + " no permanent explanatory text")
					for item in menu._buttons:
						if item.target != Actions.EDIT_MODE and is_equal_approx(item.rect.get_center().y, button(menu, Actions.EDIT_MODE).rect.get_center().y):
							check(not item.rect.intersects(button(menu, Actions.EDIT_MODE).rect), context + " entry has its own hit area")
					point(menu, Actions.EDIT_MODE, hand)
					check(menu._tooltip != null and menu._tooltip.visible and menu._tooltip.get_child(0).text.contains(Menu.I18n.t("Allow file management")), context + " hover names the exact setting")
					var anchor := menu.capture_position()
					var before := changes.size(); var reads := platform.reads.size()
					point(menu, Actions.EDIT_MODE, hand, true)
					check(menu.section == Menu.Section.SETTINGS and menu.tab == Menu.GENERAL_TAB and not menu.compact, context + " opens full general settings")
					check(not menu.file_actions.enabled and not menu.file_actions.editing and changes.size() == before and platform.calls.is_empty(), context + " shortcut never enables or writes")
					var highlighted := false
					for item in menu._buttons:
						if item.target == Menu.ROW_BASE + 1: highlighted = item.node.get_child(0).modulate == menu.ACCENT
					check(highlighted, context + " destination setting is highlighted")
					var on_target := -999
					for id in menu.choices.targets:
						var option: Dictionary = menu.choices.targets[id]
						if option.get("key") == "file_editing" and option.get("value") == true: on_target = id
					point(menu, on_target, hand, true)
					check(menu.file_actions.enabled and changes.size() == before + 1 and changes.back() == ["file_editing", true], context + " only explicit On enables management")
					if compact: check(menu.navigate_back(), context + " controller back consumes the settings shortcut")
					else: point(menu, Menu.BACK, hand, true)
					check(menu.section == source and menu.compact == compact and menu.view_mode == view and menu.capture_position() == anchor, context + " return restores the directory, view, panel and fractional position")
					check(menu.file_actions.settings_return.is_empty() and menu._cloud_page == 2, context + " return clears shortcut and retains cloud page")
					if source == Menu.Section.LOCAL:
						check(platform.reads.size() == reads + 1, context + " local write capabilities are refreshed")
						var entries: Array = menu._local_entries.duplicate(true)
						for entry in entries: entry.can_delete = true
						platform.media_list.emit(platform.reads.back().id, JSON.stringify({"state":"ready", "path":"/disk", "all_files":true, "entries":entries}))
						check(menu.capture_position() == anchor, context + " refreshed capabilities preserve scroll")
					if view == "list":
						check(not button(menu, Actions.SELECT_BASE).is_empty() and button(menu, Actions.EDIT_MODE).is_empty(), context + " enabled list directly offers checkboxes")
					else:
						point(menu, Actions.EDIT_MODE, hand, true)
						check(menu.file_actions.editing and menu.section == source, context + " enabled grid enters editing")
						point(menu, Actions.EDIT_MODE, hand, true)
						check(not menu.file_actions.editing, context + " Done exits editing")
	# Distinguish permanent read-only policy and absent capability from the global opt-in.
	for path in ["usb://session/Movies", "content://provider/tree/Movies", "/disk"]:
		fixture(menu, Menu.Section.LOCAL, false, "grid")
		menu._local_stack[0].id = path
		if path == "/disk":
			for entry in menu._local_entries: entry.management_available = false
		menu.refresh(); point(menu, Actions.EDIT_MODE, "left_hand", true)
		check(menu.section == Menu.Section.LOCAL and not button(menu, Actions.EDIT_MODE).enabled, "Read-only or permission-denied directory cannot navigate to opt-in: " + path)
		check(not menu._tooltip.get_child(0).text.contains(Menu.I18n.t("Allow file management")), "Unavailable reason does not promise enabling fixes access")
	for source in [Menu.Section.SMB, Menu.Section.CLOUD, Menu.Section.DLNA, Menu.Section.RECENT]:
		fixture(menu, source, false, "grid")
		for entry in menu._smb_entries + menu._cloud_entries: entry.management_available = false; entry.can_delete = false
		menu.refresh(); check(button(menu, Actions.EDIT_MODE).is_empty(), "Unsupported source has no enabling guide: " + str(source))
	for picker in ["audio_import_mode", "subtitle_picker_mode"]:
		fixture(menu, Menu.Section.LOCAL, false, "list"); menu.set(picker, true); menu.refresh()
		check(button(menu, Actions.EDIT_MODE).is_empty(), "Picker has no management entry: " + picker)
	fixture(menu, Menu.Section.LOCAL, true, "grid")
	var dismissed_anchor := menu.capture_position()
	point(menu, Actions.EDIT_MODE, "left_hand", true)
	menu.file_actions.set_enabled(true); menu.refresh(); menu.file_actions.set_enabled(false); menu.refresh()
	check(not menu.file_actions.settings_return.is_empty(), "Turning On then Off keeps the return destination")
	menu.dismiss()
	check(menu.section == Menu.Section.LOCAL and menu.compact and not menu.visible and menu.file_actions.settings_return.is_empty(), "Closing settings restores the original compact context")
	menu.toggle()
	check(menu.capture_position() == dismissed_anchor, "Reopening after closing Settings restores the original file and fractional position")
	fixture(menu, Menu.Section.CLOUD, false, "grid"); point(menu, Actions.EDIT_MODE, "left_hand", true)
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	check(menu.file_actions.settings_return.is_empty(), "Explicit navigation discards the shortcut return context")
	check(platform.calls.is_empty(), "Discovery, unavailable clicks and settings navigation never dispatch a mutation")
	menu.free(); platform.free()
	print("File management entry: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
