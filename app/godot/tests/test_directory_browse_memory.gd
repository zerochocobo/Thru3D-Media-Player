extends SceneTree
const Memory := preload("res://scripts/directory_browse_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/test_library_navigation_memory.gd").Platform
var checks := 0
var failures: Array[String] = []
var output := ""

class Vault extends RefCounted:
	var protected := true
	var locked := false

class MixedPlatform extends Platform:
	func entries(path: String) -> Array:
		var result := super.entries(path)
		for i in 100:
			for kind in ["video", "image"]:
				result.append({"uri": path + "/%s%03d.%s" % [kind, i, "jpg" if kind == "image" else "mp4"], "title":"%s%03d" % [kind, i], "kind":kind})
		return result

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func fresh(name: String) -> RefCounted:
	var memory := Memory.new()
	memory.load_file(output.path_join(name + ".cfg"))
	return memory

func anchor(i: int) -> Dictionary:
	return {"key": "file:///private-title-%d.mp4" % i, "index": i, "fraction": 0.25}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/directory-resume/%d" % Time.get_ticks_usec()).simplify_path()
	Privacy.vault = null; Privacy.configure(Privacy.ALL)
	var memory := fresh("policy")
	memory.remember("local", false, anchor(12), memory.revision)
	memory.remember("network", true, anchor(24), memory.revision)
	check(memory.flush(), "Initial history writes successfully")
	var disk := FileAccess.get_file_as_string(memory.path)
	check(not disk.contains("private-title") and not disk.contains("file:///"), "Position file contains no plaintext filenames or URLs")
	check(fresh("policy").lookup("network", true).get("index") == 24, "All-history restores network after restart")
	Privacy.configure(Privacy.LOCAL); memory.policy_changed()
	var local_only := fresh("policy")
	check(local_only.lookup("local", false).get("index") == 12 and local_only.lookup("network", true).is_empty(), "Local-only reads only local persisted positions")
	local_only.remember("network", true, anchor(35), local_only.revision); local_only.flush()
	check(local_only.lookup("network", true).get("index") == 35 and fresh("policy").lookup("network", true).is_empty(), "Local-only network positions live only in this process")
	Privacy.configure(Privacy.NONE); memory.policy_changed()
	var private_run := fresh("policy")
	check(private_run.lookup("local", false).is_empty(), "No-history ignores old persisted positions")
	private_run.remember("private", false, anchor(44), private_run.revision); private_run.flush()
	check(private_run.lookup("private", false).get("index") == 44 and fresh("policy").lookup("private", false).is_empty(), "No-history resumes in memory and resets on restart")
	var old_ticket: int = private_run.revision
	Privacy.configure(Privacy.ALL); private_run.policy_changed()
	private_run.remember("private", false, anchor(44), old_ticket); private_run.flush()
	check(fresh("policy").lookup("private", false).is_empty(), "Switching to record does not backfill private session positions")
	private_run.remember("new-activity", false, anchor(45), private_run.revision); private_run.flush()
	check(fresh("policy").lookup("new-activity", false).get("index") == 45, "New activity after enabling history persists")
	var clearing := fresh("policy")
	clearing.remember("local-pending", false, anchor(30), clearing.revision)
	clearing.remember("network-pending", true, anchor(31), clearing.revision)
	old_ticket = clearing.revision
	check(clearing.clear_history(true), "Network history clears")
	clearing.remember("network", true, anchor(99), old_ticket); clearing.flush()
	check(fresh("policy").lookup("network", true).is_empty() and clearing.lookup("network-pending", true).is_empty(), "Network clear invalidates delayed writes and memory")
	check(fresh("policy").lookup("local", false).get("index") == 12 and fresh("policy").lookup("local-pending", false).get("index") == 30, "Network clear preserves saved and pending local history")
	check(clearing.clear_history(false) and fresh("policy").persisted.is_empty() and clearing.session.is_empty(), "All-history clears both storage layers")
	var protected_memory := fresh("protected")
	var vault := Vault.new(); Privacy.vault = vault
	protected_memory.remember("protected", false, anchor(8), protected_memory.revision); protected_memory.flush()
	check(protected_memory.lookup("protected", false).get("index") == 8 and not FileAccess.file_exists(protected_memory.path), "Protected browsing stays memory-only")
	vault.locked = true
	check(protected_memory.lookup("protected", false).is_empty(), "Locked vault cannot restore positions")
	vault.locked = false
	check(protected_memory.lookup("protected", false).get("index") == 8, "Unlock restores same-run continuity")
	Privacy.vault = null
	await menu_cases()
	await option_cases()
	file_anchor_cases()
	await filter_cases()
	home_clear_case()
	print("Directory browse memory: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func make_menu(memory: RefCounted, platform: RefCounted, source: int) -> Node3D:
	var menu := Menu.new(); menu.browse_memory = memory
	root.add_child(menu); menu.set_process(false); menu.attach_platform(platform); menu.visible = true
	menu.section = source; menu.view_mode = "list"
	menu._local_stack = [{"id":"/disk","title":"Disk"}]
	menu._smb_server = "account-a"; menu._smb_path = "share"
	menu._dlna_server = "device-a"; menu._dlna_stack = [{"id":"root","title":"Root"}]
	return menu

func read(menu: Node3D) -> void:
	if menu.section == Menu.Section.LOCAL: menu._load_section()
	elif menu.section == Menu.Section.SMB: menu._request("smb_browse", menu.platform.media_smb_browse(menu._smb_server, menu._smb_path))
	else: menu._request("dlna_browse", menu.platform.media_dlna_browse(menu._dlna_server, "root"))
	await process_frame
	menu.refresh()

func menu_cases() -> void:
	for mode in [Privacy.ALL, Privacy.LOCAL, Privacy.NONE]:
		Privacy.configure(mode)
		for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA]:
			var name := "%s-%d" % [mode, source]
			var memory := fresh(name); var platform := Platform.new()
			var menu := make_menu(memory, platform, source)
			await read(menu); menu._set_scroll(20.25)
			menu.dismiss(); menu.free()
			var reentered := make_menu(memory, platform, source)
			await read(reentered)
			check(is_equal_approx(reentered.scroll, 20.25), "Menu recreation continues same process / " + name)
			reentered.dismiss(); reentered.free()
			var rebooted := make_menu(fresh(name), platform, source)
			await read(rebooted)
			var persistent: bool = mode == Privacy.ALL or (mode == Privacy.LOCAL and source == Menu.Section.LOCAL)
			check(is_equal_approx(rebooted.scroll, 20.25 if persistent else 0.0), "Restart obeys history policy / " + name)
			if persistent:
				platform.inserted = 3; rebooted._local_entries = []; rebooted._smb_entries = []; rebooted._dlna_entries = []
				await read(rebooted)
				check(is_equal_approx(rebooted.scroll, 23.25), "Identity survives inserted siblings / " + name)
			check(rebooted.clear_browse_history(false), "Clear menu history / " + name)
			rebooted.checkpoint_browse()
			check(rebooted.browse_memory.session.is_empty() and fresh(name).persisted.is_empty(), "Clear cannot be undone by pause/exit checkpoint / " + name)
			rebooted._set_scroll(rebooted.scroll + 1.0)
			rebooted.checkpoint_browse()
			check(not rebooted.browse_memory.session.is_empty(), "New user scroll resumes memory after clear / " + name)
			rebooted.dismiss(); rebooted.free()
	Privacy.configure(Privacy.ALL)

func option_cases() -> void:
	var memory := fresh("option"); var platform := Platform.new()
	var menu := make_menu(memory, platform, Menu.Section.LOCAL)
	await read(menu); menu._set_scroll(20.25); menu.dismiss(); menu.free()
	var disabled := make_menu(memory, platform, Menu.Section.LOCAL)
	disabled.restore_directory_position = false
	await read(disabled)
	check(is_zero_approx(disabled.scroll), "Disabled restore opens an already visited folder at top")
	for breadcrumb in [false, true]:
		disabled._set_scroll(20.25); disabled._choose(disabled.rows[21]); await process_frame
		if breadcrumb: disabled._go_to(1)
		else: disabled._go_back()
		await process_frame
		check(is_equal_approx(disabled.scroll, 20.25), "Disabled restore still preserves parent via " + ("breadcrumb" if breadcrumb else "Back"))
	disabled.dismiss(); disabled.toggle()
	check(is_zero_approx(disabled.scroll), "Disabled restore reopens library at top")
	disabled.section = Menu.Section.SETTINGS; disabled.tab = Menu.GENERAL_TAB; disabled.refresh()
	var options: Array = disabled.rows.filter(func(row): return row.get("key") == "library_restore_position")
	check(options.size() == 1 and options[0].hint == Menu.BROWSE_POSITION_HINT and not options[0].value, "Global option has explanatory tooltip and current state")
	check(disabled._tips.values().has(disabled.I18n.t(Menu.BROWSE_POSITION_HINT)), "Tooltip is attached to rendered ray targets")
	var main := preload("res://scripts/main.gd").new(); main.recent_menu = disabled
	main.settings_path = output.path_join("option-settings.cfg")
	main._on_setting_changed("library_restore_position", false)
	var settings := ConfigFile.new(); settings.load(main.settings_path)
	check(not bool(settings.get_value("library", "restore_position", true)), "Global restore option persists through the production handler")
	main.free(); disabled.visible = false; disabled.free()

func file_anchor_cases() -> void:
	var memory := fresh("selected-file"); var platform := Platform.new()
	var menu := make_menu(memory, platform, Menu.Section.LOCAL)
	for i in 60: menu._local_entries.append({"uri":"file:///disk/movie%d.mp4" % i,"title":"Movie %d" % i})
	menu.refresh(); menu._set_scroll(20.25)
	menu._choose(menu.rows[22])
	var saved: Dictionary = memory.lookup(menu._browse_scope(), false)
	check(saved.get("index") == 22 and saved.get("line_offset") == 2.0, "Opening a file preserves its own screen row through dismiss")
	var inserted: Array = [{"uri":"file:///new1.mp4"},{"uri":"file:///new2.mp4"}] + menu.rows
	check(is_equal_approx(menu.Presentation.position(inserted, saved, 1), 22.25), "Selected file stays in its screen row after insertion")
	var cloud_anchor := {"key":"cloud-id:stable","browse":true,"index":0}
	check(menu.Presentation.anchor_index([{"uri":"cloud://a/other.mp4","cloud_id":"other"},{"uri":"cloud://a/renamed.mp4","cloud_id":"stable"}], cloud_anchor) == 1, "Cloud object ID survives rename")
	check(menu.Presentation.anchor_index([{"uri":"http://server/new-token","id":"object-5"}], {"key":"id:object-5","browse":true}) == 0, "DLNA object ID survives temporary URL changes")
	menu.visible = false; menu.free()

func filter_cases() -> void:
	for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA]:
		var name := "filters-%d" % source
		var platform := MixedPlatform.new(); var memory := fresh(name)
		var menu := make_menu(memory, platform, source)
		await read(menu)
		var positions := [70.25, 80.25, 90.25]
		var keys: Array = []
		for filter in 3:
			menu._activate(Menu.FILTER_BASE + filter)
			check(is_zero_approx(menu.scroll), "Unvisited filter begins at top / %d:%d" % [source, filter])
			menu._set_scroll(positions[filter]); keys.append(menu.Presentation.browse_key(menu.rows[int(menu.scroll)]))
		for filter in [0, 2, 1]:
			menu._activate(Menu.FILTER_BASE + filter)
			check(is_equal_approx(menu.scroll, positions[filter]) and menu.Presentation.browse_key(menu.rows[int(menu.scroll)]) == keys[filter], "Filter restores its own item and offset / %d:%d" % [source, filter])
		menu.dismiss(); menu.toggle()
		check(menu.media_filter == 0 and is_equal_approx(menu.scroll, positions[0]), "Reopening All never borrows Video anchor / %d" % source)
		menu.dismiss(); menu.free()
		var rebooted := make_menu(fresh(name), platform, source); await read(rebooted)
		for filter in 3:
			rebooted._activate(Menu.FILTER_BASE + filter)
			check(is_equal_approx(rebooted.scroll, positions[filter]), "Filter positions survive restart independently / %d:%d" % [source, filter])
		# Folder rows are present in all filters. Returning restores the parent's visit filter.
		for breadcrumb in [false, true]:
			rebooted._set_scroll(20.25); rebooted._choose(rebooted.rows[21]); await process_frame
			if breadcrumb: rebooted._go_to(1)
			else: rebooted._go_back()
			await process_frame
			check(rebooted.media_filter == 2 and is_equal_approx(rebooted.scroll, 20.25), "Parent restores filter via %s / %d" % ["path" if breadcrumb else "back", source])
		rebooted.visible = false; rebooted.free()

func home_clear_case() -> void:
	var memory := fresh("home-clear")
	memory.remember("local", false, anchor(12), memory.revision); memory.flush()
	var menu := make_menu(memory, Platform.new(), Menu.Section.RECENT)
	menu.catalog = preload("res://scripts/recent_files.gd").new(output.path_join("home-recent"))
	menu.catalog.opened("file:///movie.mp4", "Movie", false); menu.catalog.save()
	menu._activate(Menu.CLEAR_HISTORY)
	check(memory.session.is_empty() and fresh("home-clear").persisted.is_empty(), "Home Clear history also clears directory positions")
	menu.visible = false; menu.free()
