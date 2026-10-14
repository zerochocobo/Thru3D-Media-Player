extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Backend extends RefCounted:
	var id := 0
	var layouts: Array = []
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, stereo: bool, _profile: String, _alpha: bool, _pause: bool, _depth: bool, tb: bool, _exact: bool) -> int:
		id += 1; layouts.append([stereo, tb]); return id
	func set_mpv_playing(_id: int, _value: bool) -> void: pass
	func close_mpv_video(_id: int) -> void: pass

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("_run")
func request_id(b: RefCounted, action: String) -> int:
	for id in b.pending:
		if b.pending[id].action == action: return id
	return -1
func ray(menu: Node3D, x: float, y: float = 0.015) -> Array:
	var origin := menu.to_global(Vector3(x, y, 1))
	return [origin, (menu.to_global(Vector3(x, y, 0)) - origin).normalized()]

func has_icon(menu: Node, target: int, icon: String) -> bool:
	for item in menu._buttons:
		if item.target != target: continue
		return item.node.get_children().any(func(node): return node is MeshInstance3D and node.material_override is StandardMaterial3D and node.material_override.albedo_texture == menu.Icons.texture(icon))
	return false

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "NAS", "provider": "emby"}
	b.open_home()
	var libraries: Array = []
	for i in 9: libraries.append({"id": "lib%d" % i, "title": "Library %d" % i, "collection_type": "tvshows" if i == 4 else "movies", "has_cover": false})
	platform.answer(request_id(b, "home"), {"capabilities": {"home_layout": "libraries", "artwork": true, "facets": ["genres", "tags", "performers"], "navigation": [], "favorite_scope": "server"}, "libraries": libraries})
	check(menu.rows.size() == 9 and menu.rows.all(func(row): return row.has("library")), "home exposes libraries directly")
	check(menu._max_scroll() == 0, "library carousel never creates a vertical scrollbar")
	check(menu._buttons.filter(func(button): return button.target >= Gallery.LIBRARY).size() == 4, "four visible library cards")
	menu.stick_scroll_horizontal(1, 0.1); check(b.gallery.library_start == 1 and b.pending.is_empty(), "horizontal stick scrolls without choosing a library")
	menu.stick_scroll(1, 0.1); check(menu.scroll == 0, "vertical input does not select or move the fixed homepage")
	b.gallery.library_start = 0; menu.refresh()
	var start := ray(menu, -0.36); var moved := ray(menu, -0.67)
	check(menu.press_pointer("left_hand", start[0], start[1], true), "library ray press captured")
	menu.update_pointer("left_hand", moved[0], moved[1], true)
	menu.release_pointer("left_hand", moved[0], moved[1], true)
	check(b.gallery.library_start == 1 and b.pending.is_empty(), "horizontal drag scrolls without opening the released card")
	b.gallery.action(Gallery.LIBRARY + 4)
	var browse := request_id(b, "browse")
	check(platform.requests[browse].library_id == "lib4" and platform.requests[browse].collection_type == "tvshows" and platform.requests[browse].mode == "library", "library card immediately queries its poster wall")
	var movie := {"id": "film1", "uri": "medialib://profile/scene/film1", "title": "Film", "has_cover": false, "basename": "film_180.mp4", "video_3d_format": "FullSideBySide"}
	platform.answer(browse, {"entries": [movie], "total": 1})
	var original_view: String = menu.view_mode
	b.display_preferences_path = ProjectSettings.globalize_path("res://../../build/output/emby-poster-wall/server_views_test.cfg")
	b.display_preferences.clear()
	b.display_preferences.profile = "damaged entry"
	check(b.scene_view() == "poster" and b.scene_size() == 1, "Invalid saved server preferences fall back safely")
	b.display_preferences.clear()
	var nodes: Array = []
	for i in 40:
		nodes.append(movie.merged({"id": "view%d" % i, "uri": "medialib://profile/scene/view%d" % i, "basename": "完整文件名_视频_%02d.mp4" % i, "has_cover": true, "image_variants": {"Primary": {"id": "view%d" % i, "image_type": "Primary", "image_tag": "p"}, "Thumb": {"id": "view%d" % i, "image_type": "Thumb", "image_tag": "t"}}}, true))
	b.entries = nodes; b.total = 40; menu.refresh(); menu._set_scroll(2)
	var first_key: String = menu.capture_position().key
	b.action(Browser.ACTION + 162)
	check(not menu._grid() and menu._cols() == 1 and b.scene_view() == "list", "Server list is independently selected")
	check(menu.capture_position().key == first_key and menu.view_mode == original_view, "Server view conversion preserves item identity and the common folder preference")
	check(menu._tips.get(Menu.ROW_BASE, "").begins_with("完整文件名_"), "List uses the actual filename and retains its full tooltip")
	check(b.pending.values().filter(func(req): return req.action == "cover").size() == 2 and b.pending.values().filter(func(req): return req.action == "cover").all(func(req): return req.image_type == "Thumb" and req.max_width == 128), "List fetches only small horizontal images")
	b.action(Browser.ACTION + 161)
	check(menu._grid() and b.scene_view() == "thumb" and b.pending.values().filter(func(req): return req.action == "cover").all(func(req): return req.image_type == "Thumb" and req.max_width == 512), "Thumbnail mode switches image variant without per-film detail queries")
	b.action(Browser.ACTION + 160)
	check(b.scene_view() == "poster" and b.pending.values().filter(func(req): return req.action == "cover").all(func(req): return req.image_type == "Primary"), "Poster mode uses poster images")
	var image_id: int = request_id(b, "cover")
	var failed_scene: String = b.pending[image_id].scene_id
	platform.answer(image_id, {"state": "error", "error": "Cover unavailable"})
	check(b.pending.values().any(func(req): return req.action == "cover" and req.scene_id == failed_scene and req.image_type == "Thumb"), "A failed poster falls back to the film's thumbnail without losing the card")
	var previous_size: Vector2 = b.tile_size()
	b.action(Browser.ACTION + 163)
	check(b.scene_size() == 2 and menu._cols() == 3 and b.tile_size().x > previous_size.x and menu._lines() == 1, "Large posters grow and reduce density to fit the panel")
	var restored := Menu.new(); root.add_child(restored); restored.server_browser.server = b.server.duplicate()
	restored.server_browser.display_preferences_path = b.display_preferences_path; restored.server_browser.load_display_preferences()
	check(restored.server_browser.scene_view() == "poster" and restored.server_browser.scene_size() == 2, "Server display preference survives a new browser instance")
	restored.free()
	b.set_display("poster", 1); b.entries = [movie]; b.total = 1; menu._reset_navigation(); menu.refresh()
	var large_size: Vector2 = menu._backdrop.mesh.size
	check(has_icon(menu, Browser.ACTION + 19, "menu") and menu._tips[Browser.ACTION + 19] == "Main menu" and not menu._side.visible, "Large media browsing offers a main menu icon with a clear tooltip")
	check(has_icon(menu, Browser.ACTION + 3, "filter") and menu._tips[Browser.ACTION + 3] == "Filters", "Filter action uses a funnel and its own tooltip")
	check(has_icon(menu, Browser.ACTION + 15, "more") and menu._tips[Browser.ACTION + 15] == "Server options", "Server options use an ellipsis distinct from filters")
	for folder in ["folderA", "folderB"]:
		b.choose({"container_node": {"id": folder, "title": folder, "container": true, "has_cover": false}})
		platform.answer(request_id(b, "browse"), {"entries": [movie], "total": 1})
	var deep_query: Dictionary = b.query.duplicate(true)
	var deep_history: int = b.history.size(); var deep_generation: int = b.generation; var calls_before: int = platform.next
	b.action(Browser.ACTION + 19)
	check(menu._side.visible and menu._buttons.any(func(item): return item.target == Menu.NAV_BASE + Menu.Section.LOCAL), "Sources are reachable directly inside nested server folders")
	check(b.query == deep_query and b.folder_path.size() == 2 and b.history.size() == deep_history and b.generation == deep_generation and platform.next == calls_before, "Showing sources keeps the current folder, history and pending requests")
	check(menu._backdrop.mesh.size == large_size, "Showing sources preserves the large content panel")
	b.action(Browser.ACTION + 3)
	check(b.view == "filters" and b.focused() and menu._side.visible and menu._backdrop.mesh.size == large_size, "Filters keep the media layout and explicit source visibility")
	b.choose({"category": "tags"}); platform.answer(request_id(b, "candidates"), {"entries": [{"id": "Tag", "name": "Tag"}], "total": 1})
	check(b.view == "candidates" and b.focused() and menu._backdrop.mesh.size == large_size, "Filter categories keep the large layout")
	b.back(); b.back()
	check(b.query == deep_query and b.folder_path.size() == 2, "Filter back returns to the original nested folder")
	b.action(Browser.ACTION + 15)
	check(b.view == "options" and b.focused() and menu._backdrop.mesh.size == large_size, "Server options keep the large layout")
	b.choose({"open_saved": true})
	check(b.view == "saved" and b.focused() and menu._backdrop.mesh.size == large_size, "Saved searches keep the large layout")
	b.back(); b.back(); b.action(Browser.ACTION + 2); b.text = "Retain search"; menu.refresh()
	check(b.focused() and menu._backdrop.mesh.size == large_size and menu._buttons.any(func(item): return item.target == Browser.ACTION + 19), "Search retains the media panel and source shortcut")
	b.action(Browser.ACTION + 19)
	check(not menu._side.visible and b.text == "Retain search" and b.keyboard == "search", "Sources can be hidden without clearing search input")
	check(not menu._buttons.any(func(item): return item.target >= Menu.NAV_BASE and item.target < Menu.NAV_BASE + Menu.NAV.size()), "Hidden source navigation has no ray targets")
	b.action(Browser.ACTION + 25); b.back(); b.back()
	check(b.view == "scenes" and b.folder_path.is_empty(), "Back still restores individual folder levels")
	b.query.tags = ["old"]; b.query.watched = true; b.query.q = "old query"; b.query.parent_id = "nested"
	b.choose({"scene": movie})
	var detail := movie.duplicate(true)
	detail.images = [{"id": "film1", "image_type": "Backdrop", "image_index": 0, "image_tag": "first"}, {"id": "film1", "image_type": "Backdrop", "image_index": 1, "image_tag": "second"}]
	detail.actors = [{"id": "actor1", "name": "Actor", "has_cover": false}]
	detail.markers = [{"title": "Opening", "position_ms": 2000}]
	detail.parts = [movie.merged({"part_label": "cd1", "title": "Film · cd1", "markers": detail.markers}, true), movie.merged({"id": "film2", "uri": "medialib://profile/scene/film2", "part_label": "cd2", "title": "Film · cd2", "video_3d_format": "HalfTopAndBottom"}, true)]
	platform.answer(request_id(b, "detail"), {"detail": detail})
	b.gallery.action(Browser.ACTION + 55)
	check(menu._buttons.any(func(button): return button.target == Gallery.PHOTO + 1) and menu._buttons.any(func(button): return button.target == Gallery.ACTOR), "detail shows multiple images and actor cards")
	var cover_requests: Array = b.pending.values().filter(func(req): return req.action == "cover")
	check(cover_requests.size() == 2 and b._request_image_key(cover_requests[0]) != b._request_image_key(cover_requests[1]), "same film's artwork indices use separate requests and cache keys")
	b.gallery.action(Gallery.PHOTO + 1)
	check(b.view == "picture" and b.gallery.selected_image == 1, "thumbnail opens its full picture")
	check(b.pending.values().all(func(req): return req.max_width == 1024 and req.image_index == 1), "picture viewer requests bounded full-size selected image")
	b.back(); check(b.view == "detail", "picture back returns to film")
	b.gallery.action(Gallery.ACTOR)
	var actor := request_id(b, "browse"); var query: Dictionary = platform.requests[actor]
	check(query.performers == ["actor1"] and query.all_libraries and query.library_id.is_empty(), "actor searches all accessible libraries")
	check(not query.has("tags") and not query.has("watched") and not query.has("parent_id") and query.q.is_empty(), "actor clears unrelated filters")
	platform.answer(actor, {"entries": [movie], "total": 1}); b.back()
	check(b.view == "detail" and b.library_id == "lib4" and b.query.tags == ["old"], "actor results restore original film and library filters")
	b.gallery.action(Browser.ACTION + 38)
	check(b.view == "metadata" and menu.rows.any(func(row): return row.has("marker")), "chapter and metadata controls remain accessible")
	b.back()
	for i in range(3, 6): b.detail.parts.append(movie.merged({"id": "film%d" % i, "uri": "medialib://profile/scene/film%d" % i, "part_label": "cd%d" % i}, true))
	b.gallery.detail_start = 0; menu.refresh()
	b.gallery.action(Browser.ACTION + 42)
	check(b.view == "detail" and b.gallery.part_start == 2 and b.gallery.selected_part == 0, "many inline parts scroll without changing selection")
	b.gallery.action(Browser.ACTION + 41)
	start = ray(menu, 0.54, -0.055); moved = ray(menu, 0.02, -0.055)
	menu.press_pointer("left_hand", start[0], start[1], true); menu.update_pointer("left_hand", moved[0], moved[1], true); menu.release_pointer("left_hand", moved[0], moved[1], true)
	check(b.view == "detail" and b.gallery.part_start == 2 and b.gallery.selected_part == 0, "large part cards support horizontal ray dragging without selecting")
	b.gallery.action(Browser.ACTION + 41); b.detail.parts = b.detail.parts.slice(0, 2)
	b.gallery.action(Gallery.PART + 1)
	check(b.view == "detail" and b.gallery.selected_part == 1 and menu._buttons.any(func(button): return button.target == Gallery.PART), "cd1 and cd2 can be selected inline on the film detail")
	b.gallery.action(Gallery.PHOTO); b.back()
	check(b.view == "detail" and b.gallery.selected_part == 1, "picture viewer preserves selected part on return")
	b.gallery.detail_start = 0; menu.refresh()
	start = ray(menu, -0.17, -0.33); moved = ray(menu, -0.17, -0.04)
	menu.press_pointer("left_hand", start[0], start[1], true); menu.update_pointer("left_hand", moved[0], moved[1], true); menu.release_pointer("left_hand", moved[0], moved[1], true)
	check(b.view == "detail" and b.gallery.detail_start == 1 and b.gallery.selected_part == 1 and menu._buttons.any(func(button): return button.target == Gallery.PHOTO), "Vertical ray drag exposes artwork without selecting an actor or part")
	b.detail.description = "完整简介 ".repeat(600)
	b.detail.tags = [{"id": "tag1", "name": "自然"}, {"id": "tag2", "name": "旅行"}]
	menu.refresh()
	check(menu._buttons.any(func(button): return button.target == Browser.ACTION + 56) and menu._buttons.any(func(button): return button.target == Gallery.TAG), "Detail offers the long synopsis and content tag buttons")
	b.gallery.action(Browser.ACTION + 56)
	check(b.view == "overview" and b.gallery.overview_lines().size() > 10 and "".join(b.gallery.overview_lines()) == b.detail.description, "Synopsis preserves all text and wraps without truncation")
	b.gallery.action(Browser.ACTION + 58); check(b.gallery.overview_start > 0, "Long synopsis scrolls")
	b.back(); check(b.view == "detail" and b.gallery.selected_part == 1, "Synopsis back retains selected part")
	var detail_start: int = b.gallery.detail_start
	b.gallery.action(Gallery.TAG)
	check(platform.requests[request_id(b, "browse")].tags == ["tag1"], "Content tags query related films")
	check(not platform.requests[request_id(b, "browse")].has("watched") and not platform.requests[request_id(b, "browse")].has("parent_id"), "Tag browsing drops unrelated previous filters")
	b.back(); check(b.view == "detail" and b.gallery.selected_part == 1 and b.gallery.detail_start == detail_start, "Tag results restore the film and detail position")
	var chosen: Array = []; menu.chosen.connect(func(uri, _title): chosen.append(uri))
	b.gallery.action(Browser.ACTION + 30)
	check(chosen == ["medialib://profile/scene/film2"] and b.selection.video_3d_format == "HalfTopAndBottom", "cd2 plays its own identity and layout metadata")
	check(menu.video_queue().map(func(item): return item.uri) == ["medialib://profile/scene/film1", "medialib://profile/scene/film2"], "previous and next playback use the ordered parts")
	b.choose({"scene": movie}); menu.set_compact(true)
	platform.answer(request_id(b, "detail"), {"detail": detail})
	check(menu.compact and b.view == "scenes" and menu.rows.size() == 2, "Late detail data populates the compact part list")
	menu.set_compact(false)
	check(b.view == "detail" and b.detail.actors.size() == 1 and b.detail.images.size() == 2, "Expand restores a detail response that arrived during compact browsing")
	menu.free(); platform.free()
	var video := Video.new(); root.add_child(video); video.set_process(false); var backend := Backend.new(); video.platform = backend
	for mode in ["HalfSideBySide", "FullSideBySide", "HalfTopAndBottom", "FullTopAndBottom"]:
		check(video.open_library("medialib://test/scene/" + mode, "Film", {"basename": "film_180.mp4", "video_3d_format": mode}), "open " + mode)
		check(video.geometry == 1 and video.stereo_sbs and video.top_bottom == mode.ends_with("TopAndBottom") and video.stereo_half == mode.begins_with("Half"), "player applies projection and server packing " + mode)
	video.mode_memory.remember("medialib://test/scene/saved", {"profile": "256x256", "geometry": 3, "stereo_sbs": false, "swap_eyes": false, "alpha_requested": false})
	video.open_library("medialib://test/scene/saved", "Film", {"basename": "film_180.mp4", "video_3d_format": "HalfSideBySide"})
	check(video.geometry == 3 and not video.stereo_sbs, "saved per-file choice wins over Emby metadata")
	video.free()
	for failure in failures: push_error(failure)
	print("Emby poster wall checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
