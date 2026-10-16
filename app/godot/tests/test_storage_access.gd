extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_library_menu.gd")
const Volume := preload("res://scripts/storage_volume.gd")
var checks := 0
var failures: Array[String] = []
const SYS := "/storage/1234-ABCD"
const RAW := "usb://dual-partition"
const TREE := "content://com.android.externalstorage.documents/tree/1234-ABCD%3AMovies/document/1234-ABCD%3AMovies"
class Platform extends Fixture.FakePlatform:
	var directory_requests: Array[String] = []
	var authorized := false
	var raw_error := true
	var hold_stops := false
	var held_stops := {}
	func storage_volumes() -> Array:
		return [{"id":"/storage/emulated/0","title":"Internal storage","container":true,"volume":true},
			{"id":SYS,"uuid":"1234-ABCD","title":"EXFAT","container":true,"volume":true,"removable":true,"storage_access":"system","read_only":true},
			{"id":"/storage/9876-DCBA","uuid":"9876-DCBA","title":"FAT32","container":true,"volume":true,"removable":true,"storage_access":"system","read_only":true},
			{"id":RAW,"title":"Disk model","container":true,"volume":true,"removable":true,"managed_usb":true,"storage_access":"usb","read_only":true}]
	func media_local_browse(path: String) -> int:
		var reply := {"source":"local","state":"ready","path":path,"all_files":false,"volumes":storage_volumes(),"entries":[]}
		if path.is_empty(): reply.entries = storage_volumes()
		elif path == SYS:
			if authorized:
				reply.entries = [{"id":TREE,"title":"Movies","container":true,"read_only":true,"can_delete":false,"can_rename":false}]
			else: reply.merge({"state":"denied","error":"STORAGE_FOLDER_ACCESS_NEEDED","access_kind":"directory"}, true)
		elif path == TREE:
			reply.entries = [{"id":TREE+"%2Fmovie.mkv","uri":TREE+"%2Fmovie.mkv","title":"movie.mkv","container":false,"size":6000000000,"read_only":true,"can_delete":false,"can_rename":false}]
		elif path == RAW:
			if raw_error: reply.merge({"state":"error","error":"USB device is in use; open a system-mounted entry","usb_stage":"claim"}, true)
			else: reply.entries = [{"id":RAW+"/0-2048","title":"exFAT · 1","container":true},{"id":RAW+"/0-500000","title":"FAT32 · 2","container":true}]
		return _reply(reply)
	func media_local_grant_directory(path: String) -> void:
		directory_requests.append(path)
		(func(): media_list.emit(0, JSON.stringify({"source":"local_access","state":"requested","path":path}))).call_deferred()
	func media_local_stop_storage(path: String) -> int:
		storage_settings.append(path)
		if hold_stops:
			next += 1; held_stops[path] = next; return next
		return _reply({"source":"local_eject","state":"stopped" if path == RAW else "released","volume_id":path,"unmounted":false})
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func settle() -> void:
	await process_frame; await process_frame; await process_frame
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu.storage_eject_requested.connect(menu.stop_storage)
	await settle()
	check(menu._buttons.any(func(b): return b.target == Menu.EJECT_STORAGE), "Global stop is discovered on Home without entering Local files")
	menu.catalog = Fixture.Catalog.new(); menu.catalog.forget("smb://srv1/Video/a.mp4"); menu.refresh()
	var home_stop: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.EJECT_STORAGE)[0]
	check(home_stop.node.position.y > 0.4, "Full Home keeps global stop in the visible upper toolbar")
	var home_point: Vector3 = home_stop.node.global_position
	menu.press_pointer("left_hand",home_point+Vector3(0,0,1),Vector3(0,0,-1),true); await settle()
	menu.press_pointer("left_hand",home_point+Vector3(0,0,1),Vector3(0,0,-1),false)
	check(platform.storage_settings.size() == 3 and menu.catalog.can_undo(), "The Home stop ray reaches every partition without activating the adjacent undo")
	platform.storage_settings.clear(); menu.catalog = null
	menu._activate(Menu.NAV_BASE+Menu.Section.LOCAL); await settle()
	check(menu.rows.size() == 4, "Both system partitions and the direct USB entry remain explicit")
	check(menu.rows[1].detail == "System mounted · Read-only" and menu.rows[2].detail == menu.rows[1].detail, "System partition rows identify access and read-only state")
	check(menu.rows[3].detail == "App managed · Read-only", "Hardware entry identifies app management")
	check(menu.Presentation.info(menu.rows[1]).card_detail == "System mounted · Read-only" and menu.Presentation.info(menu.rows[3]).subtitle == "App managed · Read-only", "Grid and compact presentation keep the source distinction")
	check(not menu._buttons.any(func(b): return b.target == Menu.ALL_FILES), "Discovery does not show an irrelevant global grant")
	menu._activate(Menu.ROW_BASE+1); await settle()
	check(menu.status == "Folder access needed" and menu._local_access_mode() == "directory", "A mounted-volume denial requests folder access")
	check(menu._tips[Menu.ALL_FILES] == "Choose a folder", "Mounted unlock action describes the actual grant")
	menu._activate(Menu.GRANT); menu._activate(Menu.GRANT); await settle()
	check(platform.directory_requests == [SYS] and platform.grants == 0, "Mounted grants use SAF once and never all-files settings")
	check(menu.status == "Choose a folder", "The active directory picker has an explicit state")
	platform.media_list.emit(0,JSON.stringify({"source":"local_access","state":"cancelled","path":SYS,"error":"Folder access needed"})); await settle()
	check(not menu._local_grant_pending and menu.status == "Folder access needed", "Cancellation releases the guard without a false grant")
	menu.compact = true; menu.refresh()
	check(menu._buttons.any(func(b): return b.target == Menu.GRANT), "Compact menus also offer directory authorization")
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.GRANT)[0]
	var point: Vector3 = button.node.global_position
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),true); await settle()
	check(platform.directory_requests.size() == 2, "The grant ray target is not covered by the folder favorite")
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),false)
	platform.authorized = true
	platform.media_list.emit(0,JSON.stringify({"source":"local_access","state":"granted","path":SYS})); await settle()
	check(menu.rows.size() == 1 and menu.rows[0].title == "Movies", "A selected subfolder appears explicitly after authorization")
	menu._activate(Menu.ROW_BASE); await settle()
	check(menu.rows[0].uri.begins_with("content://") and not menu.rows[0].get("can_delete",true) and not menu.rows[0].get("can_rename",true), "SAF media stays read-only through row conversion")
	check(menu._eject_volume().get("id") == SYS, "A SAF child retains the system eject owner")
	check(Volume.contains_uri(platform.storage_volumes()[1],menu.rows[0].uri), "System reader cleanup includes tree document media")
	menu._local_stack.clear(); menu._load_section(); await settle()
	menu.compact = false; menu.refresh(); menu._activate(Menu.ROW_BASE+3); await settle()
	check(menu.status == "USB device is in use; open a system-mounted entry", "Claim failure is visible rather than an empty success")
	check(menu._local_access_mode() == "none" and not menu._buttons.any(func(b): return b.target in [Menu.ALL_FILES,Menu.GRANT]), "Direct USB never offers shared-storage permission settings")
	platform.raw_error = false; menu._activate(Menu.REFRESH); await settle()
	check(menu.rows.size() == 2 and menu.rows[0].title == "exFAT · 1" and menu.rows[1].title == "FAT32 · 2", "Both direct partitions survive normal listing and media filtering")
	menu._request("local",899)
	menu._on_media_list(899,JSON.stringify({"source":"local","state":"loading","path":RAW,"error":"Reading USB storage…"}))
	check(menu.status == "Reading USB storage…" and menu._pending.has(899), "USB progress remains observable and retains the pending final response")
	menu._on_media_list(899,JSON.stringify({"source":"local","state":"error","path":RAW,"error":"USB partition table could not be read","usb_stage":"scan"}))
	check(menu.status == "USB partition table could not be read" and not menu._pending.has(899), "The final scan error replaces progress and is never a permission prompt")
	menu._request("local",900)
	menu._on_media_list(900, JSON.stringify({"source":"local","state":"error","path":SYS,"error":"ALL_FILES_ACCESS_NEEDED"}))
	check(menu.status == "Loading…", "A mismatched late path cannot replace the active USB result")
	menu._local_stack.clear(); menu._load_section(); await settle()
	platform.hold_stops = true
	var full_stop: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.EJECT_STORAGE)[0]
	check(full_stop.node.position.y > 0.4, "Full Local keeps the whole-disk stop in the upper toolbar")
	point = full_stop.node.global_position
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),true); await settle()
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),false)
	menu._activate(Menu.EJECT_STORAGE); await settle()
	check(platform.held_stops.size() == 3 and platform.storage_settings.size() == 3, "One global press stops both mounted partitions and the direct device exactly once")
	var pending := platform.held_stops.duplicate()
	for path in [SYS,RAW]:
		platform.media_list.emit(int(pending[path]),JSON.stringify({"source":"local_eject","state":"released" if path == SYS else "stopped","volume_id":path,"unmounted":false})); await settle()
	check(not menu._local_eject_pending.is_empty() and menu.status != "Storage access stopped", "Global completion waits for every partition and the native device")
	var last := "/storage/9876-DCBA"
	platform.media_list.emit(int(pending[last]),JSON.stringify({"source":"local_eject","state":"released","volume_id":last,"unmounted":false})); await settle()
	check(menu._local_eject_pending.is_empty() and menu._local_path().is_empty() and menu.status == "Storage access stopped", "Whole-drive app stop has one short completion and no system UI")
	check(platform.grants == 0, "Stopping never requests storage or write permission")
	menu._activate(Menu.NAV_BASE+Menu.Section.RECENT); await settle()
	menu.set_compact(true); menu.refresh()
	platform.held_stops.clear(); platform.storage_settings.clear()
	var stop_button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.EJECT_STORAGE)[0]
	point = stop_button.node.global_position
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),true); await settle()
	menu.press_pointer("left_hand",point+Vector3(0,0,1),Vector3(0,0,-1),false)
	check(platform.held_stops.size() == 3 and menu.status == "Stopping storage…", "The compact Home ray target stops the complete disk without opening either partition")
	pending = platform.held_stops.duplicate()
	for path in [SYS,RAW,last]:
		platform.media_list.emit(int(pending[path]),JSON.stringify({"source":"local_eject","state":"error" if path == RAW else "released","volume_id":path,"error":"USB stop failed" if path == RAW else "","unmounted":false})); await settle()
	check(menu.status == "USB stop failed" and menu._local_eject_pending.is_empty(), "One failed device prevents a global success notice and releases the retry guard")
	platform.hold_stops = false; menu._activate(Menu.EJECT_STORAGE); await settle()
	check(menu._local_eject_pending.is_empty() and menu.status == "Storage access stopped", "A whole-disk retry remains entirely inside the app")
	menu.queue_free(); await process_frame; platform.free()
	for failure in failures: push_error(failure)
	print("Storage authorization: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
