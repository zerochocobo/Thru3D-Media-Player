extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Main := preload("res://scripts/main.gd")
const Info := preload("res://scripts/library_presentation.gd")
const Navigation := preload("res://tests/test_library_navigation_memory.gd")
const Servers := preload("res://tests/test_media_servers.gd")
const SearchFixture := preload("res://tests/test_cloud_search.gd")
var checks := 0
var failures: Array[String] = []
class Catalog extends RefCounted:
	var entries := {}
	func lookup(uri: String) -> Dictionary: return entries.get(uri, {})
	func list_recent() -> Array[Dictionary]:
		var result: Array[Dictionary] = []; result.assign(entries.values()); return result
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void: call_deferred("run")
func buttons_fit(menu: Node) -> void:
	var controls: Array = menu._buttons.filter(func(b): return b.target in [Menu.VIEW_LIST, Menu.VIEW_GRID, Menu.REFRESH, Menu.EDIT, Menu.USB_STORAGE, Menu.EJECT_STORAGE, menu.file_actions.SORT, menu.file_actions.EDIT_MODE, menu.CloudSearch.OPEN])
	for i in controls.size():
		for j in range(i + 1, controls.size()):
			check(not controls[i].rect.intersects(controls[j].rect), "Toolbar targets do not overlap %s/%s" % [controls[i].target, controls[j].target])
func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var test_dir := ProjectSettings.globalize_path("res://../../build/output/library-view/test-data").simplify_path()
	DirAccess.make_dir_recursive_absolute(test_dir)
	check(test_dir.replace("\\", "/").contains("/build/"), "Preference test output stays in build")
	var menu := Menu.new(); root.add_child(menu); menu.visible = true
	check(menu.view_mode == "grid", "Existing users default to icon mode")
	menu.load_view_mode("unknown"); check(menu.view_mode == "grid", "Invalid preference falls back")
	var main := Main.new(); main.recent_menu = menu; main.settings_path = test_dir.path_join("view-test.cfg")
	menu.setting_changed.connect(main._on_setting_changed)
	menu.section = Menu.Section.LOCAL; menu._local_stack = [{"id": "/disk", "title": "Disk"}]
	var platform := Navigation.Platform.new(); menu.attach_platform(platform); menu._load_section(); await process_frame
	menu.refresh(); menu._set_scroll(4.0)
	var first := Info.key(menu.rows[16]); menu._activate(Menu.VIEW_LIST)
	check(not menu._grid() and menu._cols() == 1 and menu._lines() == 7, "Files render seven full-width rows")
	check(Info.key(menu.rows[int(menu.scroll)]) == first, "Switch grid to list anchors the first item")
	check(menu._buttons.filter(func(b): return b.target == Menu.ROW_BASE)[0].node.mesh.size.x > 1.0, "Mode affects real row geometry")
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	var reload_menu := Menu.new(); reload_menu.load_view_mode(saved.get_value("library", "view_mode")); reload_menu.section = Menu.Section.RECENT
	check(reload_menu.view_mode == "list" and not reload_menu._grid(), "Main settings save survives a fresh menu")
	reload_menu.free()
	buttons_fit(menu)
	menu._choose(menu.rows[30]); await process_frame
	menu._activate(Menu.VIEW_GRID); menu._go_back(); await process_frame
	check(menu.rows.size() == 60 and is_equal_approx(menu.scroll, 4.0), "Return to parent after changing mode retains item")
	menu._activate(Menu.VIEW_LIST); menu._choose(menu.rows[30]); await process_frame; menu._go_to(1); await process_frame
	check(is_equal_approx(menu.scroll, 16.0), "Breadcrumb restores parent in list mode")
	menu.dismiss(); menu.toggle()
	check(is_equal_approx(menu.scroll, 16.0), "Reopening the current directory retains position")
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.VIEW_GRID)[0]
	var origin: Vector3 = button.node.to_global(Vector3(0, 0, 0.5))
	menu.press_pointer("right_controller", origin, -menu.global_basis.z, true); menu.release_pointer("right_controller", origin, -menu.global_basis.z, true)
	check(menu._grid() and menu._drag.is_empty(), "Controller ray and trigger switch mode and release capture")
	menu._fling = 8.0; menu._hover["right_controller"] = Menu.ROW_BASE; menu.set_view_mode("list")
	check(menu._fling == 0 and menu._hover.is_empty(), "Mode change cancels old inertia and hover targets")
	menu.file_actions.modal = "sort"
	check(not menu._grid() and not menu.browser_content(), "Sort popup keeps underlying list geometry and hides view switching")
	menu.file_actions.modal = ""
	var reordered: Array = [{"uri": "file:///new", "title": "New"}, {"uri": "file:///same", "title": "Same"}, {"uri": "file:///other", "title": "Other"}]
	check(Info.position(reordered, {"key": "file:///same", "index": 0}, 1) == 1.0, "Identity wins over an old index after a directory insertion")
	for section in [Menu.Section.SMB, Menu.Section.DLNA]:
		menu.section = section; menu._smb_server = "s"; menu._smb_path = "share"; menu._dlna_server = "d"; menu._dlna_stack = [{"id": "root", "title": "Root"}]
		menu.load_view_mode("grid"); menu.scroll = 0.0
		if section == Menu.Section.SMB: menu._request("smb_browse", platform.media_smb_browse("s", "share"))
		else: menu._request("dlna_browse", platform.media_dlna_browse("d", "root"))
		await process_frame; menu._set_scroll(4.0); menu._choose(menu.rows[30]); await process_frame
		menu._activate(Menu.VIEW_LIST); menu._go_back(); await process_frame
		check(is_equal_approx(menu.scroll, 16.0), "Cross-mode parent anchor for source " + str(section))
	var catalog := Catalog.new(); menu.catalog = catalog
	var file := menu._entry_row({"title": "Long name.mp4", "uri": "smb://s/file", "size": 2147483648, "modified": 1791820800000})
	var info := Info.info(file)
	check(info.subtitle.begins_with("2.0 GB · 2026-") and info.status == "", "File rows show actual size and modification date")
	catalog.entries["smb://s/file"] = {"uri": "smb://s/file", "title": "Long name.mp4", "position_ms": 90000, "duration_ms": 180000}
	info = Info.info(file, catalog); check(info.status == "1:30 / 3:00" and is_equal_approx(info.ratio, 0.5), "Existing record provides position and ratio")
	catalog.entries["smb://s/file"].duration_ms = -1
	info = Info.info(file, catalog); check(info.status == "Played to 1:30" and info.ratio < 0, "Unknown duration has no invented percentage")
	catalog.entries["smb://s/file"].position_ms = 0
	info = Info.info({"title": "Movie", "scene": {"uri": "smb://s/file", "watched": true}}, catalog)
	check(info.status.is_empty(), "Local zero does not become a remote completed state")
	info = Info.info({"title": "Movie", "scene": {"uri": "medialib://s/scene/1", "year": 2020, "duration_ms": 7200000, "watched": true}})
	check(info.subtitle == "2020 · 2:00:00" and info.status == "Watched", "Media server has its own information and supplied watched flag")
	file = menu._entry_row({"title": "DLNA", "uri": "http://example/video", "duration_ms": 65000, "width": 3840, "height": 2160})
	check(file.duration_ms == 65000 and file.width == 3840 and Info.info(file).subtitle == "1:05 · 2160p", "DLNA optional metadata survives row conversion")
	check(Info.info(menu._entry_row({"title": "Unknown", "uri": "cloud://a/file"})).subtitle.is_empty(), "Missing fields do not display zero size or date")
	info = Info.info(menu._entry_row({"title": "Photo", "uri": "file:///p.jpg", "kind": "image", "width": 4000, "height": 3000, "duration_ms": 120000}))
	check(info.subtitle == "4000 × 3000" and info.status.is_empty() and info.ratio < 0, "Photo dimensions never become video progress")
	info = Info.info(menu._entry_row({"id": "folder", "title": "Folder", "container": true, "child_count": 12, "size": 12345}))
	check(info.subtitle == "12 items" and info.folder and info.status.is_empty(), "Folder uses supplied count without total size")
	menu.queue_free(); await process_frame; platform = null; main.free()
	var cloud_platform := SearchFixture.Platform.new(); menu = Menu.new(); root.add_child(menu); menu.attach_platform(cloud_platform); menu.visible = true
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id": "/mount1", "title": "Drive"}]
	var cloud_entries: Array = []
	for i in 48: cloud_entries.append({"id": "/mount1/%d" % i, "uri": "cloud://mount1/%d" % i, "title": "%02d.mp4" % i})
	menu._cloud_entries = cloud_entries; menu._cloud_location = "/mount1"; menu._cloud_page = 1; menu._cloud_offsets.assign([0, 48]); menu.refresh(); menu._set_scroll(5.0); menu._save_folder_position()
	menu._cloud_stack.append({"id": "/mount1/child", "title": "Child"}); menu._cloud_location = "/mount1/child"; menu._cloud_page = 0; menu._cloud_offsets.assign([0]); menu._cloud_entries = []; menu.refresh(); menu.load_view_mode("list"); menu._go_back()
	var request: Dictionary = cloud_platform.requests.back()
	menu._on_media_list(cloud_platform.requests.size(), JSON.stringify({"state": "ready", "path": request.path, "offset": request.offset, "entries": cloud_entries, "total": 48, "next_offset": -1}))
	check(is_equal_approx(menu.scroll, 20.0) and menu._cloud_page == 1 and request.offset == 48, "Cloud return keeps page and applies old grid anchor after async response")
	var calls := cloud_platform.requests.size(); menu.set_view_mode("grid")
	check(cloud_platform.requests.size() == calls and menu._cloud_page == 1, "Switching view does not fetch a page")
	menu.cloud_search.active = true; menu.cloud_search.editing = false; menu.cloud_search.entries = [cloud_platform.result("token")]; menu.refresh()
	check(menu._grid() and menu._lines() == 2, "Search results follow global icon mode")
	menu.set_view_mode("list"); info = Info.info(menu.rows[0])
	check(not menu._grid() and info.subtitle == "中文目录", "Search list gives path priority")
	menu.cloud_search.close(); menu.queue_free(); await process_frame; cloud_platform.free()
	var server_platform := Servers.Platform.new(); menu = Menu.new(); root.add_child(menu); menu.attach_platform(server_platform); menu.visible = true
	menu.section = Menu.Section.MEDIA_SERVER; var browser: RefCounted = menu.server_browser
	browser.server = {"id": "profile", "name": "NAS"}; browser.view = "scenes"; browser.total = 80; browser.end_reached = true
	for i in 80: browser.entries.append({"id": str(i), "uri": "medialib://profile/scene/%d" % i, "title": "Film %d" % i, "has_cover": true, "year": 2024, "duration_ms": 60000})
	menu.load_view_mode("list"); menu.refresh(); var before := server_platform.next
	menu._set_scroll(16.0); menu.refresh()
	check(server_platform.next == before, "Server list never requests covers or per-item details")
	menu.catalog = catalog; catalog.entries["medialib://profile/scene/20"] = {"uri": "medialib://profile/scene/20", "title": "Film 20", "position_ms": 0, "duration_ms": 60000}
	browser.choose({"scene": browser.entries[20]})
	var detail_request := -1
	for id in browser.pending:
		if browser.pending[id].action == "detail": detail_request = int(id)
	server_platform.answer(detail_request, {"detail": browser.entries[20].merged({"position_ms": 40000})})
	check(browser.detail.position_ms == 0, "Detail uses the same explicit local zero as the list")
	browser.back()
	browser._remember(); browser.view = "detail"; browser.detail = browser.entries[20]; menu.refresh(); menu.load_view_mode("grid"); browser.back()
	check(is_equal_approx(menu.scroll, 4.0), "Media server back converts stored item anchor after mode change")
	menu.set_view_mode("list"); browser.view = "home"; menu.refresh()
	check(browser.grid(), "Server home keeps its own layout while content remembers list")
	menu.queue_free(); await process_frame; server_platform.free()
	print("Library view checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
