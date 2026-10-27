extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("en")
	var state := {"privacy_mode": "all", "diagnostic_log": {}}
	var events: Array = []
	var menu := Library.new()
	menu.section = Library.Section.SETTINGS; menu.tab = Library.GENERAL_TAB
	menu.settings_provider = func(): return state
	menu.setting_changed.connect(func(key, value): events.append([key, value]))
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var header: Dictionary = menu.rows.back()
	check(header.get("diagnostic_group", false) and header.title == I18n.t("Diagnostic log"), "The diagnostic log is the last, collapsed General row")
	check(not menu.rows.any(func(row): return row.get("setting", [""])[0] == "diagnostic_log"), "Collapsed: no log actions")
	menu._choose(header)
	check(events == [["diagnostic_log", "recent"]], "Opening the group asks for the recent warnings once")
	var actions: Array = menu.rows.filter(func(row): return row.has("setting") and row.setting[0] == "diagnostic_log").map(func(row): return row.setting[1])
	check(actions == ["save", "share", "recent"], "Save, share on Wi-Fi and refresh the recent lines")
	var detail: Array = menu.rows.filter(func(row): return row.get("key", "") == "diagnostic_detail")
	check(detail.size() == 1 and detail[0].value == false and detail[0].choices.size() == 2, "Log detail offers compact (default) and full")
	state.diagnostic_log = {"url": "http://192.168.1.23:8790/k7f2", "until": "15:42", "path": "Download/Thru3D/logs/thru3d-log-1.txt",
		"lines": ["W QuestVideoLayer: picture slot 2 image wait timed out (1 times)"]}
	menu.refresh()
	var url_rows: Array = menu.rows.filter(func(row): return row.get("diagnostic_url", false))
	check(url_rows.size() == 1 and url_rows[0].title == "http://192.168.1.23:8790/k7f2" and url_rows[0].setting == ["diagnostic_log", "stop"],
		"A shared log shows its address as the row title; choosing it stops sharing")
	var saved: Array = menu.rows.filter(func(row): return row.get("detail", "") == "thru3d-log-1.txt")
	check(saved.size() == 1 and saved[0].title == I18n.t("Saved to %s") % "Download/Thru3D/logs" and saved[0].icon == "check" and saved[0].has("tip"),
		"A saved log says where it went and, on pointing, how to take it out")
	var lines: Array = menu.rows.filter(func(row): return row.get("diagnostic_line", false))
	check(lines.size() == 1 and not lines[0].enabled, "Recent lines are listed and cannot be chosen")
	check(menu.navigate_back() and not menu.rows.any(func(row): return row.get("diagnostic_line", false)), "Back collapses the group")
	menu.queue_free()
	print("Diagnostic log checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
