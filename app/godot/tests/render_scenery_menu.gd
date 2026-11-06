extends SceneTree
const Menu:=preload("res://scripts/scenery_menu.gd")
const Library:=preload("res://scripts/background_library.gd")
const I18n:=preload("res://scripts/i18n.gd")
func save_frame(viewport: SubViewport,camera: Camera3D,menu: Node3D,path: String) -> void:
	var a:=camera.unproject_position(menu.to_global(Vector3(-.80,menu._top+.055,0)))
	var b:=camera.unproject_position(menu.to_global(Vector3(.80,menu._bottom-.22,0)))
	var rectangle:=Rect2i(Vector2i(a.floor()),Vector2i((b-a).ceil())).intersection(Rect2i(Vector2i.ZERO,viewport.size))
	viewport.get_texture().get_image().get_region(rectangle).save_png(path)
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	I18n.use("zh")
	var output:=ProjectSettings.globalize_path("res://../../build/output/scenery-ui")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport:=SubViewport.new(); viewport.size=Vector2i(1500,1500); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera:=Camera3D.new(); camera.current=true; viewport.add_child(camera)
	var library:=Library.new(); library.directory=output.path_join("library-"+str(Time.get_ticks_usec())); viewport.add_child(library)
	library.import_source({"path":ProjectSettings.globalize_path("res://backgrounds/belfast_sunset_puresky.jpg"),"geometry":3},"暮色全景")
	library.import_source({"path":ProjectSettings.globalize_path("res://backgrounds/kloppenheim_06_puresky.jpg"),"geometry":3},"晨光全景")
	while library.busy: await process_frame
	var first_id:=str(library.assets.keys()[0])
	library.bind("image",first_id)
	var menu:=Menu.new(); menu.library=library
	menu.state_provider=func(mode): return {"selected":"cinema" if mode=="global" else first_id,"choice":"cinema" if mode=="global" else "custom","status":"","busy":library.busy,"import_progress":library.import_progress}
	viewport.add_child(menu); menu.open("global")
	for view in ["scene","manage","adjust"]:
		menu.view=view; menu.refresh()
		await create_timer(.15).timeout; await RenderingServer.frame_post_draw
		save_frame(viewport,camera,menu,output.path_join(view+".png"))
	menu.view="manage"; menu._activate(menu.HELP)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("requirements.png"))
	I18n.use("en"); menu.refresh()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("requirements-en.png"))
	I18n.use("zh"); menu.navigate_back()
	menu.view="scene"
	menu.session_controls_provider=func(): return {"cinema_visible":true,"cinema_lights":"auto","cinema_moving":false,"passthrough_visible":true}
	menu.refresh()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("cinema-footer.png"))
	menu.session_controls_provider=Callable()
	menu.view="manage"; menu.modal="rename"; menu.draft="暮色全景"; menu.refresh()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("rename.png"))
	menu.modal="delete"; menu.selected=[first_id]; menu.refresh()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("delete.png"))
	menu.open("image")
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("image.png"))
	# Use real unmarked files and real thumbnails for the confirmation-step preview.
	var unmarked:=output.path_join("unmarked-review.png")
	var picture:=Image.load_from_file(ProjectSettings.globalize_path("res://backgrounds/belfast_sunset_puresky.jpg"))
	picture.resize(1024,512); picture.save_png(unmarked)
	var square:=output.path_join("square-review.png")
	picture.resize(512,512); picture.save_png(square)
	library.set_process(false)
	library.import_files([{"uri":unmarked,"title":"暮色全景"},{"uri":square,"title":"180° 全景"}]); library._process(0)
	menu.begin_import()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("import.png"))
	library.set_process(true)
	while library.busy: await process_frame
	menu.finish_import(library.import_progress)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("review.png"))
	library.approve_reviews(library.reviews.keys())
	var ordinary:=output.path_join("ordinary-error.png")
	picture.resize(640,480); picture.save_png(ordinary)
	library.import_files([{"uri":ordinary,"title":"普通图片.png"}])
	while library.busy: await process_frame
	menu.finish_import(library.import_progress)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("import-error-ratio.png"))
	var large:=output.path_join("large-error.png")
	var bytes:=FileAccess.get_file_as_bytes(ordinary)
	for pair in [[16,16384],[20,8192]]:
		for i in range(4): bytes[pair[0]+i]=(pair[1]>>(24-8*i))&255
	FileAccess.open(large,FileAccess.WRITE).store_buffer(bytes)
	library.import_files([{"uri":large,"title":"超大全景.png"}])
	while library.busy: await process_frame
	menu.finish_import(library.import_progress)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("import-error-size.png"))
	library.import_files([{"uri":unmarked,"title":"暮色全景.png"},{"uri":output.path_join("missing.png"),"title":"无法读取的图片.png"}])
	while library.busy: await process_frame
	menu.finish_import(library.import_progress)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	save_frame(viewport,camera,menu,output.path_join("partial-import.png"))
	menu.free()
	var controls:=preload("res://scripts/photo_menu.gd").new()
	controls.state_provider=func(): return {"has_image":true,"title":"暮色全景","geometry":3,"can_background":true,"count":1,"index":0,"source_size":"8192 × 4096"}
	viewport.add_child(controls); controls.visible=true; controls.refresh()
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	var a:=camera.unproject_position(controls.to_global(Vector3(-.68,.32,0)))
	var b:=camera.unproject_position(controls.to_global(Vector3(.68,-.47,0)))
	viewport.get_texture().get_image().get_region(Rect2i(Vector2i(a.floor()),Vector2i((b-a).ceil()))).save_png(output.path_join("current-panorama.png"))
	controls._activate(11)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	a=camera.unproject_position(controls.to_global(Vector3(-.68,.32,0)))
	b=camera.unproject_position(controls.to_global(Vector3(.68,-.78,0)))
	viewport.get_texture().get_image().get_region(Rect2i(Vector2i(a.floor()),Vector2i((b-a).ceil()))).save_png(output.path_join("panorama-settings.png"))
	controls.state_provider=func(): return {"has_image":true,"title":"暮色全景","geometry":0,"can_background":false,"background_issue":preload("res://scripts/panorama_background_rules.gd").PROJECTION,"count":1,"index":0,"source_size":"8192 × 4096"}
	controls.refresh()
	var button: Dictionary=controls._buttons.filter(func(item): return item.target==controls.PHOTO_BACKGROUND)[0]
	controls.update_pointer("right_hand",button.node.global_position+button.node.global_basis.z*.4,-controls.global_basis.z,true)
	await create_timer(.15).timeout; await RenderingServer.frame_post_draw
	a=camera.unproject_position(controls.to_global(Vector3(-.68,.32,0)))
	b=camera.unproject_position(controls.to_global(Vector3(.68,-.94,0)))
	viewport.get_texture().get_image().get_region(Rect2i(Vector2i(a.floor()),Vector2i((b-a).ceil()))).save_png(output.path_join("image-background-guidance.png"))
	viewport.free(); print("SCENERY_UI_RENDER_OK"); quit()
