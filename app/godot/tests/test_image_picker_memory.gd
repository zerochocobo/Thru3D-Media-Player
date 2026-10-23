extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Memory := preload("res://scripts/directory_browse_memory.gd")
const Location := preload("res://scripts/image_picker_location.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []
var output := ""

class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var serial := 0
	var inserted := 0
	var count := 100
	var omit := -999
	var calls: Array[Dictionary] = []
	var dlna_missing := false
	var discoveries := 0
	func reply(result: Dictionary) -> int:
		serial += 1
		var id := serial
		calls.append(result.duplicate(true))
		(func(): media_list.emit(id, JSON.stringify(result))).call_deferred()
		return id
	func entries(path: String, offset: int = 0, size: int = 10000) -> Array:
		var rows: Array = []
		for i in range(offset, mini(count+inserted,offset+size)):
			var identity := i-inserted
			if identity == omit: continue
			rows.append({"id": "%s/%d" % [path,identity],"uri":"https://fixture/temporary-%d.jpg?token=secret" % identity,
				"title":"Image %03d.jpg" % (identity+10),"kind":"image"})
		return rows
	func media_local_browse(path: String) -> int: return reply({"state":"ready","path":path,"entries":entries(path)})
	func media_smb_browse(server: String, path: String) -> int: return reply({"state":"ready","server_id":server,"path":path,"entries":entries(path)})
	func media_dlna_browse(server: String, path: String) -> int:
		if dlna_missing: return reply({"state":"error","error":"DLNA server unavailable"})
		return reply({"state":"ready","server_id":server,"object_id":path,"entries":entries(path)})
	func media_dlna_discover() -> int:
		discoveries+=1; dlna_missing=false
		return reply({"state":"ready","servers":[{"id":"saved-dlna","name":"Saved"}]})
	func media_cloud_cancel(_id: int) -> void: pass
	func media_cloud_page_options(path: String, offset: int, _force: bool, order: String, _id: String, size: int, _subtitle: bool) -> int:
		return reply({"state":"ready","path":path,"offset":offset,"order":order,"page_size":size,"entries":entries(path,offset,size),
			"total":count+inserted,"raw_count":mini(size,count+inserted-offset),"next_offset":offset+size if offset+size<count+inserted else -1})

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func memory(path: String) -> RefCounted:
	var result:=Memory.new(); result.load_file(path); return result
func menu_for(store: RefCounted, platform: RefCounted) -> Node3D:
	var menu:=Menu.new(); menu.browse_memory=store
	root.add_child(menu); menu.set_process(false); menu.attach_platform(platform); menu.visible=true
	menu.section=Menu.Section.LOCAL; menu._local_stack=[{"id":"/videos","title":"Videos"}]; menu.view_mode="list"
	menu.cloud_pagination.preferences.path=output.path_join("paging.cfg")
	return menu
func settle(menu: Node3D) -> void:
	for i in 120:
		if menu.cloud_pagination.queued: menu.cloud_pagination.queue_at=0
		menu.cloud_pagination.tick(); await process_frame
		if i>=2 and menu._pending.is_empty() and not menu._cloud_busy and menu.cloud_pagination.batch.is_empty() and not menu.cloud_pagination.queued: break
func _initialize() -> void: call_deferred("run")
func run() -> void:
	output=ProjectSettings.globalize_path("res://../../build/output/image-picker-memory/%d" % Time.get_ticks_usec())
	Privacy.vault=null
	for policy in [Privacy.ALL,Privacy.LOCAL,Privacy.NONE]:
		Privacy.configure(policy)
		for source in [Menu.Section.LOCAL,Menu.Section.SMB,Menu.Section.DLNA,Menu.Section.CLOUD]:
			var path:=output.path_join("%s-%d.cfg" % [policy,source])
			var store:=memory(path); var platform:=Platform.new(); var menu:=menu_for(store,platform)
			menu.begin_image_picker(); await settle(menu)
			menu.section=source
			menu._local_stack=[{"id":"/photos","title":"Photos"}]
			menu._smb_server="saved-smb"; menu._smb_path="share/photos"
			menu._dlna_server="saved-dlna"; menu._dlna_stack=[{"id":"album","title":"Album"}]
			menu._cloud_stack=[{"id":"/account/photos","title":"Photos","provider":"115_open","cloud_id":"album-id"}]
			if source==Menu.Section.CLOUD: platform.count=430
			menu._load_section(); await settle(menu); menu.refresh()
			if source==Menu.Section.CLOUD:
				menu.cloud_pagination.jump(1); await settle(menu)
			check(menu.rows.size()>=40,"Image listing loaded / %s %d" % [policy,source])
			if menu.rows.size()<40: menu.free(); continue
			menu._set_scroll(30.25)
			var selected: Dictionary=menu.rows[32]
			var identity: String=menu.Presentation.browse_key(selected)
			var line_offset: float=32-menu.scroll
			menu._choose(selected)
			check(not menu.image_picker_mode and menu._local_path()=="/videos","Choosing restores underlying video directory")
			menu.visible=true; menu.begin_image_picker(); await settle(menu)
			check(menu.section==source and is_equal_approx(menu.scroll,30.25),"Same-session picker restores its own directory and selected image viewport")
			if source==Menu.Section.CLOUD: check(menu._cloud_page==1,"Cloud picker restores the selected image's page")
			menu.dismiss()
			platform.inserted=3
			menu.visible=true; menu.begin_image_picker(); await settle(menu)
			var index: int=menu.Presentation.anchor_index(menu.rows,{"key":identity,"browse":true})
			check(index>=0 and is_equal_approx(float(index)-menu.scroll,line_offset),"Selection identity survives inserted siblings")
			menu.visible=false; menu.free()
			var persistent: bool=policy==Privacy.ALL or (policy==Privacy.LOCAL and source==Menu.Section.LOCAL)
			if source==Menu.Section.DLNA and persistent: platform.dlna_missing=true
			var reboot:=menu_for(memory(path),platform); reboot.begin_image_picker(); await settle(reboot)
			check((reboot.section==source and reboot._local_path()=="/photos" if source==Menu.Section.LOCAL else reboot.section==source) if persistent else reboot.section==Menu.Section.LOCAL and reboot._local_path()=="/videos","Restart follows history policy / %s %d" % [policy,source])
			if persistent:
				if source==Menu.Section.DLNA: check(platform.discoveries==1,"Cold DLNA resume rediscovers the server once and reopens the saved object")
				if source==Menu.Section.CLOUD: check(reboot._cloud_page==1 and reboot.cloud_pagination.provider()=="115_open","Cloud restart restores provider and page")
				index=reboot.Presentation.anchor_index(reboot.rows,{"key":identity,"browse":true})
				check(index>=0 and is_equal_approx(float(index)-reboot.scroll,line_offset),"Restart restores selected item rather than the old numerical index")
				var disk:=FileAccess.get_file_as_string(path)
				check(not disk.contains("token=secret") and not disk.contains("Image 042.jpg"),"Remember navigation IDs without media URLs or selected filenames")
			reboot.visible=false; reboot.free()
			var disabled:=menu_for(store,platform); disabled.restore_directory_position=false; disabled.begin_image_picker(); await settle(disabled)
			check(disabled.section==source and is_zero_approx(disabled.scroll),"Disabled position restore still opens the remembered directory, at top")
			if source==Menu.Section.CLOUD: check(disabled._cloud_page==0,"Disabled position restore starts at the first cloud page")
			disabled.clear_browse_history(false); disabled.visible=false; disabled.free()
			var cleared:=menu_for(store,platform); cleared.begin_image_picker(); await settle(cleared)
			check(cleared.section==Menu.Section.LOCAL and cleared._local_path()=="/videos","Clear history removes picker route and item position")
			cleared.visible=false; cleared.free()
	await grid_and_policy_cases()
	Privacy.configure(Privacy.ALL)
	check(Location.clean({"source":"unsupported"}).is_empty(),"Invalid routes are ignored")
	var clean:=Location.clean({"source":"smb","server":"account","path":"share","password":"secret","uri":"https://signed"})
	check(not clean.has("password") and not clean.has("uri"),"Route schema excludes credentials and file links")
	for failure in failures: push_error(failure)
	print("Image picker memory: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func grid_and_policy_cases() -> void:
	Privacy.configure(Privacy.NONE)
	var path:=output.path_join("grid-private.cfg")
	var store:=memory(path); var platform:=Platform.new(); var menu:=menu_for(store,platform)
	menu.view_mode="grid"; menu.begin_image_picker(); await settle(menu)
	menu._local_stack=[{"id":"/photos","title":"Photos"}]; menu._load_section(); await settle(menu)
	menu._set_scroll(7.25)
	var selected: Dictionary=menu.rows[32]
	var identity: String=menu.Presentation.browse_key(selected)
	menu._choose(selected)
	platform.inserted=8
	menu.visible=true; menu.begin_image_picker(); await settle(menu)
	check(menu.view_mode=="grid" and is_equal_approx(menu.scroll,9.25),"Grid resumes selected image at the same visible row after new files")
	check(menu.Presentation.anchor_index(menu.rows,{"key":identity,"browse":true})==40,"Grid finds the original image identity")
	menu._local_stack=[{"id":"/cancelled","title":"Cancelled"}]; menu._load_section(); await settle(menu); menu.dismiss()
	menu.visible=true; menu.begin_image_picker(); await settle(menu)
	check(menu._local_path()=="/photos","Cancelling a different folder does not replace the last selected image directory")
	Privacy.configure(Privacy.ALL); menu.browse_policy_changed(); menu.checkpoint_browse()
	check(memory(path).lookup(Location.SCOPE,false).is_empty(),"Enabling history does not backfill the private picker route")
	platform.omit=32; menu._load_section(); await settle(menu)
	check(menu.rows.size()==107 and menu.scroll>=0 and menu.scroll<=menu._max_scroll(),"Removed selected image falls back to a valid nearby position")
	check(menu._local_path()=="/photos","Missing selected image does not discard its directory")
	menu.visible=false; menu.free()
