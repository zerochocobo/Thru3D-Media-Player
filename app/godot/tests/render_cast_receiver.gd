extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Caps := preload("res://scripts/cast_capabilities.gd")
class Bridge extends "res://tests/test_dlna_menu.gd".Platform:
	func dlna_receiver_enable(_value: bool) -> bool: return true
var state := {}
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/dlna-receiver/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.state_provider = func(): return state
	var library := Library.new(); camera.add_child(library)
	var bridge := Bridge.new(); library.attach_platform(bridge); library.section = Library.Section.DLNA
	for language in ["zh", "zh_Hant", "en", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for page in ["entry", "request", "vod", "live", "return"]:
			state = Caps.apply({"has_video": true, "title": "Phone video", "duration_ms": 120000, "position_ms": 43000, "geometry": 0, "playing": true, "playback_state": "playing", "volume": 65}, {"seek": page != "live", "effects": page != "live"})
			if page == "live": state.duration_ms = 0
			menu.cast_state = {"enabled": true, "active": page in ["vod", "live"]}
			library.cast_state = {"enabled": true, "name": "Thru3D"}
			if page == "request": menu.cast_state.pending = {"title": "Cast video"}
			if page == "return": library.cast_state.return_available = true
			library.visible = page in ["entry", "return"]; menu.visible = not library.visible
			library.refresh(); menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
	menu.free(); library.free(); bridge.free(); viewport.queue_free(); await process_frame
	print("Cast layouts=20"); quit()
