extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Test := preload("res://tests/test_media_server_browser.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_SERVER_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "Emby · Demo Library", "provider": "emby"}; b.capabilities = Test.CAPS.merged({"home_layout": "libraries", "artwork": true, "sorts": Browser.SORTS}, true); b.library_id = "lib1"; b.total = 250; b.end_reached = false; b.loaded_page = 1
	var capture_detail := {}
	var movies: Array = []
	var names := ["远山来信", "蓝色时刻", "深海回声", "月面航行", "夜行列车", "北境之光", "城市边缘", "荒野之路"]
	for i in 8:
		var node := {"id": str(i + 1), "title": names[i], "basename": names[i] + "_完整文件名_180_SBS_2160p_2026.mp4", "uri": "medialib://profile/scene/%d" % (i + 1), "duration_ms": 6540000, "position_ms": 2322000 if i == 1 else 0, "tags": [{"id": "自然", "name": "自然"}], "genres": [{"id": "纪录", "name": "纪录"}], "markers": [{"title": "起点", "position_ms": 0}, {"title": "山间", "position_ms": 180000}]}
		movies.append(node)
		var image := Image.create(256, 360, false, Image.FORMAT_RGB8)
		var hue := 0.48 + i * 0.055
		for y in 360:
			for x in 256:
				var color := Color.from_hsv(fmod(hue, 1.0), 0.42, 0.40 - float(y) / 1300.0)
				var d := Vector2(x - 140, y - 107).length()
				if d < 65: color = color.lerp(Color.from_hsv(fmod(hue + 0.15, 1.0), 0.21, 0.8), (1.0 - d / 65.0) * 0.8)
				if y > 230 + sin(float(x) / 40.0 + i) * 29: color = color.darkened(0.45)
				image.set_pixel(x, y, color)
		b.textures["profile/%d" % (i + 1)] = ImageTexture.create_from_image(image)
	var libraries: Array = []
	var library_names := ["电影", "剧集", "VR180", "VR360", "纪录片", "动画", "音乐现场", "家庭影像", "短片"]
	for i in library_names.size():
		libraries.append({"id": "lib%d" % (i + 1), "title": library_names[i], "collection_type": "movies", "has_cover": true})
		b.textures["profile/lib%d" % (i + 1)] = b.textures["profile/%d" % (i % 8 + 1)]
	var images: Array = []; var actors: Array = []
	for i in 7:
		var item := {"id": "2", "image_type": "Backdrop", "image_index": i, "image_tag": "demo%d" % i}
		images.append(item)
		var image := Image.create(512, 342 if i % 2 == 0 else 376, false, Image.FORMAT_RGB8)
		for y in image.get_height():
			for x in 512:
				var color := Color.from_hsv(0.49 + i * 0.035, 0.34, 0.52 - float(y) / 900.0)
				if y > 170 + sin(float(x) / 80.0 + i) * 30: color = color.darkened(0.45)
				image.set_pixel(x, y, color)
		var texture := ImageTexture.create_from_image(image)
		for width in [256, 512, 1024]: b.textures[b._request_image_key(b._image_request({"cover_image": item.merged({"max_width": width})}))] = texture
	for i in 6:
		actors.append({"id": "actor%d" % i, "name": ["林雨", "周明", "沈青", "顾川", "陈月", "叶星"][i], "has_cover": true})
		b.textures["profile/actor%d" % i] = b.textures["profile/%d" % (i + 1)]
	b.home_data = {"recent": [], "resume": [], "recent_opened": movies, "libraries": libraries}
	for i in movies.size():
		var movie: Dictionary = movies[i]
		var poster := {"id": str(movie.id), "image_type": "Primary", "image_tag": "poster"}
		var thumb := {"id": str(movie.id), "image_type": "Thumb", "image_tag": "thumb"}
		movie.cover_image = poster; movie.image_variants = {"Primary": poster, "Thumb": thumb}
		for width in [128, 512]:
			b.textures[b._request_image_key(b._image_request({"cover_image": poster.merged({"max_width": width})}))] = b.textures["profile/" + str(movie.id)]
			b.textures[b._request_image_key(b._image_request({"cover_image": thumb.merged({"max_width": width})}))] = b.textures[b._request_image_key(b._image_request({"cover_image": images[i % images.size()].merged({"max_width": 256})}))]
	for language in ["zh", "en", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for page in ["home", "home_more", "home_single", "home_recent_more", "home_empty", "scenes", "scenes_small", "scenes_large", "scenes_thumb", "scenes_list", "sort", "facets", "candidates", "folders", "folders_sources", "detail", "detail_cd2", "detail_parts_more", "detail_images", "detail_long", "overview", "picture", "filters", "filters_sources", "options", "saved", "search", "favorites"]:
			b.view = page; b.query = {"page": 1, "q": "", "all_tags": true}; b.folder_path.clear(); b.entries = movies.duplicate(true); b.candidates = []; b.detail = {}
			b.sort_query.clear()
			if page == "sort": b.view = "scenes"; b.sort_query = {"sort": "duration", "direction": "ASC"}
			b.sources_open = page in ["folders_sources", "filters_sources"]; b.keyboard = ""
			if page == "search": b.view = "scenes"; b.keyboard = "search"; b.text = "寻找影片 / Find a movie"
			if page == "filters_sources": b.view = "filters"
			b.display_preferences.profile = {"mode": "list" if page == "scenes_list" else ("thumb" if page == "scenes_thumb" else "poster"), "size": 0 if page == "scenes_small" else (2 if page == "scenes_large" else 1)}
			if page.begins_with("scenes_"): b.view = "scenes"
			b.gallery.detail_start = 1 if page == "detail_images" else 0; b.gallery.overview_start = 0; b.gallery.tag_start = 0
			if page in ["facets", "candidates"]: b.kind = "genres"; b.candidate_total = 33; b.candidates = [{"id": "纪录", "name": "纪录", "count": 18}, {"id": "剧情", "name": "剧情", "count": 22}, {"id": "科幻", "name": "科幻", "count": 12}, {"id": "冒险", "name": "冒险", "count": 6}, {"id": "动画", "name": "动画", "count": 7}, {"id": "自然", "name": "自然", "count": 9}, {"id": "音乐", "name": "音乐", "count": 4}]
			if page in ["folders", "folders_sources"]:
				b.view = "scenes"; b.query.mode = "folders"; b.query.collection_type = "movies"; b.folder_path = [{"id": "a", "title": "资料"}, {"id": "b", "title": "VR"}]
				b.entries = [{"id": "folder1", "title": "蓝色时刻", "type": "Folder", "container": true, "has_cover": false, "child_count": 1}, {"id": "folder2", "title": "深海回声", "type": "Folder", "container": true, "has_cover": true, "child_count": 1, "image_variants": {"Thumb": movies[2].image_variants.Thumb}}, {"id": "folder3", "title": "纪录片合集", "type": "Folder", "container": true, "has_cover": false, "child_count": 10}] + movies.slice(0, 1)
				b._cache_folder_artwork("folder1", {"Thumb": movies[1].image_variants.Thumb})
			b.gallery.library_start = 5 if page == "home_more" else 0
			b.gallery.recent_start = 4 if page == "home_recent_more" else 0
			b.home_data.libraries = [libraries[0].merged({"title": "Movie"}, true)] if page in ["home_single", "home_empty"] else libraries
			b.home_data.recent_opened = [] if page == "home_empty" else movies
			if page.begins_with("home_"): b.view = "home"
			b.library_id = "" if b.view == "home" else "lib1"
			if page in ["detail", "detail_cd2", "detail_parts_more", "detail_images", "detail_long", "overview", "picture"]:
				b.detail = movies[1].duplicate(true); b.detail.description = "当暮色落在城市边缘，一场安静的旅程缓缓展开。"
				b.detail.images = images; b.detail.actors = actors; b.detail.year = 2026
				if page in ["detail_long", "overview"]: b.detail.description = "当暮色落在城市边缘，一场安静的旅程缓缓展开。沿着群山与海岸，寻找生活中的细微光芒。".repeat(90)
				b.detail.parts = [movies[1].merged({"title": "蓝色时刻 · cd1", "part_label": "cd1"}, true), movies[2].merged({"title": "蓝色时刻 · cd2", "part_label": "cd2"}, true)]
				if page == "detail_parts_more":
					for i in range(3, 6): b.detail.parts.append(movies[i].merged({"title": "蓝色时刻 · cd%d" % i, "part_label": "cd%d" % i}, true))
				for i in b.detail.parts.size():
					var part_image: Dictionary = images[i].merged({"id": str(b.detail.parts[i].id)}, true)
					b.detail.parts[i].part_image = part_image
					b.textures[b._request_image_key(b._image_request({"cover_image": part_image}))] = b.textures[b._request_image_key(b._image_request({"cover_image": images[i].merged({"max_width": 256})}))]
				b.gallery.part_start = 0; b.gallery.selected_part = 1 if page == "detail_cd2" else 0
				if page in ["detail_cd2", "detail_parts_more", "detail_images", "detail_long"]: b.view = "detail"
				if page == "detail_parts_more": b.gallery.part_start = 2
			if page == "favorites": b.view = "scenes"; b.query.favorites = true; b.entries = []; b.total = 0
			else: b.total = 250
			menu._reset_navigation(); menu.refresh()
			if page == "detail": capture_detail = b.detail.duplicate(true)
			check(menu._side.visible == (not b.focused() or b.sources_open), "Source navigation follows the explicit choice: " + language + "/" + page)
			if b.media_content() and not b.sorting():
				for item in menu._buttons:
					if not item.node.is_visible_in_tree() or not menu._row_target(int(item.target)): continue
					var center: Vector3 = menu.to_local(item.node.global_position)
					check(center.y + item.rect.size.y / 2 < 0.335, "Content stays below display controls: " + language + "/" + page)
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(camera, camera, Display.new(), [menu], false, true); capture.set_process(false)
	for page in ["scenes", "detail", "sources", "sort"]:
		b.sources_open = page == "sources"; b.keyboard = ""; b.view = "scenes" if page in ["sources", "sort"] else page; b.entries = movies; b.detail = capture_detail; b.display_preferences.profile = {"mode": "poster", "size": 1}; b.sort_query = {"sort": "title", "direction": "DESC"} if page == "sort" else {}; menu.refresh()
		capture.update(); await process_frame; await RenderingServer.frame_post_draw; capture.update()
		check(capture.active == menu, "Compositor activates the complete media page: " + page)
		check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(menu._backdrop)), "Compositor captures the larger backdrop: " + page)
		if page == "sources": check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(menu._side.get_child(0))), "Compositor captures the visible source sidebar")
		if page == "sort":
			for slot in capture.slots:
				if not slot.used or not slot.nodes.has(menu._backdrop): continue
				var image: Image = slot.raw.get_texture().get_image()
				var pixel: Vector2i = Vector2i(slot.camera.unproject_position(menu.to_global(Vector3(-0.46, 0.08, 0.01))))
				var color := image.get_pixelv(pixel)
				check(maxf(color.r, maxf(color.g, color.b)) > 0.05, "Sort popup keeps the background artwork visible in the actual compositor capture")
		for slot in capture.slots:
			if slot.used: slot.raw.get_texture().get_image().save_png(output.path_join("composition-" + page + "-%d.png" % slot.index))
	capture.shutdown("test_complete")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "scope": "Desktop media layouts and production menu capture; native XR and physical headset viewing unverified"}, "\t"))
	for failure in failures: push_error(failure)
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	print("Media server layout render checks=%d failures=%d" % [checks, failures.size()]); quit(0 if failures.is_empty() else 1)
