extends SceneTree
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Fixture := preload("res://tests/test_photo_preload.gd")
var folder := ProjectSettings.globalize_path("res://../../build/output/photo-recovery")
var checks := 0
var failures: Array[String] = []

class Host extends Fixture.Host:
	var reject_depth := false
	var panorama := false
	var registration_held := false
	var registration_failure := false
	var delayed := {}
	var sources := {}
	var opened: Array[String] = []
	var portraits: Array[Dictionary] = []
	var portrait: Callable
	func has_java_method(method: String) -> bool:
		return method in ["prepare_photo_3d", "prepare_photo_portrait", "cancel_photo_portrait", "release_photo_depth_runtime"]
	func open_photo(uri: String) -> int:
		opened.append(uri)
		var file := make_file(str(sources.get(uri, uri)))
		var payload := {"state":"ready", "path":file.path, "panorama":panorama}
		if uri.get_file().begins_with("spread-"):
			payload.panorama = false
			if registration_failure: payload = {"state":"error"}
			if registration_held: delayed[file.id] = payload; return int(file.id)
		ready.call_deferred(file.id, JSON.stringify(payload))
		return int(file.id)
	func prepare_photo_3d(id: int, strength: float) -> bool:
		if reject_depth: depth_calls += 1; return false
		return super.prepare_photo_3d(id, strength)
	func prepare_photo_portrait(id: int, token: int, strength: float) -> bool:
		portraits.append({"id":id,"token":token,"strength":strength})
		return held.has(id)
	func cancel_photo_portrait(_token: int) -> void: pass
	func complete_depth(id: int, success: bool = true) -> void:
		if not success: super.complete_depth(id, false); return
		depth_pending.erase(id)
		var source := Image.new(); source.load_png_from_buffer(FileAccess.get_file_as_bytes(held[id]))
		var pair := Image.create(source.get_width()*2,source.get_height(),false,Image.FORMAT_RGBA8)
		source.convert(Image.FORMAT_RGBA8)
		pair.blit_rect(source,Rect2i(Vector2i.ZERO,source.get_size()),Vector2i.ZERO)
		pair.blit_rect(source,Rect2i(Vector2i.ZERO,source.get_size()),Vector2i(source.get_width(),0))
		var pair_path := folder.path_join("pair-%d.png" % id); pair.save_png(pair_path); pair_paths[id] = pair_path
		var image := Image.create(518,518,false,Image.FORMAT_RF); image.fill(Color(.6,0,0))
		var path := folder.path_join("depth-%d.bin" % id); FileAccess.open(path,FileAccess.WRITE).store_buffer(image.get_data()); depth_paths[id] = path
		depth.call_deferred(id,JSON.stringify({"state":"ready","path":path,"width":518,"height":518,"rect":[0,0,1,1],
			"stereo_path":pair_path,"stereo_width":pair.get_width(),"stereo_height":pair.get_height(),"stereo_strength":strengths[id],"stereo_strategy":"video_soft_shift_gpu"}))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func settle(photo: Node, host: RefCounted, success := true) -> void:
	var until := Time.get_ticks_msec()+6000
	while (photo.loading or photo._depth_busy) and Time.get_ticks_msec()<until:
		for id in host.depth_pending.keys(): host.complete_depth(id,success)
		await create_timer(.01).timeout
	check(not photo.loading and not photo._depth_busy and photo.error.is_empty(),"Readable colour survives loading/conversion")
	photo.finish_transition(); photo.gallery._process(1)
func tap(menu: Node, target: int) -> void:
	var found := false
	for button in menu._buttons:
		if button.target != target: continue
		found = button.enabled
		var origin: Vector3 = button.node.global_position + button.node.global_basis.z
		menu.press_pointer("right_hand",origin,-menu.global_basis.z,true)
		menu.release_pointer("right_hand",origin,-menu.global_basis.z,true)
		break
	check(found,"Real ray control remains enabled: %d" % target)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array[Dictionary] = []
	for i in 4:
		var image := Image.create(160,100,false,Image.FORMAT_RGBA8); image.fill(Color.RED if i%2==0 else Color.BLUE)
		var path := folder.path_join("page-%d.png" % i); image.save_png(path)
		entries.append({"uri":"file://"+path,"title":"page-%d.png" % i,"kind":"image"})
	var cfg := ConfigFile.new(); cfg.save(folder.path_join("app.cfg"))
	var app := Main.new(); app.settings_path = folder.path_join("app.cfg"); root.add_child(app); app.set_process(false)
	app.recent_menu.dismiss(); app.photo_active = true; app.player_menu = app.photo_menu
	var photo: Node = app.photo; photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("modes")); photo.mode_memory.read_only = true
	var host := Host.new(); host.folder = folder; host.ready = photo._on_ready; host.depth = photo._on_depth; host.use_stereo = true; photo.platform = host
	photo.auto_depth = true; photo.spatial_preferred = false
	# Reproduce wall expansion, conversion rejection and a subsequent switch to Single.
	photo.set_layout_mode(2); photo.open_image(entries[0].uri,entries[0].title,entries); photo.gallery._process(.01)
	host.reject_depth = true; photo.gallery.activate(0); await settle(photo,host)
	check(photo._texture != null and photo.depth_error == "3D unavailable" and not photo.depth_enabled,"Rejected automatic 3D retains the decoded wall image")
	check(host.depth_calls == 1,"Fallback does not immediately retry the failed conversion")
	app.photo_menu.visible = true; app.photo_menu.refresh()
	tap(app.photo_menu,app.photo_menu.PHOTO_LAYOUT); tap(app.photo_menu,app.photo_menu.PHOTO_LAYOUT_BASE)
	check(photo.gallery.mode == 0 and photo.panel.visible,"Wall-to-Single remains usable after 3D failure")
	app.photo_menu.refresh(); tap(app.photo_menu,app.photo_menu.MODE); tap(app.photo_menu,app.photo_menu.MODE_PROJECTION+3)
	check(photo.geometry == 3 and not photo.depth_requested,"User can select panorama projection after automatic 3D failure")
	# Recognized panoramas must never be sent through flat automatic depth.
	photo.close_image(); photo.mode_lock.clear(); photo.gallery.set_mode(2); host.panorama = true
	var before := host.depth_calls
	photo.open_image(entries[1].uri,entries[1].title,entries); photo.gallery._process(.01); photo.gallery.activate(1); await settle(photo,host)
	check(photo.geometry == 3 and host.depth_calls == before,"Panorama wall selection opens immersive projection without a 3D request")
	photo.set_layout_mode(0); check(photo.geometry == 3 and photo.panel.visible,"Switching panorama from wall to Single preserves immersive projection")
	# Async conversion failure uses the same fallback; source errors still expose Close and layouts.
	photo.close_image(); host.panorama = false; host.reject_depth = false
	photo.open_image(entries[2].uri,entries[2].title,entries); await settle(photo,host,false)
	check(photo.depth_error == "3D unavailable" and photo.index == 2 and photo.panel.visible,"Async depth error also leaves a visible original")
	check(photo.set_depth(true),"Conversion can be explicitly retried after fallback")
	await settle(photo,host)
	check(photo.depth_enabled and photo.depth_error.is_empty(),"Retry uses the retained original source lease")
	photo.close_image(); photo.open_image(entries[0].uri,entries[0].title,entries)
	photo._on_ready(photo._request,'{"state":"error"}')
	app.photo_menu.refresh(); tap(app.photo_menu,app.photo_menu.PHOTO_LAYOUT); tap(app.photo_menu,app.photo_menu.PHOTO_LAYOUT_BASE+2)
	tap(app.photo_menu,app.photo_menu.PHOTO_WALL_ROWS+1)
	app.photo_menu.refresh(); tap(app.photo_menu,107)
	check(not app.photo_active and not photo.loading,"Close exits a failed image through the production menu")
	# Full-spread native registration, conversion and portrait mask use one shared native lease.
	app.photo_active = true; app.player_menu = app.photo_menu; app.recent_menu.dismiss()
	photo.gallery.set_mode(4); photo.auto_depth = true
	photo.magazine.cache_directory = folder.path_join("spreads")
	photo.open_image(entries[0].uri,entries[0].title,entries); await settle(photo,host)
	var id: int = photo._display_request
	check(photo.depth_enabled and photo._size == Vector2(320,100),"Magazine supports automatic 2D-to-3D for the full spread")
	var native := Image.new(); native.load_png_from_buffer(FileAccess.get_file_as_bytes(host.held[id]))
	check(native.get_size()==Vector2i(320,100) and native.get_pixel(20,20).r>.9 and native.get_pixel(200,20).b>.9,"Native converter source contains both pages in reading order")
	check(host.held.size()==1 and photo.magazine.transfer.is_empty() and DirAccess.get_files_at(photo.magazine.cache_directory).is_empty(),"Only the native spread lease remains; source pages and handoff file are released")
	app.photo_menu.visible = true; app.photo_menu.refresh(); tap(app.photo_menu,app.photo_menu.PHOTO_DEPTH)
	check(app.photo_menu._depth_open and is_instance_valid(app.photo_menu._depth_knob),"Magazine exposes the actual 3D strength slider through a ray click")
	app.photo_menu.navigate_back()
	check(photo.set_depth(false) and not photo.depth_enabled and photo.set_depth(true) and photo.depth_enabled,"Magazine can toggle 2D and 3D using its registered spread")
	check(photo.can_spatial() and photo.set_spatial_mode(true),"Magazine also respects the existing spatial 3D viewing choice")
	photo._reveal_seconds = 0; photo._maybe_start_spatial()
	var spatial_until := Time.get_ticks_msec()+5000
	while not photo._spatial.prepared and Time.get_ticks_msec()<spatial_until: await create_timer(.01).timeout
	check(photo._spatial.prepared,"The actual spatial renderer builds from the composed spread and matching depth")
	photo.set_spatial_mode(false)
	app.photo_menu.visible = true; app.photo_menu.refresh(); tap(app.photo_menu,app.photo_menu.PHOTO_PORTRAIT)
	check(photo.portrait_requested and host.portraits.back().id == id,"Portrait passthrough requests the composed spread, not either source page")
	var mask := PackedByteArray(); mask.resize(640*100); mask.fill(255)
	var mask_path := folder.path_join("matte.r8"); FileAccess.open(mask_path,FileAccess.WRITE).store_buffer(mask)
	photo._on_portrait(id,JSON.stringify({"state":"ready","token":photo._portrait_epoch,"format":"r8_sbs","strategy":"video_soft_shift_gpu","path":mask_path,"width":640,"height":100,"strength":photo.depth_strength}))
	var until := Time.get_ticks_msec()+5000
	while not photo.portrait_enabled and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(photo.portrait_enabled and photo._portrait_texture.get_size()==Vector2(640,100),"Full-spread matte is accepted by the actual portrait renderer")
	photo.set_portrait(false); photo.magazine.right_to_left = true; photo.magazine.reload(); await settle(photo,host)
	native.load_png_from_buffer(FileAccess.get_file_as_bytes(host.held[photo._display_request]))
	check(native.get_pixel(20,20).b>.9 and native.get_pixel(200,20).r>.9,"Right-to-left rebuilds the native conversion source in the selected order")
	photo.close_image()
	var pages: Array[Dictionary] = []
	for i in 3:
		var uri := "comic://recovery/%d" % i
		host.sources[uri] = entries[i].uri
		pages.append({"uri":uri,"title":entries[i].title,"kind":"image"})
	photo.open_image(pages[0].uri,pages[0].title,pages); await settle(photo,host)
	check(photo.archive_mode and photo.depth_enabled and photo.can_portrait() and photo._size==Vector2(320,100),"Archive spreads use the same 3D and portrait source registration")
	photo.navigate(1); await settle(photo,host)
	check(photo.index==2 and photo.depth_enabled and photo.can_portrait() and photo._size==Vector2(160,100),"An odd final page keeps 3D and portrait support without a second page")
	photo.close_image(); photo.open_image(entries[0].uri,entries[0].title,entries); await settle(photo,host)
	# A native registration error falls back to the readable spread; a late ready cannot resurrect a closed album.
	host.registration_failure = true; photo.navigate(1); await settle(photo,host)
	check(photo._size==Vector2(320,100) and photo.depth_error=="3D unavailable" and not photo.snapshot().depth_available,"Registration failure keeps the spread readable without converting the wrong page")
	host.registration_failure = false; host.registration_held = true; photo.magazine.reload()
	until = Time.get_ticks_msec()+5000
	while host.delayed.is_empty() and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not host.delayed.is_empty(),"Registration can be cancelled while its ready response is delayed")
	photo.close_image()
	for delayed_id in host.delayed: photo._on_ready(delayed_id,JSON.stringify(host.delayed[delayed_id]))
	check(photo._texture==null and not photo.loading and host.held.is_empty() and DirAccess.get_files_at(photo.magazine.cache_directory).is_empty(),"Closing cancels native registration and removes temporary joined pixels")
	app.free(); await process_frame
	print("Photo recovery and magazine conversion: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
