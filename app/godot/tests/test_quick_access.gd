extends SceneTree
## Quick-access side list of the playback file window. Set QUICK_ACCESS_PREVIEW_DIR (without --headless) for pictures.
const Library := preload("res://scripts/library_menu.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Favorite := preload("res://scripts/favorite_store.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []
var chosen: Array = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func has(menu: Node, target: int) -> bool: return menu._buttons.any(func(button): return button.target == target)
func row_titles(menu: Node) -> Array:
	var quick: RefCounted = menu.quick_access
	return quick.rows.slice(int(quick.pages[quick.tab]) * quick.PAGE_SIZE, (int(quick.pages[quick.tab]) + 1) * quick.PAGE_SIZE).map(func(row): return str(row.title))

func folder_view(menu: Node) -> void:
	menu.section = Library.Section.LOCAL
	menu._local_stack = [{"id": "/sdcard/Movies", "title": "Movies"}]
	menu._local_entries = [{"uri": "file:///sdcard/Movies/海边.mp4", "title": "海边.mp4", "kind": "video", "size": 734003200},
		{"uri": "file:///sdcard/Movies/山谷.mp4", "title": "山谷.mp4", "kind": "video", "size": 1073741824},
		{"uri": "file:///sdcard/Movies/森林.mp4", "title": "森林.mp4", "kind": "video", "size": 524288000}]
	menu.set_compact(true)

func run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	Privacy.vault = null; Privacy.configure("all")
	var folder := "user://test_quick_access/%d" % Time.get_ticks_usec()
	var recent := Recent.new(folder.path_join("recent"))
	var store := Favorite.new(folder.path_join("favorites"))
	for i in 8:
		var uri := ("smb://nas/Series/第%02d集.mkv" if i % 2 == 0 else "cloud://mount/Series/第%02d集.mkv") % i
		recent.opened(uri, "山海之旅 · 第 %02d 集" % i, false); recent.progress(uri, (i + 1) * 300000, 2700000)
	recent.opened("smb://nas/Photos/京都.jpg", "京都 · 秋日散步", false, "image")
	store.toggle("smb://nas/Series/第00集.mkv", "山海之旅 · 第 00 集", "video", {})
	store.toggle("dlna://tv/item1", "客厅电视录像", "video", {})
	var series := {"type": "local", "path": "/sdcard/连续剧", "stack": [{"id": "/sdcard/连续剧", "title": "连续剧"}]}
	store.toggle(preload("res://scripts/media_location.gd").folder_uri(series), "连续剧", "folder", series)
	var output := OS.get_environment("QUICK_ACCESS_PREVIEW_DIR")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1500, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Library.new(); camera.add_child(menu); menu.position = Vector3(-0.2, 0, -1.4); menu.visible = true
	menu.catalog = recent; menu.collections.store = store
	menu.chosen.connect(func(uri, title): chosen.append([uri, title]))
	menu.current_file_provider = func(): return "smb://nas/Series/第06集.mkv"
	var quick: RefCounted = menu.quick_access
	var saved := []
	menu.setting_changed.connect(func(key, value): if key == "library_quick_access": saved.append(value))
	menu.section = Library.Section.RECENT; menu.set_compact(true)
	check(has(menu, quick.TOGGLE), "The switch stays in its corner on the home page too")
	menu.set_compact(false); menu.section = Library.Section.LOCAL; menu.refresh()
	check(not has(menu, quick.TOGGLE), "The full library has no side-list button")
	folder_view(menu)
	check(has(menu, quick.TOGGLE) and not has(menu, quick.TAB) and not menu.has_meta("subtitle_anchor_bounds"), "The file window offers the side list, closed by default")
	var closed_bounds: Rect2 = menu.panel_bounds()
	menu._activate(quick.TOGGLE)
	check(saved == [true], "Opening the list is saved for the next launch")
	var corner: Dictionary = menu._buttons.filter(func(button): return button.target == quick.TOGGLE)[0]
	check(menu._buttons.all(func(button): return button.target == quick.TOGGLE or button.rect.end.y > -0.3 or button.rect.end.x > menu.COMPACT_SIZE.x * 0.5 or button.rect.end.x <= corner.rect.position.x), "The switch is the rightmost control of the bottom row")
	var closer: Dictionary = menu._buttons.filter(func(button): return button.target == menu.CLOSE)[0]
	check(is_equal_approx(closer.rect.get_center().x, 0.51) and is_equal_approx(closer.rect.get_center().y, 0.36), "Close keeps the top-right corner")
	check(quick.shown() and has(menu, quick.TAB) and has(menu, quick.TAB + 1) and menu.rows.size() == 3, "The button opens the list beside the unchanged folder")
	check(row_titles(menu).size() == 6 and row_titles(menu) == recent.list_recent().slice(0, 6).map(func(entry): return str(entry.title)), "Recent entries keep the home page's order, six to a page: %s" % [row_titles(menu)])
	var bounds: Rect2 = menu.panel_bounds()
	check(bounds.end.x > closed_bounds.end.x + 0.4 and is_equal_approx(bounds.position.x, closed_bounds.position.x), "The list extends the window to the right only")
	menu._align_playback_panel()
	check(quick.anchor(bounds).get_center().is_equal_approx(closed_bounds.get_center()), "Opening the list does not recentre the file window")
	for button in menu._buttons:
		if button.target < quick.TOGGLE or button.target > quick.ROW + quick.PAGE_SIZE: continue
		for child in button.node.get_children():
			if child is Label3D and not child.text.is_empty():
				check(menu.text_width(child.text, child.font_size / menu.TEXT_RASTER_SCALE) <= button.rect.size.x, "Side-list text fits: " + child.text)
	if not output.is_empty(): await snapshot(viewport, output, "recent")
	menu._activate(quick.NEXT)
	check(int(quick.pages[0]) == 1 and row_titles(menu).size() == 3 and not menu._buttons.filter(func(b): return b.target == quick.NEXT)[0].enabled, "Paging reaches the remaining entries")
	menu._activate(quick.TAB + 1)
	check(quick.tab == 1 and row_titles(menu).size() == 3 and not has(menu, quick.NEXT), "Favorites are the second tab")
	if not output.is_empty(): await snapshot(viewport, output, "favorites")
	store.protected = true; store.locked = true; menu.refresh()
	check(quick.rows.size() == 1 and quick.rows[0].get("unlock_favorites", false), "Locked favorites show only the unlock prompt")
	menu._activate(quick.ROW)
	check(menu.collections.operation == "unlock" and menu.collections.active() and chosen.is_empty(), "The prompt opens the PIN dialog")
	menu._activate(menu.collections.CANCEL)
	store.protected = false; store.locked = false; menu.refresh()
	var target: int = quick.rows.find_custom(func(row): return row.get("kind") == "folder")
	menu._activate(quick.ROW + target)
	check(chosen.is_empty() and menu.section == Library.Section.LOCAL and menu._local_path() == "/sdcard/连续剧" and menu.visible, "A favorite folder opens in the file window")
	folder_view(menu); menu._activate(quick.TAB)
	quick.pages[0] = 0; menu.refresh()
	var wanted := str(quick.rows[1].uri)
	menu._activate(quick.ROW + 1)
	check(chosen.size() == 1 and chosen[0][0] == wanted, "One click reopens a recent entry: %s" % [chosen])
	check(menu.section == Library.Section.RECENT and menu.collections.home_tab == 0 and not menu.visible, "Playback continues in the recent context, as from the home page")
	check(str(menu._playback_context.get("uri", "")) == wanted, "The playback context remembers the reopened entry")
	menu.show_playback_files(true)
	check(menu.section == Library.Section.RECENT and has(menu, quick.TOGGLE) and quick.shown(), "The list stays open when the window returns")
	menu._activate(quick.TOGGLE)
	check(saved == [true, false] and not quick.shown() and not menu.has_meta("subtitle_anchor_bounds"), "Closing is saved too and releases the window anchor")
	var restarted := Library.new(); camera.add_child(restarted); restarted.catalog = recent; restarted.collections.store = store
	restarted.quick_access.opened = true; restarted.visible = true; folder_view(restarted)
	check(restarted.quick_access.shown() and has(restarted, quick.TAB), "A saved open state shows the list as soon as the window opens")
	restarted.free()
	menu.free(); viewport.free()
	print("Quick access: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func snapshot(viewport: SubViewport, output: String, name: String) -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for frame in 20: await process_frame
	await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))
