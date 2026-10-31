extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var output := ProjectSettings.globalize_path("res://../../build/output/photo-portrait/render")
class Host extends RefCounted:
	func open_photo(_uri: String) -> int: return 2
	func prepare_photo_3d(_id: int, _strength: float) -> bool: return true
	func prepare_photo_portrait(_id: int, _token: int, _strength: float) -> bool: return true
	func cancel_photo_portrait(_token: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func copy_layer_band(_slot: int, _color: int, _y: int, _rows: int) -> bool: return true
	func copy_layer_band_masked(_slot: int, _color: int, _mask: int, _y: int, _rows: int) -> bool: return true
	func create_layer_image(_slot: int, _width: int, _height: int, _levels: int, _static: bool) -> bool: return true
	func acquire_layer_image(_slot: int) -> int: return 1
	func release_layer_image(_slot: int, _mips: bool) -> bool: return true
	func destroy_layer_image(_slot: int) -> void: pass

class Layer extends VideoLayer:
	var inset := Vector2.ZERO
	var blend := -1
	var failed := false
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func hide(_owner: Object = null) -> void: pass
	func show(_surface: Node3D, _origin: XROrigin3D, _source: int = SURFACE, _size := Vector2(SURFACE_SIZE, SURFACE_SIZE), _stereo: int = -1,
			_inset := Vector2.ZERO, _pano := Vector4(0, 0, 1, 1), _blend := OPAQUE, _extras: Array = [], _processed := false) -> bool:
		inset = _inset; blend = _blend; return not failed
func check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func frame(name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image(); result.save_png(output.path_join(name+".png")); return result
func centre(image: Image,eye: int) -> float:
	var sum := 0.0; var count := 0
	for x in image.get_width():
		var pixel := image.get_pixel(x,150)
		if (pixel.r > 0.8 if eye == 0 else pixel.g > 0.8): sum += x; count += 1
	return sum/maxi(1,count)
func foreground_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x,y)
			if pixel.r > 0.1 or pixel.g > 0.1: count += 1
	return count
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(600,300); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLUE; viewport.add_child(world)
	var camera := Camera3D.new(); camera.position = Vector3(0,1.6,0); camera.fov = 70; viewport.add_child(camera)
	var photo := Photo.new(); viewport.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.flat_pose.origin = Vector3(0,1.6,-2); photo.screen_curve = 0; photo.screen_scale = 0.5
	var color := Image.create(256,128,false,Image.FORMAT_RGBA8); color.fill(Color.RED)
	var pair := Image.create(512,128,false,Image.FORMAT_RGBA8); pair.fill(Color.RED); pair.fill_rect(Rect2i(256,0,256,128),Color.GREEN)
	var near := Image.create(518,518,false,Image.FORMAT_RF); near.fill(Color(0.8,0,0))
	photo.auto_depth = true; photo.queue.assign([{"uri":"file://portrait.png","title":"portrait.png"}])
	photo._accept({"image":color,"thumbnail":color,"info":{},"depth_data":{"image":near,"rect":Vector4(0,0,1,1),"stereo_image":pair}}, {"id":1,"index":0})
	photo.finish_transition()
	var mask := Image.create(512,128,false,Image.FORMAT_R8); mask.fill(Color.BLACK)
	mask.fill_rect(Rect2i(72,16,88,112),Color.WHITE); mask.fill_rect(Rect2i(256+96,16,88,112),Color.WHITE)
	photo._portrait_texture = ImageTexture.create_from_image(mask); photo.portrait_enabled = true; photo._apply_geometry()
	var positions := []
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		var rendered: Image = await frame("portrait-eye-%d" % eye)
		check(rendered.get_pixel(230,150).b > 0.8, "Cutout reveals the environment outside the subject")
		positions.append(centre(rendered,eye))
		check(positions.back()>230 and positions.back()<380, "Each eye keeps its own coloured foreground")
	check(positions[1] > positions[0]+15, "Per-eye mask disparity is preserved instead of sharing one flat silhouette")
	photo.material.set_shader_parameter("target_state",2)
	var targeted: Image = await frame("portrait-targeted")
	check(targeted.get_pixel(230,150).b > 0.8, "Selection feedback cannot add an opaque photo rectangle around a portrait")
	photo.portrait_enabled = false; photo._apply_geometry(); photo.material.set_shader_parameter("target_state",0)
	var restored: Image = await frame("portrait-off")
	check(restored.get_pixel(230,150).g > 0.8, "Turning portrait off restores complete stereo colour")
	photo.platform = Host.new(); photo.portrait_requested = true; photo.auto_portrait = true
	photo.portrait_enabled = true; photo._portrait_curve = 0; photo._apply_geometry()
	photo.queue.append({"uri":"file://next.png","title":"next.png"})
	check(photo.navigate(1), "Finished portrait navigates using the production selection path")
	check(is_instance_valid(photo._departing) and photo._departing.material_override.get_shader_parameter("portrait_enabled"), "The moving old image retains its own portrait matte")
	photo._transition_time = photo.TRANSITION_SECONDS * 0.5; photo._update_transition()
	var departing: Image = await frame("portrait-next-departing")
	check(departing.get_pixel(230,150).b > 0.8, "The departing cutout leaves the environment visible outside its silhouette")
	photo._transition_time = photo.TRANSITION_SECONDS; photo._update_transition()
	var waiting: Image = await frame("portrait-next-loading")
	check(foreground_pixels(waiting) < 500, "Portrait loading adds only a small indicator without a rectangular cover")
	var data := {"image":near,"rect":Vector4(0,0,1,1),"stereo_image":pair,"strength":photo.depth_strength}
	photo._accept({"image":color,"thumbnail":color,"info":{},"depth_data":data},{"id":2,"index":1})
	photo.finish_transition(); photo._maybe_start_portrait(); photo._process_presentation()
	var preparing: Image = await frame("portrait-next-preparing")
	check(photo._presentation_pending and foreground_pixels(preparing) < 500, "The next colour pair stays hidden until its own matte is ready")
	photo._portrait_texture = ImageTexture.create_from_image(mask); photo.portrait_enabled = true; photo._apply_geometry()
	photo._process_presentation()
	var complete: Image = await frame("portrait-next-ready")
	check(not photo._presentation_pending and complete.get_pixel(230,150).b > 0.8 and centre(complete,1) > 230, "The next completed cutout reveals the environment without a frame")
	photo.set_portrait(false)
	photo.free()
	# Exercise the final layer handoff with production deferred textures. The stub records
	# native submission; these pixels are the actual eye-buffer remainder, not a fake compositor.
	photo = Photo.new(); viewport.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.platform = Host.new(); photo.video_layer = Layer.new(photo.platform)
	var origin := XROrigin3D.new(); viewport.add_child(origin)
	var xr_camera := XRCamera3D.new(); origin.add_child(xr_camera); photo.view_camera = xr_camera
	camera.make_current()
	photo.flat_pose.origin = Vector3(0,1.6,-2); photo.screen_curve = 0; photo.screen_scale = 0.5
	photo.transparent_background = true; photo.auto_depth = true
	photo.queue.assign([{"uri":"file://layer-portrait.png","title":"layer-portrait.png"}])
	var proxy := Image.create(32,16,false,Image.FORMAT_RGBA8); proxy.fill(Color.RED)
	photo._accept({"image":color,"proxy":proxy,"info":{},"depth_data":data},{"id":3,"index":0}); photo.finish_transition()
	photo.portrait_requested = true; photo.portrait_enabled = true
	photo._portrait_texture = ImageTexture.create_from_image(mask); photo._portrait_mask = mask.get_data(); photo._apply_geometry()
	photo.material.set_shader_parameter("test_eye", 1)
	check(not photo._texture_full and photo._stereo_texture == null, "Layer handoff keeps the large stereo texture deferred as on device")
	photo._process_layer()
	check(photo.layer_shown and not photo._presentation_pending, "Completed cutout reaches the production layer handoff")
	check(photo._stereo_texture == null, "Removing the border does not force a duplicate full-size stereo upload")
	check(photo.video_layer.inset == Vector2.ZERO and photo.video_layer.blend == VideoLayer.SOURCE_ALPHA, "The alpha layer covers the full cutout instead of leaving an ordinary photo rim")
	check(photo.material.get_shader_parameter("layer_cut") == Vector4(0,0,1,1), "The eye-buffer photo is fully excluded while the alpha layer supplies it")
	var rim: Image = await frame("portrait-layer-eye-buffer-remainder")
	check(foreground_pixels(rim) == 0, "No coloured or blurred rectangular rim remains around the native cutout")
	photo.video_layer.failed = true; photo._process_layer()
	var fallback: Image = await frame("portrait-layer-fallback")
	check(not photo.layer_shown and fallback.get_pixel(230,150).b > 0.8 and centre(fallback,1) > 230, "A failed layer submission restores the masked stereo shader without a border")
	photo.video_layer.failed = false; photo.portrait_requested = false; photo.portrait_enabled = false; photo._apply_geometry(); photo._process_layer()
	var ordinary_cut: Vector4 = photo.material.get_shader_parameter("layer_cut")
	check(photo.layer_shown and photo.video_layer.blend == VideoLayer.OPAQUE and photo.video_layer.inset == photo._edge_feather()
		and ordinary_cut.x > 0 and ordinary_cut.z < 1, "Ordinary photos retain their original feather and overlapping eye-buffer edge")
	photo.free(); origin.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo portrait render: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
