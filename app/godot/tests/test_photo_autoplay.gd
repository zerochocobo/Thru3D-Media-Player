extends SceneTree
const Auto := preload("res://scripts/photo_autoplay.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Presentation := preload("res://tests/test_photo_presentation.gd")
const I18n := preload("res://scripts/i18n.gd")
var now_us := 0
var checks:=0
var failures: Array[String]=[]
var output:=ProjectSettings.globalize_path("res://../../build/output/photo-autoplay")

class Slide extends Node3D:
	signal changed
	var queue: Array=[0,1,2]
	var queue_complete:=true
	var loading:=false
	var presented:=true
	var failed:=false
	var serial:=0
	var advances:=0
	var accepts:=true
	func autoplay_failed() -> bool: return failed
	func autoplay_ready() -> bool: return presented and not loading
	func autoplay_identity() -> Array: return [serial]
	func navigate(direction: int) -> bool:
		if not accepts: return false
		advances+=direction; serial+=1; loading=true; return true

class Harness extends "res://scripts/main.gd":
	var focused:=true
	func _input_focused() -> bool: return focused
	func _vr_passthrough_active() -> bool: return false

func _initialize() -> void: run.call_deferred()
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func tick(auto: RefCounted, photo: Node3D, delta: float, blocked: bool, wall_seconds: float = -1) -> bool:
	now_us += roundi((delta if wall_seconds < 0 else wall_seconds) * 1000000)
	return auto.tick(photo, delta, blocked)

func main_tick(main: Node3D, delta: float) -> void:
	now_us += roundi(delta * 1000000)
	main._tick_photo_autoplay(delta)

func scheduler_checks() -> void:
	var auto:=Auto.new(); auto.clock=func(): return now_us
	var slide:=Slide.new()
	check(not auto.enabled and auto.interval==5,"Autoplay starts off with five seconds")
	check(auto.effect=="slide", "Existing settings default to the original slide")
	for value in [null, 1, true, "unknown"]:
		check(not auto.set_effect(value) and auto.effect=="slide", "Invalid transition cannot alter the saved style")
	for value in [NAN,INF,-INF,"10",true]:
		check(not auto.set_interval(value) and auto.interval==5,"Invalid interval cannot corrupt the timer")
	auto.set_interval(1);check(auto.interval==3,"Minimum interval is three seconds")
	auto.set_interval(50);check(auto.interval==30,"Maximum interval is thirty seconds")
	auto.set_interval(5);auto.set_enabled(true);slide.presented=false
	for frame in 300: tick(auto,slide,1,false)
	check(slide.advances==0,"Minutes of loading/conversion never spend display time or queue advances")
	slide.presented=true;tick(auto,slide,1,false)
	for second in 4: tick(auto,slide,1,false)
	check(slide.advances==0,"Ready image receives the complete five-second dwell")
	check(tick(auto,slide,1,false) and slide.advances==1,"Exactly one normal next-image action occurs after the dwell")
	for frame in 100: tick(auto,slide,1,false)
	check(slide.advances==1,"Slow next-image load cannot produce repeated requests")
	slide.loading=false;tick(auto,slide,1,false);tick(auto,slide,1,false)
	tick(auto,slide,1,true);tick(auto,slide,1,false)
	for second in 4:tick(auto,slide,1,false)
	check(slide.advances==1,"Interaction pause starts a fresh full dwell on resume")
	tick(auto,slide,1,false);check(slide.advances==2,"Resumed dwell advances normally")
	slide.loading=false;tick(auto,slide,1,false);tick(auto,slide,1,false);slide.serial+=1
	tick(auto,slide,1,false)
	for second in 4:tick(auto,slide,1,false)
	check(slide.advances==2,"Manual selection or effect rebuild restarts the clock")
	tick(auto,slide,1,false);check(slide.advances==3,"New presentation receives its own dwell")
	slide.loading=false;tick(auto,slide,0,false)
	for frame in 12: tick(auto,slide,1.0/90.0,false,.4)
	check(slide.advances==3,"Clamped frame deltas do not shorten the five-second dwell")
	tick(auto,slide,1.0/90.0,false,.21)
	check(slide.advances==4,"Five elapsed display seconds advance even during slow startup frames")
	slide.loading=false;tick(auto,slide,0,false);tick(auto,slide,60,false)
	check(slide.advances==5,"A foreground frame stall submits at most one ordinary advance")
	for frame in 60: tick(auto,slide,1,false)
	check(slide.advances==5,"Long stalls never accumulate a backlog of future advances")
	slide.failed=true;tick(auto,slide,.1,false)
	check(not auto.enabled and slide.advances==5,"A load or render failure stops autoplay instead of skipping bad files")
	slide.failed=false;slide.loading=false;slide.accepts=false;auto.set_enabled(true);tick(auto,slide,0,false)
	for second in 5:tick(auto,slide,1,false)
	check(not auto.enabled,"A disabled next-image action stops at a non-looping end")
	slide.queue=[0];auto.set_enabled(true);tick(auto,slide,.1,false)
	check(not auto.enabled,"One-image albums cannot cycle a picture into itself")
	slide.free()

func clock_checks() -> void:
	# Exercise Godot's real clamped process delta under a startup-like CPU stall.
	# The production clock must still advance after three displayed seconds.
	var auto:=Auto.new();auto.set_interval(3);auto.set_enabled(true)
	var slide:=Slide.new();auto.tick(slide,0,false)
	var started:=Time.get_ticks_msec();var frame_seconds:=0.0
	for frame in 10:
		OS.delay_msec(350);await process_frame
		var delta:=root.get_process_delta_time();frame_seconds+=delta
		auto.tick(slide,delta,false)
	check(frame_seconds<3 and Time.get_ticks_msec()-started>=3000,"Startup stall reproduces a shorter engine clock than elapsed display time")
	check(slide.advances==1,"Production monotonic clock advances on time despite slow initial frames")
	print("Photo autoplay real clock: %d ms wall, %.3f s process delta, %d advances"%[Time.get_ticks_msec()-started,frame_seconds,slide.advances])
	slide.free()

func resource_checks() -> void:
	var photo:=make_photo();var host: RefCounted=photo.platform
	photo.autoplay.set_enabled(true);tick(photo.autoplay,photo,0,false)
	for second in 5:tick(photo.autoplay,photo,1,false)
	check(photo.loading and host.next_id==11,"Autoplay invokes the production normal selection exactly once")
	for frame in 500:tick(photo.autoplay,photo,1,false)
	check(host.next_id==11 and photo.pending_index==1,"A stalled real native request cannot accumulate further opens")
	var pixels:=Image.create(320,200,false,Image.FORMAT_RGBA8);pixels.fill(Color(.6,.2,.3))
	photo._prepare_display({"image":pixels,"info":{"width":320,"height":200,"path":"unused.jpg"}},
		{"id":photo._request,"index":1,"serial":photo._serial})
	check(not photo.autoplay_ready(),"Decoded colour still waits for the visible transition")
	photo.finish_transition();photo._process_presentation();tick(photo.autoplay,photo,0,false)
	for second in 4:tick(photo.autoplay,photo,1,false)
	check(host.next_id==11,"Production next image receives its full dwell after final presentation")
	tick(photo.autoplay,photo,1,false)
	check(host.next_id==12 and photo.pending_index==0,"Ordinary album end follows existing Next-image wrap behavior")
	photo.free()

func converted_presentation_checks() -> void:
	var photo:=make_photo();photo.close_image(false)
	photo.queue.assign([{"uri":"file://one.jpg","title":"One"},{"uri":"file://two.jpg","title":"Two"}])
	photo.auto_depth=true
	var origin:=XROrigin3D.new();photo.add_child(origin);var camera:=XRCamera3D.new();origin.add_child(camera);photo.view_camera=camera
	photo.video_layer=Presentation.Layer.new(photo.platform)
	photo._select(0);photo._process(.3)
	var id: int=photo._request
	var color:=Image.create(1024,1024,false,Image.FORMAT_RGBA8);color.fill(Color(.2,.3,.5))
	var proxy:=Image.create(64,64,false,Image.FORMAT_RGBA8);proxy.fill(Color(.2,.3,.5))
	var map:=Image.create(518,518,false,Image.FORMAT_RF);map.fill(Color(.7,0,0))
	var pair:=Image.create(2048,1024,false,Image.FORMAT_RGBA8);pair.fill(Color(.2,.3,.5))
	photo._prepare_display({"image":color,"proxy":proxy,"info":{"width":1024,"height":1024,"path":"unused.jpg"}},
		{"id":id,"index":0,"serial":photo._serial})
	photo.autoplay.set_enabled(true)
	for frame in 100:tick(photo.autoplay,photo,1,false)
	check(photo.platform.next_id==id and (photo._presentation_pending or photo.loading),"Native 3D preparation cannot consume display time")
	photo._finish_depth(id,{"image":map,"rect":Vector4(0,0,1,1),"stereo_image":pair,"strength":photo.depth_strength,"strategy":"video_soft_shift_gpu"},false)
	for frame in 100:tick(photo.autoplay,photo,1,false)
	check(photo.platform.next_id==id and photo.placeholder_visible(),"CPU stereo result still cannot start autoplay under the loading cover")
	for frame in 16:
		photo._process(.1)
		if photo.autoplay_ready():break
	check(photo.autoplay_ready() and photo.layer_shown,"Final native stereo submission releases presentation")
	var presented_identity: Array=photo.autoplay_identity()
	# Leave neighbouring colour/depth requests unfinished while this real stereo
	# presentation stays visible. They must neither block nor restart its dwell.
	photo._prefetch_depth_request=id+100;photo._prefetch_request=id+101
	photo._prefetch_decode={"id":id+101,"index":1}
	check(photo.autoplay_ready(),"Unfinished neighbour 3D conversion and colour preload cannot block the current stereo dwell")
	check(photo.autoplay_identity()==presented_identity,"Neighbour preparation cannot change the current picture's presentation identity")
	tick(photo.autoplay,photo,0,false)
	for second in 4:tick(photo.autoplay,photo,1.0/90.0,false,1)
	check(photo.platform.next_id==id,"Ready stereo image receives its full five seconds")
	check(photo._prefetch_depth_request!=0 and photo._prefetch_request!=0,"Neighbour tasks remain unfinished at the end of the dwell")
	tick(photo.autoplay,photo,1.0/90.0,false,1)
	check(photo.platform.next_id==id+1,"Only the completed stereo dwell selects the next image")
	check(photo.loading and photo.pending_index==1 and photo.placeholder_visible(),"At five seconds an unprepared next picture immediately enters normal loading")
	for second in 20:tick(photo.autoplay,photo,1,false)
	check(photo.platform.next_id==id+1 and not photo.autoplay._armed,"Loading the next picture never consumes its display dwell or opens more pictures")
	# Complete the newly selected picture after a long load. Its own conversion
	# and upload must finish before it receives a fresh, full display interval.
	photo._process(.3)
	photo._prepare_display({"image":color,"proxy":proxy,"info":{"width":1024,"height":1024,"path":"unused-next.jpg"}},
		{"id":id+1,"index":1,"serial":photo._serial})
	for second in 10:tick(photo.autoplay,photo,1,false)
	check(photo.platform.next_id==id+1 and not photo.autoplay._armed,"Next-picture 3D conversion remains outside its five-second display interval")
	photo._finish_depth(id+1,{"image":map,"rect":Vector4(0,0,1,1),"stereo_image":pair,"strength":photo.depth_strength,"strategy":"video_soft_shift_gpu"},false)
	for frame in 16:
		photo._process(.1)
		if photo.autoplay_ready():break
	check(photo.autoplay_ready() and photo.layer_shown,"The newly loaded picture finishes native 3D presentation normally")
	tick(photo.autoplay,photo,0,false)
	for second in 4:tick(photo.autoplay,photo,1,false)
	check(photo.platform.next_id==id+1,"After slow loading the new final picture still stays for the full interval")
	var next_epoch: int=photo._serial
	tick(photo.autoplay,photo,1,false)
	check(photo._serial>next_epoch and (photo.pending_index==0 or photo.index==0),"The next dwell expires independently of all preceding loading time, including a cached wraparound")
	photo.free()

func make_photo() -> Node3D:
	var photo:=Photo.new(); photo.auto_depth=false;photo.history_enabled=false;root.add_child(photo)
	photo.set_process(false);photo.gallery.set_process(false);photo.platform=Presentation.Host.new();photo.autoplay.clock=func(): return now_us
	photo.queue.assign([{"uri":"file://first.jpg","title":"First"},{"uri":"file://next.jpg","title":"Next"}])
	photo.index=0;photo.local_uri="file://first.jpg";photo._display_request=10;photo._request=10
	photo._size=Vector2(320,200)
	var pixels:=Image.create(320,200,false,Image.FORMAT_RGBA8);pixels.fill(Color(.1,.4,.5))
	photo._texture=ImageTexture.create_from_image(pixels);photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._apply_geometry();photo.panel.visible=true
	return photo

func readiness_checks(photo: Node3D) -> void:
	check(photo.autoplay_ready(),"Production plain photo is fully presented")
	for flag in ["loading","_presentation_pending","_transition_active","_rotation_preview","inspect"]:
		photo.set(flag,true);check(not photo.autoplay_ready(),"Production readiness excludes "+flag);photo.set(flag,false)
	photo._reveal_seconds=.1;check(not photo.autoplay_ready(),"Reveal animation does not count as complete");photo._reveal_seconds=0
	photo._placeholder.visible=true;check(not photo.autoplay_ready(),"Loading cover does not count as the picture");photo._placeholder.visible=false
	photo.gallery.mode=2;check(not photo.autoplay_ready(),"Autoplay targets big pictures, not wall overview")
	photo.gallery.focus=0;photo.gallery.progress=.5;check(not photo.autoplay_ready(),"Opening a wall picture waits for the completed focus animation")
	photo.gallery.progress=1;photo.gallery.mode=0;photo.gallery.focus=-1
	photo.depth_requested=true;photo._depth_busy=true;check(not photo.autoplay_ready(),"Current 3D conversion holds the display clock")
	photo._depth_busy=false;photo.depth_requested=false
	photo.portrait_requested=true;photo.portrait_enabled=false;check(not photo.autoplay_ready(),"Portrait segmentation completion is required")
	photo.portrait_enabled=true;photo._portrait_strength=photo.depth_strength-.2
	check(not photo.autoplay_ready(),"An old portrait at a different strength cannot start the clock")
	photo._portrait_strength=photo.depth_strength;check(photo.autoplay_ready(),"Final matching portrait can start the clock")
	photo.portrait_requested=false;photo.portrait_enabled=false
	photo._upload={"row":1};check(not photo.autoplay_ready(),"Final compositor texture upload must finish");photo._upload={}
	var origin:=XROrigin3D.new();photo.add_child(origin);var camera:=XRCamera3D.new();origin.add_child(camera);photo.view_camera=camera
	photo.video_layer=Presentation.Layer.new(photo.platform);photo._full_image=photo._texture.get_image()
	check(not photo.autoplay_ready(),"Available but unsubmitted native picture is not fully shown")
	photo.layer_shown=true;check(photo.autoplay_ready(),"Final native layer submission opens the clock")
	photo.layer_shown=false;photo.depth_requested=true;photo.depth_enabled=true
	photo.platform=null # Valid shader-only depth rendering has no native prepared pair.
	check(photo.autoplay_ready(),"Shader-only 3D does not wait for a nonexistent compositor image")
	photo.depth_requested=false;photo.depth_enabled=false;photo.video_layer=null;photo.view_camera=null;origin.free()
	photo.error="Image unavailable";check(photo.autoplay_failed(),"A production read failure stops the timer");photo.error=""
	photo.auto_depth=true;photo.depth_error="3D unavailable"
	check(photo.autoplay_failed(),"Failed automatic 3D cannot silently turn into repeated 2D fallback advances")
	photo.auto_depth=false;photo.depth_error=""

func controls_checks(photo: Node3D) -> void:
	var main:=Harness.new();main.photo=photo;main.photo_active=true;main.settings_path=output.path_join("settings.cfg")
	main.photo_menu=Menu.new();root.add_child(main.photo_menu);main.photo_menu.set_process(false)
	var menu: Node3D=main.photo_menu;menu.state_provider=photo.snapshot
	menu.action_requested.connect(main._on_photo_action);menu.setting_requested.connect(main._on_photo_adjustment);menu.adjustment_requested.connect(main._on_photo_adjustment)
	main.player_menu=menu;main.recent_menu=preload("res://scripts/library_menu.gd").new();main.recent_menu.visible=false
	menu.visible=true;menu.section=0;menu.refresh()
	var icon := preload("res://scripts/menu_icons.gd").texture("photo_autoplay").get_image()
	var ink := icon.get_used_rect()
	check(ink.position.x >= 4 and ink.position.y >= 4 and ink.end.x <= icon.get_width()-4 and ink.end.y <= icon.get_height()-4,
		"Autoplay strokes retain padding on all four sides of the actual icon canvas")
	var targets: Array=[Menu.PHOTO_GALLERY,Menu.PHOTO_INSPECT,Menu.PHOTO_ADJUST,Menu.PHOTO_AUTOPLAY,Menu.PHOTO_PREVIOUS]
	for index in targets.size()-1:
		var a: Dictionary=menu._buttons.filter(func(b):return b.target==targets[index])[0]
		var b: Dictionary=menu._buttons.filter(func(b):return b.target==targets[index+1])[0]
		check(a.rect.end.x<=b.rect.position.x,"Left controls are ordered and do not overlap")
	menu._activate(Menu.PHOTO_AUTOPLAY)
	check(photo.autoplay.enabled,"Control bar icon turns autoplay on")
	check(menu._buttons.filter(func(b):return b.target==Menu.PHOTO_AUTOPLAY)[0].node.material_override.get_shader_parameter("surface_color")==menu.SELECTED,"Autoplay has a visible selected state")
	main_tick(main,.5);main_tick(main,.5)
	check(photo.autoplay._elapsed>0,"Ordinary photo control bar does not pause autoplay")
	for kind in ["settings","inspect","grab","focus","depth","library","speech"]:
		match kind:
			"settings":menu.section=1
			"inspect":photo.inspect=true
			"grab":main._grab={"hand":"right_hand"}
			"focus":main.focused=false
			"depth":menu._depth_open=true
			"library":main.recent_menu.visible=true
			"speech":photo.comic.speech_state="playing"
		main_tick(main,.5)
		check(photo.autoplay._elapsed==0 and photo.autoplay.enabled,"Interaction/focus pause resets dwell without disabling: "+kind)
		menu.section=0;photo.inspect=false;main._grab={};main.focused=true;menu._depth_open=false;main.recent_menu.visible=false;photo.comic.speech_state="idle"
		main_tick(main,.5);main_tick(main,.5)
	main_tick(main,.5);main_tick(main,.5)
	main._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	now_us += 60000000
	main._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	main_tick(main,.1)
	check(photo.autoplay._elapsed==0 and photo.autoplay.enabled,"Application focus notifications discard all background dwell time")
	menu._activate(Menu.PHOTO_AUTOPLAY);check(not photo.autoplay.enabled,"Second icon click turns autoplay off")
	main._on_photo_adjustment("autoplay_interval",11)
	var saved:=ConfigFile.new();check(saved.load(main.settings_path)==OK,"Autoplay interval is saved")
	var restored:=Photo.new();restored.restore_view_settings(saved)
	check(restored.autoplay.interval==11 and not restored.autoplay.enabled,"Only interval persists; viewing never auto-starts after restart");restored.free()
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language);menu.section=1;menu.refresh()
		var sliders: Array=menu.choices.targets.values().filter(func(item):return item.get("key")=="autoplay_interval" and item.get("kind")=="slider")
		check(sliders.size()==1,"Image settings provide the interval slider in "+language)
		var openers: Array=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_effect" and menu.choices.targets[id].get("kind")=="open")
		check(openers.size()==1 and menu.choices.targets.values().all(func(item):return item.get("key")!="autoplay_effect" or item.get("kind")=="open"),"Transition is one closed dropdown in "+language)
		for effect in Photo.autoplay_effects():
			var opener: int=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_effect" and menu.choices.targets[id].get("kind")=="open")[0]
			menu.choices.action(opener)
			var options: Array=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_effect" and menu.choices.targets[id].get("kind")=="choose")
			check(menu.choices.opened=="autoplay_effect" and options.size()==Photo.autoplay_effects().size(),"Dropdown lists every transition in "+language)
			menu.choices.action(options.filter(func(id):return menu.choices.targets[id].value==effect)[0])
			check(photo.autoplay.effect==effect and photo.snapshot().autoplay_effect==effect and menu.choices.opened.is_empty(),"Choosing a transition applies it and closes the list")
			var opened: int=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_effect")[0]
			var face: Dictionary=menu._buttons.filter(func(item):return item.target==opened)[0]
			check(face.select_caption.text==I18n.t({"cut":"Cut","fade":"Crossfade","wipe":"Soft wipe","depth":"Depth dissolve","slide":"Slide"}[effect]),"Closed dropdown shows the selected transition")
	main._on_photo_adjustment("autoplay_effect","fade")
	saved.load(main.settings_path)
	var restored_effect:=Photo.new();restored_effect.restore_view_settings(saved)
	check(restored_effect.autoplay.effect=="fade" and not restored_effect.autoplay.enabled,"Chosen effect persists without automatically starting playback")
	restored_effect.free()
	var slider_id: int=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_interval" and menu.choices.targets[id].get("kind")=="slider")[0]
	var slider: Dictionary=menu.choices.sliders[slider_id]
	var press: Vector3=slider.node.to_global(Vector3(slider.left+slider.width*.5,0,.5))
	menu.press_pointer("right",press,-menu.global_basis.z,true)
	check(not menu.choices.capture.is_empty(),"The production interval slider captures the pointer")
	var end: Vector3=slider.node.to_global(Vector3(slider.left+slider.width,0,.5))
	menu.update_pointer("right",end,-menu.global_basis.z,true);menu.refresh_values()
	check(photo.autoplay.interval==30 and not menu.choices.capture.is_empty(),"Dragging previews 30 seconds without replacing the captured slider")
	menu.release_pointer("right",end,-menu.global_basis.z,true)
	saved.load(main.settings_path)
	check(float(saved.get_value("photo","autoplay_interval"))==30 and menu.choices.capture.is_empty(),"Releasing commits the exact slider interval to settings")
	menu.section=0;photo.autoplay.set_enabled(true);main.photo_active=false;main_tick(main,.1)
	check(not photo.autoplay.enabled,"Leaving photo mode stops autoplay")
	photo.autoplay.set_enabled(true);photo.close_image()
	check(not photo.autoplay.enabled,"Closing a picture stops autoplay")
	photo.toggle_autoplay();check(not photo.autoplay.enabled,"A closed picture cannot restart autoplay from a retained queue")
	menu.free();main.recent_menu.free();main.free();I18n.use("en")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	scheduler_checks()
	await clock_checks()
	resource_checks()
	converted_presentation_checks()
	var photo:=make_photo();readiness_checks(photo);controls_checks(photo);photo.free()
	for failure in failures:push_error(failure)
	print("Photo autoplay: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
