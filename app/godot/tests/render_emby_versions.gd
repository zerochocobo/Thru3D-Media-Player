extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Data := preload("res://tests/test_emby_versions.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/emby-versions")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "Emby · NAS", "provider": "emby"}
	b.capabilities = {"home_layout": "libraries", "artwork": true, "navigation": [], "favorite_scope": "server"}
	var fixture := Data.new(); var film: Dictionary = fixture.movie(); fixture.free()
	for language in ["zh", "en", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for page in ["single", "multiple", "long", "list"]:
			b.view = "detail"; b.detail = film.duplicate(true); b.gallery.selected_versions.clear()
			b.detail.title = "远山来信" if language == "zh" else "Letters from the Mountains"
			b.detail.description = ("旅途从群山之间开始，穿过宁静湖泊与古老森林。这是一段关于自然与时光的旅程。" if language == "zh" else "A journey through quiet lakes and ancient forests, following the changing seasons across the distant mountains. ").repeat(4)
			if page == "single": b.detail.erase("versions")
			elif page == "long": b.detail.versions[0].version_name = "4K · Director's extended edition · Full Side by Side"
			elif page == "list":
				for i in 8:
					b.detail.versions.append(film.versions[0].merged({"source_id": str(i + 3), "version_name": "4K · Extended edition %d" % (i + 3), "basename": "Letters from the Mountains - extended edition %d.mp4" % (i + 3)}, true))
				b.view = "versions"
			menu._reset_navigation(); menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
			var selectors: Array = menu._buttons.filter(func(button): return button.target == Browser.ACTION + 59)
			check(selectors.size() == (1 if page in ["multiple", "long"] else 0), language + "/" + page + " selector visibility")
			if not selectors.is_empty():
				var selector: Dictionary = selectors[0]
				var label: Label3D = selector.node.get_child(0)
				check(label.get_aabb().size.x < selector.rect.size.x, language + "/" + page + " version caption stays inside button")
				for other in menu._buttons:
					if other.target != selector.target: check(not selector.rect.intersects(other.rect), language + "/" + page + " selector does not overlap another control")
			if page == "list": check(menu._max_scroll() > 0 and menu.rows.size() == 10, language + " long version list scrolls")
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Emby versions render checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
