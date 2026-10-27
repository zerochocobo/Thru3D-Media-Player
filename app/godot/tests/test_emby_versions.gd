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

func movie() -> Dictionary:
	return {"id": "film", "uri": "medialib://profile/scene/film", "title": "A film", "description": "A film description.", "position_ms": 40000,
		"versions": [
			{"id": "film", "source_id": "1", "version_name": "1", "uri": "medialib://profile/scene/film?source=1", "title": "A film · 1", "basename": "A film - 1.mp4", "duration_ms": 60000, "position_ms": 0, "default_version": true, "width": 1920, "height": 1080, "markers": []},
			{"id": "film", "source_id": "2", "version_name": "2", "uri": "medialib://profile/scene/film?source=2", "title": "A film · 2", "basename": "A film - 2.mp4", "duration_ms": 90000, "position_ms": 0, "width": 3840, "height": 2160, "markers": [{"title": "Second chapter", "position_ms": 30000}]}]}

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new(); var catalog := Catalog.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER; menu.catalog = catalog
	var b: RefCounted = menu.server_browser
	b.server = {"id": "profile", "name": "NAS", "provider": "emby"}; b.capabilities = {"artwork": true, "home_layout": "libraries", "navigation": []}
	b.view = "detail"; b.detail = movie(); b.detail.erase("versions"); menu.refresh()
	var old_text: String = menu.text_snapshot(); var old_buttons: Array = menu._buttons.map(func(button): return [button.target, button.rect])
	b.detail.versions = [movie().versions[0]]; menu.refresh()
	check(menu.text_snapshot() == old_text and menu._buttons.map(func(button): return [button.target, button.rect]) == old_buttons, "one version preserves the existing text, controls and geometry")
	check(not menu._buttons.any(func(button): return button.target == Browser.ACTION + 59), "single source has no version selector")
	b.detail = movie(); menu.refresh()
	check(menu._buttons.any(func(button): return button.target == Browser.ACTION + 59), "multiple sources add a selector in detail")
	check(b.gallery.playback_node().source_id == "1" and b.gallery.playback_node().position_ms == 0, "default version never borrows ambiguous item progress")
	var selector: Dictionary = menu._buttons.filter(func(button): return button.target == Browser.ACTION + 59)[0]
	var pose: Transform3D = selector.node.global_transform
	check(menu.press_pointer("right_hand", pose.origin + pose.basis.z * 0.3, -pose.basis.z, true), "version selector accepts ray press")
	menu.release_pointer("right_hand", pose.origin + pose.basis.z * 0.3, -pose.basis.z, true)
	check(b.view == "versions" and menu.rows.size() == 2, "ray opens version file list")
	check(menu.rows[0].selected and menu.rows[1].detail == "A film - 2.mp4", "list shows current selection and filenames")
	menu.stick_scroll(1, 0.1); menu.stick_scroll_horizontal(1, 0.1)
	check(b.view == "versions" and b.gallery.playback_node().source_id == "1", "sticks only scroll and never change the selected file")
	b.choose(menu.rows[1])
	check(b.view == "detail" and b.gallery.playback_node().source_id == "2", "selection returns to the same film detail")
	check(b.gallery.playback_node().duration_ms == 90000 and b.gallery.playback_node().width == 3840, "detail metadata follows selected file")
	b.open_versions(); b.back()
	check(b.gallery.playback_node().source_id == "2", "back without selection preserves current version")
	b.gallery.action(Browser.ACTION + 38)
	check(menu.rows.any(func(row): return row.has("marker") and row.marker.title == "Second chapter"), "metadata uses selected version chapters")
	b.back()
	var chosen: Array = []; menu.chosen.connect(func(uri, title): chosen.append([uri, title]))
	b.entries = [{"id": "film", "uri": "medialib://profile/scene/film"}, {"id": "other", "uri": "medialib://profile/scene/other"}]
	b.gallery.action(Browser.ACTION + 30)
	check(chosen.size() == 1 and chosen[0][0] == "medialib://profile/scene/film?source=2", "play signal carries exact selected source URI")
	check(b.playback_entries()[0].uri == chosen[0][0] and b.playback_entries().size() == 2, "play queue keeps selected identity without treating versions as consecutive episodes")
	b.entries = [{"id": "film", "uri": "medialib://other-account/scene/film"}]
	check(b.playback_entries()[0].uri == "medialib://other-account/scene/film", "same item ID in another account cannot inherit the chosen version")
	menu.toggle(); b.selection.clear(); b.view = "home"; b.home_data = {"libraries": [], "recent_opened": [movie()]}
	catalog.records = [{"uri": "medialib://profile/scene/film?source=2", "title": "A film · 2", "duration_ms": 90000, "position_ms": 12000}, {"uri": "medialib://profile/scene/film?source=1", "title": "A film · 1", "duration_ms": 60000, "position_ms": 5000}]
	var history: Array = b.home_recent_entries()
	check(history.size() == 1 and history[0].id == "film" and history[0].uri.ends_with("source=2"), "recent row merges by item while retaining latest exact version")
	b.choose({"scene": history[0], "recent_opened": true})
	check(platform.requests[platform.next].scene_id == "film", "detail API receives item ID without source query")
	platform.answer(platform.next, {"detail": movie()})
	check(b.gallery.playback_node().source_id == "2" and b.gallery.playback_node().position_ms == 12000, "recent detail restores selected version and its progress")
	b.open_versions(); b.choose(menu.rows[0])
	check(b.gallery.playback_node().source_id == "1" and b.gallery.playback_node().position_ms == 5000, "switching versions restores each file's own local progress")
	check(preload("res://scripts/media_location.gd").infer("medialib://profile/scene/film?source=2").item_id == "film", "source navigation keeps library item identity")
	check(preload("res://scripts/file_mode_memory.gd").key_for(movie().versions[0].uri) != preload("res://scripts/file_mode_memory.gd").key_for(movie().versions[1].uri), "per-file settings use independent version identities")
	b.detail.parts = [movie().merged({"part_label": "cd1"}), {"id": "cd2", "uri": "medialib://profile/scene/cd2", "part_label": "cd2"}]
	b.gallery.selected_part = 0; b.selection = b.gallery.playback_node(); menu.refresh()
	check(b.playback_entries().size() == 2 and b.playback_entries()[0].uri.ends_with("source=1") and b.playback_entries()[1].id == "cd2", "multipart queue preserves selected version for each part")
	b.gallery.action(Gallery.PART + 1)
	check(not menu._buttons.any(func(button): return button.target == Browser.ACTION + 59), "switching to a single-source part hides selector")
	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("Emby versions checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
