extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_archive_comics.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/comic-archives/ui")
func _initialize() -> void: run.call_deferred()
func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
func cached_images(library: Node) -> void:
	var path := ProjectSettings.globalize_path("res://../../build/output/comic-archives/fixtures/pages/2.png")
	if not FileAccess.file_exists(path): return
	var image := Image.load_from_file(path)
	for row in library.rows:
		if row.has("thumbnail_key"): library.Thumbnails.store(str(row.thumbnail_key), image)
	library.refresh()
func run() -> void:
	var privacy := preload("res://scripts/media_privacy.gd")
	var previous_mode := privacy.mode
	privacy.configure(privacy.NONE)
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400,1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color(.18,.21,.25); viewport.add_child(environment)
	var camera := Camera3D.new(); camera.fov = 52; camera.position = Vector3(0,0,1.5); viewport.add_child(camera)
	for language in ["zh","en","ja"]:
		preload("res://scripts/i18n.gd").use(language)
		var library := Library.new(); var host := Fixture.Host.new(); library.platform = host
		host.values.assign(["comic-test", "example 123", "密码 示例", "long-example-password-0123456789-ABCDEFG", "book-five", "book-six"])
		viewport.add_child(library); library.visible = true; library.set_process(false)
		library.archives.manage(); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("book-%s.png" % language))
		library.archives.managing = false; library.archives.message = "Archive password required or incorrect"
		library.archives.password = "comic-test"; library.archives.persist = true; library.refresh(); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("unlock-%s.png" % language))
		library.archives.message = "Archive format or compression is not supported"; library.refresh(); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("unsupported-%s.png" % language))
		library.archives.entries.assign([
			{"path":"第02章/002.png","kind":"image","uri":"comic://render/1"},
			{"path":"第02章/010.png","kind":"image","uri":"comic://render/2"},
			{"path":"第02章/附录/001.png","kind":"image","uri":"comic://render/3"},
			{"path":"第10章/001.png","kind":"image","uri":"comic://render/4"},
			{"path":"封面.png","kind":"image","uri":"comic://render/0"},
			{"path":"readme.txt","kind":"file"}])
		library.archives.target = {"uri":"file:///漫画合集.zip", "title":"漫画合集.zip"}
		library.archives.managing = false; library.archives.ready_data = {"session":"render"}
		library.archives.finish_open(); cached_images(library); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("directory-root-%s.png" % language))
		library.archives.change_directory("第02章"); cached_images(library); library.set_view_mode("list"); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("directory-nested-%s.png" % language))
		library.set_compact(true); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("directory-compact-%s.png" % language))
		library.queue_free(); await frames()
	privacy.configure(previous_mode)
	print("Archive comic UI rendered")
	quit()
