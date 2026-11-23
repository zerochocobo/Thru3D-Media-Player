extends SceneTree
## Source marks on recent/favorite entries. Set SOURCE_ICONS_PREVIEW_DIR (without --headless) for pictures.
const Library := preload("res://scripts/library_menu.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Favorite := preload("res://scripts/favorite_store.gd")
const Presentation := preload("res://scripts/library_presentation.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Icons := preload("res://scripts/menu_icons.gd")
var checks := 0
var failures: Array[String] = []

class Accounts extends RefCounted:
	signal media_list(id: int, payload: String)
	var profiles := {"cloud": [{"id": "mount", "provider": "baidu", "name": "旅行盘"}],
		"server": [{"id": "srv-1", "provider": "emby", "name": "Emby"}, {"id": "srv-2", "provider": "jellyfin", "name": "客厅"}]}
	var reads := {"cloud": 0, "server": 0}
	var unavailable := ""
	func account_list(kind: String) -> String:
		reads[kind] += 1
		if kind == unavailable: return "null"
		return JSON.stringify(profiles[kind])

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

## Glyph textures drawn below the list, outside the buttons' own type icons.
func marks(menu: Node, key: String) -> int:
	var texture: Texture2D = Icons.texture(key)
	var found := [0]
	var walk := func(node: Node, again: Callable) -> void:
		if node is MeshInstance3D and node.material_override is StandardMaterial3D and node.material_override.albedo_texture == texture: found[0] += 1
		for child in node.get_children(): again.call(child, again)
	walk.call(menu._list, walk)
	return found[0]

func has_caption(node: Node, prefix: String) -> bool:
	if node is Label3D and node.text.begins_with(prefix): return true
	for child in node.get_children():
		if has_caption(child, prefix): return true
	return false

func run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	Privacy.vault = null; Privacy.configure("all")
	var cases := [
		[{"uri": "file:///sdcard/Movies/a.mp4"}, "device"], [{"uri": "usb://token/a.mp4"}, "usb"],
		[{"uri": "smb://nas/Video/a.mp4"}, "server"], [{"uri": "dlna://server/item"}, "cast"],
		[{"uri": "http://192.168.1.2:8200/MediaItems/22.mkv"}, "cast"], [{"uri": "cloud://mount/a.mp4"}, "cloud"],
		[{"uri": "medialib://emby/Items/1"}, "media_library"],
		[{"uri": "folder://abc", "location": {"type": "smb", "server_id": "nas", "path": "Video"}}, "server"],
		[{"uri": "folder://abc", "location": {"type": "cloud", "path": "/mount/Video"}}, "cloud"],
		[{"uri": "folder://abc", "location": {"type": "dlna", "server_id": "tv"}}, "cast"],
		[{"uri": "folder://abc", "location": {"type": "server", "server_id": "plex"}}, "media_library"],
		[{"uri": "folder://abc", "location": {"type": "local", "path": "/sdcard/Movies"}}, "device"],
		[{"uri": "archive://page", "location": {"type": "archive", "source_uri": "smb://nas/Comics/a.zip", "path": "ch1"}}, "server"],
		[{"title": "Unlock favorites", "unlock_favorites": true}, ""],
	]
	for case in cases:
		check(Presentation.source_icon(case[0]) == case[1], "Source of %s is %s, got %s" % [case[0].get("uri", ""), case[1], Presentation.source_icon(case[0])])
	var folder := "user://test_source_icons/%d" % Time.get_ticks_usec()
	var recent := Recent.new(folder.path_join("recent"))
	var store := Favorite.new(folder.path_join("favorites"))
	var entries := [["smb://nas/Video/山谷.mkv", "山谷", "video"], ["file:///sdcard/Movies/海边.mp4", "海边", "video"],
		["medialib://srv-2/scene/9", "海洋", "video"],
		["dlna://tv/item1", "客厅电视", "video"], ["cloud://mount/旅行/雪山.mp4", "雪山", "video"],
		["medialib://srv-1/scene/9?source=a", "纪录片", "video"], ["smb://nas/Photos/京都.jpg", "京都", "image"]]
	for entry in entries:
		recent.opened(entry[0], entry[1], false, entry[2])
		store.toggle(entry[0], entry[1], entry[2], {})
	store.toggle("folder://series", "连续剧", "folder", {"type": "cloud", "path": "/mount/连续剧", "stack": [{"id": "/mount/连续剧", "title": "连续剧"}]})
	check(recent.save(), "Save URI-only history before starting the menu")
	var output := OS.get_environment("SOURCE_ICONS_PREVIEW_DIR")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Library.new(); camera.add_child(menu); menu.position = Vector3(0, 0, -1.4); menu.visible = true
	var accounts := Accounts.new(); menu.attach_platform(accounts)
	menu.catalog = Recent.new(folder.path_join("recent")); menu.catalog.load_saved()
	menu.collections.store = Favorite.new(folder.path_join("favorites")); menu.section = Library.Section.RECENT
	for scene in ["recent-grid", "recent-list", "favorites-grid", "favorites-list", "compact-grid", "compact-list"]:
		menu.set_compact(scene.begins_with("compact"))
		menu.collections.home_tab = 1 if scene.begins_with("favorites") else 0
		menu.load_view_mode("grid" if scene.ends_with("grid") else "list"); menu.scroll = 0; menu.refresh()
		check(marks(menu, "provider_baidu") >= 1 and marks(menu, "cast") >= 1 and marks(menu, "provider_emby") >= 1 and marks(menu, "device") >= 1,
			"Each visible source has its mark: " + scene)
		check(marks(menu, "server") >= (1 if scene.begins_with("compact") else 2), "SMB entries carry the server mark: " + scene)
		check(has_caption(menu._list, "百度网盘 · 旅行盘") and has_caption(menu._list, "Emby"), "Visible provider names: " + scene)
		check(has_caption(menu._list, "Jellyfin · 客厅"), "Same media item ID on another server: " + scene)
		if output.is_empty(): continue
		DirAccess.make_dir_recursive_absolute(output)
		for frame in 20: await process_frame
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(scene + ".png"))
	check(accounts.reads == {"cloud": 1, "server": 1}, "Redrawing cards and changing tabs reuse account metadata")
	menu.catalog.progress("medialib://srv-1/scene/9?source=a", 1000, 60000)
	menu.quick_access.opened = true; menu.refresh()
	var side_rows: Array = menu._buttons.filter(func(button): return button.target >= menu.quick_access.ROW and button.target < menu.quick_access.ROW + menu.quick_access.PAGE_SIZE)
	check(side_rows.any(func(button): return has_caption(button.node, "Emby · 0:01 / 1:00")), "Quick access keeps the source beside playback progress")
	var favorites: RefCounted = menu.collections.store
	favorites.toggle("folder://shows", "剧集", "folder", {"type": "server", "server_id": "srv-2", "folder_path": [{"id": "shows", "title": "剧集"}]})
	favorites.toggle("folder://book", "漫画", "folder", {"type": "archive", "source_uri": "cloud://mount/漫画.zip", "source_title": "漫画", "path": "卷一"})
	menu.collections.home_tab = 1; menu.refresh()
	check(has_caption(menu._list, "Jellyfin · 客厅 · 剧集"), "Server folder uses its own account and retains its path")
	check(has_caption(menu._list, "百度网盘 · 旅行盘 · 漫画 / 卷一"), "Archive folder uses the container's drive")
	accounts.profiles.cloud[0].name = "新盘名"
	accounts.media_list.emit(0, '{"source":"cloud","state":"accounts_changed"}')
	check(has_caption(menu._list, "百度网盘 · 新盘名"), "Renaming a drive refreshes visible favorites")
	accounts.profiles.server.clear()
	accounts.media_list.emit(0, '{"source":"medialib","state":"accounts_changed"}')
	check(not has_caption(menu._list, "Jellyfin") and marks(menu, "media_library") > 0, "Removed servers fall back to their category")
	accounts.profiles.cloud.append({"id": "srv-1", "provider": "123_open", "name": "123云盘"})
	favorites.toggle("cloud://srv-1/海报.jpg", "海报", "image", {})
	accounts.unavailable = "cloud"
	accounts.media_list.emit(0, '{"source":"cloud","state":"accounts_changed"}')
	check(not has_caption(menu._list, "123云盘"), "Unavailable metadata does not guess from a matching server ID")
	accounts.unavailable = ""
	menu.refresh()
	check(has_caption(menu._list, "123云盘") and marks(menu, "cloud") > 0, "Drive without brand artwork retains its name after retry")
	preload("res://scripts/i18n.gd").use("en"); menu.refresh()
	check(has_caption(menu._list, "123 Cloud Drive") and not has_caption(menu._list, "123 Cloud Drive · 123云盘"), "Localized brand does not repeat the default profile name")
	menu.free(); viewport.free()
	print("Source icons: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
