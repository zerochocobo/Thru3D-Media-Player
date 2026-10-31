extends SceneTree
## Real GL pixels: production auditorium, frame leases, portrait/VR/packed shaders.
## No decoder, OpenXR runtime or inference is simulated by these pixel comparisons.
const Main := preload("res://scripts/main.gd")
var main: Node3D
var view: SubViewport
var textures: Array[ImageTexture] = []
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-alpha-visibility")
var checks := 0
var failures: Array[String] = []
var samples: Array = []

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frame(label: String) -> Image:
	await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	image.save_png(output.path_join(label + ".png"))
	return image
func difference(a: Color, b: Color) -> float:
	return maxf(absf(a.r-b.r), maxf(absf(a.g-b.g), absf(a.b-b.b)))

func bind_source(packed: bool, shape: bool, tint: Color = Color(0.05, 0.95, 0.12)) -> void:
	main.video._binding.unbind(); textures.clear()
	var color := Image.create(1280 if packed else 640,640 if packed else 360,false,Image.FORMAT_RGBA8)
	color.fill(tint)
	var mask := Image.create(640,320,false,Image.FORMAT_R8)
	# Narrow enough to leave visible scenery in both equirectangular and fisheye views.
	for y in 320:
		for x in 320:
			var alpha := smoothstep(.39,.41,x/320.0) * (1.0-smoothstep(.59,.61,x/320.0)) * smoothstep(.25,.27,y/320.0) * (1.0-smoothstep(.73,.75,y/320.0))
			mask.set_pixel(x,y,Color(alpha,0,0)); mask.set_pixel(x+320,y,Color(alpha,0,0))
	if packed:
		# Same six-block fixture packing as tools/media/generate_c04_fixtures.py.
		var packed_mask := mask.duplicate(); packed_mask.resize(512,256,Image.INTERPOLATE_BILINEAR)
		for y in 256:
			for x in 512:
				var dy := 512+y if y < 128 else y-128
				var dx := 512+x if x < 256 else (1152+x-256 if x < 384 else x-384)
				color.set_pixel(dx,dy,Color(packed_mask.get_pixel(x,y).r,0,0))
	var depth := Image.create(320,320,false,Image.FORMAT_R8); depth.fill(Color(2.0/3.0,0,0))
	textures.assign([ImageTexture.create_from_image(color),ImageTexture.create_from_image(mask),ImageTexture.create_from_image(depth)])
	var pair := {"session_id":7,"logical_session_id":7,"generation":1,"frame_id":3,"pts_us":100000,
		"format_revision":1,"effect_revision":1,"model_generation":1,"slot_token":8,
		"color_texture_id":RenderingServer.texture_get_native_handle(textures[0].get_rid()),
		"alpha_texture_id":RenderingServer.texture_get_native_handle(textures[1].get_rid()),
		"width":color.get_width(),"height":color.get_height(),"input_width":320,"input_height":320,"alpha_width":640,"alpha_height":320,
		"rotation_degrees":0,"model_content_rect":[0,0,1,1],"stereo_sbs":packed,
		"alpha_slot_token":8,"alpha_frame_id":3,"alpha_pts_us":100000,
		"source_pts_verified":true,"immutable_color_frame":true,"pair_identity_verified":true,
		"alpha_fence_ready":true,"alpha_gpu_uploaded":true,"alpha_texture_format":"GL_R8_numeric"}
	if shape:
		pair.merge({"portrait_texture_id":RenderingServer.texture_get_native_handle(textures[2].get_rid()),"portrait_slot_token":8,"portrait_frame_id":3,"portrait_pts_us":100000})
	check(main.video._binding.bind(main.video.material,pair), "Bind complete source lease")
	main.video.media.last_pair = pair
	main.video.media.format = {"width":color.get_width(),"height":color.get_height(),"pixel_aspect":1.0,"unapplied_rotation_degrees":0}
	main.video._rvm_alpha = not packed
	main.video.material.set_shader_parameter("alpha_enabled",not packed)
	main.video._apply_geometry(); main._update_background(); main.video._sync_portrait()

func compare(label: String) -> void:
	main.video.panel.visible = false
	var background := await frame(label + "-background")
	main.video.panel.visible = true
	var actual := await frame(label)
	# Reference is the same source/pose/shader without any auditorium depth or colour.
	main.cinema_environment._model.visible = false
	main.display._set_background(true)
	var reference := await frame(label + "-reference")
	main.display._set_background(false); main.cinema_environment._model.visible = true
	var opaque := 0; var visible := 0; var holes := 0; var unchanged := 0; var soft := 0; var blended := 0
	for y in range(0,actual.get_height(),2):
		for x in range(0,actual.get_width(),2):
			var ref := reference.get_pixel(x,y); var pixel := actual.get_pixel(x,y); var back := background.get_pixel(x,y)
			if ref.a > .995 and ref.get_luminance() > .1:
				opaque += 1
				if difference(ref,pixel) < .025: visible += 1
			elif ref.a < .001:
				holes += 1
				if difference(pixel,back) < .015: unchanged += 1
			elif ref.a > .1 and ref.a < .9:
				soft += 1
				var expected := Color(ref.r+back.r*(1-ref.a),ref.g+back.g*(1-ref.a),ref.b+back.b*(1-ref.a))
				if difference(pixel,expected) < .04: blended += 1
	check(opaque > 100 and visible >= opaque * .98, label + " cutout survives auditorium depth")
	check(holes > 100 and unchanged >= holes * .99, label + " transparent area keeps the actual hall")
	check(soft > 0 and blended >= soft * .95, label + " soft contour blends once")
	samples.append({"case":label,"opaque":opaque,"visible":visible,"holes":holes,"unchanged":unchanged,"soft":soft,"blended":blended})

func check_controls() -> void:
	main._show_player_menu()
	var pointer: Dictionary = main.controller_feedback._make_pointer()
	pointer.dot.visible = true; pointer.dot.scale = Vector3.ONE * .015
	pointer.dot.global_position = main.xr_camera.global_transform * Vector3(-.2,.1,-1.5)
	var actual := await frame("menu-and-pointer")
	main.video.panel.visible = false; main.cinema_environment._model.visible = false; main.display._set_background(true)
	var reference := await frame("menu-and-pointer-reference")
	var solid := 0; var preserved := 0
	for y in range(0,actual.get_height(),2):
		for x in range(0,actual.get_width(),2):
			var pixel := reference.get_pixel(x,y)
			if pixel.a > .995 and pixel.get_luminance() > .2:
				solid += 1
				if difference(pixel,actual.get_pixel(x,y)) < .025: preserved += 1
	check(solid > 100 and preserved >= solid * .99,"Actual menu glyphs and pointer draw above the cutout")
	main.display._set_background(false); main.cinema_environment._model.visible = true; main.video.panel.visible = true
	main.video_menu.dismiss()
	for node in pointer.values(): node.free()

func run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "gl_compatibility":
		push_error("Cinema Alpha requires the real GL renderer"); quit(2); return
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new(); config.set_value("appearance","background","dark"); config.set_value("alpha","keep_background",true)
	config.save(output.path_join("render.cfg"))
	view = SubViewport.new(); view.size = Vector2i(960,640); view.own_world_3d = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	main = Main.new(); main.settings_path = output.path_join("render.cfg"); view.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop(); main._head_placed = true
	main.video._remember_file = false; main.video.history_enabled = false
	main.video.local_uri = "file:///cinema-alpha-render.mp4"; main.video.media.begin(7); main.video.media.state = "playing"
	main.video.requested_play = true; main.video._waiting_first = false; main.video.panel.visible = true
	main.video.geometry = 0; main.video.stereo_sbs = false
	bind_source(false,false)
	main.background.select("cinema")
	var deadline := Time.get_ticks_msec() + 20000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	main._update_background(); main._sync_cinema_screen()
	check(main._cinema_scene_active(), "Production auditorium loads")
	var screen: Dictionary = main.cinema_environment.snapshot().screen
	main.xr_camera.look_at(Vector3(screen.position[0],screen.position[1],screen.position[2]),Vector3.UP)
	# The auditorium screen is above the eye. Restoring a small portrait must keep
	# its viewed centre, not bring that elevated world position straight toward us.
	main.settings.set_value("portrait_screen","distance",2.0); main.settings.set_value("portrait_screen","scale",1.0)
	main.video.alpha_requested = true; main.video.alpha_enabled = true
	bind_source(false,true)
	await compare("2d-ai-saved-near")
	main.settings.erase_section_key("portrait_screen","distance"); main.settings.erase_section_key("portrait_screen","scale")
	for mode in ["2d-ai", "2d-flat-fallback", "vr180-ai", "fisheye-ai", "vr-native-alpha"]:
		main.video.alpha_requested = false; main.video.alpha_enabled = false; main.video.packed_file = false; main.video.packed_alpha = false
		main.video.geometry = 0; main.video.stereo_sbs = false; main.video._apply_geometry(); main._update_background(); main._sync_cinema_screen()
		var packed: bool = mode == "vr-native-alpha"
		main.video.geometry = 0 if mode.begins_with("2d") else (1 if mode == "vr180-ai" else 2)
		main.video.alpha_requested = not packed; main.video.alpha_enabled = true; main.video.packed_file = packed; main.video.packed_alpha = packed; main.video.stereo_sbs = packed
		bind_source(packed,mode == "2d-ai")
		if main.video.geometry == 0:
			main._on_playback_adjustment("portrait_distance",40.0); main.video._sync_portrait()
			check(main.video.portrait.active == (mode == "2d-ai"), "Use intended flat/portrait geometry")
		else: main.video.reset_view()
		for eye in ([1,2] if packed else [0]):
			main.video.set_viewing_eye(eye); main.video._sync_portrait()
			await compare(mode + "-eye" + str(eye))
		if not packed:
			bind_source(false,mode == "2d-ai",Color(.95,.05,.12))
			await compare(mode + "-next-frame")
		if mode == "2d-ai":
			main._on_playback_adjustment("portrait_scale",100.0)
			main._on_playback_adjustment("portrait_distance",2.0); main.video._sync_portrait()
			await compare("2d-ai-slider-near")
			await check_controls()
		main._on_setting_changed("alpha_keep_background",false)
		check(main.video.panel.material_override in [main.video.material,main.video.portrait.material], mode + " off restores original material identity")
		main._on_setting_changed("alpha_keep_background",true)
		main.background.select("belfast"); main._update_background()
		check(main.video.panel.material_override in [main.video.material,main.video.portrait.material], mode + " panorama keeps original depth policy")
		main.background.select("cinema"); main._update_background()
	main.video._binding.unbind()
	check(not main.video._scene_overlay or RenderingServer.material_get_param(main.video._scene_overlay.material.get_rid(),"color_texture") == null,"Retiring the lease detaches the overlay texture")
	main.video.local_uri = ""; main.video.media.session_id = 0; main.free(); view.free()
	var report := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures,"samples":samples},"\t")); report.close()
	for failure in failures: push_error(failure)
	print("Cinema Alpha pixels: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
