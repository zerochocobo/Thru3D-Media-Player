extends SceneTree
const Main := preload("res://scripts/main.gd")
var checks:=0
var failures: Array=[]
func check(value: bool,message: String) -> void:
	checks+=1
	if not value: failures.append(message); printerr(message)
func _initialize() -> void: _run.call_deferred()
func wait_for(controller: Node) -> void:
	var deadline:=Time.get_ticks_msec()+20000
	while (controller.library.busy or not controller._pending.is_empty() or not controller._delete.is_empty()) and Time.get_ticks_msec()<deadline: await process_frame
	check(not controller.library.busy and controller._pending.is_empty(),"Scene jobs finish")
func _run() -> void:
	var directory:=ProjectSettings.globalize_path("res://../../build/output/scenery-integration-")+str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	var config:=ConfigFile.new(); config.set_value("appearance","background","dark"); config.set_value("ui","language","zh")
	var settings_path:=directory.path_join("settings.cfg"); config.save(settings_path)
	var main:=Main.new(); main.settings_path=settings_path; root.add_child(main)
	await process_frame
	var scenery: Node=main.scenery
	main._show_full_library()
	main.recent_menu.section=main.LibraryMenu.Section.SETTINGS; main.recent_menu.tab=main.recent_menu.GENERAL_TAB; main.recent_menu.refresh()
	check(not main.recent_menu._buttons.any(func(item): return item.target==main.recent_menu.TAB_BASE+main.recent_menu.BACKGROUND_TAB),"Global settings no longer expose a Background tab")
	var before: Array=main.recent_menu.rows.duplicate(true)
	main.recent_menu._activate_footer(main.recent_menu.SCENERY)
	check(main._active_menu()==main.scenery_menu,"Global footer owns modal input")
	check(not main.recent_menu.visible,"Parent footer is hidden")
	check(main.scenery_menu.mode=="global","Video/library defaults to global scope")
	main._navigate_back()
	check(main.recent_menu.visible and main.recent_menu.rows==before,"Close restores exact parent content")
	var source:=directory.path_join("pano.png")
	var image:=Image.create(128,64,false,Image.FORMAT_RGB8); image.fill(Color(.2,.3,.5)); image.save_png(source)
	scenery.library.import_source({"path":source,"geometry":3},"Test panorama")
	await wait_for(scenery)
	var id:=str(scenery.library.assets.keys()[0])
	main.photo_active=true; main.player_menu=main.photo_menu
	main.photo_menu.section=0; main.photo_menu.refresh()
	check(not main.photo_menu._buttons.any(func(item): return item.target==main.photo_menu.PHOTO_SCENERY),"Image control bar removes its old background entry")
	scenery.open(main.recent_menu)
	check(main.scenery_menu.mode=="image","Image context defaults to image mode")
	main.scenery_menu._activate(main.scenery_menu.MODE)
	check(main.scenery_menu.mode=="global","User can explicitly choose global scope")
	main.scenery_menu.dismiss(); scenery.open(main.photo_menu)
	check(main.scenery_menu.mode=="image","Reopening from image controls resets scope to image rather than last global tab")
	scenery.select("image",id); await wait_for(scenery)
	check(main.photo_background.choice=="custom" and main.background.choice=="dark","Image choice does not change global background")
	check(main.photo_background.ready_sky()!=null,"Selected custom image renders")
	check(scenery.library.bindings.image.id==id,"Mode binding commits after load")
	scenery.use_native_dialogs=false; scenery._begin_import()
	check(main.recent_menu.background_picker_mode and not main.scenery_menu.visible,"Shared picker temporarily owns input")
	check(not main.recent_menu._buttons.filter(func(item): return item.target==main.recent_menu.SCENERY)[0].enabled,"Background import cannot recursively open another scene modal")
	main.recent_menu.audio_selection={source:{"uri":source,"title":"pano.png"}}
	main.recent_menu._activate(main.recent_menu.BACKGROUND_PICKER_DONE)
	await wait_for(scenery)
	check(main.scenery_menu.visible and not main.recent_menu.visible,"Completing import restores scene manager")
	check(scenery.library.assets.size()==1,"Picker imports deduplicate by content")
	scenery._begin_import(); main.recent_menu.dismiss()
	check(main.scenery_menu.visible and not main.recent_menu.background_picker_mode,"Picker cancel restores manager")
	scenery.select("global","belfast")
	check(scenery._pending.global.candidate.sky==null,"Preload candidate prepares data without allocating an unused sky")
	scenery.select("global","dark"); await wait_for(scenery)
	check(main.background.choice=="dark","Rapid requests commit only latest choice")
	check(main.photo_background.choice=="custom","Other scope remains intact")
	var previous: String=main.background.choice
	scenery.library.assets["a".repeat(64)]={"title":"Missing","orientation":1}
	scenery.select("global","a".repeat(64)); await wait_for(scenery)
	check(main.background.choice==previous,"Failed load keeps previous presented scene")
	check(scenery.library.bindings.global.id=="dark","Failed load keeps previous saved binding")
	scenery.library.assets.erase("a".repeat(64))
	scenery.import_current({"path":source,"geometry":3},"Late import","global")
	scenery.select("global","dark"); await wait_for(scenery)
	check(main.background.choice=="dark","Late import cannot override a newer selection")
	main.scenery_menu.view="manage"; main.scenery_menu.refresh()
	var index: int=main.scenery_menu._cards.find_custom(func(item): return item.id==id)
	var rename_target: int=main.scenery_menu.RENAMES+index
	var rename_button: Dictionary=main.scenery_menu._buttons.filter(func(item): return item.target==rename_target)[0]
	var ray_origin: Vector3=rename_button.node.global_position+rename_button.node.global_basis.z*.4
	var ray_direction: Vector3=-rename_button.node.global_basis.z
	var hit: Dictionary=main.scenery_menu.ray_hit(ray_origin,ray_direction)
	check(int(hit.get("target",-1))==rename_target,"Inline rename ray target sits in front of its card")
	main.scenery_menu.press_pointer("left_hand",ray_origin,ray_direction,true)
	main.scenery_menu.release_pointer("left_hand",ray_origin,ray_direction,true)
	check(main.scenery_menu.modal=="rename","Ray click opens rename rather than switching scene")
	main.scenery_menu.editor.cancel(); main.scenery_menu._activate(main.scenery_menu.BACK)
	main.scenery_menu._activate(main.scenery_menu.REMOVES+index)
	check(scenery.library.assets.has(id),"Remove opens confirmation without deleting")
	main.scenery_menu._activate(main.scenery_menu.BACK)
	check(scenery.library.assets.has(id),"Cancel preserves selected asset")
	main.scenery_menu._activate(main.scenery_menu.REMOVES+index)
	main.scenery_menu._activate(main.scenery_menu.CONFIRM); await wait_for(scenery)
	check(not scenery.library.assets.has(id) and main.photo_background.choice=="belfast","Confirmed remove restores the referenced mode")
	check(FileAccess.file_exists(source),"Manager never deletes original image")
	main.scenery_menu.dismiss()
	main._show_full_library()
	main.recent_menu.begin_background_picker()
	check(main.recent_menu.background_picker_mode and main.recent_menu.image_picker_mode,"Batch picker reuses existing image browser")
	main.recent_menu.dismiss()
	check(not main.recent_menu.background_picker_mode,"Cancel clears picker state")
	main.free(); await process_frame
	# Both legacy owned copies migrate to one content identity without removing either source.
	var legacy_config:=ConfigFile.new(); var legacy_paths: Array=[]
	for descriptor in [["appearance","user://backgrounds"],["photo_background","user://photo_backgrounds"]]:
		DirAccess.make_dir_recursive_absolute(descriptor[1])
		var path: String=str(descriptor[1]).path_join("custom_scenery_test_%d.image"%Time.get_ticks_usec())
		DirAccess.copy_absolute(source,path); legacy_paths.append(path)
		legacy_config.set_value(descriptor[0],"background","custom")
		legacy_config.set_value(descriptor[0],"custom_path",path)
		legacy_config.set_value(descriptor[0],"custom_title","Legacy")
	var legacy_settings:=directory.path_join("legacy.cfg"); legacy_config.save(legacy_settings)
	var migrated:=Main.new(); migrated.settings_path=legacy_settings; root.add_child(migrated)
	await wait_for(migrated.scenery)
	check(migrated.background.choice=="custom" and migrated.photo_background.choice=="custom","Both legacy mode selections migrate")
	var presented_sky: Sky=migrated.background.ready_sky()
	check(presented_sky!=null and migrated.background.ready_sky()==presented_sky,"Displayed panorama creates one reusable sky")
	check(migrated.scenery.library.assets.size()==1,"Identical legacy copies deduplicate across modes")
	check(migrated.background.custom_path==migrated.photo_background.custom_path,"Migrated modes share the same immutable asset")
	check(legacy_paths.all(func(path): return FileAccess.file_exists(path)),"Migration keeps original portable copies")
	legacy_config.load(legacy_settings)
	check(legacy_config.get_value("appearance","background_asset_id")==legacy_config.get_value("photo_background","background_asset_id"),"Stable asset references persist per mode")
	migrated.free(); await process_frame
	var restored:=Main.new(); restored.settings_path=legacy_settings; root.add_child(restored)
	await wait_for(restored.scenery)
	check(restored.background.choice=="custom" and restored.photo_background.choice=="custom","Catalog and mode bindings restore across restart")
	restored.free(); await process_frame
	for path in legacy_paths: DirAccess.remove_absolute(path)
	print("Scenery integration: %d checks, %d failures"%[checks,failures.size()]); quit(0 if failures.is_empty() else 1)
