extends SceneTree
## The scene picker reopens in the folder the last scene was picked from.
const Menu := preload("res://scripts/library_menu.gd")
const Memory := preload("res://scripts/directory_browse_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []
var output := ""

class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var serial := 0
	func reply(result: Dictionary) -> int:
		serial += 1
		var id := serial
		(func(): media_list.emit(id, JSON.stringify(result))).call_deferred()
		return id
	func entries(path: String) -> Array:
		return [{"id": path + "/Hall.glb", "uri": "https://fixture/hall.glb?token=secret", "title": "Hall.glb", "kind": "scene", "size": 4096},
			{"id": path + "/Clip.mp4", "uri": "https://fixture/clip.mp4", "title": "Clip.mp4", "kind": "video"}]
	func media_local_browse(path: String) -> int: return reply({"state": "ready", "path": path, "entries": entries(path)})
	func media_smb_browse(server: String, path: String) -> int: return reply({"state": "ready", "server_id": server, "path": path, "entries": entries(path)})

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func menu_for(store: RefCounted, platform: RefCounted) -> Node3D:
	var menu := Menu.new()
	menu.browse_memory = store
	root.add_child(menu)
	menu.set_process(false)
	menu.attach_platform(platform)
	menu.visible = true
	menu.section = Menu.Section.LOCAL
	menu._local_stack = [{"id": "/videos", "title": "Videos"}]
	menu.view_mode = "list"
	return menu

func settle(menu: Node3D) -> void:
	for i in 60:
		await process_frame
		if i >= 2 and menu._pending.is_empty(): break

func scene_row(menu: Node3D) -> Dictionary:
	for row in menu.rows:
		if row.get("kind", "") == "scene": return row
	return {}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/scene-picker-memory/%d" % Time.get_ticks_usec())
	Privacy.vault = null
	Privacy.configure(Privacy.ALL)
	var picked: Array = []
	for source in [Menu.Section.LOCAL, Menu.Section.SMB]:
		var path := output.path_join("%d.cfg" % source)
		var store := Memory.new()
		store.load_file(path)
		var platform := Platform.new()
		var menu := menu_for(store, platform)
		menu.scene_file_selected.connect(func(uri, title, bytes): picked.append([uri, title, bytes]))
		menu.begin_scene_picker(); await settle(menu)
		check(menu.scene_picker_mode and menu.section == Menu.Section.LOCAL and menu._local_path() == "/videos", "With nothing remembered the picker opens where the browser was / %d" % source)
		menu.section = source
		menu._local_stack = [{"id": "/models", "title": "Models"}]
		menu._smb_server = "nas"; menu._smb_path = "share/models"
		menu._load_section(); await settle(menu); menu.refresh()
		var row := scene_row(menu)
		check(not row.is_empty(), "Scene files are listed / %d" % source)
		if row.is_empty(): menu.free(); continue
		picked.clear()
		menu._choose(row)
		check(picked.size() == 1 and picked[0][1] == "Hall.glb" and not menu.scene_picker_mode and menu.section == Menu.Section.LOCAL and menu._local_path() == "/videos", "Picking a scene hands it over and puts the browser back / %d" % source)
		menu.visible = true; menu.begin_scene_picker(); await settle(menu)
		check(menu.section == source and (menu._local_path() == "/models" if source == Menu.Section.LOCAL else menu._smb_server == "nas" and menu._smb_path == "share/models") and not scene_row(menu).is_empty(), "The picker reopens in the folder of the last pick / %d" % source)
		menu.section = Menu.Section.LOCAL
		menu._local_stack = [{"id": "/elsewhere", "title": "Elsewhere"}]
		menu._load_section(); await settle(menu)
		menu.dismiss()
		menu.visible = true; menu.begin_scene_picker(); await settle(menu)
		check(menu.section == source and (source != Menu.Section.LOCAL or menu._local_path() == "/models"), "Looking around without picking changes nothing / %d" % source)
		menu.dismiss()
		menu.visible = true; menu.begin_image_picker(); await settle(menu)
		check(menu.section == Menu.Section.LOCAL and menu._local_path() == "/videos", "The image picker keeps its own place / %d" % source)
		menu.dismiss()
		menu.visible = false; menu.free()
		var again := Memory.new()
		again.load_file(path)
		var reboot := menu_for(again, platform)
		reboot.begin_scene_picker(); await settle(reboot)
		check(reboot.section == source and (source != Menu.Section.LOCAL or reboot._local_path() == "/models"), "The folder is still remembered after a restart / %d" % source)
		var disk := FileAccess.get_file_as_string(path)
		check(not disk.is_empty() and not disk.contains("token=secret") and not disk.contains("Hall.glb"), "Only the route is stored, not the file / %d" % source)
		reboot.dismiss(); reboot.visible = false; reboot.free()
	for failure in failures: push_error(failure)
	print("Scene picker memory: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
