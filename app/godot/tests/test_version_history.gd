extends SceneTree

const History := preload("res://scripts/version_history.gd")
const Menu := preload("res://scripts/library_menu.gd")
const BrowserFixture := preload("res://tests/test_web_browser_panel.gd")
const Channel := preload("res://scripts/distribution_channel.gd")
var failures: Array[String] = []
var checks := 0

const Reader := preload("res://scripts/release_notes_dialog.gd")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func lower(config: ConfigFile) -> String:
	return str(config.get_value(History.SECTION, "unread_from", ""))

func filters() -> void:
	var reader := Reader.new()
	var contexts := [["pico", "standard", "other"], ["quest", "quest_store", "other"],
		["pico", "pico_cn_store", "other"], ["openxr", "standard", "qiyu"],
		["openxr", "standard", "other"], ["openxr", "standard", ""]]
	for lang in ["en", "zh", "zh_Hant", "ja"]:
		for c in contexts:
			var context := {"vendor": c[0], "channel": c[1], "runtime": c[2]}
			var name := "%s/%s" % [str(c), lang]
			check(reader.prepare("0.18.3", lang, context), name + " loaded")
			var current: Dictionary = reader.entries[0]
			var notes: PackedStringArray = current.notes
			var legacy: Dictionary = reader._catalog.filter(func(row): return row.version == "0.18.3")[0]
			var raw: Array = legacy.notes[lang]
			check(notes.has(raw[4]) and notes.has(raw[6]) and notes.has(raw[7]), name + " keeps hardware verification and common rendering notes")
			check(notes.has(raw[8].text) == (c[0] == "openxr" and c[2] != "other"), name + " QIYU-only clarity")
			check(notes.has(raw[9].text) == (c[0] == "openxr"), name + " OpenXR keyboard")
			check(notes.has(raw[10].text) == (c[0] == "pico"), name + " PICO hand switching")
			check(reader.entries.any(func(r): return r.version == "0.17.8") == (c[0] == "quest"), name + " all-exclusive release")
			var keyboard: Dictionary = reader.entries.filter(func(r): return r.version == "0.16.6")[0]
			check(("quest" in str(keyboard.title).to_lower()) == (c[0] == "quest"), name + " version heading matches visible features")
			var store: Dictionary = reader._catalog.filter(func(r): return r.version == "0.15.1")[0]
			var projected: Dictionary = reader.entries.filter(func(r): return r.version == "0.15.1")[0]
			check(projected.notes.has(store.notes[lang][6].text) == (c[1] == "pico_cn_store"), name + " China store only")
			reader.prepare("0.18.4", lang, context)
			var structured_release: Dictionary = reader._catalog.filter(func(row): return row.version == "0.18.4")[0]
			check(reader.entries[0].version == "0.18.4" and reader.entries[0].notes.has(structured_release.items[0].text[lang]), name + " structured release displays its own translation")
			reader.prepare("0.17.12", lang, context)
			check(reader.entries[0].version == "0.17.12" and reader.newest_unread("0.17.9") == "0.17.12", name + " sideload cap")
			reader.prepare("0.17.8", lang, context)
			check((reader.newest_unread("0.17.7") != "") == (c[0] == "quest"), name + " empty unread range hides notice")
	var langs := {"zh": "更新记录", "zh_Hant": "更新記錄", "en": "one", "ja": "一"}
	var structured := [{"version":"1.0", "date":"2026-11-20", "title":langs,
		"items":[{"id":"common","text":langs},{"id":"pico","scope":["pico"],"text":langs}]}]
	check(History.visible_entries(structured, "1.0", "zh_Hant", {"vendor":"quest","channel":"","runtime":""})[0].notes == PackedStringArray(["更新記錄"]), "Traditional Chinese uses its own structured text and shares scope")

func ray(menu: Menu, target: int) -> void:
	var buttons := menu._buttons.filter(func(b): return b.target == target)
	check(buttons.size() == 1, "Unique ray target %d" % target)
	if buttons.is_empty(): return
	var centre: Vector3 = buttons[0].node.global_position
	var front: Vector3 = buttons[0].node.global_basis.z
	check(menu.ray_hit(centre + front, -front).get("target") == target, "Nearest ray target %d" % target)
	menu.press_pointer("right_hand", centre + front, -front, true)
	menu.release_pointer("right_hand", centre + front, -front, true)

func _run() -> void:
	filters()
	var dir := ProjectSettings.globalize_path("res://../../build/version-history/test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	var report := dir.path_join("legacy.json")
	var path := dir.path_join("settings.cfg")
	var config := ConfigFile.new()
	check(History.record_launch(config, "0.17.9", report) and lower(config) == "", "First install quiet")
	History.record_launch(config, "0.17.10", report)
	History.record_launch(config, "0.17.12", report)
	check(lower(config) == "0.17.9", "Two upgrades keep earliest unread bound")
	config.set_value("ui", "language", "zh_Hant")
	config.set_value("appearance", "background", "dark")
	config.save(path)
	var reloaded := ConfigFile.new()
	check(reloaded.load(path) == OK and not History.record_launch(reloaded, "0.17.12", report) and lower(reloaded) == "0.17.9", "Unread survives restart")
	History.record_launch(reloaded, "0.17.10", report)
	check(lower(reloaded) == "0.17.9", "Rollback keeps eligible unread")
	History.record_launch(reloaded, "0.17.9", report)
	check(lower(reloaded) == "", "Rollback below range drops unread")
	check(History.compare("0.16.6.1", "0.16.6") > 0 and History.compare("0.17.10", "0.17.9") > 0, "Numeric ordering")
	var legacy := ConfigFile.new()
	legacy.set_value("ui", "language", "en")
	History.record_launch(legacy, "0.18.2", report)
	check(History.unread("0.18.2", lower(legacy)) and not History.unread("0.18.1", lower(legacy)), "Unknown legacy start includes only installed version")
	History.record_launch(legacy, "0.18.3", report)
	check(History.unread("0.18.2", lower(legacy)), "Unknown legacy bound survives next upgrade")
	var file := FileAccess.open(report, FileAccess.WRITE)
	file.store_string('{"app_version":"0.16.6"}')
	file.close()
	legacy.erase_section(History.SECTION)
	History.record_launch(legacy, "0.16.6.1", report)
	check(lower(legacy) == "0.16.6", "Legacy diagnostics supply real start")

	ProjectSettings.set_setting("application/config/version", "0.17.12")
	var main := preload("res://scripts/main.gd").new()
	main.settings_path = path
	root.add_child(main)
	var menu: Menu = main.recent_menu
	var reader := menu.release_notes
	if not menu.visible: menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu._activate(Menu.TAB_BASE + Menu.ABOUT_TAB)
	var offline := menu.rows.find_custom(func(r): return r.has("version_history"))
	var online := menu.rows.find_custom(func(r): return r.has("online_history"))
	check(offline >= 0 and online == offline + 1, "Two permanent About rows")
	ray(menu, Menu.ROW_BASE + online)
	check(menu.section == Menu.Section.SETTINGS and menu.tab == Menu.ABOUT_TAB and menu.status == "Could not open the browser" and not menu.web_browser.opened, "Unavailable browser leaves About visible with an error")
	var original_channel: Variant = ProjectSettings.get_setting(Channel.KEY)
	var original_platform := menu.platform
	var bridge := BrowserFixture.Platform.new()
	menu.attach_platform(bridge)
	for channel in ["standard", "pico_cn_store", "quest_store"]:
		ProjectSettings.set_setting(Channel.KEY, channel)
		bridge.browser.url = ""
		ray(menu, Menu.ROW_BASE + online)
		menu.web_browser.tick()
		check(menu.web_browser.active() and bridge.browser.url == "https://thru3d.com/changelog.html?lang=zh", channel + " opens localized changelog in the embedded browser")
		check(menu.unread_from == "0.17.9" and not reader.opened, channel + " website preserves offline notice")
		check(menu.navigate_back() and bridge.actions.back() == "back", channel + " Back uses embedded browser history")
		menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
		menu._activate(Menu.TAB_BASE + Menu.ABOUT_TAB)
	ProjectSettings.set_setting(Channel.KEY, original_channel)
	menu.attach_platform(original_platform)
	bridge.free()
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	reader.data_path = dir.path_join("missing.json")
	ray(menu, Menu.WHATS_NEW)
	check(reader.opened and reader.entries.is_empty() and menu.unread_from == "0.17.9", "Missing offline file keeps notice")
	menu.navigate_back()
	reader.data_path = History.DATA
	ray(menu, Menu.WHATS_NEW)
	check(reader.opened and reader.entries[reader.selected].version == "0.17.12" and reader.unread_versions.keys() == ["0.17.12","0.17.11","0.17.10"], "Three unread releases, latest selected, rest of history available")
	check(menu.unread_from.is_empty() and reader.entries.back().version == "0.1.0" and not menu.web_browser.opened, "Offline rendered content acknowledges interval once")
	ray(menu, Reader.VERSION_BASE + 2)
	check(reader.selected == 2 and reader.body_offset == 0 and reader.unread_versions.size() == 3, "Selecting another version resets body and preserves session dots")
	check(reader.lines.size() > Reader.BODY_SIZE, "Long notes wrap across pages")
	ray(menu, Reader.BODY_DOWN)
	check(reader.body_offset > 0, "Ray pages through long text")
	ray(menu, Reader.BODY_UP)
	var start := menu.to_global(Vector3(-0.52, -0.15, 1))
	var front := -menu.global_basis.z
	menu.press_pointer("right_hand", start, front, true)
	menu.update_pointer("right_hand", start + menu.global_basis.y * 0.20, front, true)
	menu.release_pointer("right_hand", start + menu.global_basis.y * 0.20, front, true)
	check(reader.list_offset > 0 and reader.selected == 2 and reader.capture.is_empty(), "List ray drag scrolls without selection")
	menu.update_pointer("right_hand", menu.to_global(Vector3(0.2,0,1)), front, true)
	menu.stick_scroll(-1, 0.5)
	check(reader.body_offset > 0, "Thumbstick scrolls focused body")
	ray(menu, Reader.CLOSE)
	check(not reader.opened and menu.section == Menu.Section.RECENT and not menu._buttons.any(func(b): return b.target == Menu.WHATS_NEW), "Close restores media library")
	config.load(path)
	check(not History.record_launch(config, "0.17.12", report) and lower(config) == "", "Read interval persists across restart")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu._activate(Menu.TAB_BASE + Menu.ABOUT_TAB)
	menu._activate(Menu.ROW_BASE + offline)
	check(reader.opened and reader.selected == 0 and reader.unread_versions.is_empty(), "About reopens installed version without dots")
	menu.navigate_back()
	check(menu.section == Menu.Section.SETTINGS and menu.tab == Menu.ABOUT_TAB, "Back restores About")
	ProjectSettings.set_setting("application/config/version", "0.18.1.1")
	menu.unread_from = "0.16.9"
	menu._activate(Menu.ROW_BASE + offline)
	check(reader.missing_current and reader.entries[0].version == "0.18.1" and reader.unread_versions.has("0.17.0") and not reader.unread_versions.has("0.16.8"), "Missing installed and start versions use nearest lower record with its own label")
	main.free()
	for temporary_file in [report, path]: DirAccess.remove_absolute(temporary_file)
	DirAccess.remove_absolute(dir)
	print("version history checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
