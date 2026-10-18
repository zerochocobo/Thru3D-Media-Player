extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String]=[]
class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 0
	func reply(path: String) -> int:
		sequence+=1
		var id := sequence
		var entries := [{"id":path+"/child","title":"Child","container":true},
			{"uri":"file://"+path+"/photo.png","title":"photo.png","kind":"image"},
			{"uri":"file://"+path+"/video.mp4","title":"video.mp4","kind":"video"}]
		(func():media_list.emit(id,JSON.stringify({"state":"ready","path":path,"object_id":path,"server_id":"server","entries":entries}))).call_deferred()
		return id
	func media_local_browse(path: String) -> int: return reply(path)
	func media_smb_browse(_server: String, path: String) -> int: return reply(path)
	func media_dlna_browse(_server: String, path: String) -> int: return reply(path)
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func has_video(menu: Node) -> bool: return menu.rows.any(func(row):return row.get("kind")=="video")
func _run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.visible=true; menu.attach_platform(Platform.new())
	for source in [Menu.Section.LOCAL,Menu.Section.SMB,Menu.Section.DLNA]:
		menu.section=source; menu._local_stack=[{"id":"/disk","title":"Disk"}]; menu._smb_server="server"; menu._smb_path="share"
		menu._dlna_server="server"; menu._dlna_stack=[{"id":"root","title":"Root"}]
		if source==Menu.Section.LOCAL: menu._load_section()
		elif source==Menu.Section.SMB: menu._request("smb_browse",menu.platform.media_smb_browse("server","share"))
		else: menu._request("dlna_browse",menu.platform.media_dlna_browse("server","root"))
		await create_timer(0.01).timeout; menu.refresh()
		check(has_video(menu) and menu.rows.any(func(row):return row.has("container")),"Fixture supplies mixed files and a child folder for source "+str(source))
		menu._activate(Menu.FILTER_BASE+2)
		check(menu.media_filter==2 and not has_video(menu),"Manual image filter applies in current directory "+str(source))
		menu.refresh(); check(menu.media_filter==2,"A redraw within the same directory preserves its active filter")
		var folders: Array=menu.rows.filter(func(row):return row.has("container"))
		if folders.is_empty(): check(false,"Missing folder after filtering: "+str(menu.rows)); menu.queue_free(); quit(1); return
		menu._choose(folders[0]); await create_timer(0.01).timeout
		check(menu.media_filter==0 and has_video(menu),"Opening a child does not hide its videos "+str(source))
		menu._activate(Menu.FILTER_BASE+2); menu._go_back(); await process_frame
		check(menu.media_filter==0 and has_video(menu),"Going back clears the child filter instead of restoring a hidden global one")
		menu._activate(Menu.FILTER_BASE+2); menu.dismiss(); menu.toggle()
		check(menu.media_filter==0 and has_video(menu),"Reopening the browser shows all files again")
		menu._activate(Menu.FILTER_BASE+2); menu.remember_playback_context(); menu.dismiss(); menu.show_playback_files(true)
		check(menu.media_filter==0 and has_video(menu),"Playback context does not resurrect the previous manual filter")
		menu.set_compact(false); menu.visible=true
	menu.section=Menu.Section.CLOUD; menu._cloud_stack=[{"id":"drive","title":"Drive"}]; menu.media_filter=2; menu.refresh()
	menu._cloud_stack.append({"id":"child","title":"Child"}); menu.refresh()
	check(menu.media_filter==0,"Cloud folder navigation also expires a manual filter")
	menu.section=Menu.Section.RECENT; menu.media_filter=2; menu.collections.switch_tab(1); menu.collections.switch_tab(0)
	check(menu.media_filter==0,"Recent and Favorites tabs do not remember an old file-type filter")
	menu.section=Menu.Section.LOCAL; menu.begin_media_browse(2)
	menu._choose({"container":{"id":"/other","title":"Other"}}); await process_frame
	check(menu.media_filter==2 and not has_video(menu),"An explicit external photo picker keeps its purpose across directories")
	menu.begin_media_browse(1); menu._go_back(); await process_frame
	check(menu.media_filter==1 and has_video(menu) and not menu.rows.any(func(row):return row.get("kind")=="image"),"An explicit external video picker also retains its intended scope")
	menu._activate(Menu.FILTER_BASE+2); menu._choose({"container":{"id":"/another","title":"Another"}}); await process_frame
	check(menu.media_browse_intent==0 and menu.media_filter==0 and has_video(menu),"A manual filter replaces the external intent and expires normally")
	menu.queue_free(); await process_frame
	print("Library filter scope: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
