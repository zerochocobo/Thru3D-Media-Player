extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_archive_loading.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/rar-small-cache/ui")
func _initialize() -> void: run.call_deferred()
func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
func run() -> void:
	var privacy := preload("res://scripts/media_privacy.gd")
	var previous := privacy.mode; privacy.configure(privacy.NONE)
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400,1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR; environment.environment.background_color = Color(.18,.21,.25); viewport.add_child(environment)
	var camera := Camera3D.new(); camera.fov = 52; camera.position = Vector3(0,0,1.5); viewport.add_child(camera)
	var checked := 0
	for language in ["zh","zh_TW","en","ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for compact in [false, true]:
			var library := Library.new(); var host := Fixture.Host.new(); library.platform = host
			viewport.add_child(library); library.visible = true; library.set_process(false); library.set_compact(compact)
			library._set_backdrop(Vector2(1.68,1.44),Vector2(.13,.015))
			library.archives.open({"uri":"cloud://fixture/book.rar","title":"book.rar"})
			for percent in [0,37,100]:
				library.archives.accept_result(42,JSON.stringify({"state":"loading","received":percent,"total":100})); library.archives.tick()
				await frames()
				var panel: MeshInstance3D = library._backdrop
				var label: Label3D = library.archives.progress_label
				if panel.position != Vector3.ZERO or Vector2(label.position.x,label.position.y) != Vector2.ZERO:
					push_error("Archive modal is not centred"); quit(1); return
				if not label.text.ends_with(" %d%%" % percent): push_error("Archive percent not rendered"); quit(1); return
				var path := output.path_join("loading-%s-%s-%03d.png" % [language,"compact" if compact else "library",percent])
				if viewport.get_texture().get_image().save_png(path) != OK: quit(1); return
				checked += 1
			library.archives.close(); library.queue_free(); await frames()
	privacy.configure(previous)
	print("Archive loading UI: %d images checked" % checked)
	quit(0)
