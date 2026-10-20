extends SceneTree
## Desktop review of real, private inputs; never part of an APK scene or a generated-image mockup.
const Photo:=preload("res://scripts/photo_display.gd")
var inputs: Dictionary
var output: String
var index:=0
var batch:=false
var current: Dictionary
var photo: Node3D
var source_view: SubViewport
var spatial_view: SubViewport
var camera: Camera3D
var reference_surface: MeshInstance3D
var horizontal: HSlider
var vertical: HSlider
var caption: Label
var ticker: Timer
var automatic:=false
var phase:=0.0
var results: Array=[]
var working:=false
var fill_enabled:=true
var motion: CheckButton
var ui_capture:=false
var diagnostic: Node3D
const Spatial:=preload("res://scripts/photo_spatial_scene.gd")

class DepthHost extends RefCounted:
	var owner: Node3D
	var path: String
	var stereo: Dictionary
	func prepare_photo_3d(id: int, _strength: float) -> bool:
		var payload: Dictionary=stereo.duplicate()
		payload.merge({"state":"ready","path":path,"width":518,"height":518,"rect":[0,0,1,1]},true)
		owner._on_depth.call_deferred(id,JSON.stringify(payload))
		return true
	func prepare_photo_scene_depth(id: int, token: int) -> bool:
		owner._on_spatial_depth.call_deferred(id,JSON.stringify({"state":"ready","scene_token":token,"path":path,"width":518,"height":518,"rect":[0,0,1,1]}))
		return true
	func cancel_photo_scene_depth(_id: int,_token: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass

func _initialize() -> void: call_deferred("start")

func start() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.is_empty(): push_error("Pass inputs.json after --"); quit(1); return
	inputs=JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	output=inputs.output
	batch="--capture" in args
	ui_capture="--ui-capture" in args
	if batch:
		for entry in inputs.cases:
			await load_case(entry)
			await capture_case()
			await unload()
		FileAccess.open(output.path_join("render-results.json"),FileAccess.WRITE).store_string(JSON.stringify({"scope":"Real-photo desktop OpenGL, production PhotoDisplay/spatial geometry and shader; desktop MNN/HEIF inputs, no Android/XR", "cases":results},"\t"))
		print("Real spatial review: %d real photographs captured"%results.size())
		quit(); return
	build_ui()
	await choose(0)
	if ui_capture:
		await choose(inputs.cases.size()-1)
		horizontal.value=8; vertical.value=0
		await picture(root,output.path_join("desktop-preview.png"))
		await choose(1)
		await choose(0)
		print("Real spatial review UI: all case switches and capture completed")
		await unload(); quit(); return
	ticker=Timer.new(); ticker.wait_time=1.0/30; ticker.timeout.connect(animate); root.add_child(ticker); ticker.start()
	motion.button_pressed=true

func make_view(size: Vector2i) -> SubViewport:
	var view:=SubViewport.new(); view.size=size; view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; view.msaa_3d=Viewport.MSAA_2X
	root.add_child(view)
	var world:=WorldEnvironment.new(); var environment:=Environment.new()
	environment.background_mode=Environment.BG_COLOR; environment.background_color=Color("10151c")
	world.environment=environment; view.add_child(world)
	return view

func make_camera(view: SubViewport) -> Camera3D:
	var value:=Camera3D.new(); value.near=.05; value.fov=rad_to_deg(2.0*atan(2.12/6.0))
	view.add_child(value); value.current=true; return value

func load_case(entry: Dictionary) -> void:
	working=true; current=entry
	var aspect: float=float(entry.width)/(2.0 if entry.native_stereo else 1.0)/float(entry.height)
	var size:=Vector2i(roundi(1600*aspect),1600)
	if size.x>1920: size=Vector2i(1920,roundi(1920/aspect))
	source_view=make_view(size); spatial_view=make_view(size)
	var source_camera:=make_camera(source_view); source_camera.position.x=-0.032
	camera=make_camera(spatial_view)
	photo=Photo.new(); photo.history_enabled=false; photo.spatial_preferred=true; spatial_view.add_child(photo); photo.set_process(false)
	photo.view_camera=camera; photo.flat_pose=Transform3D(Basis(),Vector3(0,0,-3)); photo.screen_curve=0
	photo.screen_scale=2.0/photo._screen_dimensions(aspect).y
	photo.queue.assign([{"uri":"file://"+entry.source,"title":"Apple 空间照片" if entry.native_stereo else "普通照片"}])
	var metadata:={"path":entry.source,"raw_rgba":true,"decoded_width":int(entry.width),"decoded_height":int(entry.height),
		"width":int(entry.width),"height":int(entry.height),"orientation":1,"native_stereo":bool(entry.native_stereo),"spatial_disparity":0.0}
	var decoded: Dictionary=Photo._decode({"info":metadata})
	if not decoded.has("image"): push_error("Review source decode failed"); quit(1); return
	photo._accept(decoded,{"id":index+1,"index":0}); photo.finish_transition()
	photo._reveal_seconds=0; photo._placeholder.visible=false
	photo.material.set_shader_parameter("reveal_progress",1.0)
	photo.material.set_shader_parameter("test_eye",0)
	var host:=DepthHost.new(); host.owner=photo; host.path=entry.depth; host.stereo=entry; photo.platform=host
	if not entry.native_stereo:
		if not entry.has("stereo_path"): push_error("Prepare the production GPU stereo reference first"); quit(1); return
		photo.set_depth(true)
		var conversion_deadline:=Time.get_ticks_msec()+60000
		while not photo.depth_enabled and Time.get_ticks_msec()<conversion_deadline:
			photo._process_depth_jobs(); await create_timer(.01).timeout
		if not photo.depth_enabled or not photo._display_depth_data.has("stereo_image"):
			push_error("Existing 2D-to-3D conversion did not complete"); quit(1); return
	photo._spatial_auto_due=false
	reference_surface=MeshInstance3D.new(); reference_surface.mesh=photo.panel.mesh
	reference_surface.transform=photo.panel.transform; reference_surface.material_override=photo.material.duplicate()
	reference_surface.material_override.set_shader_parameter("spatial_hidden",false)
	source_view.add_child(reference_surface)
	photo._spatial_auto_due=true; photo._maybe_start_spatial()
	if not photo.spatial_requested: push_error("Could not automatically start production spatial view"); quit(1); return
	var deadline:=Time.get_ticks_msec()+60000
	while not photo._spatial.prepared and photo.spatial_requested and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	if not photo._spatial.prepared: push_error("Spatial view preparation failed"); quit(1); return
	# Unfilled geometry is a diagnostic control, never a product/user preference.
	diagnostic=Spatial.new(); spatial_view.add_child(diagnostic)
	var data:=Photo._read_depth(JSON.stringify({"state":"ready","path":entry.depth,"width":518,"height":518,"rect":[0,0,1,1]}))
	diagnostic.begin(decoded.image,data.image,data.rect,photo._spatial.reference,photo._flat.size,entry.native_stereo,1.0,false)
	deadline=Time.get_ticks_msec()+60000
	while not diagnostic.prepared and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	if not diagnostic.prepared: push_error("Diagnostic geometry did not prepare"); quit(1); return
	move_head(0,0)
	working=false

func unload() -> void:
	if root.has_node("Review/Images"):
		for control in root.get_node("Review/Images").get_children(): control.texture=null
	if is_instance_valid(photo): photo.close_image(); photo.free(); photo=null
	if is_instance_valid(diagnostic): diagnostic.free(); diagnostic=null
	if is_instance_valid(source_view): source_view.free()
	if is_instance_valid(spatial_view): spatial_view.free()
	await process_frame

func move_head(x_cm: float,y_cm: float,z_cm: float = 0.0) -> void:
	if not is_instance_valid(photo): return
	var head:=Transform3D(Basis(),Vector3(x_cm/100.0,y_cm/100.0,z_cm/100.0)).looking_at(Vector3(0,0,-3))
	camera.transform=head*Transform3D(Basis(),Vector3(-.032,0,0))
	photo._process_spatial()
	if is_instance_valid(diagnostic):
		diagnostic.sync(photo.panel.transform,photo._flat.size,photo.panel.global_transform.affine_inverse()*camera.global_position,photo.material.render_priority)
		diagnostic.visible=not fill_enabled
	photo._spatial.visible=fill_enabled and photo._spatial.coverage>0
	if is_instance_valid(caption): caption.text="左右 %+.1f cm   上下 %+.1f cm"%[x_cm,y_cm]

func picture(view: Viewport,path: String) -> Image:
	for frame in 3: await RenderingServer.frame_post_draw
	var image:=view.get_texture().get_image()
	if not path.is_empty(): image.save_png(path)
	return image

func capture_case() -> void:
	var folder:=output.path_join(current.id).path_join("render")
	DirAccess.make_dir_recursive_absolute(folder)
	# This diagnostic belonged to the replaced background-layer prototype.
	if FileAccess.file_exists(folder.path_join("right-fill-mask.png")): DirAccess.remove_absolute(folder.path_join("right-fill-mask.png"))
	await picture(source_view,folder.path_join("original.png"))
	var flat_camera:=source_view.get_camera_3d()
	flat_camera.transform=Transform3D(Basis(),Vector3(.08,0,0)).looking_at(Vector3(0,0,-3))*Transform3D(Basis(),Vector3(-.032,0,0))
	await picture(source_view,folder.path_join("flat-right.png"))
	flat_camera.position=Vector3(-.032,0,0); flat_camera.rotation=Vector3.ZERO
	var record:={"id":current.id,"native_stereo":current.native_stereo,"reference_distance_m":3.0,"gaze":"head looks at photo centre, parallel left eye at -32mm",
		"auto_started":photo.spatial_requested and photo.spatial_preferred,"converted_before_spatial":photo.depth_enabled if not current.native_stereo else false,
		"reference_eye":"left","eye_separation_m":0.064,"viewport":[spatial_view.size.x,spatial_view.size.y],"resources":photo._spatial.report,"views":[]}
	for entry in [["centre",0.0,0.0,0.0],["left",-8.0,0.0,0.0],["right",8.0,0.0,0.0],["up",0.0,6.0,0.0],
		["left12",-12.0,0.0,0.0],["right12",12.0,0.0,0.0],["left20",-20.0,0.0,0.0],["right20",20.0,0.0,0.0],
		["down12",0.0,-12.0,0.0],["forward20",0.0,0.0,-20.0]]:
		move_head(entry[1],entry[2],entry[3])
		await picture(spatial_view,folder.path_join(entry[0]+".png"))
		record.views.append({"name":entry[0],"head_cm":[entry[1],entry[2],entry[3]],"coverage":photo._spatial.coverage})
	move_head(8,0)
	fill_enabled=false; move_head(8,0)
	await picture(spatial_view,folder.path_join("right-no-fill.png"))
	fill_enabled=true; move_head(8,0)
	for frame in 9:
		move_head(-8.0+frame*2.0,0)
		await picture(spatial_view,folder.path_join("motion-%02d.png"%frame))
	results.append(record)
	print("Captured ",current.id," ",photo._spatial.report)

func build_ui() -> void:
	root.size=Vector2i(1500,1000); root.title="Thru3D · 真实照片空间预览"
	var base:=VBoxContainer.new(); base.name="Review"; base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); root.add_child(base)
	var toolbar:=HBoxContainer.new(); base.add_child(toolbar)
	for i in inputs.cases.size():
		var button:=Button.new(); button.text=("Apple 空间照片" if inputs.cases[i].native_stereo else "普通照片 %d"%(i+1))
		button.pressed.connect(choose.bind(i)); toolbar.add_child(button)
	var reset:=Button.new(); reset.text="正视"; reset.pressed.connect(func():motion.button_pressed=false; horizontal.value=0; vertical.value=0); toolbar.add_child(reset)
	motion=CheckButton.new(); motion.text="头动"; motion.toggled.connect(func(value):automatic=value); toolbar.add_child(motion)
	var fill:=CheckButton.new(); fill.text="补洞"; fill.button_pressed=true
	fill.toggled.connect(func(value):fill_enabled=value; if not working: move_head(horizontal.value,vertical.value))
	toolbar.add_child(fill)
	horizontal=HSlider.new(); horizontal.min_value=-25; horizontal.max_value=25; horizontal.step=.1; horizontal.custom_minimum_size.x=200
	vertical=HSlider.new(); vertical.min_value=-15; vertical.max_value=15; vertical.step=.1; vertical.custom_minimum_size.x=130
	horizontal.value_changed.connect(func(_value):if not working: move_head(horizontal.value,vertical.value))
	vertical.value_changed.connect(func(_value):if not working: move_head(horizontal.value,vertical.value))
	toolbar.add_child(horizontal); toolbar.add_child(vertical)
	caption=Label.new(); toolbar.add_child(caption)
	var headings:=HBoxContainer.new(); base.add_child(headings)
	for title in ["原立体模式 · 左眼","空间视图 · 左眼"]:
		var label:=Label.new(); label.text=title; label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER; label.size_flags_horizontal=Control.SIZE_EXPAND_FILL; headings.add_child(label)
	var images:=HBoxContainer.new(); images.name="Images"; images.size_flags_vertical=Control.SIZE_EXPAND_FILL; base.add_child(images)
	for name in ["Source","Spatial"]:
		var image:=TextureRect.new(); image.name=name; image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED; image.size_flags_horizontal=Control.SIZE_EXPAND_FILL; images.add_child(image)

func choose(value: int) -> void:
	if working: return
	working=true; index=value
	await unload(); await load_case(inputs.cases[index])
	var images: HBoxContainer=root.get_node("Review/Images")
	images.get_node("Source").texture=source_view.get_texture(); images.get_node("Spatial").texture=spatial_view.get_texture()
	horizontal.value=0; vertical.value=0; move_head(0,0)

func animate() -> void:
	if working or not automatic: return
	phase+=1.0/30
	horizontal.value=sin(phase*1.5)*20.0
