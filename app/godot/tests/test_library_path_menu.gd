extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const PathMenu := Menu.PathMenu
const LibraryFixture := preload("res://tests/test_library_navigation_memory.gd")
const ViewFixture := preload("res://tests/render_library_views.gd")
const DEPTH := 12
const FOLDERS := ["影视库", "电影", "立体电影", "动画", "剧场版", "蓝光收藏", "原盘", "日语", "2025", "上半年", "精选", "海边的故事"]
var checks := 0
var failures: Array[String] = []

class Platform extends LibraryFixture.Platform:
	func media_cloud_cancel(_id: int) -> void: pass

	func media_cloud_page_options(path: String, offset: int, _force: bool, order: String, _folder: String, size: int, _subtitles: bool) -> int:
		var listing := entries(path)
		return reply({"state": "ready", "path": path, "offset": offset, "order": order, "page_size": size, "entries": listing, "total": listing.size(),
			"raw_count": listing.size(), "raw_ids": listing.map(func(row): return row.id), "next_offset": -1})

	func media_cloud_browse(path: String, _force: bool) -> int:
		return reply({"state": "ready", "path": path, "entries": entries(path)})

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func set_depth(menu: Node3D, source: int, depth: int, sample: bool = false) -> void:
	menu.archives.close()
	menu.section = source
	var stack: Array[Dictionary] = []
	var names: Array = []
	var path := ""
	for i in depth:
		var name := str(FOLDERS[i]) if sample else "Same name" if i in [2, 8] else "Folder %d" % (i + 1)
		names.append(name)
		path += "/folder%d" % (i + 1)
		stack.append({"id": path, "title": name, "provider": "115_open"})
	match source:
		Menu.Section.LOCAL:
			menu._local_stack = stack
		Menu.Section.SMB:
			menu._smb_server = "nas"
			menu._smb_path = "/".join(names)
		Menu.Section.DLNA:
			menu._dlna_server = "dlna"
			menu._dlna_stack = stack
		Menu.Section.CLOUD:
			menu._cloud_stack = stack
		_:
			var archive = menu.archives
			archive.browser_section = source
			archive._browsing = true
			archive.target = {"uri": "file:///disk/Pictures.cbz", "title": "Pictures.cbz"}
			archive.directory = "/".join(names)
			archive.session = "test"
	menu.refresh()

func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}

func pointer(menu: Node3D, target: int, press: bool = false) -> bool:
	var item := button(menu, target)
	if item.is_empty(): return false
	var node: Node3D = item.node
	var ray := node.global_basis.z.normalized()
	var origin := node.global_position + ray
	if press: return menu.press_pointer("right_hand", origin, -ray, true)
	menu.update_pointer("right_hand", origin, -ray, true)
	return menu._hover.get("right_hand") == target

func run() -> void:
	var output := OS.get_environment("THRU3D_LIBRARY_PATH_PREVIEW")
	if not output.is_empty():
		await render(output)
		quit(0 if failures.is_empty() else 1)
		return
	var menu := Menu.new()
	root.add_child(menu)
	menu.set_process(false)
	menu.attach_platform(Platform.new())
	menu.visible = true
	for compact in [false, true]:
		menu.set_compact(compact)
		set_depth(menu, Menu.Section.LOCAL, 1)
		check(button(menu, PathMenu.TOGGLE).is_empty(), "Shallow layout does not add shortcut")
		set_depth(menu, Menu.Section.LOCAL, 2)
		check(not button(menu, PathMenu.TOGGLE).is_empty(), "Shortcut starts at level two")
		check_header_position(menu)
		for source in [Menu.Section.LOCAL, Menu.Section.SMB, Menu.Section.DLNA, Menu.Section.CLOUD, Menu.Section.RECENT]:
			set_depth(menu, source, DEPTH)
			var path := menu._crumbs()
			for level in range(path.size() - 1):
				set_depth(menu, source, DEPTH)
				check(pointer(menu, PathMenu.TOGGLE, true) and menu.path_menu.open, "Trigger opens path")
				var target := PathMenu.ROOT
				if level > 0:
					var opening_offset := maxi(0, path.size() - 1 - PathMenu.VISIBLE_ROWS)
					var offset := mini(opening_offset, level - 1)
					if offset < opening_offset:
						menu.stick_scroll(1.0, float(opening_offset - offset) / PathMenu.SCROLL_SPEED)
					target = PathMenu.ROW + level - 1 - offset
				check(pointer(menu, target, true), "Visible ancestor accepts one click")
				await process_frame
				check(menu._crumbs() == path.slice(0, level + 1) or (source in [Menu.Section.LOCAL, Menu.Section.CLOUD] and level == 0 and menu._crumbs().is_empty()), "Exact target / compact %s / source %d / level %d" % [compact, source, level])
				check(not menu.path_menu.open, "Jump closes path")
				if source == Menu.Section.CLOUD:
					check(not menu.cloud_error.shows_notice(), "Cloud destination accepts the requested page")
		check_hover(menu)
		check_tree(menu)
		await check_position(menu)
		set_depth(menu, Menu.Section.LOCAL, DEPTH)
		menu.collections.home_return = {"tab": 1, "page": 0, "scroll": 0.0}
		menu.refresh()
		check(pointer(menu, Menu.Collections.RETURN_HOME, true) and menu.collections.home_tab == 1 and menu.collections.home_return.is_empty(), "Existing collection return restores Favorites")
		set_depth(menu, Menu.Section.LOCAL, DEPTH)
		menu.image_picker_mode = true
		menu.refresh()
		check(pointer(menu, PathMenu.TOGGLE, true) and pointer(menu, PathMenu.ROOT, true) and menu.section == Menu.Section.LOCAL, "Picker can jump to its source root")
		menu.image_picker_mode = false
		if not compact:
			set_depth(menu, Menu.Section.LOCAL, DEPTH)
			check(pointer(menu, PathMenu.INLINE + 1, true) and menu._local_stack.size() == DEPTH - 1, "Inline crumb stays clickable past ten levels")
		await process_frame
	menu.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Library path menu: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_hover(menu: Node3D) -> void:
	set_depth(menu, Menu.Section.LOCAL, DEPTH)
	var path: Array = menu._crumbs()
	var now := Time.get_ticks_msec()
	check(pointer(menu, PathMenu.TOGGLE), "Ray sees the folder tree")
	menu.path_menu.tick(now)
	menu.path_menu.tick(now + PathMenu.OPEN_MS - 1)
	check(not menu.path_menu.open, "Brief hover leaves path closed")
	menu.path_menu.tick(now + PathMenu.OPEN_MS)
	check(menu.path_menu.open and menu._crumbs() == path, "Dwell opens without navigating")
	check(pointer(menu, PathMenu.ROW), "Ray moves from header to popover row")
	menu.path_menu.tick(now + PathMenu.OPEN_MS + 20)
	menu.path_menu.tick(now + PathMenu.OPEN_MS + PathMenu.CLOSE_MS + 20)
	check(menu.path_menu.open, "Hover within the dropdown keeps it open")
	check(pointer(menu, Menu.BACK, true) and not menu.path_menu.open and menu._crumbs() == path, "Outside click closes without activating covered navigation")
	check(pointer(menu, PathMenu.TOGGLE, true) and menu.navigate_back() and menu._crumbs() == path, "Back dismisses the dropdown before changing folders")
	check(pointer(menu, PathMenu.TOGGLE, true), "Trigger reopens dropdown")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	menu.path_menu.tick(Time.get_ticks_msec() + PathMenu.CLOSE_MS + 1)
	check(not menu.path_menu.open, "Leaving the dropdown closes it after the grace period")

func check_header_position(menu: Node3D) -> void:
	var back: Rect2 = button(menu, Menu.BACK).rect
	var toggle: Rect2 = button(menu, PathMenu.TOGGLE).rect
	var path_start := 0.0
	if menu.compact:
		for label: Label3D in menu._labels:
			if label.text.ends_with("Folder 2"): path_start = label.position.x; break
	else:
		path_start = button(menu, Menu.CRUMB_BASE + 1).rect.position.x
	check(back.end.x < toggle.position.x and toggle.end.x < path_start and button(menu, PathMenu.ROOT).is_empty(),
		"The tree button fits between Back and the path, and root lives inside the dropdown")

func check_tree(menu: Node3D) -> void:
	set_depth(menu, Menu.Section.LOCAL, DEPTH)
	check(pointer(menu, PathMenu.TOGGLE, true), "Open the whole path")
	var root_button: Node3D = button(menu, PathMenu.ROOT).node
	var root_label: Label3D = root_button.get_child(1)
	var root_position := root_button.global_position
	var current := button(menu, PathMenu.ROW + PathMenu.VISIBLE_ROWS - 1)
	var current_label: Label3D = current.node.get_child(1)
	check(root_label.text == menu._crumbs().front() and current_label.text == menu._crumbs().back(), "Root and current folder show their actual names")
	check(is_equal_approx(root_label.global_position.x, current_label.global_position.x), "All levels use the same left alignment")
	check(not current.enabled and pointer(menu, current.target, true) and menu.path_menu.open, "Current folder marks the end without jumping")
	check(pointer(menu, PathMenu.EARLIER, true), "Arrow scrolls toward the source")
	var pinned: Node3D = button(menu, PathMenu.ROOT).node
	check(pinned.global_position.is_equal_approx(root_position), "Source root remains in reach while scrolling")
	menu.navigate_back()

func check_position(menu: Node3D) -> void:
	set_depth(menu, Menu.Section.LOCAL, 0)
	menu._local_stack = [{"id": "/disk", "title": "Disk"}]
	menu._load_section()
	await process_frame
	menu._set_scroll(4.0)
	var visible_row: int = menu._first_line() * menu._cols()
	menu._choose(menu.rows[visible_row])
	await process_frame
	menu._choose(menu.rows[0])
	await process_frame
	check(pointer(menu, PathMenu.TOGGLE, true) and pointer(menu, PathMenu.ROW, true), "One click jumps from the grandchild to Disk")
	await process_frame
	check(is_equal_approx(menu.scroll, 4.0), "Path jump restores the target folder's scroll position")

func render(output: String) -> void:
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 940)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(-0.08, -0.05, 1.94)
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_COLOR
	camera.environment.background_color = Color("#080f1c")
	viewport.add_child(camera)
	var menu := Menu.new()
	viewport.add_child(menu)
	menu.set_process(false)
	menu.attach_platform(Platform.new())
	menu.visible = true
	var fixture := ViewFixture.new()
	for compact in [false, true]:
		menu.set_compact(compact)
		camera.fov = 20 if compact else 25
		camera.position = Vector3(0, 0, 1.28) if compact else Vector3(-0.08, -0.05, 1.94)
		set_depth(menu, Menu.Section.LOCAL, DEPTH, true)
		menu._local_entries = fixture.entries()
		menu.view_mode = "list"
		menu.refresh()
		var layout := "compact" if compact else "full"
		await screenshot(viewport, output.path_join(layout + "-closed.png"))
		pointer(menu, PathMenu.TOGGLE, true)
		pointer(menu, PathMenu.ROW + PathMenu.VISIBLE_ROWS - 2)
		await screenshot(viewport, output.path_join(layout + "-open.png"))
	fixture.free()
	viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Library path screenshots: %d checks, %d failures" % [checks, failures.size()])

func screenshot(viewport: SubViewport, path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(not image.is_empty() and image.save_png(path) == OK, "Saved " + path)
