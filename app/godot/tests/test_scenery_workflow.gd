extends SceneTree
const Main:=preload("res://scripts/main.gd")
const Rules:=preload("res://scripts/panorama_background_rules.gd")
var checks:=0
var failures: Array=[]
var app: Node
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: failures.append(message); printerr(message)
func _initialize() -> void: _run.call_deferred()
func settle(controller: Node) -> void:
	var deadline:=Time.get_ticks_msec()+15000
	while (controller.library.busy or not controller._pending.is_empty()) and Time.get_ticks_msec()<deadline: await process_frame
	check(not controller.library.busy and controller._pending.is_empty(),"Background work settles")
func tap(menu: Node,target: int) -> void:
	app._menu_touched_ms=Time.get_ticks_msec()
	var found: Array=menu._buttons.filter(func(item): return item.target==target)
	check(not found.is_empty() and found[0].enabled,"Visible action is enabled: %d"%target)
	if found.is_empty(): return
	var point: Vector3=found[0].node.global_position+found[0].node.global_basis.z*.4
	check(int(menu.ray_hit(point,-menu.global_basis.z).get("target",-1))==target,"Ray hits the intended action: %d"%target)
	menu.press_pointer("right_hand",point,-menu.global_basis.z,true)
	menu.release_pointer("right_hand",point,-menu.global_basis.z,true)
func _run() -> void:
	var directory:=ProjectSettings.globalize_path("res://../../build/output/scenery-workflow-")+str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	var config:=ConfigFile.new(); config.set_value("appearance","background","dark"); config.set_value("effects","auto_3d",false); config.set_value("ui","language","zh")
	var path:=directory.path_join("settings.cfg"); config.save(path)
	var main:=Main.new(); app=main; main.settings_path=path; root.add_child(main); await process_frame
	var controller: Node=main.scenery
	var menu: Node=main.photo_menu
	var source:=directory.path_join("current.png")
	var image:=Image.create(256,128,false,Image.FORMAT_RGB8); image.fill(Color(.2,.5,.7)); image.save_png(source)
	main.photo.open_image("file://"+source,"Current image")
	var deadline:=Time.get_ticks_msec()+10000
	while main.photo.loading and Time.get_ticks_msec()<deadline: await process_frame
	main.photo.finish_transition(); main.photo.set_projection(3)
	main.photo_active=true; main.player_menu=menu; main.recent_menu.visible=false; menu.visible=true; menu.section=0; menu.refresh()
	check(main.photo.can_background(),"Current panorama can be used directly")
	check(not menu._buttons.any(func(item): return item.target==menu.PHOTO_SCENERY),"Old background-management icon stays removed")
	check(not menu._buttons.any(func(item): return item.target in [menu.PHOTO_BACKGROUND,menu.PHOTO_GLOBAL_BACKGROUND]),"Playback control bar does not add background-setting actions")
	tap(menu,11)
	check(menu.section==1,"Current panorama background actions belong to the existing player settings panel")
	main.photo.set_projection(0); menu.refresh()
	check(main.photo.background_issue()==Rules.PROJECTION and not main.photo.can_background(),"Flat panorama viewing explains how to choose a supported projection")
	var disabled: Dictionary=menu._buttons.filter(func(item): return item.target==menu.PHOTO_BACKGROUND)[0]
	menu.update_pointer("right_hand",disabled.node.global_position+disabled.node.global_basis.z*.4,-menu.global_basis.z,true)
	check(not disabled.enabled and menu._tooltip.visible and menu._tooltip.get_child(0).text.contains(menu.I18n.t(Rules.PROJECTION)),"Disabled background action exposes corrective guidance to a real ray")
	main.photo.set_projection(3); menu.refresh()
	check(main.photo.background_issue().is_empty() and main.photo.can_background(),"Choosing 360 degrees immediately clears the restriction")
	var uri: String=main.photo.local_uri
	tap(menu,menu.PHOTO_BACKGROUND)
	check(main._photo_menu_state().photo_background_saving,"Current-image button shows saving immediately")
	await settle(controller)
	var id:=str(controller.library.bindings.image.id)
	check(controller.library.assets.has(id) and main.photo_background.choice=="custom","Viewing action imports and applies to image mode")
	check(main.background.choice=="dark","Image action leaves global scope unchanged")
	check(main._photo_menu_state().photo_background_applied and not main._photo_menu_state().photo_background_saving,"Image action reports completion")
	tap(menu,menu.PHOTO_GLOBAL_BACKGROUND); await settle(controller)
	check(controller.library.bindings.global.id==id and controller.library.assets.size()==1,"Global action reuses the same content asset")
	check(main._photo_menu_state().photo_global_background_applied,"Global action reports its own scope")
	check(main.photo.local_uri==uri and main.photo.geometry==3 and main.photo_active and menu.visible,"Direct actions preserve the viewed panorama and its menu")
	controller.open(menu)
	tap(main.scenery_menu,main.scenery_menu.HELP)
	check(main.scenery_menu.modal=="requirements" and controller.library.bindings.image.id==id,"Requirements open on demand without changing the selected background")
	tap(main.scenery_menu,main.scenery_menu.BACK)
	check(main.scenery_menu.modal.is_empty() and main.scenery_menu.mode=="image","Closing help preserves the image-mode context")
	controller.use_native_dialogs=false; controller._begin_import()
	var unmarked:=directory.path_join("unmarked.png"); image.fill(Color(.6,.3,.1)); image.save_png(unmarked)
	var square:=directory.path_join("square.png"); image.resize(128,128); image.save_png(square)
	main.recent_menu.audio_selection={unmarked:{"uri":unmarked,"title":"Panorama 360"},square:{"uri":square,"title":"Panorama 180"}}
	main.recent_menu._activate(main.recent_menu.BACKGROUND_PICKER_DONE)
	check(main.scenery_menu.visible and main.scenery_menu.view=="import","Picker returns straight to a visible import step")
	check(controller.library.import_progress.total==2,"Central progress counts the selected images")
	await settle(controller)
	var scenery: Node=main.scenery_menu
	check(scenery.view=="review" and scenery._cards.size()==2,"Unmarked images open their previews automatically")
	check(scenery.selected.size()==2,"Review starts ready to confirm without another selection step")
	check(scenery._cards.all(func(item): return controller.library.texture(item.id)!=null),"Every review candidate has an actual preview")
	check(scenery._cards.map(func(item): return item.geometry).has(1) and scenery._cards.map(func(item): return item.geometry).has(3),"Review identifies VR180 and 360 projections")
	tap(scenery,scenery.APPROVE)
	check(scenery.view=="manage" and controller.library.assets.size()==3,"One confirmation opens the added backgrounds")
	check(controller.library.bindings.image.id==id and controller.library.bindings.global.id==id,"Adding to the library does not silently change either active background")
	controller._import_files([{"uri":unmarked,"title":"Same panorama"}]); await settle(controller)
	check(scenery.view=="manage" and controller.library.reviews.is_empty(),"Known content completes directly without repeated confirmation")
	var ordinary:=directory.path_join("ordinary.png"); image.resize(128,96); image.save_png(ordinary)
	controller._import_files([{"uri":ordinary,"title":"Ordinary image"}]); await settle(controller)
	check(scenery.view=="import_error" and controller.library.import_progress.failed==1,"Rejected input has a clear error step")
	check(scenery._buttons.any(func(item): return item.target==scenery.ADD and item.enabled),"Error step offers choosing another image")
	check(controller.library.error==Rules.RATIO and controller.library.import_progress.errors[0].reason==Rules.RATIO,"Import failure names the ratio requirement instead of saying unsupported")
	controller._import_files([{"uri":unmarked,"title":"Known panorama"},{"uri":directory.path_join("missing.png"),"title":"Missing image"}]); await settle(controller)
	check(scenery.view=="manage" and controller.library.import_progress.existing==1 and controller.library.import_progress.added==0 and controller.library.import_progress.failed==1,"Mixed results distinguish existing content from failed input")
	tap(scenery,scenery.ISSUES)
	check(scenery.modal=="issues" and controller.library.import_progress.errors[0].reason==Rules.READ,"Mixed results retain a readable per-file failure reason")
	tap(scenery,scenery.HELP); tap(scenery,scenery.BACK)
	check(scenery.modal=="issues","Requirements return to the failure detail they were opened from")
	tap(scenery,scenery.BACK)
	check(scenery.modal.is_empty() and scenery.view=="manage","Failure details return to the added backgrounds")
	scenery.dismiss()
	check(menu.visible and main.photo.local_uri==uri,"Closing management restores the original viewing context")
	main.free(); await process_frame
	print("Scenery workflow: %d checks, %d failures"%[checks,failures.size()]); quit(0 if failures.is_empty() else 1)
