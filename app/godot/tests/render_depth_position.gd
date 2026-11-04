extends SceneTree
const VideoMenu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/depth-position")
var state := {"has_video":true,"has_image":true,"title":"Stereo position · 立体位置","source_uri":"file:///sample.mp4",
	"geometry":0,"depth_requested":true,"depth_enabled":true,"depth_available":true,"depth_strength":0.5,
	"depth_position":0,"count":8,"index":2,"can_previous":true,"can_next":true,"duration_ms":900000,"position_ms":240000,
	"screen_distance":3.0,"screen_scale":1.0,"inspect_magnification":2.0}
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440,1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; camera.position.y = -0.15; viewport.add_child(camera)
	for photo in [false,true]:
		camera.position = Vector3(0, -0.15, 0) if photo else Vector3(0, 0.4, 0.25)
		var menu: Node3D = PhotoMenu.new() if photo else VideoMenu.new()
		menu.state_provider = func(): return state.duplicate()
		viewport.add_child(menu); menu.toggle(); menu.set_process(false)
		menu.section = 1
		for language in ["zh","en","ja"]:
			I18n.use(language)
			state.depth_position = 100 if language == "en" else (-100 if language == "ja" else 0)
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(("photo" if photo else "video-settings") + "-" + language + ".png"))
		if not photo:
			I18n.use("zh"); state.depth_position = 0; state.stereo = true
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("video-settings-stereo-zh.png"))
			state.stereo = false; menu.section = 0; menu._depth_open = true
			camera.position = Vector3(0, -0.15, 0)
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("video-quick-zh.png"))
		menu.free()
	var library := Library.new(); library.settings_provider = func(): return {"depth_position_default":0}
	viewport.add_child(library); library.set_process(false); library.visible = true
	library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB
	I18n.use("zh"); library.refresh()
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("global-zh.png"))
	library.free()
	print("Depth position UI render complete")
	quit()
