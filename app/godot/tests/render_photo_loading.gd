extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/photo-view-feedback-20261012/render")
var viewport: SubViewport
var camera: Camera3D
var photo: Node3D
var checks := 0
var failures: Array[String] = []

class SlowHost extends RefCounted:
	signal photo_preview_ready(id: int, payload: String)
	func open_photo(_uri: String) -> int: return 10
	func open_photo_preview(_uri: String) -> int: return 20
	func release_photo_preview(_id: int) -> void: pass
	func cancel_photo_preview(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func frame(name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name+".png")); return image
func at(image: Image, uv: Vector2) -> Color:
	var size: Vector2 = photo._placeholder_size if photo.loading else photo._flat.size
	var world: Vector3 = photo.global_transform * photo.flat_pose * Vector3((uv.x-.5)*size.x,(.5-uv.y)*size.y,0)
	return image.get_pixelv(Vector2i(camera.unproject_position(world)))
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(960,540); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR; world.environment.background_color = Color(0.02,0.04,0.08)
	viewport.add_child(world)
	camera = Camera3D.new(); camera.position = Vector3(0,1.6,0); camera.fov = 70; viewport.add_child(camera)
	photo = Photo.new(); viewport.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.view_camera = camera; photo.history_enabled = false; photo.platform = SlowHost.new()
	photo.mode_memory = Memory.new("user://photo_reveal_render_modes")
	photo.screen_curve = 0; photo.screen_scale = .65; photo.flat_pose.origin = Vector3(0,1.6,-2.4)
	photo.open_image("file://reveal-test.png","reveal-test.png",[])
	photo._on_metadata(10,photo._serial,0,{"width":400,"height":200})
	photo._process(.3)
	photo._placeholder_material.set_shader_parameter("flow_time",-1.0)
	var automatic: Image = await frame("waiting-auto-1")
	await create_timer(.25).timeout
	var automatic_next: Image = await frame("waiting-auto-2")
	check(automatic.get_data()!=automatic_next.get_data(),"The production TIME clock animates the cover without script updates")
	photo._placeholder_material.set_shader_parameter("flow_time",1.0)
	var waiting: Image = await frame("waiting-1")
	photo._placeholder_material.set_shader_parameter("flow_time",2.6)
	var flowing: Image = await frame("waiting-2")
	check(waiting.get_data()!=flowing.get_data(),"Waiting has visible low-contrast light movement")
	var centre := at(waiting,Vector2(.5,.5)); var edge := at(waiting,Vector2(.005,.5)); var outside := waiting.get_pixel(5,5)
	check(centre.a>0 and centre.r>outside.r,"The frosted surface is visible before image data")
	check(centre.r>.4 and centre.g>.4 and absf(centre.r-centre.g)<.12,"Waiting glass is milky white rather than a dark solid fill")
	check(absf(edge.r-outside.r)<absf(centre.r-outside.r),"The glass edge feathers into the environment")
	for i in 16:
		photo._placeholder_material.set_shader_parameter("flow_time",float(i)*.25)
		await frame("waiting-animation-%02d" % i)
	var image := Image.create(400,200,false,Image.FORMAT_RGB8); image.fill(Color.RED)
	image.fill_rect(Rect2i(200,0,200,200),Color.GREEN)
	photo._accept({"image":image,"thumbnail":image,"info":{}},{"id":10,"index":0})
	photo._process(Photo.REVEAL_SECONDS*.4)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		var partial: Image = await frame("reveal-eye-%d" % eye)
		check(at(partial,Vector2(.2,.5)).r>.8,"The light reveals loaded colour behind its frontier in each eye")
		var covered := at(partial,Vector2(.8,.5))
		check(covered.r>.4 and absf(covered.g-covered.r)<.15,"The unrevealed side remains white frost rather than exposing green photo content")
	photo._process(Photo.REVEAL_SECONDS)
	var ready: Image = await frame("ready")
	check(not photo.placeholder_visible() and at(ready,Vector2(.8,.5)).g>.8,"Completion immediately removes the glass and fully shows the image")
	photo.set_target_feedback(2)
	var targeted: Image = await frame("ready-targeted")
	check(ready.get_data()==targeted.get_data(),"Selecting the full photograph never adds a blue or opaque frame")
	# Deterministic frames for reviewing the actual production shader without a headset.
	var sky := Image.new()
	if sky.load("res://backgrounds/belfast_sunset_puresky.jpg") == OK:
		sky.resize(960,480,Image.INTERPOLATE_LANCZOS)
		photo._texture = ImageTexture.create_from_image(sky)
		photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._placeholder.visible = true; photo._placeholder_material.set_shader_parameter("presentation_opacity",1.0)
	for i in 32:
		var progress := float(i)/31
		photo.material.set_shader_parameter("reveal_progress",progress)
		photo._placeholder_material.set_shader_parameter("reveal_progress",progress)
		await frame("animation-%02d" % i)
	await gallery_waiting()
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify({"state":"passed" if failures.is_empty() else "failed","checks":checks,"failures":failures,"physical_xr_verified":false}))
	photo.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo loading pixels: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func room() -> void:
	# A simple synthetic room gives the user a safe approximation of passthrough contrast.
	for item in [
		[Vector3(0,-.08,-3),Vector3(14,.1,16),Color(.22,.24,.27)],
		[Vector3(0,2.5,-7),Vector3(14,6,.1),Color(.46,.49,.53)],
		[Vector3(2.1,2.55,-6.9),Vector3(2.4,2,.05),Color(.26,.42,.56)],
		[Vector3(2.1,2.55,-6.85),Vector3(.06,2,.05),Color(.7,.73,.76)],
		[Vector3(2.1,2.55,-6.85),Vector3(2.4,.06,.05),Color(.7,.73,.76)],
		[Vector3(-2,1.05,-5.7),Vector3(2.8,.12,.8),Color(.27,.22,.18)]]:
		var mesh := MeshInstance3D.new(); mesh.mesh = BoxMesh.new(); mesh.mesh.size = item[1]
		var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = item[2]; mesh.material_override = material
		viewport.add_child(mesh); mesh.position = item[0]

func gallery_waiting() -> void:
	photo.close_image(); photo.set_layout_mode(0)
	camera.transform = Transform3D(Basis.IDENTITY,Vector3(0,1.6,0))
	photo.flat_pose = Transform3D(Basis.IDENTITY,Vector3(0,1.6,-2.4))
	photo.open_image("file://white-glass.png","white-glass.png",[])
	photo._process(.3)
	viewport.transparent_bg = true
	var env := (viewport.get_child(0) as WorldEnvironment).environment
	env.background_mode = Environment.BG_CLEAR_COLOR
	var alpha: Image = await frame("glass-alpha")
	check(at(alpha,Vector2(.5,.5)).a>.25 and at(alpha,Vector2(.5,.5)).a<.7,"The waiting surface is genuinely translucent")
	viewport.transparent_bg = false; env.background_mode = Environment.BG_COLOR
	room()
	photo._placeholder_material.set_shader_parameter("flow_time",1.0)
	await frame("demo-single-white-glass")
	for step in 16:
		photo._placeholder_material.set_shader_parameter("flow_time",float(step)*.25)
		await frame("demo-single-flow-%02d" % step)
	var items: Array[Dictionary] = []
	for index in 24: items.append({"uri":"file://waiting-%d.png"%index,"title":"%d.png"%index,"kind":"image","photo_info":{"width":400,"height":200}})
	for layout in [2,3]:
		photo.close_image(); photo.set_layout_mode(0)
		camera.transform = Transform3D(Basis.IDENTITY,Vector3(0,1.6,0))
		photo.open_image(str(items[0].uri),"waiting.png",items)
		photo._on_metadata(10,photo._serial,0,{"width":400,"height":200})
		photo.set_layout_mode(layout); photo.gallery._process(.35)
		photo.gallery.previews.set_process(false)
		var card: Dictionary = photo.gallery.cards[0]
		if layout == 3: camera.look_at(card.pose.origin,Vector3.UP)
		var prefix := "wall" if layout == 2 else "fragments"
		for item in photo.gallery.cards.values(): item.node.material_override.set_shader_parameter("flow_time",1.0)
		var first: Image = await frame("demo-"+prefix+"-white-glass")
		for item in photo.gallery.cards.values(): item.node.material_override.set_shader_parameter("flow_time",2.6)
		var second: Image = await frame(prefix+"-glass-flow")
		check(first.get_data()!=second.get_data(),"Unloaded "+prefix+" cards have moving light")
		var pixel := Vector2i(camera.unproject_position(card.pose.origin))
		var color := first.get_pixelv(pixel)
		check(color.r>.45 and color.g>.45,"Unloaded "+prefix+" cards stay white and visible against the room")
		photo.gallery.activate(0); photo.gallery._process(1)
		camera.look_at(photo.gallery.focus_pose.origin,Vector3.UP)
		var pending: Image = await frame(prefix+"-full-waiting")
		check(pending.get_pixel(480,270).r>.4 and card.node.material_override.get_shader_parameter("waiting_for_full"),"Opening an unloaded "+prefix+" photo shows moving glass at full size")
		photo._process(.5)
		var image := Image.create(400,200,false,Image.FORMAT_RGB8); image.fill(Color.RED)
		image.fill_rect(Rect2i(200,0,200,200),Color.GREEN)
		photo._accept({"image":image,"thumbnail":image,"info":{}},{"id":10,"index":0})
		photo._process(Photo.REVEAL_SECONDS*.4); photo.gallery._process(1)
		await frame(prefix+"-full-revealing")
		check(photo.placeholder_visible() and photo._placeholder_material.render_priority>photo.material.render_priority,"The "+prefix+" reveal retains its frosted cover above the arriving full image")
		photo._process(Photo.REVEAL_SECONDS); photo.gallery._process(.1)
		await frame(prefix+"-full-ready")
		check(not photo.placeholder_visible() and photo.panel.visible,"Completed "+prefix+" images remove the glass immediately")
