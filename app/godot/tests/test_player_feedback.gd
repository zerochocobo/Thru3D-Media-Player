extends SceneTree
const Main := preload("res://scripts/main.gd")
const Background := preload("res://scripts/app_background.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const BrowserTest := preload("res://tests/test_media_server_browser.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/player-feedback")
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw
func slot_for(capture: Node, node: Node) -> Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node): return slot
	return {}
func sample(slot: Dictionary, node: Node3D, point: Vector3) -> Color:
	var local: Vector3 = slot.layer.to_local(node.to_global(point))
	var uv := Vector2(local.x / slot.layer.quad_size.x + .5, .5 - local.y / slot.layer.quad_size.y)
	var image: Image = slot.raw.get_texture().get_image()
	return image.get_pixelv(Vector2i(uv * Vector2(image.get_size())))
func backgrounds() -> void:
	var source := output.path_join("vr180-source.png")
	var path := output.path_join("vr180-sky.image")
	for spec in [[Vector2i(256,128),true,false,false], [Vector2i(256,128),true,false,true],
		[Vector2i(128,256),true,true,false], [Vector2i(128,256),true,true,true],
		[Vector2i(128,128),true,false,false], [Vector2i(128,128),true,true,true], [Vector2i(128,128),false,false,false]]:
		var size: Vector2i = spec[0]
		var image := Image.create(size.x,size.y,false,Image.FORMAT_RGB8); image.fill(Color.RED)
		if spec[1]: image.fill_rect(Rect2i(0,size.y/2,size.x,size.y/2) if spec[2] else Rect2i(size.x/2,0,size.x/2,size.y),Color.BLUE)
		image.save_png(source)
		var before := FileAccess.get_sha256(source)
		var job := {"copy":true,"path":path,"orientation":1,"geometry":1,"stereo":spec[1],"top_bottom":spec[2],"swap_eyes":spec[3]}
		var result := Background._read_custom(FileAccess.open(source,FileAccess.READ),job)
		check(not result.is_empty(), "VR180 mono/full/half SBS/TB import " + str(spec))
		if result.is_empty(): continue
		var sky: Image = result.image; var mid := sky.get_size()/2
		check(sky.get_width()==sky.get_height()*2 and sky.get_width()<=4096, "Sky is bounded mono 2:1")
		check(sky.get_pixelv(mid).is_equal_approx(Color.BLUE if spec[3] else Color.RED), "Front uses selected eye")
		check(sky.get_pixel(0,mid.y).r < .05 and sky.get_pixel(sky.get_width()-1,mid.y).r < .05, "Rear is dark, no duplicate scene")
		check(FileAccess.get_sha256(source)==before, "Source image remains untouched")
		job.copy=false
		var restored := Background._read_custom(FileAccess.open(path,FileAccess.READ),job)
		check(restored.image.get_data()==sky.get_data(), "Persisted background restores without another crop")
	check(not Background.source_supported(Vector2(1600,900),1,false,false), "Ordinary rectangular images are not mistaken for VR180")
	check(not Background.source_supported(Vector2(256,128),2,true,false), "Fisheye projection is not imported as equirectangular")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	backgrounds()
	var config := ConfigFile.new(); config.set_value("appearance","background","dark"); config.set_value("ui","language","zh")
	var settings_path := output.path_join("settings.cfg"); config.save(settings_path)
	var viewport := SubViewport.new(); viewport.size=Vector2i(1600,1100); viewport.own_world_3d=true; viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var main := Main.new(); main.settings_path=settings_path; viewport.add_child(main); main.set_process(false)
	var menu = main.video_menu
	main._show_player_menu()
	menu.set_process(false)
	main._toggle_controls_lock()
	var pose: Transform3D = menu.global_transform
	main.xr_camera.position += Vector3(3,1,2)
	main._place_menu(menu)
	check(menu.space_locked() and menu.global_transform.is_equal_approx(pose), "Locked bar stays in world when reopened from a moved head")
	main.view_follow.enabled=true; main._update_view_follow()
	check(menu.global_transform.is_equal_approx(pose),"Spatial lock takes priority over head following")
	main.view_follow.enabled=false
	menu._activate(menu.PLAYBACK_SETTINGS)
	check(not menu._popup_surfaces.is_empty(), "Settings popup exists on locked controls")
	var popup_pose: Transform3D = menu._popup_surfaces[0].global_transform
	menu.refresh_layout_reference(); menu.arrange_surfaces()
	check(menu._popup_surfaces[0].global_transform.is_equal_approx(popup_pose), "Locked popup does not follow head")
	main.video.local_uri="file:///fixture.mp4"; main.video.media.state="playing"
	main._show_recent_menu()
	check(main.recent_menu.space_locked(), "Attached library inherits spatial lock")
	var library_pose: Transform3D = main.recent_menu.global_transform
	main.recent_menu.set_layout_viewer(main.xr_camera.global_transform)
	check(main.recent_menu.global_transform.is_equal_approx(library_pose), "Attached child cannot independently chase head")
	main.recent_menu.dismiss(); main._show_player_menu()
	main.video.local_uri=""; main.video.media.state="closed"
	main._toggle_controls_lock()
	check(not menu.space_locked() and menu.global_transform.is_equal_approx(pose), "Unlock does not jump")
	main._toggle_controls_lock(); main._recenter()
	check(not menu.space_locked() and not menu.global_transform.is_equal_approx(pose), "Explicit recenter unlocks and retrieves bar")
	check(menu._tips[menu.SPACE_LOCK] == preload("res://scripts/i18n.gd").t("Lock spatial position"), "Recenter refreshes lock icon/tooltip")
	main._toggle_controls_lock(); menu.dismiss(); main._on_system_recentered()
	check(not menu.space_locked(),"System recenter also unlocks hidden controls")
	main._show_player_menu(); menu.cinema_world_anchor=true
	main._toggle_controls_lock(); menu._activate(menu.PLAYBACK_SETTINGS)
	var cinema_popup:Transform3D=menu._popup_surfaces[0].global_transform
	main.xr_camera.position+=Vector3(2,0,1)
	menu._reset_navigation(); menu.refresh(); menu._activate(menu.PLAYBACK_SETTINGS)
	check(menu._popup_surfaces[0].global_transform.is_equal_approx(cinema_popup),"New cinema popups use the locked head reference")
	main._clear_controls_locks(); menu.cinema_world_anchor=false
	main.xr_camera.position=Vector3(0,1.6,0); main._recenter()
	main._on_setting_changed("bar_transparency",true)
	check(menu._adjustment=="bar_transparency" and menu.visible and not main.recent_menu.visible, "Display setting previews actual control bar")
	check(menu._adjust_rows[menu.BAR_TRANSPARENCY].key=="bar_transparency", "Opacity slider available without a movie")
	main._on_playback_adjustment("bar_transparency",55)
	check(is_equal_approx(menu._backdrop.material_override.get_shader_parameter("surface_color").a,.45), "Preview changes only control plate")
	var glyph_probe:MeshInstance3D=menu._quad(Vector2(.035,.035),Vector3(-.52,-.14,.006),Color.WHITE,12)
	menu.add_child(glyph_probe); menu._decorations.append(glyph_probe)
	var capture := Capture.new(); viewport.add_child(capture); capture.configure(main.xr_origin, main.xr_camera, main.display,[menu],false,true); capture.set_process(false)
	viewport.transparent_bg=true # Native projection alpha is observable in host capture.
	var performance_samples: Array = []
	for opacity in [0,55,80]:
		main._set_bar_transparency(opacity); capture.update(); await frames(); capture.update(); await frames()
		var before_repaints: int = capture.repaints
		for frame in 15:
			capture._painted_ms=0 # Force the production signature/keepalive path too.
			capture.update(); await process_frame; await RenderingServer.frame_post_draw
		check(capture.repaints==before_repaints,"Stationary translucent controls do not continuously repaint %d"%opacity)
		performance_samples.append({"transparency":opacity,"draw_calls":viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
			"texture_bytes":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),"allocated_capture_pixels":capture.slots.map(func(s):return [s.raw.size.x,s.raw.size.y]),"layers":capture.snapshot().layers})
		var slot := slot_for(capture,glyph_probe)
		check(not slot.is_empty(), "Bar controls retain native-layer path")
		check(not slot_for(capture,menu._title).is_empty() and not menu._title.has_meta("menu_eye_buffer"), "Filename retains HD capture with its opaque caption plate")
		check(slot_for(capture,menu._backdrop).is_empty() and menu._backdrop.layers==1, "Translucent plate stays in eye buffer to avoid double alpha")
		var glyph_pixel:Vector2i=Vector2i(main.xr_camera.unproject_position(glyph_probe.global_position))
		var projection_alpha:float=viewport.get_texture().get_image().get_pixelv(glyph_pixel).a
		check(projection_alpha<.025,"Plate cannot refill native glyph holes at transparency %d: %.3f"%[opacity,projection_alpha])
		if not slot.is_empty():
			var color := sample(slot,menu,Vector3(-.53,.025,0))
			check(color.a<.025, "Native capture does not paint over translucent plate %d: %.3f" % [opacity,color.a])
			if opacity==55: slot.raw.get_texture().get_image().save_png(output.path_join("control-text-layer.png"))
		capture.set_active(false); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("opacity-%d.png" % opacity))
		capture.set_active(true)
	for metric in ["draw_calls","texture_bytes","allocated_capture_pixels","layers"]:
		check(performance_samples.all(func(sample):return sample[metric]==performance_samples[0][metric]),"Opacity does not increase "+metric)
	FileAccess.open(output.path_join("transparency-performance.json"),FileAccess.WRITE).store_string(JSON.stringify({"scope":"Desktop OpenGL structural costs; not headset GPU timings","samples":performance_samples},"\t"))
	capture.free()
	menu._activate(menu.BAR_DONE)
	check(main.recent_menu.visible and main.recent_menu.tab==main.recent_menu.DISPLAY_TAB, "Done returns to Display settings")
	var saved := ConfigFile.new(); saved.load(settings_path)
	check(saved.get_value("ui","bar_transparency")==80.0,"Transparency is persisted")
	main.photo_active=true; main.player_menu=main.photo_menu; main._open_bar_appearance()
	main._on_photo_adjustment("bar_transparency",35)
	check(main.photo_menu._adjust_rows[main.photo_menu.BAR_TRANSPARENCY].label.text=="35%","Photo preview uses current slider value")
	main._navigate_back(); main.photo_active=false; main.player_menu=main.video_menu
	await artwork(main,viewport)
	main.queue_free(); await process_frame
	print("Player feedback: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)

func artwork(main: Node, viewport: SubViewport) -> void:
	main._show_full_library(); var menu = main.recent_menu; menu.set_process(false)
	menu.section=menu.Section.MEDIA_SERVER
	var b: RefCounted=menu.server_browser; b.server={"id":"demo","name":"Emby","provider":"emby"}; b.capabilities=BrowserTest.CAPS.merged({"artwork":true},true); b.view="detail"
	b.detail={"id":"movie","title":"远山来信","year":2026,"description":"穿过晨雾与山谷，记录旅途中的光影。","parts":[{"id":"cd1","part_label":"cd1","basename":"远山来信_180_SBS_8K_cd1.mp4"},{"id":"cd2","part_label":"cd2","basename":"远山来信_180_SBS_8K_cd2.mp4"}],"backdrops":[]}
	for part in b.detail.parts: part.title=part.basename
	for i in 2:
		var item: Dictionary={"id":"movie","image_type":"Backdrop","image_index":i,"image_tag":"back%d"%i}
		b.detail.backdrops.append(item)
		var image:=Image.create(1024,512,false,Image.FORMAT_RGB8)
		for y in 512:
			for x in 1024:
				var color:=Color(.25+.35*float(x)/1024,.4,.65) if i==0 else Color(.7,.25,.12)
				if y>210+sin(float(x)/130)*80: color=color.darkened(.6)
				image.set_pixel(x,y,color)
		b.textures[b._request_image_key(b._image_request({"cover_image":item.merged({"max_width":1024})}))]=ImageTexture.create_from_image(image)
	menu.refresh(); await frames()
	check(is_instance_valid(b.backdrop.surface),"Detail displays API background art")
	check(b.backdrop.surface == menu._backdrop, "Artwork replaces the panel fill instead of competing at equal priority")
	check(menu._backdrop.material_override.render_priority < menu._buttons.back().node.material_override.render_priority, "Detail controls render above artwork")
	viewport.get_texture().get_image().save_png(output.path_join("emby-background.png"))
	b.backdrop.mode="slideshow"; menu.refresh(); b.backdrop.elapsed=12
	menu._stick_ms=Time.get_ticks_msec()-1000
	b.backdrop.tick(.1)
	check(b.backdrop.progress>0,"Two API backdrops start crossfade")
	for i in 8: b.backdrop.tick(.1)
	check(b.backdrop.index==1 and b.backdrop.progress==0,"Crossfade finishes and advances once")
	b.backdrop.elapsed=11; b.backdrop.tick(.1)
	var capture:=Capture.new(); viewport.add_child(capture); capture.configure(main.xr_origin,main.xr_camera,main.display,[menu],false,true); capture.set_process(false)
	for part in [0,1,0]:
		menu._hover["right_hand"]=b.gallery.PART+part; menu._update_tooltip()
		capture.update(); await frames(); capture.update(); await frames()
		var slot:=slot_for(capture,menu._tooltip)
		check(not slot.is_empty(),"CD hover keeps a dedicated high-density layer")
		if not slot.is_empty():
			check(slot.tooltip and slot.rect.size.x<1.3,"Tooltip bounds do not accumulate across different cards")
			check(float(slot.raw.size.x)/slot.layer.quad_size.x>=Capture.DENSITY*.9,"CD tooltip capture retains density")
			slot.raw.get_texture().get_image().save_png(output.path_join("cd-tooltip-layer.png"))
		var before:float=b.backdrop.elapsed; b.backdrop.tick(.1)
		check(is_equal_approx(before,b.backdrop.elapsed),"Artwork rotation pauses during tooltip reading")
	capture.free(); await frames()
	viewport.get_texture().get_image().save_png(output.path_join("emby-cd-tooltip.png"))
	menu._hover.clear(); menu._hide_tooltip()
	var failed:Dictionary=b._image_request({"cover_image":b.detail.backdrops[0].merged({"max_width":1024})})
	b.failed_covers[b._request_image_key(failed)]=true
	b.textures.erase(b._request_image_key(failed))
	b.backdrop.mode="static"; menu.refresh()
	b.backdrop.tick(.1)
	check(b.backdrop.pictures.size()==1 and b.backdrop.pictures[0].image_index==1,"Failed first artwork falls back to another image")
	b.backdrop.mode="off"; menu.refresh()
	check(b.backdrop.nodes().is_empty() and not is_instance_valid(b.backdrop.surface),"Off makes no background requests or surface")
	check(menu._backdrop.material_override.shader == menu.SURFACE, "Disabling artwork restores the ordinary panel material")
	menu.visible=false; b.backdrop.tick(.1)
	check(b.backdrop.current==null and b.backdrop.next==null,"Leaving page releases slideshow texture references")
	var platform:=Fixture.Platform.new(); menu.attach_platform(platform)
	menu.visible=true; b.failed_covers.clear(); b.backdrop.mode="slideshow"
	b.detail={"id":"requests","title":"Requests","has_cover":false,"backdrops":[{"id":"new","image_type":"Backdrop","image_index":0},{"id":"new","image_type":"Backdrop","image_index":1}]}
	menu.refresh(); b.backdrop.elapsed=11; b.backdrop.tick(.1)
	var requests:Array=b.pending.keys()
	check(requests.size()==2 and b.pending.values().all(func(req):return req.image_type=="Backdrop" and req.max_width==1024),"Slideshow has only current and next background requests")
	menu.dismiss(); b.backdrop.tick(.1)
	check(requests.all(func(id):return id in platform.cancelled) and b.pending.is_empty(),"Leaving cancels both outstanding image requests")
	for id in requests: platform.answer(id,{"path":output.path_join("vr180-source.png")})
	check(not menu.visible and b.covers.is_empty(),"Late cancelled artwork cannot reopen or populate the page")
	menu.attach_platform(null); platform.free()
