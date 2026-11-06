extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Rotation := preload("res://scripts/screen_rotation_control.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/screen-rotation/hover-preview")

func _initialize() -> void: call_deferred("run")
func capture(viewport: SubViewport, name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	I18n.use("zh")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(0, 1.6, 0); camera.fov = 65; viewport.add_child(camera)
	var video := Video.new(); viewport.add_child(video); video.set_process(false); video.view_camera = camera
	video.local_uri = "file:///dance.mp4"; video.media.begin(7); video.media.format = {"width": 1920, "height": 1080}
	video.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2)); video._apply_geometry(); video.panel.visible = true
	var image := Image.create(480, 270, false, Image.FORMAT_RGB8)
	for y in 270:
		for x in 480:
			var color := Color(0.06, 0.18, 0.28).lerp(Color(0.15, 0.48, 0.55), float(y) / 270)
			if x % 80 < 2 or y % 90 < 2: color = color.lightened(0.18)
			if y < 12: color = Color(0.95, 0.52, 0.22)
			image.set_pixel(x, y, color)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(image))
	video.material.set_shader_parameter("source_size", Vector2(480, 270))
	var title := Label3D.new(); title.text = "DANCE  /  01"; title.font_size = 48; title.pixel_size = 0.002
	title.position = Vector3(0, 0.20, 0.01); title.no_depth_test = true; video.panel.add_child(title)
	var rotation := Rotation.new(); viewport.add_child(rotation)
	rotation.sync(video, false)
	await capture(viewport, "idle-no-mark")
	rotation.sync(video, true)
	await capture(viewport, "hover-lower-left")
	rotation.update_pointer("mouse", camera.global_position, (video.panel.to_global(video.screen_corner(Rotation.lower_left_corner(video))) - camera.global_position).normalized(), true)
	await capture(viewport, "hover-tooltip")
	video.set_screen_rotation(90); rotation.sync(video, true)
	rotation.clear_pointer_visuals()
	await capture(viewport, "hover-rotated-90")
	video.set_screen_rotation(132); rotation.sync(video, true, true, 2)
	await capture(viewport, "drag-132")
	video.set_screen_rotation(0); rotation.sync(video, false); video.set_corner_hover(0)
	await capture(viewport, "hover-other-corner-resize")
	video.set_corner_hover(-1)
	rotation.visible = false; video.panel.visible = false
	var menu := Menu.new(); viewport.add_child(menu); menu.set_process(false)
	menu.state_provider = func(): return {"has_video": true, "geometry": 0, "screen_rotation": 0,
		"screen_distance": 2, "screen_scale": 100, "screen_curve": 0, "screen_cinema": false, "screen_dimensions": Vector2(1.9, 1.07)}
	menu.global_position = Vector3(0, 1.0, -1.8)
	menu.section = 1; menu._adjustment = "screen"; menu.visible = true; menu.refresh()
	await capture(viewport, "settings")
	menu._hover["mouse"] = 452; menu._update_highlights()
	await capture(viewport, "settings-rotation-tooltip")
	viewport.free()
	print("Screen rotation preview: 8 images saved to " + output)
	quit()
