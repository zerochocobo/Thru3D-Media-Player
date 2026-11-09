extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Corner := preload("res://scripts/screen_lock_control.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/screen-lock/preview")
var state := {"has_video": true, "geometry": 0, "screen_edit_locked": false, "screen_default_locked": true,
	"screen_distance": 2.0, "screen_scale": 120.0, "screen_curve": 30.0, "screen_rotation": 0.0,
	"screen_cinema": false, "screen_curve_modes_available": true, "screen_dimensions": Vector2(2.28, 1.284)}

func _initialize() -> void: run.call_deferred()
func shot(viewport: SubViewport, name_: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name_ + ".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	Menu.I18n.use("zh")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(0, 1.6, 0); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); viewport.add_child(menu); menu.set_process(false); menu.state_provider = func(): return state
	menu.global_position = Vector3(0, 0.96, -1.8); menu.section = 1; menu._adjustment = "screen"; menu.visible = true; menu.refresh()
	await shot(viewport, "settings-unlocked")
	state.screen_edit_locked = true; menu.refresh_values()
	await shot(viewport, "settings-locked")
	state.screen_cinema = true; menu.refresh_values()
	await shot(viewport, "upright-locked")
	state.screen_scene_locked = true; state.screen_scene_picture = true; menu.refresh_values()
	await shot(viewport, "cinema-locked")
	state.screen_scene_picture = false; menu.refresh()
	await shot(viewport, "beach-locked")
	menu.visible = false
	var video := Video.new(); viewport.add_child(video); video.set_process(false); video.view_camera = camera
	video.local_uri = "file:///screen-lock-preview.mp4"; video.media.begin(1); video.media.format = {"width": 1920, "height": 1080}
	video.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2)); video._apply_geometry(); video.panel.visible = true
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.08, 0.19, 0.25); video.panel.material_override = material
	var control := Corner.new(); viewport.add_child(control)
	control.sync(video, false, false); await shot(viewport, "idle")
	control.sync(video, true, false); await shot(viewport, "corner-unlocked")
	control.sync(video, true, true); await shot(viewport, "corner-locked")
	video.set_screen_rotation(90); control.sync(video, true, true); await shot(viewport, "corner-rotated")
	video.set_screen_rotation(0); control.sync(video, false, true)
	var feedback := preload("res://scripts/playback_status_overlay.gd").new()
	feedback.source = func(): return {"caption": Menu.I18n.t("Screen locked\nUnlock at the top-left or in Screen settings"), "fps_visible": false}
	camera.add_child(feedback)
	await shot(viewport, "locked-feedback")
	viewport.queue_free(); await process_frame; quit()
