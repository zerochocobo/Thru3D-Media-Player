extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
var checks := 0
var failures: Array[String] = []
var poster: Texture2D
var backdrop: Texture2D
var library_picture: Texture2D
var actor_pictures := {}

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("run")
func request_id(b: RefCounted, action: String) -> int:
	for id in b.pending:
		if b.pending[id].action == action: return id
	return -1
func texture(path: String, size: Vector2i, tint: Color) -> Texture2D:
	var image := Image.new()
	if not path.is_empty():
		check(image.load(path) == OK, "Plex artwork decodes in the actual UI image loader")
		check(image.get_width() <= 512 and image.get_height() <= 512, "Plex artwork respects the requested image bound")
	else: image = Image.create(size.x, size.y, false, Image.FORMAT_RGB8); image.fill(tint)
	return ImageTexture.create_from_image(image)
func cache(b: RefCounted, image: Dictionary, value: Texture2D) -> void:
	for width in [128, 256, 512, 1024]:
		var key: String = b._request_image_key(b._image_request({"cover_image": image.merged({"max_width": width})}))
		b.textures[key] = value
func fill(b: RefCounted, data: Dictionary) -> void:
	for item in data.home.libraries:
		if item.has("cover_image") and str(item.id) == str(data.home.libraries[0].id): cache(b, item.cover_image, library_picture)
	for type in data.detail.image_variants:
		cache(b, data.detail.image_variants[type], poster if type == "Primary" else backdrop)
	for actor in data.detail.get("actors", []):
		if actor_pictures.has(str(actor.id)) and actor.has("cover_image"): cache(b, actor.cover_image, actor_pictures[str(actor.id)])
func fallback() -> Dictionary:
	var primary := {"id": "12", "image_type": "Primary", "image_index": 0, "image_tag": "poster"}
	var art := {"id": "12", "image_type": "Backdrop", "image_index": 0, "image_tag": "art"}
	return {"home": {"capabilities": {"home_layout": "libraries", "artwork": true, "favorite_scope": "local", "navigation": ["genres", "tags", "folders"], "facets": ["genres", "tags", "performers", "studios"], "sorts": ["created_at", "title", "date", "duration", "rating100"]},
		"libraries": [{"id": "1", "title": "电影", "collection_type": "movies", "has_cover": false}, {"id": "2", "title": "剧集", "collection_type": "tvshows", "has_cover": false}], "recent_opened": [], "resume": []},
		"detail": {"id": "12", "title": "远山来信", "uri": "medialib://profile/scene/12", "has_cover": true, "description": "一段穿越山川与海岸的旅程。", "duration_ms": 60000,
			"image_variants": {"Primary": primary, "Thumb": art, "Backdrop": art}, "cover_image": primary, "images": [primary, art], "backdrops": [art], "actors": [], "genres": [], "tags": []}}

func run() -> void:
	var data := fallback()
	var input := OS.get_environment("VRPP_PLEX_UI_DATA")
	if not input.is_empty():
		var loaded: Variant = JSON.parse_string(FileAccess.get_file_as_string(input))
		check(loaded is Dictionary, "Production Plex presentation data is valid")
		if loaded is Dictionary: data = loaded
	var images: Dictionary = data.get("preview_images", {})
	poster = texture(str(images.get("poster", "")), Vector2i(256, 384), Color(0.14, 0.30, 0.35))
	backdrop = texture(str(images.get("backdrop", "")), Vector2i(512, 288), Color(0.10, 0.20, 0.26))
	library_picture = texture(str(images.get("library", "")), Vector2i(512, 288), Color(0.18, 0.28, 0.23))
	for key in images:
		if str(key).begins_with("actor-"): actor_pictures[str(key).trim_prefix("actor-")] = texture(str(images[key]), Vector2i(256, 384), Color(0.14, 0.20, 0.26))
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "Plex", "provider": "plex"}
	b.display_preferences.clear()
	b.open_home(); platform.answer(request_id(b, "home"), data.home.duplicate(true)); fill(b, data); menu.refresh()
	check(b.gallery.home() and menu._max_scroll() == 0, "Bound Plex uses the same fixed library carousel as Emby")
	check(menu.rows.size() == data.home.libraries.size(), "Plex home exposes libraries rather than a generic command list")
	b.gallery.action(Gallery.LIBRARY)
	var request: Dictionary = platform.requests[request_id(b, "browse")]
	check(request.library_id == str(data.home.libraries[0].id) and request.mode == "library", "Plex card opens its library poster wall")
	platform.answer(request_id(b, "browse"), {"entries": [data.detail], "total": 1}); fill(b, data); menu.refresh()
	check(b.media_content() and b.scene_view() == "poster" and menu._grid(), "Plex defaults to the shared poster wall")
	for mode in ["poster", "thumb", "list"]:
		b.action(Browser.ACTION + {"poster": 160, "thumb": 161, "list": 162}[mode])
		check(b.scene_view() == mode, "Plex supports the shared display option: " + mode)
	b.choose({"scene": data.detail}); platform.answer(request_id(b, "detail"), {"detail": data.detail.duplicate(true)})
	fill(b, data); menu.refresh()
	check(b.gallery.rich_detail() and b.backdrop.pictures.size() > 0, "Plex detail uses the existing poster, background and synopsis composition")
	check(menu._buttons.any(func(item): return item.target == Browser.ACTION + 30), "Plex exposes the existing native play action")
	b.detail.actors = [{"id": "51", "name": "Alex", "has_cover": false}]
	b.gallery.action(Gallery.ACTOR)
	request = platform.requests[request_id(b, "browse")]
	check(request.get("all_libraries", false) and request.performers == ["51"], "Plex actor uses the shared cross-library filmography action")
	b.cancel(); b.view = "detail"; b.detail = data.detail.duplicate(true)
	b.detail.versions = [data.detail.merged({"source_id": "81", "version_name": "4K", "uri": "medialib://profile/scene/12?source=81"}, true), data.detail.merged({"source_id": "82", "version_name": "1080p", "uri": "medialib://profile/scene/12?source=82"}, true)]
	b.gallery.selected_versions[str(b.detail.id)] = "82"
	check(b.gallery.playback_node().uri.ends_with("source=82"), "Plex version choice retains its explicit source through native play")
	b.detail = data.detail.duplicate(true); b.gallery.selected_versions.clear()
	var output := OS.get_environment("VRPP_PLEX_UI_PREVIEW")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		for language in ["zh", "en"]:
			preload("res://scripts/i18n.gd").use(language)
			for page in ["home", "poster", "thumb", "list", "detail"]:
				b.cancel(); menu.visible = true; b.view = "home" if page == "home" else "detail" if page == "detail" else "scenes"
				b.query = {"page": 1, "q": "", "mode": "library", "collection_type": "movies"}; b.library_id = "" if page == "home" else str(data.home.libraries[0].id)
				b.actor_name = ""; b.labels.clear(); b.folder_path.clear(); b.history.clear()
				menu.status = ""
				b.home_data = data.home.duplicate(true); b.detail = data.detail.duplicate(true); b.entries = [data.detail]; b.total = 1; b.end_reached = true
				b.display_preferences.profile = {"mode": page if page in ["poster", "thumb", "list"] else "poster", "size": 1}
				fill(b, data); menu._reset_navigation(); menu.refresh()
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				check(viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png")) == OK, "Plex preview saved")
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Plex library UI: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
