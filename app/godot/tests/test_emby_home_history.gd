extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Gallery := preload("res://scripts/media_server_gallery.gd")
var checks := 0
var failures: Array[String] = []

class Catalog extends RefCounted:
	var records: Array = []
	func list_recent() -> Array: return records.duplicate(true)

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("_run")
func request_id(b: RefCounted, action: String) -> int:
	for id in b.pending:
		if b.pending[id].action == action: return id
	return -1
func ray(menu: Node3D, x: float) -> Array:
	var origin := menu.to_global(Vector3(x, -0.355, 1))
	return [origin, (menu.to_global(Vector3(x, -0.355, 0)) - origin).normalized()]

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new(); var catalog := Catalog.new()
	catalog.records.append({"uri": "medialib://profile/scene/cd2", "title": "Completed cd2", "position_ms": 0, "duration_ms": 60000, "has_cover": false})
	for i in 6: catalog.records.append({"uri": "medialib://profile/scene/m%d" % i, "title": "Local %d" % i, "position_ms": 0 if i == 0 else 5000, "duration_ms": 60000, "has_cover": false})
	catalog.records.append({"uri": "medialib://other/scene/foreign", "title": "Other account", "position_ms": 5000})
	catalog.records.append({"uri": "file:///local.mp4", "title": "Other source", "position_ms": 5000})
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER; menu.catalog = catalog
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "NAS", "provider": "emby"}; b.open_home()
	var libraries: Array = []
	for i in 9: libraries.append({"id": "lib%d" % i, "title": "Library %d" % i, "has_cover": false})
	platform.answer(request_id(b, "home"), {"capabilities": {"home_layout": "libraries", "artwork": true, "navigation": []}, "libraries": libraries, "recent_opened": [
		{"id": "cd2", "uri": "medialib://profile/scene/cd2", "title": "Server title", "position_ms": 12000, "basename": "film_180-cd2.mp4", "video_3d_format": "FullSideBySide", "has_cover": false},
		{"id": "remote", "uri": "medialib://profile/scene/remote", "title": "Server history", "position_ms": 8000, "has_cover": false}]})
	var history: Array = b.home_recent_entries()
	check(history.size() == 8 and history[0].id == "cd2" and history[0].position_ms == 0, "completed local entries stay visible and override stale server progress")
	check(history[1].id == "m0" and history[1].position_ms == 0, "recently opened entries do not require a positive playback position")
	check(history[0].basename == "film_180-cd2.mp4" and history[0].video_3d_format == "FullSideBySide", "local history keeps matching server metadata")
	check(history.back().id == "remote" and not history.any(func(item): return item.get("title", "").begins_with("Other")), "server history merges without duplicate IDs or other accounts/sources")
	check(menu.rows.size() == 17 and b.entries.size() == 8, "homepage exposes library and recent rows and keeps a recent playback queue")
	check(menu._buttons.filter(func(button): return button.target >= Gallery.RECENT and button.target < Gallery.RECENT + 8).size() == 4, "second row shows four recent cards together")
	check(menu.text_snapshot().contains("Recently opened") and menu._max_scroll() == 0, "recent row heading is visible without creating a vertical list")
	b.gallery.action(Browser.ACTION + 37); b.gallery.action(Browser.ACTION + 44)
	check(b.gallery.library_start == 1 and b.gallery.recent_start == 1, "rows have independent arrow positions")
	var start := ray(menu, -0.36); var moved := ray(menu, -0.67)
	check(menu.press_pointer("left_hand", start[0], start[1], true), "recent row ray press captures")
	menu.update_pointer("left_hand", moved[0], moved[1], true); menu.release_pointer("left_hand", moved[0], moved[1], true)
	check(b.view == "home" and b.gallery.recent_start == 2 and b.gallery.library_start == 1 and b.pending.is_empty(), "recent horizontal drag scrolls without selecting or moving libraries")
	b.gallery.stick_at = 0; menu.stick_scroll_horizontal(1, 0.1)
	check(b.gallery.recent_start == 3 and b.gallery.library_start == 1 and b.pending.is_empty(), "horizontal stick scrolls the recent row after pointing there")
	b.gallery.recent_start = 0; menu.refresh(); b.gallery.action(Gallery.RECENT)
	var detail_id := request_id(b, "detail")
	check(platform.requests[detail_id].scene_id == "cd2" and platform.requests[detail_id].recent_position_ms == 0, "recent card opens the correct item's detail with its local progress")
	platform.answer(detail_id, {"detail": {"id": "cd2", "uri": "medialib://profile/scene/cd2", "title": "Film", "position_ms": 12000, "has_cover": false, "parts": [
		{"id": "cd1", "uri": "medialib://profile/scene/cd1", "part_label": "cd1", "position_ms": 10000, "has_cover": false},
		{"id": "cd2", "uri": "medialib://profile/scene/cd2", "part_label": "cd2", "position_ms": 12000, "has_cover": false}]}})
	check(b.gallery.selected_part == 1 and b.gallery.playback_node().position_ms == 0, "completed recent cd2 selects that part and starts at zero instead of stale server progress")
	b.back(); check(b.view == "home" and b.gallery.library_start == 1 and b.gallery.recent_start == 0, "detail back restores both row positions")
	catalog.records.push_front({"uri": "medialib://profile/scene/new", "title": "Just opened", "position_ms": 0, "has_cover": false}); menu.refresh()
	check(b.home_recent_entries()[0].id == "new", "returning homepage sees new local openings without another server query")
	b.gallery.action(Gallery.RECENT)
	check(b.entries[0].id == "new", "opening a refreshed recent card also refreshes the playback queue")
	b.back()
	catalog.records.clear(); b.home_data.recent_opened = []; b.home_data.libraries = [libraries[0]]; menu.refresh()
	check(not menu._buttons.any(func(button): return button.target >= Gallery.RECENT) and not menu.text_snapshot().contains("Recently opened"), "empty history does not fabricate recent videos")
	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("Emby home history checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
