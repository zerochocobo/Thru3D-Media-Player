extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Fakes := preload("res://tests/test_photo_animation_depth.gd")
var failures: Array[String] = []
var checks := 0
var view: SubViewport
var photo: Node3D
var output := ProjectSettings.globalize_path("res://../../build/output/animated-photo-depth/render")

class Platform extends Fakes.Platform:
	func photo_animation_pixels(_id: int, frame: int) -> PackedByteArray:
		var image := Image.create(256,128,false,Image.FORMAT_RGBA8); image.fill(Color(0.05,0.3,0.1,1))
		image.fill_rect(Rect2i(52 if frame == 1 else 144,32,40,64),Color.RED)
		return image.get_data()
	func photo_animation_depth_pixels(_id: int, frame: int) -> PackedByteArray:
		var image := Image.create(32,16,false,Image.FORMAT_RF); image.fill(Color(0.95 if frame == 1 else 0.6,0,0))
		return image.get_data()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

func centroid(image: Image) -> Vector2:
	var point := Vector2.ZERO; var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x,y)
			if color.r > 0.8 and color.g < 0.1 and color.b < 0.1:
				point += Vector2(x,y); count += 1
	check(count > 50, "Visible animated foreground")
	return point / maxf(count,1)

func eyes(label: String) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		for frame in 3: await RenderingServer.frame_post_draw
		var image := view.get_texture().get_image()
		image.save_png(output.path_join("%s-eye%d.png" % [label,eye]))
		points.append(centroid(image))
	return points

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view = SubViewport.new(); view.size = Vector2i(512,512); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); view.add_child(camera)
	photo = Photo.new(); view.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	var platform := Platform.new(); photo.platform = platform; photo.view_camera = camera
	photo._metadata = {"animated":true}; photo._display_request = 1; photo._request = 1
	photo.queue.assign([{"uri":"file://motion.gif", "title":"Motion.gif"}]); photo.index = 0
	photo.auto_portrait = false; photo.spatial_preferred = false
	photo._size = Vector2(256,128); photo.flat_pose = Transform3D(Basis(),Vector3(0,0,-2))
	var image := Image.create_from_data(256,128,false,Image.FORMAT_RGBA8,platform.photo_animation_pixels(1,1))
	photo._full_image = image; photo._display_result = {"image":image}; photo._texture = ImageTexture.create_from_image(image)
	photo._texture_full = true; photo.panel.visible = true; photo.sharpness = 0
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo.material.set_shader_parameter("sharpness",0.0)
	platform.report.width = 256; platform.report.height = 128
	platform.depth_report.width = 32; platform.depth_report.height = 16; platform.depth_report.rect = [0,0,32,16]
	photo.animation.app_focused = func(): return true
	photo.animation.activate(); photo.set_depth(true); photo.set_depth_strength(2.0); photo.animation.tick()
	var first := await eyes("frame1")
	var disparity1 := first[1].x - first[0].x
	check(disparity1 < -1 and absf(first[1].y - first[0].y) < 0.1, "First animated frame has horizontal stereo disparity")
	platform.report.token = 2; platform.depth_report.token = 2; platform.depth_report.frame_id = 2
	photo.animation.tick()
	var second := await eyes("frame2")
	var disparity2 := second[1].x - second[0].x
	check(second[0].x - first[0].x > 40, "The foreground moves while 3D stays enabled")
	check(disparity2 < -0.5 and absf(disparity2) < absf(disparity1) - 1, "The moving frame uses its updated depth")
	photo.animation.toggle()
	var paused := await eyes("paused")
	check(paused[0].distance_to(second[0]) < 0.01, "Pause retains the displayed stereo frame")
	photo.animation.toggle()
	for angle in [90,180,270]:
		photo.set_screen_rotation(angle)
		var rotated := await eyes("rotated%d" % angle)
		check(rotated[1].x - rotated[0].x < -0.5 and absf(rotated[1].y - rotated[0].y) < 0.1,
			"Animated disparity stays horizontal after %d degree rotation" % angle)
	photo.set_depth(false)
	var flat := await eyes("off")
	check(flat[0].distance_to(flat[1]) < 0.01, "Off restores identical mono eye images")
	photo.platform = null; view.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo animation depth render: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
