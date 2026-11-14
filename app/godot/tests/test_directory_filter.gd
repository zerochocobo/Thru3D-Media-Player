extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	signal media_list(id: int, payload: String)
	var calls: Array = []
	func media_smb_browse(server: String, path: String) -> int:
		calls.append([server, path]); return calls.size()
	func media_dlna_browse(server: String, path: String) -> int:
		calls.append([server, path]); return calls.size()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); print("FAILED: " + message)

func click(menu: Node, target: int) -> void:
	var matches: Array = menu._buttons.filter(func(button): return button.target == target)
	check(matches.size() == 1 and matches[0].enabled, "Unique enabled target %d" % target)
	if matches.size() != 1: return
	var node: Node3D = matches[0].node
	var origin := node.to_global(Vector3(0, 0, 1))
	var direction := -node.global_basis.z
	check(menu.ray_hit(origin, direction).get("target") == target, "Unobstructed ray %d" % target)
	menu.press_pointer("left_hand", origin, direction, true)
	menu.release_pointer("left_hand", origin, direction, true)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var menu := Library.new(); var host := Host.new(); menu.platform = host
	menu.collections.store = Favorites.new("user://directory-filter-header")
	root.add_child(menu); menu.set_process(false); menu.visible = true
	var files: Array = [{"id":"share/电影", "title":"电影合集", "container":true},
		{"id":"share/unrelated", "title":"Other folder", "container":true},
		{"uri":"smb://saved/share/film.mp4", "title":"电影 Film.MP4", "kind":"video"},
		{"uri":"smb://saved/share/film.jpg", "title":"电影 Film.jpg", "kind":"image"},
		{"uri":"smb://saved/share/other.mp4", "title":"Other.mp4", "kind":"video"}]
	for section in [Library.Section.SMB, Library.Section.DLNA]:
		for compact in [false, true]:
			for view in ["list", "grid"]:
				menu.subtitle_filter.reset(); menu.section = section; menu.compact = compact; menu.view_mode = view
				menu._smb_server = "saved"; menu._smb_path = "share"; menu._dlna_server = "saved"; menu._dlna_stack = []
				menu._smb_entries = files.duplicate(true); menu._dlna_entries = files.duplicate(true); menu.media_filter = 0; menu.refresh()
				var before := host.calls.size()
				click(menu, menu.SubtitleFilter.OPEN)
				check(menu.text_snapshot().contains(menu.I18n.t(menu.SubtitleFilter.DIRECTORY_HINT)), "Visible current-directory-only hint")
				click(menu, menu.SubtitleFilter.INPUT); await process_frame
				menu.system_text_input.set_text("subtitle_filter", "电影")
				check(menu.rows.size() == 5, "Draft leaves listing unchanged")
				menu.system_text_input._submitted("电影")
				check(menu.rows.size() == 3, "Chinese filename matching includes matching folders")
				menu.subtitle_filter.apply("fILm")
				check(menu.rows.size() == 2, "Case-insensitive literal matching")
				menu._change_media_filter(1)
				check(menu.rows.size() == 1 and menu.rows[0].kind == "video", "Filename and media type filters combine")
				menu.subtitle_filter.apply("*Film*")
				check(menu.rows.is_empty() and menu.subtitle_filter.status_text() == "No matching files", "No wildcard or recursive search")
				click(menu, menu.SubtitleFilter.CLEAR)
				check(menu.rows.size() == 4 and menu.subtitle_filter.query.is_empty(), "Clear retains selected file type")
				check(host.calls.size() == before, "Filtering never makes network requests")
				check(menu.navigate_back() and not menu.subtitle_filter.enabled, "Back closes filter before changing directory")
				menu.media_filter = 0; menu.refresh(); click(menu, menu.SubtitleFilter.OPEN); menu.subtitle_filter.apply("电影")
				menu._choose(menu.rows[0])
				check(not menu.subtitle_filter.enabled and menu.subtitle_filter.query.is_empty(), "Entering matching folder clears the query")
	menu.compact = false; menu.view_mode = "list"; menu.section = Library.Section.SMB
	menu._smb_server = ""; menu._smb_path = ""; menu.refresh()
	check(not menu.subtitle_filter.available(), "Server discovery is not a current-directory filter")
	menu._smb_path = "stale/share"
	check(not menu.subtitle_filter.available(), "A disconnected SMB path cannot expose filtering")
	menu._smb_server = "saved"; menu._smb_path = "share"; menu._smb_entries = []
	for i in 45: menu._smb_entries.append({"uri":"smb://saved/share/%d.mp4" % i,"title":"%02d.mp4" % i})
	menu.refresh(); menu._set_scroll(15)
	var anchor := menu.capture_position()
	click(menu, menu.SubtitleFilter.OPEN); menu.subtitle_filter.apply("44"); click(menu, menu.SubtitleFilter.OPEN)
	check(is_equal_approx(menu.scroll, menu.Presentation.position(menu.rows, anchor, 1)), "Close restores unfiltered scroll anchor")
	var store := Favorites.new("user://directory-filter-favorites")
	for spec in [["folder", "folder://fixture"], ["video", "file:///film.mp4"], ["image", "file:///photo.jpg"]]:
		store.entries[store.key_for(spec[1])] = {"uri":spec[1],"kind":spec[0],"title":spec[0],"added":1}
	menu.collections.store = store; menu.section = Library.Section.RECENT; menu.collections.home_tab = 1; menu.media_filter = 0; menu.refresh()
	var buttons: Array = menu._buttons.filter(func(button): return button.target >= Library.FILTER_BASE and button.target <= Library.FILTER_BASE + 3)
	buttons.sort_custom(func(a,b): return a.rect.position.x < b.rect.position.x)
	check(buttons.map(func(button):return button.target - Library.FILTER_BASE) == [0,3,1,2], "Favorites order is All/Folders/Video/Images")
	click(menu, Library.FILTER_BASE + 3)
	check(menu.rows.size() == 1 and menu.rows[0].kind == "folder", "Folder category contains only folders")
	store.locked = true; menu.refresh()
	check(menu.rows.size() == 1 and menu.rows[0].has("unlock_favorites"), "Folder filter never hides unlock entry")
	store.locked = false; menu.collections.switch_tab(0)
	check(menu.media_filter == 0 and not menu._buttons.any(func(button):return button.target == Library.FILTER_BASE + 3), "Recent list has no folder-only category")
	menu.free(); await process_frame
	for failure in failures: push_error(failure)
	print("Directory filter checks=%d failures=%d" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
