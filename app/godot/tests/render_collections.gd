extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Favorite := preload("res://scripts/favorite_store.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Player := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
var checks := 0
var images := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)
func run() -> void:
	var output := OS.get_environment("COLLECTIONS_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Library.new(); camera.add_child(menu); menu.position = Vector3(0, 0, -1.4); menu.visible = true
	var store := Favorite.new(output.path_join("fixtures/" + str(Time.get_ticks_usec())))
	var recent := Recent.new(store.directory.path_join("recent")); menu.catalog = recent; menu.collections.store = store
	for i in 8:
		var uri := "file:///Series/Episode%02d.mp4" % i
		store.toggle(uri, "山海之旅 · 第 %02d 集" % i, "video", {"type":"local","path":"/Series","stack":[{"id":"/Series","title":"Series"}]})
		recent.opened(uri, "山海之旅 · 第 %02d 集" % i, false); recent.progress(uri, i * 300000, 2400000); recent.save()
	menu.settings_provider = func():return {"privacy_mode":"local","favorites_lock_level":"relaxed"}
	var folder_location := {"type":"local","path":"/Movies/连续剧","stack":[{"id":"/Movies","title":"Movies"},{"id":"/Movies/连续剧","title":"连续剧"}]}
	var folder_uri: String = menu.collections.Location.folder_uri(folder_location)
	var player := Player.new(); camera.add_child(player); player.position = Vector3(0, -0.12, -1.25)
	player.state_provider = func():return {"has_video":true,"geometry":0,"playing":true,"title":"山海之旅 · 第一集","position_ms":123456,"duration_ms":2400000}
	player.favorite_provider = func():return {"enabled":true,"selected":true,"locked":false}
	var photo := Photo.new(); camera.add_child(photo); photo.position = player.position
	photo.state_provider = func():return {"has_image":true,"depth_available":true,"layout":0,"count":8,"index":1,"gallery_focus":-1,"title":"京都 · 秋日散步.jpg"}
	photo.favorite_provider = func():return {"enabled":true,"selected":false,"locked":false}
	for language in ["zh","zh_Hant","ja","en"]:
		preload("res://scripts/i18n.gd").use(language)
		for scene in ["recent-grid","recent-hover","favorites-list","favorites-hover","favorites-recover","favorites-selection","favorites-folder-list","favorites-folder-hover","favorites-locked-list","favorites-locked-grid","folder-toolbar","privacy-collapsed","privacy-open","privacy","pin","pin-confirm","pin-busy","video","video-depth","photo","photo-depth"]:
			menu.collections.modal = ""; menu.visible = true; player.visible = false; photo.visible = false
			player._depth_open = false; photo._depth_open = false
			store.busy = false
			menu.section = Library.Section.RECENT; store.protected = false; store.locked = false; menu.collections.home_tab = 0
			if scene == "recent-grid": menu.load_view_mode("grid")
			elif scene == "recent-hover": menu.load_view_mode("grid")
			elif scene == "favorites-list": menu.collections.home_tab = 1; menu.load_view_mode("list")
			elif scene == "favorites-hover": menu.collections.home_tab = 1; menu.load_view_mode("grid")
			elif scene == "favorites-recover": menu.collections.home_tab = 1; menu.load_view_mode("grid")
			elif scene == "favorites-selection": menu.collections.home_tab = 1; menu.load_view_mode("list")
			elif scene in ["favorites-folder-list", "favorites-folder-hover"]:
				store.toggle(folder_uri, "Local files", "folder", folder_location)
				menu.collections.home_tab = 1; menu.load_view_mode("list" if scene.ends_with("list") else "grid")
			elif scene in ["favorites-locked-list", "favorites-locked-grid"]:
				store.protected = true; store.locked = true; menu.collections.home_tab = 1
				menu.load_view_mode("list" if scene.ends_with("list") else "grid")
			elif scene == "folder-toolbar":
				menu.section = Library.Section.LOCAL; menu.load_view_mode("grid")
				menu._local_stack = [{"id":"/Series","title":"Series"}]
				menu._local_volumes = [{"id":"/usb","title":"USB drive","removable":true}]
				menu._local_entries = recent.list_recent()
			elif scene in ["privacy-collapsed", "privacy-open"]: menu.section = Library.Section.SETTINGS; menu.tab = Library.GENERAL_TAB; menu.collections.privacy_expanded = false; menu.scroll = 0
			elif scene == "privacy": store.protected = true; menu.section = Library.Section.SETTINGS; menu.tab = Library.GENERAL_TAB; menu.collections.privacy_expanded = true; menu.scroll = 3
			elif scene == "pin": menu.collections.open_password("enable"); menu.collections.text = "12"
			elif scene == "pin-confirm":
				menu.collections.open_password("enable"); menu.collections.text = "0123"; menu.collections._submit()
			elif scene == "pin-busy":
				menu.collections.open_password("enable"); menu.collections.stage = "confirm"; store.busy = true
				menu.collections.message = "Still processing. You can return."
			elif scene in ["video", "video-depth"]: menu.visible = false; player.visible = true; player._depth_open = scene.ends_with("depth"); player.refresh()
			elif scene in ["photo", "photo-depth"]: menu.visible = false; photo.visible = true; photo._depth_open = scene.ends_with("depth"); photo.refresh()
			if menu.visible: menu.refresh()
			if scene == "privacy-open": menu._choose(menu.rows.filter(func(row):return row.get("group_header", false))[0])
			if scene == "favorites-recover": menu.collections._toggle_card_favorite(menu.rows[0])
			if scene in ["favorites-hover", "favorites-recover", "recent-hover", "favorites-folder-hover"]:
				var tile: Dictionary = menu._buttons.filter(func(b):return b.target == menu.ROW_BASE)[0]
				menu.update_pointer("right_controller", tile.node.to_global(Vector3(0, -0.08, 0.7)), -tile.node.global_basis.z, true)
				var action: Dictionary = menu._buttons.filter(func(b):return b.target == menu.collections.REMOVE_ROW)[0]
				menu.update_pointer("right_controller", action.node.to_global(Vector3(0, 0, 0.7)), -action.node.global_basis.z, true)
			if scene == "favorites-selection":
				menu.collections._toggle_selection(menu.rows[0]); menu.collections._toggle_selection(menu.rows[1])
			var active: Node3D = menu if menu.visible else (photo if photo.visible else player)
			for button in active._buttons:
				for child in button.node.get_children():
					if child is Label3D and not child.text.is_empty() and not child.autowrap_mode:
						var width: float = active.text_width(child.text, child.font_size / active.TEXT_RASTER_SCALE)
						check(width <= button.rect.size.x + 0.02, "Button text fits: " + language + "/" + scene + "/" + child.text)
			# Texture and font uploads can outlive the first two frames after switching menus.
			for frame in 20: await process_frame
			await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			if scene in ["video-depth", "photo-depth"]:
				var provider: Callable = active.favorite_provider
				active.favorite_provider = Callable(); active.refresh()
				for frame in 20: await process_frame
				await RenderingServer.frame_post_draw
				var reference := viewport.get_texture().get_image()
				var start: Vector2i = Vector2i(camera.unproject_position(active.to_global(Vector3(0.275, 0.23, 0.022))))
				var end: Vector2i = Vector2i(camera.unproject_position(active.to_global(Vector3(0.31, 0.20, 0.022))))
				var difference := 0.0
				for y in range(start.y, end.y):
					for x in range(start.x, end.x):
						var a := image.get_pixel(x, y); var b := reference.get_pixel(x, y)
						difference = maxf(difference, maxf(absf(a.r-b.r), maxf(absf(a.g-b.g), absf(a.b-b.b))))
				check(difference < 0.04, "Favorite pixels cannot cover the depth popup: " + language + "/" + scene)
				active.favorite_provider = provider
			if scene in ["photo", "video"]:
				for button in active._buttons:
					if button.target not in [100, 107, 108, active.FAVORITE]: continue
					var center: Vector2i = Vector2i(camera.unproject_position(button.node.global_position))
					var peak := 0.0
					for y in range(maxi(0, center.y - 20), mini(image.get_height(), center.y + 20)):
						for x in range(maxi(0, center.x - 20), mini(image.get_width(), center.x + 20)):
							peak = maxf(peak, image.get_pixel(x, y).get_luminance())
					check(peak > 0.30, "Visible controller glyph: " + language + "/" + scene + "/" + str(button.target))
			check(not image.is_empty(), "Rendered image: " + scene)
			image.save_png(output.path_join(language + "-" + scene + ".png"))
			images += 1
			if scene == "favorites-recover": store.restore(); menu.collections.pending_favorites.clear()
			if scene in ["favorites-folder-list", "favorites-folder-hover"]: store.remove(folder_uri); store.undo.clear()
	menu.free(); player.free(); photo.free(); viewport.free()
	Privacy.vault = null; Privacy.configure("all")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"images":images}, "\t"))
	print("Collections render: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
