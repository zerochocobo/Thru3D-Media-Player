extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func request_id(b: RefCounted, action: String) -> int:
	for id in b.pending:
		if b.pending[id].action == action: return id
	return -1
func button(menu: Node, target: int) -> MeshInstance3D:
	for item in menu._buttons:
		if item.target == target: return item.node
	return null
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser
	b.cancel(); b.server = {"id": "display-test", "provider": "emby", "name": "NAS"}
	b.capabilities = {"artwork": true, "sorts": Browser.SORTS, "navigation": ["folders"], "favorite_scope": "server"}
	b.display_preferences_path = "user://settings/display-options-test.cfg"; b.display_preferences.clear()
	b.view = "scenes"; b.library_id = "movies"; b.query = {"mode": "library", "collection_type": "movies"}
	var movie := {"id": "movie", "uri": "medialib://display-test/scene/movie", "title": "ABC-501 A complete server title", "basename": "abc-501_180-cd1.mp4", "has_cover": false}
	b.entries = [movie]; b.total = 1; b.set_display("list", 1)
	check(button(menu, Menu.ROW_BASE).get_children().any(func(node): return node is Label3D and node.text == movie.title), "List renders the complete Emby title rather than its basename")
	check(menu._tips[Menu.ROW_BASE] == movie.title + "\n" + movie.basename, "Tooltip retains both server title and original filename")
	b.entries = [movie.merged({"title": "  "}, true)]; menu.refresh()
	check(button(menu, Menu.ROW_BASE).get_children().any(func(node): return node is Label3D and node.text == movie.basename), "Blank title falls back to the filename")
	b.query = {"mode": "folders", "collection_type": "movies", "parent_id": "parent", "tags": ["keep"]}
	b.entries = []
	for i in 28: b.entries.append({"id": "folder%d" % i, "title": "Folder %d" % i, "type": "Folder", "container": true, "child_count": 1, "has_cover": false})
	b.total = 28; b.set_display("poster", 1)
	check(b.tile_size().x > b.tile_size().y and b.scene_view() == "poster", "Movie folders become landscape without changing the saved poster preference")
	check(b.pending.values().filter(func(req): return req.action == "folder_artwork").size() == 2 and not b.busy and menu.status.is_empty(), "Only two visible folder lookups run without blocking browsing")
	var id := request_id(b, "folder_artwork"); var folder_id: String = platform.requests[id].scene_id
	var inherited := {"id": "unique-film", "image_type": "Thumb", "image_tag": "film-thumb"}
	platform.answer(id, {"image_variants": {"Thumb": inherited}})
	var folder: Dictionary = b.entries.filter(func(node): return node.id == folder_id)[0]
	var shown: Dictionary = b.display_node(folder)
	check(shown.id == folder_id and shown.container and shown.cover_image.id == "unique-film" and shown.has_cover, "Unique movie artwork does not replace the folder identity")
	var calls: int = platform.next; menu.refresh()
	check(not b.pending.values().any(func(req): return req.action == "folder_artwork" and req.scene_id == folder_id), "Resolved folder metadata is cached across redraws")
	check(menu.video_queue().is_empty(), "Decorated folders stay out of the playback queue")
	id = request_id(b, "folder_artwork"); var stale: int = id
	menu._set_scroll(4)
	check(platform.cancelled.has(stale) and not b.pending.has(stale), "Scrolling cancels metadata requests for folders outside the loaded viewport")
	platform.answer(stale, {"image_variants": {"Thumb": inherited}})
	check(not b.folder_artwork.has(b._folder_key(str(platform.requests[stale].scene_id))), "Cancelled metadata cannot decorate a later viewport")
	b.cancel(); b.folder_artwork.clear(); menu._reset_navigation()
	b.entries = [folder.merged({"child_count": 2}, true), folder.merged({"id": "own", "image_variants": {"Thumb": {"id": "own", "image_type": "Thumb"}}, "has_cover": true}, true)]
	menu.refresh()
	check(request_id(b, "folder_artwork") == -1, "Multi-film folders and folders with their own horizontal image need no lookup")
	b.query.collection_type = "tvshows"; menu.refresh()
	check(b.tile_size().y > b.tile_size().x and request_id(b, "folder_artwork") == -1, "TV folders retain the original poster behavior")
	b.query.collection_type = "movies"; b.entries = [folder]; menu.status = ""; menu.refresh()
	id = request_id(b, "folder_artwork")
	platform.answer(id, {"state": "error", "error": "Server unavailable"})
	check(not b.busy and menu.status.is_empty() and request_id(b, "folder_artwork") == -1, "Optional artwork failure preserves browsing and cannot loop on every redraw")
	b.query.collection_type = "movies"; b.entries = []
	for i in 28: b.entries.append(movie.merged({"id": "sort%d" % i, "uri": "medialib://display-test/scene/sort%d" % i}, true))
	b.total = 120; b.loaded_page = 3; b.end_reached = true; menu.refresh(); menu._set_scroll(2)
	var context: Dictionary = b.context_state(); var history_size: int = b.history.size()
	b.action(Browser.ACTION + 4)
	check(b.sorting() and b.view == "scenes" and b.focused() and b.pending.is_empty() and button(menu, Browser.ACTION + 175) != null, "Sort opens a popup over the loaded list without changing page or requesting media")
	check(button(menu, Menu.ROW_BASE) != null and menu.scroll == context.scroll, "Popup leaves the film list and browsing position in place")
	menu.stick_scroll(1, 1)
	check(menu.scroll == context.scroll and not menu._in_list(Vector3(0, 0, 0)), "Popup blocks background list scrolling and drag capture")
	var origin := menu.to_global(Vector3(0.61, 0, 1)); var direction := -menu.global_basis.z
	var gap := menu.ray_hit(origin, direction)
	check(gap.target == Menu.NONE and not gap.enabled, "Gaps inside the popup block rays from reaching the film underneath")
	origin = menu.to_global(Vector3(0.75, -0.45, 1))
	check(menu.ray_hit(origin, direction).target == Browser.ACTION + 177, "Outside popup area offers a dismiss target above the background list")
	menu.press_pointer("left_hand", origin, direction, true); menu.release_pointer("left_hand", origin, direction, true)
	check(not b.sorting() and b.query == context.query and menu.scroll == context.scroll, "Outside click dismisses without selecting a film or changing sort")
	b.action(Browser.ACTION + 4)
	b.action(Browser.ACTION + 171); b.action(Browser.ACTION + 175)
	check(b.sort_query.sort == "title" and b.sort_query.direction == "ASC" and b.query == context.query and b.pending.is_empty(), "Field and direction edit a draft without replacing the visible list")
	b.back()
	check(b.query == context.query and b.history.size() == history_size and b.entries == context.entries, "Back cancels sort edits and restores the existing loaded list")
	b.action(Browser.ACTION + 4); menu.set_compact(true)
	check(b.sort_query.is_empty() and b.view == "scenes" and menu.rows.size() == 28 and b.query == context.query, "Collapsing the browser dismisses the popup and retains the media list")
	menu.set_compact(false)
	b.action(Browser.ACTION + 4); b.action(Browser.ACTION + 171); b.action(Browser.ACTION + 176); b.action(Browser.ACTION + 11)
	var req: Dictionary = platform.requests[request_id(b, "browse")]
	check(req.sort == "title" and req.direction == "DESC" and req.page == 1, "Apply sends title descending to the server starting at page one")
	check(req.parent_id == "parent" and req.tags == ["keep"] and req.library_id == "movies" and b.history.size() == history_size, "Apply preserves folder and filters without adding a spurious Back level")
	check(b.scene_view() == "poster" and b.scene_size() == 1, "Sort persistence keeps the display preference")
	platform.answer(request_id(b, "browse"), {"entries": [movie], "total": 120})
	b.end_reached = false; b.more()
	req = platform.requests[request_id(b, "browse")]
	check(req.page == 2 and req.sort == "title" and req.direction == "DESC", "Next page keeps the same global server sort")
	var restored := Menu.new(); root.add_child(restored)
	restored.server_browser.server = b.server.duplicate(); restored.server_browser.display_preferences_path = b.display_preferences_path; restored.server_browser.load_display_preferences()
	check(restored.server_browser._display_settings().sort == "title" and restored.server_browser._display_settings().direction == "DESC" and restored.server_browser.scene_view() == "poster", "New browser reloads sort direction and existing view together")
	restored.free(); b.cancel()
	b.capabilities.favorite_scope = "local"; b.favorites["display-test"] = [movie.merged({"title": "Film 2"}, true), movie.merged({"id": "ten", "title": "Film 10"}, true)]
	b.query = {"favorites": true, "sort": "title", "direction": "DESC"}
	check(b._local_favorites_query().map(func(node): return node.title) == ["Film 10", "Film 2"], "Local favorite title descending uses numeric-aware ordering")
	b.query.direction = "ASC"
	check(b._local_favorites_query().map(func(node): return node.title) == ["Film 2", "Film 10"], "Local favorites also honor ascending")
	b.view = "detail"; b.detail = movie.duplicate(true); b.detail.actors = []; b.detail.images = []
	for i in 8: b.detail.actors.append({"id": "actor%d" % i, "name": "Actor %d" % i, "has_cover": false})
	for i in 6: b.detail.images.append({"id": "movie", "image_type": "Backdrop", "image_index": i})
	b.gallery.detail_start = 0; menu.refresh()
	var actor_card := button(menu, Gallery.ACTOR)
	check(actor_card.mesh.size.y > actor_card.mesh.size.x, "Actor cards use a portrait layout")
	var actor_label: Label3D = actor_card.get_children().filter(func(node): return node is Label3D and not node.text.is_empty())[0]
	check(actor_label.position.y < 0 and actor_label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "Actor name is centered below the portrait")
	var photo_card := button(menu, Gallery.PHOTO)
	check(photo_card.mesh.size.x / photo_card.mesh.size.y < 1.7, "Artwork cards leave room for roughly three-to-two stills")
	check(actor_card.position.y - actor_card.mesh.size.y / 2 > photo_card.position.y + photo_card.mesh.size.y / 2, "Actor and artwork rows do not overlap")
	check(photo_card.position.y - photo_card.mesh.size.y / 2 > -0.5325, "Artwork clears the bottom tag buttons")
	b.gallery.action(Browser.ACTION + 35)
	check(b.gallery.actor_start == 3 and button(menu, Gallery.ACTOR + 7) != null, "Horizontal actor paging reaches the final portrait")
	b.gallery.action(Gallery.ACTOR + 7)
	req = platform.requests[request_id(b, "browse")]
	check(req.performers == ["actor7"] and req.all_libraries, "Larger portrait still opens related works across all libraries")
	b.back(); b.gallery.action(Gallery.PHOTO + 2)
	check(b.view == "picture" and b.gallery.selected_image == 2, "Larger artwork still opens the selected full image")
	for i in 300: b._cache_folder_artwork("bounded%d" % i, {})
	check(b.folder_artwork.size() == 256 and not b.folder_artwork.has(b._folder_key("bounded0")), "Folder metadata cache has a fixed memory bound")
	b.choose({"refresh_server": true})
	check(b.folder_artwork.is_empty() and b.view == "home", "Explicit server refresh clears stale or failed folder metadata")
	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("Emby display options checks=%d failures=%d" % [checks, failures.size()]); quit(0 if failures.is_empty() else 1)
