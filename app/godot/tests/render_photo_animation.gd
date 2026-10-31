extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Fakes := preload("res://tests/test_photo_animation.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/image-formats/render")
var viewport: SubViewport
func _initialize() -> void: call_deferred("run")
func capture(name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name+".png")); return image
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1280,800); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position = Vector3(0,1.6,0); viewport.add_child(camera)
	var photo := Photo.new(); viewport.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.view_camera = camera; photo.history_enabled = false; photo.platform = Fakes.Platform.new()
	photo._metadata = {"animated":true}; photo._display_request = 1
	photo.queue = [{"uri":"file://motion.avif","title":"Motion.avif"}]; photo.index = 0
	photo.flat_pose = Transform3D(Basis(),Vector3(0,1.6,-2.4)); photo._size = Vector2(2,2)
	var image := Image.create(2,2,false,Image.FORMAT_RGBA8); image.fill(Color.BLUE); image.generate_mipmaps()
	photo._full_image = image; photo._display_result = {"image":image}; photo._texture = ImageTexture.create_from_image(image)
	photo.material.set_shader_parameter("photo_texture",photo._texture); photo._detail_material.set_shader_parameter("photo_texture",photo._texture)
	photo._apply_geometry(); photo.panel.visible = true
	photo.animation.app_focused = func(): return true
	photo.animation.activate(); photo.animation.tick()
	var menu := Menu.new(); menu.state_provider = photo.snapshot; menu.queue_provider = func(): return photo.queue
	viewport.add_child(menu); menu.position = Vector3(0,1.12,-1.4); menu.rotation.x = -.28; menu.toggle()
	var red := await capture("playing")
	photo.platform.report.token = 2; photo.animation.tick(); photo.animation.toggle(); menu.refresh()
	var green := await capture("paused")
	var passed := red.get_pixel(640,280).r>.8 and green.get_pixel(640,280).g>.8
	photo.platform = null; viewport.queue_free(); await process_frame
	print("Photo animation real renderer: "+str(passed)); quit(0 if passed else 1)
