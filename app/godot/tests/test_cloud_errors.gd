extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Paging := preload("res://tests/test_cloud_pagination.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func enabled(menu: Node, target: int) -> bool:
	return menu._buttons.any(func(button): return button.target == target and button.enabled)

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Paging.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD); platform.respond(1)
	menu._choose(menu.rows[0]); platform.respond(2)
	menu._set_scroll(2.25)
	menu._activate(Menu.CLOUD_NEXT)
	var request: Dictionary = platform.requests.back()
	var original := "OpenList /list115 · code 500\nlist115.list\n115 code: 430004, message: 文件夹不存在或无权限 " + "长目录错误原因".repeat(60) + " END"
	platform.media_list.emit(3, JSON.stringify({"state": "error", "path": request.path, "offset": request.offset,
		"error": "Cloud connection failed", "error_reason": "cloud_unavailable", "error_detail": original}))
	check(menu.rows.size() == 48 and menu._cloud_page == 0 and not menu._cloud_busy, "Failure preserves page and ends loading")
	check(menu.cloud_error.detail.contains(original) and menu.cloud_error.detail.contains("offset=48"), "Full original and failed page survive without 80-character truncation")
	check(menu.text_snapshot().contains("115 430004") and enabled(menu, Menu.CloudBrowseError.OPEN), "Footer identifies provider code and exposes details")
	for compact in [false, true]:
		menu.set_compact(compact); menu._set_scroll(1.25)
		var previous: float = menu.scroll
		menu._activate(Menu.CloudBrowseError.OPEN)
		check(menu.cloud_error.opened and not menu._grid() and not menu.browser_content(), "Details use a scrollable text pane")
		check(menu.rows.map(func(row): return row.title).reduce(func(a, b): return a + b, "").contains(" END"), "Wrapped rows retain the final reason")
		check(enabled(menu, Menu.SCROLLBAR), "Long diagnostics expose a scrollbar")
		menu._set_scroll(menu._max_scroll()); check(menu.text_snapshot().contains(" END"), "Final text is reachable by scrolling")
		var calls: int = platform.requests.size()
		menu._activate(Menu.CLOUD_NEXT); check(platform.requests.size() == calls, "Detail pane blocks hidden pagination")
		menu._activate(Menu.CloudBrowseError.BACK)
		check(not menu.cloud_error.opened and is_equal_approx(menu.scroll, previous) and menu.rows.size() == 48, "Closing details restores folder and scroll")
	menu._activate(Menu.CLOUD_NEXT); check(menu.cloud_error.detail.is_empty(), "Retry clears stale error")
	platform.respond(4); check(menu.status.is_empty() and menu._cloud_page == 1, "Successful retry commits page")
	menu._activate(Menu.CLOUD_NEXT); platform.media_list.emit(5, "broken JSON with secret-payload")
	check(menu.cloud_error.detail.contains("invalid JSON") and not menu.cloud_error.detail.contains("secret-payload"), "Malformed response is identified without echoing payload")
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	check(menu.cloud_error.detail.is_empty(), "Changing source clears error context")
	menu.free(); platform.free()
	print("cloud error checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
