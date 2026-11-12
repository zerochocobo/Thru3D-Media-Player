extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Presentation := preload("res://tests/test_photo_presentation.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/photo-transitions-20261112")
var view: SubViewport
var camera: Camera3D

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func make_photo() -> Node3D:
	var photo := Photo.new(); photo.auto_depth = false; photo.history_enabled = false
	(view if view else root).add_child(photo)
	photo.set_process(false); photo.gallery.set_process(false)
	photo.platform = Presentation.Host.new()
	photo.queue.assign([{"uri":"file://one.jpg", "title":"One"}, {"uri":"file://two.jpg", "title":"Two"}, {"uri":"file://three.jpg", "title":"Three"}])
	photo.index = 0; photo.local_uri = "file://one.jpg"; photo._display_request = 10; photo._request = 10
	photo._size = Vector2(320, 200)
	photo.screen_curve = 0; photo.screen_scale = 0.6; photo.flat_pose.origin = Vector3(0, 0, -3)
	var pixels := Image.create(320, 200, false, Image.FORMAT_RGBA8); pixels.fill(Color.RED)
	photo._texture = ImageTexture.create_from_image(pixels)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo.sharpness = 0; photo.edge_feather_strength = 0
	photo._display_info = {"width":320,"height":200,"path":"unused.jpg"}
	photo._apply_geometry(); photo.panel.visible = true
	return photo

func advance(photo: Node3D, effect: String) -> void:
	photo.autoplay.set_effect(effect); photo.autoplay.set_enabled(true)
	photo.autoplay.advancing = true
	check(photo.navigate(1), "Production next-image accepts " + effect)
	photo.autoplay.advancing = false

func accept(photo: Node3D, dimensions := Vector2i(200, 320), instant := false, pixels: Image = null) -> void:
	if pixels == null:
		pixels = Image.create(dimensions.x, dimensions.y, false, Image.FORMAT_RGBA8); pixels.fill(Color.BLUE)
	var data := {"image":pixels,"info":{"width":pixels.get_width(),"height":pixels.get_height(),"path":"unused.jpg"}}
	photo._prepare_display(data, {"id":photo._request,"index":photo.pending_index,"serial":photo._serial,"instant":instant,"render_ready":instant})
	photo._process_presentation()

func behavior_checks() -> void:
	for effect in ["cut", "fade"]:
		for cached in [false, true]:
			var photo := make_photo()
			var pose: Transform3D = photo.panel.transform; var size: Vector2 = photo._flat.size
			advance(photo, effect)
			check(photo.loading and photo.slideshow.waiting and not photo.placeholder_visible() and not photo._transition_active, "Loading keeps the current picture without sliding or frost")
			photo._on_metadata(photo._request, photo._serial, photo.pending_index, {"width":200,"height":320})
			check(photo.panel.transform.is_equal_approx(pose) and photo._flat.size.is_equal_approx(size), "Incoming portrait metadata cannot move or resize the frame")
			accept(photo, Vector2i(200,320), cached)
			check(photo.panel.transform.is_equal_approx(pose) and photo._flat.size.is_equal_approx(size), "Accepted portrait keeps the fixed frame")
			check(photo.layer_content_scale().is_equal_approx(Vector2(0.390625,1)), "Portrait is contained without stretching or cropping")
			check(not photo.placeholder_visible() and not photo._transition_active, "New effects never enter the legacy transition")
			if effect == "fade":
				check(photo.slideshow.fading and not photo.autoplay_ready(), "Cached and uncached fade both hold the next dwell")
				photo.slideshow.tick(photo.slideshow.FADE_SECONDS * 0.5)
				check(is_equal_approx(photo.material.get_shader_parameter("slideshow_mix"),0.5), "Fade reaches a real halfway mix")
				check(photo.panel.transform.is_equal_approx(pose), "Fade has no spatial movement")
				photo.slideshow.tick(photo.slideshow.FADE_SECONDS)
			check(not photo.slideshow.busy() and photo.autoplay_ready(), "Finished transition releases autoplay readiness")
			check(photo.slideshow.outgoing == null and photo.material.get_shader_parameter("slideshow_old_texture") == null, "Outgoing GPU references are released after the transition")
			var origin := XROrigin3D.new(); photo.add_child(origin)
			var layer := VideoLayer.new(null)
			var values := layer.layer_values(photo, origin, VideoLayer.PICTURE, Vector2(200,320))
			check(values.size() >= 15 and is_equal_approx(values[13],size.x*0.390625) and is_equal_approx(values[14],size.y), "Native layer uses the same contained picture size")
			photo.navigate(1)
			check(not photo.slideshow.locked() and photo._transition_active and photo.placeholder_visible(), "Manual navigation retains its original slide and releases the fixed frame")
			photo.free()
	for effect in ["wipe", "depth"]:
		var swept := make_photo()
		advance(swept, effect); accept(swept, Vector2i(320,200))
		check(swept.slideshow.fading and swept.material.get_shader_parameter("slideshow_style") == swept.slideshow.STYLES[effect], "%s starts a shader sweep" % effect)
		check(swept.material.get_shader_parameter("slideshow_depth_source") == 0, "%s without any depth map does not sample one" % effect)
		swept.slideshow.tick(swept.slideshow.SECONDS[effect] * 0.9)
		check(swept.slideshow.fading, "%s runs its own longer duration" % effect)
		swept.slideshow.tick(swept.slideshow.SECONDS[effect])
		check(not swept.slideshow.busy() and swept.autoplay_ready(), "%s finishes and releases the next dwell" % effect)
		swept.free()
	var ordered := make_photo()
	advance(ordered, "depth")
	var ordered_image := Image.create(320, 200, false, Image.FORMAT_RGBA8); ordered_image.fill(Color.BLUE)
	ordered._prepare_display({"image":ordered_image,"info":{"width":320,"height":200,"path":"unused.jpg"}}, {"id":ordered._request,"index":ordered.pending_index,"serial":ordered._serial,"instant":false,"render_ready":false})
	var near_map := Image.create(4, 4, false, Image.FORMAT_RF); near_map.fill(Color(.8,0,0))
	ordered._depth_texture = ImageTexture.create_from_image(near_map)
	ordered._process_presentation()
	check(ordered.material.get_shader_parameter("slideshow_depth_source") == 1, "Depth dissolve orders the reveal by the incoming depth map")
	ordered.free()
	var held := make_photo()
	advance(held, "cut")
	var ready := Image.create(200, 320, false, Image.FORMAT_RGBA8); ready.fill(Color.BLUE)
	held._prepare_display({"image":ready,"info":{"width":200,"height":320,"path":"unused.jpg"}}, {"id":held._request,"index":held.pending_index,"serial":held._serial,"instant":false,"render_ready":false})
	var state: Dictionary = held.snapshot()
	check(held.slideshow.waiting and held._presentation_pending and not state.loading and not state.preparing_depth, "A ready picture held for one frame is not reported as loading")
	held._process_presentation()
	check(held.slideshow.locked() and not held.slideshow.busy(), "Cut keeps the fixed frame while autoplay runs")
	held.toggle_autoplay(); held._process(0.0)
	check(not held.autoplay.enabled and not held.slideshow.locked() and held.layer_content_scale() == Vector2.ONE 		and is_equal_approx(held._flat.size.x / held._flat.size.y, 200.0 / 320.0), "Stopping autoplay returns the window to the picture's own shape")
	held.free()
	var photo := make_photo()
	advance(photo, "fade")
	var stale := {"id":photo._request,"index":photo.pending_index,"serial":photo._serial}
	photo.navigate(1)
	check(not photo.slideshow.busy() and photo.slideshow.outgoing == null, "Manual interruption releases pending transition resources")
	photo._on_ready(stale.id, JSON.stringify({"state":"ready","width":16,"height":16,"path":"unused.jpg"}))
	check(photo.index == 0 and photo.pending_index == 2, "Late old selection cannot replace the manual target")
	photo.free()
	# Cold 3D preparation must not consume dwell time or replace the retained picture with frost.
	photo=make_photo()
	var held_origin:=XROrigin3D.new();photo.add_child(held_origin)
	var held_camera:=XRCamera3D.new();held_origin.add_child(held_camera);photo.view_camera=held_camera
	photo.video_layer=Presentation.Layer.new(photo.platform);photo._full_image=photo._texture.get_image()
	for i in 4:photo._process_layer()
	check(photo.layer_shown,"Fixture submits the old native photo before loading")
	var submissions: int=photo.video_layer.submissions
	var key: String=photo._layer_key
	advance(photo,"fade")
	photo.flat_pose.origin.x+=.25;photo._apply_flat_pose();photo._process_layer()
	check(photo.layer_shown and photo.video_layer.submissions==submissions+1 and photo._layer_key==key,"Loading resubmits the old layer when its window moves")
	check(photo._hole.transform.is_equal_approx(photo.panel.transform),"The retained native cutout follows the moved window")
	photo.free()
	for effect in ["cut", "fade"]:
		photo = make_photo();photo.auto_depth = true
		var origin := XROrigin3D.new();photo.add_child(origin)
		var xr_camera := XRCamera3D.new();origin.add_child(xr_camera);photo.view_camera = xr_camera
		photo.video_layer = Presentation.Layer.new(photo.platform)
		advance(photo,effect)
		accept(photo,Vector2i(200,320))
		check(photo.loading and photo.slideshow.waiting and not photo.placeholder_visible(),"Next 3D conversion retains the outgoing image")
		var depth := Image.create(32,32,false,Image.FORMAT_RF);depth.fill(Color(.7,0,0))
		var pair := Image.create(400,320,false,Image.FORMAT_RGBA8);pair.fill(Color.BLUE)
		photo._finish_depth(photo._request,{"image":depth,"rect":Vector4(0,0,1,1),"stereo_image":pair,"strength":photo.depth_strength,"strategy":"video_soft_shift_gpu"},false)
		photo._process_presentation()
		check(not photo.slideshow.waiting and (photo.slideshow.fading == (effect=="fade")),"3D transition starts only after the final stereo result")
		photo.slideshow.tick(1)
		for i in 4:photo._process_layer()
		check(photo.layer_shown and photo.autoplay_ready(),"Completed 3D returns to the native layer before the next dwell")
		var keep: Vector4=photo._hole_material.get_shader_parameter("keep_rect")
		check(keep.x>.3 and keep.z<.4,"Native cutout is contained within the portrait content")
		photo.free()
	# Frame geometry remains fixed through source rotations and repeated transitions.
	photo = make_photo();photo.screen_curve=35;photo._apply_geometry()
	var shape: Mesh=photo.panel.mesh;var fixed: Transform3D=photo.panel.transform
	advance(photo,"cut");photo._image_rotations["file://two.jpg"]=90.0
	accept(photo,Vector2i(200,320))
	check(photo.panel.mesh==shape and photo.panel.transform.is_equal_approx(fixed),"Source rotation leaves the curved window unchanged")
	check(not photo.slideshow.layer_compatible(),"Rotated source mapping uses the shader instead of a stretched native layer")
	advance(photo,"fade");accept(photo,Vector2i(400,100));photo.slideshow.tick(1)
	check(photo.panel.mesh==shape and photo.panel.transform.is_equal_approx(fixed),"Repeated landscape transition keeps the original curved window")
	photo.free()
	photo=make_photo();advance(photo,"cut");accept(photo,Vector2i(10,10000))
	photo.edge_feather_strength=3;photo._shape_screen()
	check(photo._edge_feather().x<.1 and photo._layer_keep().x<.5,"Very narrow content retains a valid feather and compositor centre")
	photo.inspect=true;photo.crop_center=Vector2(.5,.6);photo._update_inspect()
	var detail_center: Vector2=photo._detail_material.get_shader_parameter("crop_center")
	check(is_equal_approx(detail_center.x,.5),"Magnifier remains centred in contained portrait pixels")
	photo.free()
	photo = make_photo();advance(photo,"cut")
	photo._on_ready(photo._request, JSON.stringify({"state":"error"}))
	check(not photo.slideshow.busy() and photo.index == 0 and photo.panel.visible and not photo.error.is_empty(), "Failed loading retains the old picture and ends the pending transition")
	photo.free()
	photo = make_photo();advance(photo,"fade");photo.close_image()
	check(not photo.slideshow.locked() and photo.slideshow.outgoing == null, "Closing releases the fixed frame and pending snapshot")
	photo.free()

func pixels(name: String) -> Image:
	for frame in 3: await process_frame; await RenderingServer.frame_post_draw
	var result := view.get_texture().get_image()
	check(result.save_png(output.path_join(name+".png")) == OK, "Render saved " + name)
	return result

func render_checks() -> void:
	view = SubViewport.new(); view.size = Vector2i(960,640); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var world := WorldEnvironment.new(); world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR; world.environment.background_color = Color(0,1,0)
	view.add_child(world)
	camera = Camera3D.new(); camera.fov = 60; view.add_child(camera)
	var photo := make_photo()
	var before := await pixels("fade-before")
	advance(photo,"fade")
	var waiting := await pixels("fade-loading")
	check(before.get_data() == waiting.get_data(), "Slow loading leaves the rendered picture unchanged")
	accept(photo,Vector2i(200,320))
	var start := await pixels("fade-start")
	check(before.get_data() == start.get_data(), "Fade starts with exactly the old image")
	photo.slideshow.tick(photo.slideshow.FADE_SECONDS * 0.5)
	var half := await pixels("fade-middle")
	var center := half.get_pixel(480,320)
	check(center.r > .35 and center.b > .35 and center.g < .05, "Opaque midpoint mixes red and blue without leaking the green background")
	photo.slideshow.tick(photo.slideshow.FADE_SECONDS)
	var after := await pixels("fade-after")
	check(after.get_pixel(480,320).b > .9 and after.get_pixel(300,320).g > .9, "Portrait has blue content and transparent side margins")
	photo.free()
	# Old/new native stereo layout and eye swap are sampled independently in one blend.
	photo = make_photo();photo.stereo_sbs = true;photo._size = Vector2(640,200)
	var old := Image.create(640,200,false,Image.FORMAT_RGBA8);old.fill(Color.RED);old.fill_rect(Rect2i(320,0,320,200),Color.GREEN)
	photo._texture = ImageTexture.create_from_image(old);photo.material.set_shader_parameter("photo_texture",photo._texture);photo._apply_geometry()
	advance(photo,"fade")
	var next := Image.create(320,400,false,Image.FORMAT_RGBA8);next.fill(Color.BLUE);next.fill_rect(Rect2i(0,200,320,200),Color.WHITE)
	photo.load_mode_lock({"geometry":0,"layout":2,"fisheye_fov":180,"depth":false})
	accept(photo, Vector2i(320,400), false, next)
	photo.slideshow.tick(photo.slideshow.FADE_SECONDS*.5)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		var rendered := await pixels("stereo-eye-%d"%eye)
		var c := rendered.get_pixel(480,320)
		check(c.b>.35 and ((c.r>.35 and c.g<.05) if eye==0 else (c.g>.9)), "SBS to TB fade keeps source eye "+str(eye))
	photo.free()
	photo=make_photo()
	var translucent:=Image.create(320,200,false,Image.FORMAT_RGBA8);translucent.fill(Color(1,0,0,.5))
	photo._texture=ImageTexture.create_from_image(translucent);photo.material.set_shader_parameter("photo_texture",photo._texture)
	var alpha_before:=await pixels("alpha-before")
	advance(photo,"fade")
	translucent=Image.create(320,200,false,Image.FORMAT_RGBA8);translucent.fill(Color(0,0,1,.5))
	accept(photo,Vector2i(320,200),false,translucent);photo.slideshow.tick(photo.slideshow.FADE_SECONDS*.5)
	var alpha_half:=await pixels("alpha-middle")
	check(absf(alpha_before.get_pixel(480,320).g-alpha_half.get_pixel(480,320).g)<.02,"Transparent midpoint preserves alpha without an extra exposure of the background")
	photo.free()
	# Sweeps: halfway through, one side of the frame already shows the new image and the other the old.
	for effect in ["wipe", "depth"]:
		photo = make_photo()
		advance(photo, effect)
		var incoming := Image.create(320,200,false,Image.FORMAT_RGBA8);incoming.fill(Color.BLUE)
		photo._prepare_display({"image":incoming,"info":{"width":320,"height":200,"path":"unused.jpg"}}, {"id":photo._request,"index":photo.pending_index,"serial":photo._serial,"instant":false,"render_ready":false})
		if effect == "depth":
			var map := Image.create(8,1,false,Image.FORMAT_RF)
			for x in 8: map.set_pixel(x,0,Color(1.0 if x < 4 else 0.0,0,0))
			photo._depth_texture = ImageTexture.create_from_image(map)
			photo.material.set_shader_parameter("depth_texture", photo._depth_texture)
		photo._process_presentation()
		photo.slideshow.tick(photo.slideshow.SECONDS[effect] * 0.5)
		var swept := await pixels("%s-middle" % effect)
		var left := 960; var right := -1
		for x in 960:
			if swept.get_pixel(x,320).g < .5: left = mini(left,x); right = maxi(right,x)
		var early := swept.get_pixel(left + (right-left)/5, 320); var late := swept.get_pixel(right - (right-left)/5, 320)
		check(right > left and early.b > .9 and late.r > .9, "%s halfway shows new pixels on one side and old on the other" % effect)
		photo.slideshow.tick(photo.slideshow.SECONDS[effect])
		var done := await pixels("%s-after" % effect)
		check(done.get_pixel(left + 4, 320).b > .9 and done.get_pixel(right - 4, 320).b > .9, "%s ends on the full new image" % effect)
		photo.free()
	view.free();view=null

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	behavior_checks()
	if DisplayServer.get_name() != "headless": await render_checks()
	for failure in failures: push_error(failure)
	print("Photo slideshow transitions: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
