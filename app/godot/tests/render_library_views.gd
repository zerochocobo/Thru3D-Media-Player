extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_library_views.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func entries() -> Array:
	return [
		{"id": "/disk/3D", "title": "3D Movies", "container": true, "modified": 1791820800000, "child_count": 12},
		{"id": "/disk/film", "title": "【蓝光3D】山海之旅 — 完整版 2024.SBS.2160p.mkv", "uri": "smb://nas/film", "size": 12884901888, "modified": 1791820800000},
		{"id": "/disk/photo", "title": "京都 · 秋日の散歩.jpg", "uri": "file:///photo.jpg", "kind": "image", "size": 7340032, "modified": 1791820800000, "width": 4000, "height": 3000},
		{"id": "/disk/no-duration", "title": "Live concert — part two.mp4", "uri": "cloud://drive/live", "size": 4294967296},
		{"id": "/disk/dlna", "title": "Sunrise at the coast.mp4", "uri": "http://example.invalid/video", "duration_ms": 4920000, "width": 3840, "height": 2160},
		{"id": "/disk/unknown", "title": "Long filename without additional metadata.mp4", "uri": "cloud://drive/unknown"},
		{"id": "/disk/small", "title": "Short clip.mp4", "uri": "file:///clip", "size": 524288, "duration_ms": 65000}]
func run() -> void:
	var output := OS.get_environment("QUEST_LIBRARY_VIEWS_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 900); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.visible = true
	var catalog := Test.Catalog.new(); menu.catalog = catalog
	catalog.entries = {
		"smb://nas/film": {"uri": "smb://nas/film", "title": "【蓝光3D】山海之旅 — 完整版 2024.SBS.2160p.mkv", "position_ms": 2292000, "duration_ms": 6120000},
		"cloud://drive/live": {"uri": "cloud://drive/live", "title": "Live concert — part two.mp4", "position_ms": 985000, "duration_ms": -1},
		"file:///photo.jpg": {"uri": "file:///photo.jpg", "title": "京都 · 秋日の散歩.jpg", "kind": "image", "position_ms": 0, "duration_ms": -1}}
	var raw := entries()
	for language in ["zh", "zh_Hant", "ja", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		for source_name in ["local", "smb", "dlna", "cloud", "server", "search", "recent"]:
			menu.cloud_search.close(); menu.scroll = 0.0
			menu._local_stack = [{"id": "/disk", "title": "Movies"}]; menu._smb_server = "nas"; menu._smb_path = "Movies"; menu._dlna_server = "dlna"; menu._dlna_stack = [{"id": "0", "title": "Movies"}]; menu._cloud_stack = [{"id": "/drive", "title": "Drive"}]
			menu._local_entries = raw; menu._smb_entries = raw; menu._dlna_entries = raw; menu._cloud_entries = raw
			menu.section = {"local": Menu.Section.LOCAL, "smb": Menu.Section.SMB, "dlna": Menu.Section.DLNA, "cloud": Menu.Section.CLOUD, "server": Menu.Section.MEDIA_SERVER, "search": Menu.Section.CLOUD, "recent": Menu.Section.RECENT}[source_name]
			if source_name == "server":
				var browser: RefCounted = menu.server_browser; browser.server = {"id": "demo", "name": "Cinema"}; browser.view = "scenes"; browser.total = 4; browser.end_reached = true
				browser.entries = [
					{"id": "1", "uri": "smb://nas/film", "title": "山海之旅", "year": 2024, "duration_ms": 6120000, "has_cover": false},
					{"id": "2", "uri": "medialib://demo/scene/2", "title": "Ocean in spring", "year": 2023, "duration_ms": 5400000, "watched": true, "has_cover": false},
					{"id": "3", "title": "Documentary collection", "container": true, "child_count": 18, "has_cover": false},
					{"id": "4", "uri": "medialib://demo/scene/4", "title": "Episode with limited metadata", "has_cover": false}]
			if source_name == "search":
				menu.cloud_search.active = true; menu.cloud_search.editing = false; menu.cloud_search.query = "3D"
				menu.cloud_search.entries = [{"title": "【蓝光3D】山海之旅.mkv", "kind": "video", "relative_path": "/Movies/3D/山海之旅.mkv", "size": 12884901888, "search_token": "fixture"}, {"title": "Vacation.jpg", "kind": "image", "relative_path": "/Photos/Vacation.jpg", "search_token": "photo"}]
			for mode in ["list", "grid"]:
				menu.load_view_mode(mode); menu.refresh()
				var label: String = source_name + "-" + language + "-" + mode
				for button in menu._buttons:
					if not menu._row_target(button.target) or mode != "list": continue
					for child in button.node.get_children():
						if not child is Label3D: continue
						var width := menu.text_width(child.text, child.font_size / menu.TEXT_RASTER_SCALE)
						var left: float = child.position.x
						if child.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT: left -= width
						elif child.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER: left -= width * 0.5
						check(left >= -0.62 and left + width <= 0.62, "Row text fits: " + label + ":" + child.text)
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				var image := viewport.get_texture().get_image(); check(not image.is_empty(), "GPU image: " + label)
				image.save_png(output.path_join(label + ".png"))
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "images": 56}, "\t"))
	menu.queue_free(); viewport.queue_free(); await process_frame
	print("Library view render checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
