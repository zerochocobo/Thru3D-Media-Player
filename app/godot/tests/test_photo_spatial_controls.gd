extends SceneTree
const Fixture:=preload("res://tests/test_photo_spatial_scene.gd")
const Photo:=preload("res://scripts/photo_display.gd")
const Menu:=preload("res://scripts/photo_menu.gd")
const VideoMenu:=preload("res://scripts/player_menu.gd")
var checks:=0
var failures: Array[String]=[]

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

static func state(native: bool, spatial: bool, converted: bool = true) -> Dictionary:
	return {"has_image":true,"geometry":0,"count":1,"native_stereo":native,"stereo":native,
		"spatial_preferred":spatial,"spatial_requested":spatial and (native or converted),"spatial_ready":spatial,
		"depth_requested":converted and not native,"depth_enabled":converted and not native,
		"depth_available":not native,"depth_strength":1.0}

func click(menu: Node3D,target: int) -> void:
	var entry: Dictionary=menu._buttons.filter(func(b):return b.target==target)[0]
	var origin: Vector3=entry.node.to_global(Vector3(0,0,1))
	var direction: Vector3=-entry.node.global_basis.z
	check(menu.press_pointer("right",origin,direction,true),"Ray presses target %d"%target)
	menu.release_pointer("right",origin,direction,true)

func run() -> void:
	var f:=Fixture.fixture()
	var pair:=Image.create(640,240,false,Image.FORMAT_RGBA8)
	pair.blit_rect(f.image,Rect2i(0,0,320,240),Vector2i.ZERO)
	var photo:=Photo.new(); root.add_child(photo); photo.set_process(false)
	photo._texture=ImageTexture.create_from_image(f.image); photo._display_result={"image":f.image}
	photo._size=Vector2(320,240); photo._display_request=1; photo.history_enabled=false
	photo.depth_requested=true; photo.depth_enabled=true; photo.platform=Fixture.StereoHost.new()
	photo._display_depth_data={"image":f.depth,"rect":f.rect,"stereo_image":pair,"strength":2.0}
	photo.depth_strength=2.0; photo._apply_geometry(); photo.panel.visible=true
	check(photo.set_spatial_mode(true),"Converted photo enters spatial mode using its completed stereo pair")
	await wait_scene(photo)
	var first: PackedVector3Array=photo._spatial.surfaces[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(photo._spatial.report.strength==1.0 and photo.depth_strength==2.0,"Spatial relief is fixed while the 200% stereo choice survives")
	check(photo.set_spatial_mode(false) and not photo.spatial_preferred and photo.depth_strength==2.0,"Spatial Off restores the previous original stereo setting")
	photo.depth_strength=.5; photo._display_depth_data.strength=.5
	check(photo.set_spatial_mode(true),"Same photo can reenter from a different original stereo strength")
	await wait_scene(photo)
	var second: PackedVector3Array=photo._spatial.surfaces[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(first==second,"Original 50% and 200% choices produce identical fixed spatial geometry")
	photo.set_spatial_mode(false)
	photo.set_depth(false); photo.set_depth(true)
	check(not photo.spatial_preferred,"Conversion Off/On does not silently undo the selected spatial Off mode")
	photo.platform=null; photo.close_image(); photo.free(); await process_frame
	var native_photo:=Photo.new(); root.add_child(native_photo); native_photo.set_process(false)
	native_photo._texture=ImageTexture.create_from_image(pair); native_photo._display_result={"image":pair}
	native_photo._metadata={"native_stereo":true}; native_photo.stereo_sbs=true
	native_photo._size=Vector2(640,240); native_photo._display_request=1; native_photo.history_enabled=false; native_photo.auto_depth=true
	native_photo.platform=Fixture.Host.new(); native_photo._apply_geometry(); native_photo.panel.visible=true
	native_photo._spatial_auto_due=true; native_photo._maybe_start_spatial()
	check(native_photo.spatial_requested,"Apple still enters the default spatial mode automatically")
	var native_host: RefCounted=native_photo.platform
	var native_strength: float=native_photo.depth_strength
	check(not native_photo.set_depth_strength(0) and not native_photo.set_depth_strength(2) and native_photo.spatial_requested and native_photo.depth_strength==native_strength,"Native strength changes, including zero, cannot alter its mode or captured depth")
	check(native_photo.set_spatial_mode(false,true) and not native_photo.spatial_requested and not native_photo.spatial_preferred,"Apple can switch to static mode through the production viewing-mode action")
	check(native_photo.stereo_sbs and native_photo._metadata.native_stereo and not native_photo.depth_requested and native_photo.auto_depth,"Static Apple preserves its captured pair and the ordinary-photo auto-conversion preference")
	native_photo._spatial_auto_due=true; native_photo._maybe_start_spatial()
	native_photo._on_spatial_depth(1,JSON.stringify({"state":"error","scene_token":native_host.token}))
	check(not native_photo.spatial_requested and native_host.calls==1 and native_photo.spatial_error.is_empty(),"Auto startup and late native scene responses cannot override a static selection")
	check(native_photo.set_spatial_mode(true) and native_photo.spatial_requested and native_host.calls==2,"Apple can switch back to head-tracked spatial mode")
	check(native_photo.set_spatial_mode(false,true) and native_host.cancelled==2 and native_photo.depth_strength==native_strength,"Native mode changes cancel pending scene work without adjusting strength")
	native_photo.spatial_error="Spatial view unavailable"
	check(native_photo.set_spatial_mode(false,true) and native_photo.spatial_error.is_empty(),"Choosing native static mode clears a previous scene-generation error")
	native_photo.set_spatial(false,true); native_photo.platform=null; native_photo.close_image(); native_photo.free(); await process_frame

	var menu:=Menu.new(); root.add_child(menu); menu.set_process(false); menu.visible=true
	var current:=state(false,true)
	menu.state_provider=func():return current
	var actions: Array=[]; var strengths: Array=[]; var commits: Array=[]
	menu.action_requested.connect(func(action):
		actions.append(action)
		if action=="photo_spatial": current.spatial_preferred=not current.spatial_preferred; current.spatial_requested=current.spatial_preferred
		elif action=="photo_spatial_on": current.spatial_preferred=true; current.spatial_requested=true
		elif action=="photo_static": current.spatial_preferred=false; current.spatial_requested=false; current.depth_requested=not current.native_stereo
		elif action=="depth": current.depth_requested=not current.depth_requested)
	menu.depth_strength_requested.connect(func(value):strengths.append(value); current.depth_strength=value; current.depth_requested=value>0)
	menu.depth_strength_committed.connect(func():commits.append(true))
	for lang in ["en","zh","zh_Hant","ja"]:
		Fixture.I18n.use(lang)
		for native in [false,true]:
			for spatial in [false,true]:
				current.assign(state(native,spatial)); menu._depth_open=true; menu.refresh()
				if native:
					check(menu._depth_open and menu._can_depth(),"Native Apple photos can open the viewing-mode popup: "+lang)
					check(menu._buttons.any(func(b):return b.target==Menu.PHOTO_DEPTH and b.enabled),"Native Apple 2D-to-3D entry is enabled: "+lang)
					check(menu._buttons.all(func(b):return b.target not in [Menu.DEPTH,Menu.DEPTH_RESET]),"Native Apple has no strength or reset controls in either viewing mode")
				check(menu._buttons.any(func(b):return b.target==Menu.PHOTO_SPATIAL and b.enabled),"Photo mode switch remains reachable: %s/%s/%s"%[lang,native,spatial])
				check(menu._buttons.filter(func(b):return b.get("photo_mode_selected",false)).size()==1,"Viewing modes always have exactly one selected radio")
				var rail:=menu._buttons.any(func(b):return b.target==Menu.DEPTH)
				check(rail==(not native and not spatial),"Only original converted-photo mode has a depth rail: %s/%s/%s"%[lang,native,spatial])
				check(is_instance_valid(menu._depth_knob)==rail,"Hidden rail leaves no knob/reset controls")
	current.assign(state(false,true)); menu._depth_open=true; menu.refresh()
	click(menu,Menu.PHOTO_STATIC)
	check(not current.spatial_preferred and menu._depth_open and is_instance_valid(menu._depth_knob),"Mode switch reveals the original 0..200 rail without closing the popup")
	var entry: Dictionary=menu._buttons.filter(func(b):return b.target==Menu.DEPTH)[0]
	var span: Vector2=menu._depth_span()
	var low_y: float=lerpf(span.x,span.y,Menu.DepthStrength.to_fraction(.01))
	var low_origin: Vector3=entry.node.to_global(Vector3(0,low_y-entry.rect.get_center().y,1))
	check(menu.press_pointer("right",low_origin,-entry.node.global_basis.z,true) and is_equal_approx(strengths.back(),.01),"Photo rail has no artificial bottom Off dead zone above 0%")
	menu.release_pointer("right",low_origin,-entry.node.global_basis.z,true)
	var origin: Vector3=entry.node.to_global(Vector3(0,span.y-entry.rect.get_center().y,1))
	check(menu.press_pointer("right",origin,-entry.node.global_basis.z,true) and strengths.back()==2.0,"Ray reaches 200% in original stereo mode")
	menu.release_pointer("right",origin,-entry.node.global_basis.z,true)
	check(commits.size()==2 and not menu.has_pointer_capture() and not current.spatial_preferred,"Each slider release commits once and leaves spatial mode Off")
	click(menu,Menu.PHOTO_SPATIAL)
	check(current.spatial_preferred and not is_instance_valid(menu._depth_knob),"Spatial On removes the depth rail immediately")
	click(menu,Menu.PHOTO_SPATIAL)
	check(current.spatial_preferred and menu._buttons.filter(func(b):return b.get("photo_mode_selected",false)).size()==1,"Clicking the selected radio never toggles the mode off")
	current.assign(state(true,true)); menu._depth_open=false; menu.refresh()
	click(menu,Menu.PHOTO_DEPTH)
	check(menu._depth_open,"Ray opens the native viewing-mode entry")
	var strength_count:=strengths.size()
	click(menu,Menu.PHOTO_STATIC)
	check(not current.spatial_preferred and not current.depth_requested and menu._depth_open and not is_instance_valid(menu._depth_knob),"Native static selection keeps the popup open with no strength rail")
	click(menu,Menu.PHOTO_STATIC)
	check(not current.spatial_preferred and strengths.size()==strength_count,"Selecting native static twice does not convert the pair or emit a strength change")
	click(menu,Menu.PHOTO_SPATIAL)
	check(current.spatial_preferred and not is_instance_valid(menu._depth_knob),"Native spatial selection also has no strength rail")
	var count:=actions.size()
	menu._press_quick_icon("right",Menu.PHOTO_DEPTH); menu._icon_tap={"released":true,"hand":"right","target":Menu.PHOTO_DEPTH,"source":"","time":Time.get_ticks_msec()}
	menu._press_quick_icon("right",Menu.PHOTO_DEPTH)
	check(actions.size()==count and strengths.size()==strength_count,"Native Apple photos never expose a double-click conversion or strength action")
	menu.free()
	var video:=VideoMenu.new(); root.add_child(video); video.visible=true; video.set_process(false)
	video.state_provider=func():return {"has_video":true,"geometry":0,"depth_requested":true,"depth_strength":1.0}
	video._depth_open=true; video.refresh()
	check(is_instance_valid(video._depth_knob) and video._buttons.all(func(b):return b.target!=Menu.PHOTO_SPATIAL) and video._depth_span()==VideoMenu.DEPTH_SPAN,"Video keeps its exact original depth slider coordinates without a photo spatial switch")
	video.free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo spatial controls: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func wait_scene(photo: Node3D) -> void:
	var deadline:=Time.get_ticks_msec()+30000
	while not photo._spatial.prepared and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(photo._spatial.prepared,"Spatial worker finishes")
