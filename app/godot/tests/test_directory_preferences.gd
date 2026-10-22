extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
const Order := preload("res://scripts/library_order.gd")
var checks := 0
var failures: Array[String] = []
var saved := {}

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); menu.visible = true
	menu.setting_changed.connect(func(key, value):
		if key == "library_orders": saved = value.duplicate(true))
	var entries := [{"id":"/folder","title":"B folder","container":true,"modified":20,"size":999},
		{"uri":"file:///a.mp4","title":"A.mp4","modified":30,"size":10},
		{"uri":"file:///c.mp4","title":"C.mp4","modified":10,"size":20}]
	for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA]:
		menu.file_actions.load({}); menu.section = source
		menu._local_stack = [{"id":"/parent","title":"Parent"}]; menu._local_entries = entries
		menu._smb_server = "account-a"; menu._smb_path = "share/parent"; menu._smb_entries = entries
		menu._dlna_server = "server-a"; menu._dlna_stack = [{"id":"parent","title":"Parent"}]; menu._dlna_entries = entries
		menu.refresh()
		check(menu.file_actions.folders_first() and menu.rows[0].has("container"), "Folders first defaults on: " + str(source))
		menu._activate(Actions.SORT)
		check(menu._buttons.any(func(b): return b.target == Actions.FOLDERS_FIRST and b.enabled), "Sort popup exposes grouping without file editing: " + str(source))
		menu._activate(Actions.FOLDERS_FIRST)
		check(not menu.file_actions.folders_first() and menu.rows[0].title == "A.mp4", "Unticking mixes folders and files naturally: " + str(source))
		menu.file_actions.choose_order("name_desc")
		var parent_scope := menu.file_actions.scope()
		check(menu.rows[0].title == "C.mp4", "Descending mixed order: " + str(source))
		if source == Menu.Section.LOCAL: menu._local_stack.append({"id":"/parent/child","title":"Child"})
		elif source == Menu.Section.SMB: menu._smb_path += "/child"
		else: menu._dlna_stack.append({"id":"child","title":"Child"})
		menu.refresh()
		check(menu.file_actions.order() == "name_asc" and menu.file_actions.folders_first(), "Child uses its own defaults: " + str(source))
		var child_scope := menu.file_actions.scope()
		menu.file_actions.set_default("library_default_order", "modified_desc")
		menu.file_actions.set_default("library_default_folders_first", false)
		check(menu.file_actions.order() == "name_asc" and menu.file_actions.folders_first(), "Changing global defaults preserves visited child: " + str(source))
		menu.file_actions.load(saved)
		check(menu.file_actions.order() == "name_asc" and menu.file_actions.folders_first(), "Both preferences survive serialization: " + str(source))
		check(saved.directories[parent_scope] == {"order":"name_desc","folders_first":false} and saved.directories.has(child_scope), "Parent and child are independently persisted: " + str(source))
		if source == Menu.Section.LOCAL: menu._local_stack = [{"id":"/other","title":"Other"}]
		elif source == Menu.Section.SMB: menu._smb_server = "account-b"
		else: menu._dlna_server = "server-b"
		menu.refresh()
		check(not menu.file_actions.folders_first() and menu.file_actions.order() == ("name_asc" if source == Menu.Section.DLNA else "modified_desc"), "New directories/accounts use global defaults with capability fallback: " + str(source))
	menu.section = Menu.Section.LOCAL; menu._local_stack = [{"id":"/mixed","title":"Mixed"}]
	menu.file_actions.load({}); menu.refresh(); menu.file_actions.choose_order("modified_desc", false)
	check(menu.rows.map(func(row): return row.title) == ["A.mp4","B folder","C.mp4"], "Mixed timestamps compare folders against files")
	menu.file_actions.choose_order("size_desc", false)
	check(menu.rows.back().has("container"), "Mixed size treats folder size as unknown instead of recursive size")
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB; menu.refresh()
	check(menu.rows.any(func(row): return row.get("key") == "library_default_order") and menu.rows.any(func(row): return row.get("key") == "library_default_folders_first"), "General settings expose both global defaults")
	# Cloud order is a directory-wide protocol value, never a per-page client sort.
	var platform := preload("res://tests/test_library_file_actions.gd").Platform.new()
	menu.attach_platform(platform); menu.section = Menu.Section.CLOUD
	menu._cloud_stack = [{"id":"/account","title":"Cloud","provider":"115_open"}]
	menu._cloud_entries = entries; menu.file_actions.load({}); menu.refresh()
	menu.file_actions.choose_order("modified_desc", false)
	check(platform.calls.back().order == "mixed_modified_desc", "Cloud grouping reaches provider before page selection")
	platform.respond(platform.calls.size(), "error", {"path":"/account","offset":0,"order":"mixed_modified_desc"})
	check(menu.file_actions.cloud_order() == "name_asc" and menu.file_actions.folders_first(), "Failed cloud grouping leaves both saved preferences intact")
	menu.file_actions.choose_order("modified_desc", false)
	platform.respond(platform.calls.size(), "ready", {"path":"/account","offset":0,"order":"mixed_modified_desc","entries":[],"next_offset":-1})
	check(menu.file_actions.cloud_order() == "mixed_modified_desc" and not menu.file_actions.folders_first(), "Successful cloud grouping persists both choices")
	menu._cloud_stack.append({"id":"/account/child","title":"Child"})
	check(menu.file_actions.cloud_order() == "name_asc", "Cloud child does not inherit parent sorting")
	menu._cloud_stack[0].provider = "quark_open"
	check(not menu.file_actions.grouping_supported(), "Unverified native APIs cannot pretend to reorder whole directories")
	var main := preload("res://scripts/main.gd").new()
	main.recent_menu = menu
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/directory-sort/preferences.cfg").simplify_path()
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	menu.setting_changed.connect(main._on_setting_changed)
	main._on_setting_changed("library_default_order", "modified_desc")
	main._on_setting_changed("library_default_folders_first", false)
	var config := ConfigFile.new()
	check(config.load(main.settings_path) == OK, "Production settings handler writes the global defaults")
	var reloaded := Menu.new(); reloaded.section = Menu.Section.LOCAL; reloaded._local_stack = [{"id":"/fresh","title":"Fresh"}]
	reloaded.file_actions.load(config.get_value("library", "orders", {}))
	check(reloaded.file_actions.order() == "modified_desc" and not reloaded.file_actions.folders_first(), "New menu restores defaults from the saved settings file")
	reloaded.free(); main.free()
	menu.queue_free(); await process_frame; platform.free()
	print("Directory preferences: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
