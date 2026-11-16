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
	var entries := [["file:///sdcard/Movies/海边.mp4", "海边", "video"], ["smb://nas/Video/山谷.mkv", "山谷", "video"],
		["dlna://tv/item1", "客厅电视", "video"], ["cloud://mount/旅行/雪山.mp4", "雪山", "video"],
		["medialib://emby/Items/9", "纪录片", "video"], ["smb://nas/Photos/京都.jpg", "京都", "image"]]
	for entry in entries:
		recent.opened(entry[0], entry[1], false, entry[2])
		store.toggle(entry[0], entry[1], entry[2], {})
	store.toggle("folder://series", "连续剧", "folder", {"type": "cloud", "path": "/mount/连续剧", "stack": [{"id": "/mount/连续剧", "title": "连续剧"}]})
	var output := OS.get_environment("SOURCE_ICONS_PREVIEW_DIR")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Library.new(); camera.add_child(menu); menu.position = Vector3(0, 0, -1.4); menu.visible = true
	menu.catalog = recent; menu.collections.store = store; menu.section = Library.Section.RECENT
	for scene in ["recent-grid", "recent-list", "favorites-grid", "favorites-list", "compact-grid", "compact-list"]:
		menu.set_compact(scene.begins_with("compact"))
		menu.collections.home_tab = 1 if scene.begins_with("favorites") else 0
		menu.load_view_mode("grid" if scene.ends_with("grid") else "list"); menu.scroll = 0; menu.refresh()
		check(marks(menu, "cloud") >= 1 and marks(menu, "cast") >= 1 and marks(menu, "media_library") >= 1 and marks(menu, "device") >= 1,
			"Each visible source has its mark: " + scene)
		check(marks(menu, "server") >= (1 if scene.begins_with("compact") else 2), "SMB entries carry the server mark: " + scene)
		if output.is_empty(): continue
		DirAccess.make_dir_recursive_absolute(output)
		for frame in 20: await process_frame
		await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(scene + ".png"))
	menu.free(); viewport.free()
	print("Source icons: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
