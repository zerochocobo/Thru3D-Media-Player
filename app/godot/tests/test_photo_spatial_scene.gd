extends SceneTree
const Geometry:=preload("res://scripts/photo_spatial_geometry.gd")
const Scene:=preload("res://scripts/photo_spatial_scene.gd")
const Photo:=preload("res://scripts/photo_display.gd")
const Menu:=preload("res://scripts/photo_menu.gd")
const I18n:=preload("res://scripts/i18n.gd")
var checks:=0
var failures: Array[String]=[]
var directory:="user://spatial-scene-tests"

class Host extends RefCounted:
	var calls:=0
	var token:=0
	var cancelled:=0
	func prepare_photo_scene_depth(_id: int, value: int) -> bool:
		calls+=1; token=value; return true
	func cancel_photo_scene_depth(_id: int, _value: int) -> void: cancelled+=1
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass

class StereoHost extends RefCounted:
	func prepare_photo_3d(_id: int,_strength: float) -> bool: return true

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

static func fixture() -> Dictionary:
	var image:=Image.create(320,240,false,Image.FORMAT_RGBA8)
	var depth:=Image.create(80,60,false,Image.FORMAT_RF)
	for y in 240:
		for x in 320:
			image.set_pixel(x,y,Color(0.05,0.35+0.3*float(x)/320,0.3+0.4*float(y)/240))
	image.fill_rect(Rect2i(120,55,80,130),Color(0.95,0.05,0.02))
	depth.fill(Color(0.1,0,0)); depth.fill_rect(Rect2i(30,14,20,32),Color(0.9,0,0))
	return {"image":image,"depth":depth,"rect":Vector4(0,0,1,1)}

func _initialize() -> void: call_deferred("run")
func settle(scene: Node) -> void:
	var deadline:=Time.get_ticks_msec()+30000
	while not scene.prepared and scene.error.is_empty() and Time.get_ticks_msec()<deadline:
		await create_timer(0.01).timeout
	check(scene.prepared,"Background worker completes a bounded scene")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var f:=fixture(); var eye:=Vector3(0,0,3); var size:=Vector2(2,1.5)
	var data:=Geometry.prepare(f.image,f.depth,f.rect,eye,size)
	check(not data.is_empty() and data.triangles>10000 and data.triangles<=Geometry.MAX_TRIANGLES,"Connected mesh stays within the lightweight geometry budget")
	check(data.color.has_mipmaps() and not data.has("background"),"Keep the sharp source texture without a low-resolution fill layer")
	check(data.color.get_width()==320 and data.color.get_pixel(150,100).r>0.9,"Main colour retains source detail and foreground")
	check(data.fill and data.gradient_half_cells.x>0 and data.gradient_half_cells.y>0,"Our photo gradient rule covers both lateral and vertical head movement")
	for uv in [Vector2(.1,.2),Vector2(.8,.7),Vector2(.5,.5)]:
		for near_value in [0.0,0.5,1.0]:
			var p:=Geometry.point(uv,near_value,eye,size,data.span)
			var projected:=eye+(p-eye)*(eye.z/(eye.z-p.z))
			check(Vector2(projected.x,projected.y).distance_to(Vector2(uv.x-.5,.5-uv.y)*size)<0.00001,"Reference camera rays preserve photograph composition")
	var near_p:=Geometry.point(Vector2(.5,.5),.9,eye,size,data.span)
	var far_p:=Geometry.point(Vector2(.5,.5),.1,eye,size,data.span)
	check(near_p.z>far_p.z,"Foreground has physically nearer geometry")
	var large:=Image.create(4096,2160,false,Image.FORMAT_RGBA8); large.fill(Color.CORNFLOWER_BLUE)
	var bounded:=Geometry.prepare(large,f.depth,f.rect,eye,size)
	check(maxi(bounded.color.get_width(),bounded.color.get_height())<=2048 and bounded.color.get_width()*bounded.color.get_height()<=Geometry.MAX_PIXELS,"Large source is bounded before GPU upload")
	check(bounded.texture_bytes<20*1024*1024 and bounded.triangles<=Geometry.MAX_TRIANGLES,"Lightweight texture and geometry budgets are enforced")
	large=null; bounded={}
	var square:=Image.create(2048,2048,false,Image.FORMAT_RGBA8)
	var capped:=Geometry.prepare(square,f.depth,f.rect,eye,size)
	check(capped.color.get_width()*capped.color.get_height()<=Geometry.MAX_PIXELS,"Square photos obey the pixel limit after integer rounding")
	square=null; capped={}
	var pair:=Image.create(640,240,false,Image.FORMAT_RGBA8)
	for y in 240:
		for x in 320: pair.set_pixel(x,y,f.image.get_pixel(x,y))
	pair.fill_rect(Rect2i(320,0,320,240),Color.GREEN)
	var native:=Geometry.prepare(pair,f.depth,f.rect,eye,size,true)
	check(native.native_pair and native.color.get_width()==320 and native.color.get_pixel(150,100).r>.9,"Native Apple pair selects the left channel without packing or double disparity")
	var scene:=Scene.new(); root.add_child(scene)
	scene.begin(f.image,f.depth,f.rect,eye,size,false)
	await settle(scene)
	var mesh_id: int=scene.surfaces[0].mesh.get_instance_id()
	scene.sync(Transform3D.IDENTITY,size,Vector3(.08,0,3))
	check(scene.visible and scene.coverage>.99,"Small lateral head movement keeps the spatial scene active")
	scene.sync(Transform3D.IDENTITY,size,Vector3(.8,0,3))
	check(scene.visible and scene.coverage==1,"Large head movement never switches to a different stereo projection")
	check(scene.surfaces[0].mesh.get_instance_id()==mesh_id,"Head movement reuses static geometry")
	scene.clear(); check(not scene.prepared and scene.report.is_empty(),"Scene resources clear on exit")
	scene.queue_free(); await process_frame
	var photo:=Photo.new(); photo.history_enabled=false; root.add_child(photo)
	check(not photo.spatial_preferred,"New photo viewers default to static 3D")
	var settings:=ConfigFile.new()
	settings.set_value("photo","spatial_preferred",true); photo.restore_view_settings(settings)
	check(photo.spatial_preferred,"An explicitly saved global spatial choice still restores")
	settings.set_value("photo","spatial_preferred",false); photo.restore_view_settings(settings)
	check(not photo.spatial_preferred,"An explicitly saved global static choice still restores")
	photo.spatial_preferred=true; photo.restore_view_settings(ConfigFile.new())
	check(not photo.spatial_preferred,"Settings without a viewing-mode choice restore static 3D")
	photo._texture=ImageTexture.create_from_image(f.image); photo._size=Vector2(320,240); photo._display_request=1
	photo._display_result={"image":f.image}; photo._display_depth_data={"image":f.depth,"rect":f.rect}
	photo._apply_geometry(); photo.panel.visible=true
	check(not photo.spatial_preferred and not photo.can_spatial() and not photo.set_spatial(true),"The default viewing mode never converts an ordinary 2D photo directly")
	photo.depth_requested=true; photo.depth_enabled=true; photo.auto_depth=true
	photo.platform=StereoHost.new()
	check(not photo.can_spatial(),"The current plugin must finish its generated stereo pair before spatial view is eligible")
	photo._display_depth_data.merge({"stereo_image":pair,"strength":0.5})
	check(not photo.can_spatial(),"A stale-strength pair cannot enter spatial view")
	photo._display_depth_data.strength=1.0
	check(photo.can_spatial(),"A matching completed stereo conversion is eligible")
	photo._depth_busy=true
	check(not photo.can_spatial(),"Spatial waits while conversion is still running")
	photo._depth_busy=false; photo.platform=null
	var curve: float=photo.screen_curve
	photo._spatial_auto_due=true; photo._maybe_start_spatial()
	check(not photo.spatial_requested and photo.depth_enabled and not photo._spatial.prepared,"A completed 2D-to-3D photo stays in static 3D by default")
	check(photo.set_spatial_mode(true) and photo.spatial_requested,"A completed 2D-to-3D photo can explicitly enter spatial view")
	await settle(photo._spatial)
	photo._process_spatial()
	check(photo._spatial.visible and photo.material.get_shader_parameter("spatial_hidden"),"New geometry replaces the fixed stereo image")
	photo.platform=StereoHost.new()
	check(photo.set_depth_strength(1.0) and photo.spatial_requested,"A no-op strength refresh keeps the selected spatial view active")
	photo.platform=null
	check(photo.set_spatial(false) and is_equal_approx(photo.screen_curve,curve) and not photo.material.get_shader_parameter("spatial_hidden"),"Exit restores the original viewing surface and curve")
	check(photo.depth_requested and photo.depth_enabled and photo.auto_depth,"Existing 2D-to-3D viewing choice survives spatial mode")
	photo._spatial_auto_due=true; photo._maybe_start_spatial()
	check(not photo.spatial_requested and not photo.spatial_preferred,"Manual exit keeps the original stereo view instead of immediately auto-enabling again")
	check(photo.set_depth(false) and not photo.can_spatial(),"Turning 2D-to-3D off restores ordinary 2D without spatial conversion")
	photo.platform=Host.new(); photo.set_depth(true)
	check(not photo.spatial_preferred,"A manual spatial Off choice survives conversion Off/On on the same photo")
	photo.depth_requested=false; photo.depth_enabled=false
	var host:=Host.new(); photo.platform=host; photo._metadata={"native_stereo":true}; photo.stereo_sbs=true
	photo._texture=ImageTexture.create_from_image(pair); photo._display_result={"image":pair}; photo._display_depth_data={}
	photo._apply_geometry(); photo.spatial_preferred=true; photo._spatial_auto_due=true; photo._maybe_start_spatial()
	check(photo.spatial_requested and host.calls==1,"Native Apple automatically requests its scene without enabling mono conversion")
	var token: int=host.token
	photo._on_spatial_depth(1,JSON.stringify({"state":"error","scene_token":token-1}))
	check(photo.spatial_requested and photo._spatial_waiting,"Stale depth response cannot fail the active mode")
	var depth_path:=ProjectSettings.globalize_path(directory.path_join("left-depth.bin"))
	var model_depth: Image=f.depth.duplicate(); model_depth.resize(518,518,Image.INTERPOLATE_NEAREST)
	FileAccess.open(depth_path,FileAccess.WRITE).store_buffer(model_depth.get_data())
	photo._on_spatial_depth(1,JSON.stringify({"state":"ready","scene_token":token,"path":depth_path,"width":518,"height":518,"rect":[0,0,1,1]}))
	await settle(photo._spatial)
	check(photo._spatial.report.source_eye=="left" and photo._spatial.surfaces[0].material_override.get_shader_parameter("image_texture").get_image().get_pixel(150,100).r>.9,"Native success callback builds the left-eye scene through the production lifecycle")
	check(photo.set_spatial_mode(false,true),"Native static viewing action accepts the completed scene")
	check(photo.stereo_sbs and photo._metadata.native_stereo and not photo.depth_requested,"Native stereo settings survive entering and leaving spatial mode")
	photo._on_spatial_depth(1,JSON.stringify({"state":"error","scene_token":token}))
	check(not photo.spatial_requested,"Late response cannot reactivate the scene")
	photo.close_image(); photo.queue_free(); await process_frame
	for lang in ["en","zh","zh_Hant","ja"]:
		I18n.use(lang)
		var menu:=Menu.new(); root.add_child(menu)
		menu.state_provider=func(): return {"has_image":true,"geometry":0,"spatial_available":true,"count":1}
		menu._mode_open=true; menu.refresh()
		check(not menu._spatial_mode(),"A snapshot without a viewing-mode choice defaults to static 3D in "+lang)
		check(menu._buttons.any(func(b):return b.target==Menu.PHOTO_SPATIAL and b.enabled),"Mode picker exposes spatial view in "+lang)
		var actions: Array=[]
		menu.action_requested.connect(func(action):actions.append(action))
		menu._activate(Menu.PHOTO_SPATIAL)
		check(actions==["photo_spatial"],"Spatial entry dispatches the shared ray-menu action in "+lang)
		menu.free()
	for failure in failures: push_error(failure)
	print("Photo spatial scene: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
