extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var checks := 0
var failures: Array[String] = []
var photo: Node3D
var host: DepthHost
var folder := "user://stereo-rotation"
var entries: Array[Dictionary] = []
var depth: Image
var view: SubViewport
var camera: Camera3D
var gpu := OS.get_cmdline_user_args().has("--gpu")
var results := []

class DepthHost extends RefCounted:
	signal photo_ready(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var masks: Array[Dictionary] = []
	var next_id := 100
	var on_depth: Callable
	var auto_deliver := false
	func open_photo(uri: String) -> int:
		next_id += 1
		photo_ready.emit.call_deferred(next_id, JSON.stringify({"state":"ready", "path":uri.trim_prefix("file://")}))
		return next_id
	func prepare_photo_3d(id: int, strength: float) -> bool: return prepare_photo_3d_rotated(id, strength, 0)
	func prepare_photo_3d_rotated(id: int, strength: float, rotation: int) -> bool:
		calls.append({"id":id,"strength":strength,"rotation":rotation})
		if auto_deliver: on_depth.call_deferred(id, strength, rotation)
		return true
	func prepare_photo_portrait(_id: int, _token: int, _strength: float) -> bool: return true
	func prepare_photo_portrait_rotated(id: int, token: int, strength: float, rotation: int) -> bool:
		masks.append({"id":id,"token":token,"strength":strength,"rotation":rotation}); return true
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func pair(rotation: int) -> Image:
	if gpu:
		var file := "res://../../build/output/photo-rotation-fix/gpu/pair-r%d.rgba" % rotation
		var bytes := FileAccess.get_file_as_bytes(file)
		if bytes.size() != 384 * 128 * 4:
			push_error("Run tools/Test-PhotoStereoRotation.py first"); quit(2)
			return Image.create(384,128,false,Image.FORMAT_RGBA8)
		return Image.create_from_data(384,128,false,Image.FORMAT_RGBA8,bytes)
	var image := Image.create(384,128,false,Image.FORMAT_RGBA8)
	image.fill(Color(0.2, float(rotation)/360.0, 0.6)); return image

func data(rotation: int, strength: float = 1.0) -> Dictionary:
	return {"image":depth,"rect":Vector4(0,0,1,1),"stereo_image":pair(rotation),"strength":strength,"rotation":rotation,"strategy":"video_soft_shift_gpu"}

func deliver(id: int, strength: float, rotation: int) -> void:
	var path := ProjectSettings.globalize_path(folder.path_join("pair-r%d.rgba" % rotation))
	FileAccess.open(path, FileAccess.WRITE).store_buffer(pair(rotation).get_data())
	photo._on_depth(id, JSON.stringify({"state":"ready","path":ProjectSettings.globalize_path(folder.path_join("depth.bin")),
		"width":518,"height":518,"rect":[0,0,1,1],"stereo_path":path,"stereo_width":384,"stereo_height":128,
		"stereo_strength":strength,"stereo_rotation":rotation,"stereo_strategy":"video_soft_shift_gpu"}))

func settle() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while (photo.snapshot().loading or photo._depth_busy or photo._depth_thread or not photo._depth_queue.is_empty()) and Time.get_ticks_msec() < deadline:
		await create_timer(.01).timeout
	photo.finish_transition(); photo._process_presentation()
	check(not photo.snapshot().loading and not photo._depth_busy and photo.error.is_empty() and photo.depth_error.is_empty(), "Presentation completes at requested angle")

func pixel_centroid(pixels: Image) -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for y in pixels.get_height():
		for x in pixels.get_width():
			var c := pixels.get_pixel(x,y)
			if c.r > .8 and c.g < .2 and c.b < .2: sum += Vector2(x,y); count += 1
	check(count > 30, "Each eye renders the foreground marker")
	return sum / maxf(count,1)

func render_pair(rotation: int) -> void:
	if not gpu: return
	var points := []
	photo.material.set_shader_parameter("sharpness",0.0)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		for frame in 3: await RenderingServer.frame_post_draw
		var pixels := view.get_texture().get_image()
		pixels.save_png("res://../../build/output/photo-rotation-fix/display-r%d-eye%d.png" % [rotation,eye])
		points.append(pixel_centroid(pixels))
	var delta: Vector2 = points[1] - points[0]
	check(delta.x < -1 and absf(delta.y) < .1, "Production photo shader keeps viewer-horizontal disparity at %d: %s" % [rotation,delta])
	results.append({"angle":rotation,"right_minus_left_px":[delta.x,delta.y]})

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	depth = Image.create(518,518,false,Image.FORMAT_RF); depth.fill(Color(.95,0,0))
	FileAccess.open(folder.path_join("depth.bin"),FileAccess.WRITE).store_buffer(depth.get_data())
	for index in 2:
		var pixels := Image.create(192,128,false,Image.FORMAT_RGBA8); pixels.fill(Color(80.0/255,80.0/255,80.0/255))
		pixels.fill_rect(Rect2i(64,42,64,43),Color(240.0/255,10.0/255,30.0/255))
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % index)); pixels.save_png(path)
		entries.append({"uri":"file://"+path,"title":"%d.png"%index,"kind":"image"})
	view = SubViewport.new(); view.size = Vector2i(384,384); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.6; camera.position = Vector3(0,0,3); camera.current = true; view.add_child(camera)
	photo = Photo.new(); photo.history_enabled = false; photo.auto_depth = false; photo.spatial_preferred = false
	photo.view_camera = camera; view.add_child(photo)
	photo.open_image(entries[0].uri, entries[0].title, entries); await settle()
	photo.set_screen_curve(0); photo.set_flat_world_pose(Transform3D.IDENTITY)
	host = DepthHost.new(); host.on_depth = deliver; host.photo_ready.connect(photo._on_ready); photo.platform = host
	photo.set_depth(true); deliver(photo._display_request,1.0,0); await settle(); await render_pair(0)
	var original_center: Vector3 = photo.panel.global_position
	var previous_key: String = photo._layer_source().key
	for rotation in [90,180,270,0]:
		var old_rotation := int(photo.screen_rotation)
		check(photo.rotate_clockwise(), "Rotate action accepted")
		check(host.calls.back().rotation == rotation, "Bridge receives the new angle")
		check(photo._depth_busy and photo._presentation_pending and not photo.depth_enabled and photo._stereo_texture == null, "Wrong-direction pair is hidden until rebuilt")
		check(photo.panel.global_position.is_equal_approx(original_center), "3D regeneration preserves the centre")
		photo._finish_depth(photo._display_request,data(old_rotation),false)
		check(photo._depth_busy and not photo.depth_enabled, "Late previous-angle pixels cannot replace the new request")
		photo._on_depth(photo._display_request,JSON.stringify({"state":"error","stereo_rotation":old_rotation}))
		check(photo.depth_error.is_empty() and photo._depth_busy, "Late previous-angle errors cannot fail the new request")
		deliver(photo._display_request,1.0,old_rotation)
		check(photo._depth_queue.is_empty(), "Previous-angle payload is rejected before a texture decode is queued")
		deliver(photo._display_request,1.0,rotation); await settle(); await render_pair(rotation)
		check(photo.depth_enabled and int(photo._display_depth_data.rotation) == rotation, "Only the matching pair becomes visible")
		check(photo._display_depth_data.image.get_data() == depth.get_data(), "Rotations reuse the unchanged model depth")
		var key: String = photo._layer_source().key
		check(key != previous_key and key.contains(":r%d:" % rotation), "XR upload identity includes angle")
		previous_key = key
		check(not photo._valid_cached_depth(data(old_rotation),0), "CPU/GPU cache rejects a previous-angle pair")
	# Drag previews do not launch inference/pair generation for intermediate angles.
	var preview_calls := host.calls.size()
	photo.begin_screen_rotation(); photo.set_screen_rotation(43); photo.set_screen_rotation(112)
	check(host.calls.size()==preview_calls and not photo.depth_enabled and not photo._presentation_pending, "Continuous drag hides the old pair without starting conversion")
	photo.set_screen_rotation(90); photo.finish_screen_rotation(true)
	check(host.calls.size()==preview_calls+1 and host.calls.back().rotation==90, "Release regenerates the final stereo angle once")
	deliver(photo._display_request,1.0,90); await settle()
	check(photo.depth_enabled and not photo._rotation_preview, "New stereo pair resumes after drag commit")
	photo.begin_screen_rotation(); photo.set_screen_rotation(0); photo.finish_screen_rotation(true)
	deliver(photo._display_request,1.0,0); await settle()
	# Foreground and neighbour angle validation must use each file's own remembered angle.
	photo.rotate_clockwise(); deliver(photo._display_request,1.0,90); await settle()
	check(photo._valid_cached_depth(data(0),1) and not photo._valid_cached_depth(data(0),0), "Neighbour cache uses its own photo angle")
	host.auto_deliver = true
	photo.navigate(1); await settle()
	check(photo.index == 1 and photo.screen_rotation == 0 and host.calls.back().rotation == 0, "Next photo does not inherit rotation")
	photo.navigate(-1); await settle()
	check(photo.index == 0 and photo.screen_rotation == 90 and int(photo._display_depth_data.rotation) == 90, "Returning restores and redraws the remembered angle")
	# Spatial rotation remains geometric; returning to static stereo rebuilds for the new roll.
	photo.spatial_requested = true; photo.spatial_preferred = true
	var calls := host.calls.size()
	check(photo.rotate_clockwise() and host.calls.size() == calls, "Spatial view rotation does not regenerate its static pair")
	photo.set_spatial(false); await settle()
	check(host.calls.back().rotation == 180 and int(photo._display_depth_data.rotation) == 180, "Leaving spatial view restores a correctly directed static pair")
	# A portrait's matte must be warped for the same angle as its colour pair.
	host.auto_deliver = false; photo.auto_portrait = true; photo.portrait_requested = true; photo.portrait_enabled = true
	check(photo.rotate_clockwise(), "Portrait photo accepts centre rotation")
	deliver(photo._display_request,1.0,270)
	var deadline := Time.get_ticks_msec()+5000
	while host.masks.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(not host.masks.is_empty() and host.masks.back().rotation == 270 and not photo.portrait_enabled, "Matte request shares the colour angle")
	var mask := PackedByteArray(); mask.resize(384*128); mask.fill(255)
	FileAccess.open(folder.path_join("mask.r8"),FileAccess.WRITE).store_buffer(mask)
	photo._on_portrait(photo._display_request,JSON.stringify({"state":"ready","token":photo._portrait_epoch,"strength":1.0,"rotation":270,
		"path":ProjectSettings.globalize_path(folder.path_join("mask.r8")),"width":384,"height":128,"format":"r8_sbs","strategy":"video_soft_shift_gpu"}))
	await settle()
	check(photo.portrait_enabled and photo._valid_cached_portrait(photo._display_depth_data.portrait_data,photo._display_depth_data), "Matching matte and colour commit together")
	if gpu: FileAccess.open("res://../../build/output/photo-rotation-fix/display-report.json",FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	photo.close_image(); photo.platform = null; host.on_depth = Callable(); host = null
	view.free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo stereo rotation: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
