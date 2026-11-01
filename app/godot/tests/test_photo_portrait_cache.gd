extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Fixtures := preload("res://tests/test_photo_preload.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://portrait_cache_%d" % Time.get_ticks_usec()
class Host extends Fixtures.Host:
	var masks := {}
	var matte_paths := {}
	var portrait_calls := 0
	var portrait_background_calls := 0
	var portrait_ready: Callable
	var portrait_preload: Callable
	func has_java_method(method: String) -> bool:
		return method in ["background_resource_policy", "prepare_photo_portrait", "cancel_photo_portrait", "prepare_preloaded_photo_portrait", "cancel_preloaded_photo_portrait"] or super.has_java_method(method)
	func background_resource_policy() -> String:
		return '{"spare_bytes":4294967296,"cache_limit":201326592,"retain":true,"work":true}'
	func prepare_photo_portrait(id: int, token: int, strength: float) -> bool:
		portrait_calls += 1; masks[id] = {"token":token,"strength":strength,"background":false}; return true
	func prepare_preloaded_photo_portrait(id: int, token: int, strength: float) -> bool:
		portrait_background_calls += 1; masks[id] = {"token":token,"strength":strength,"background":true}; return true
	func cancel_preloaded_photo_portrait() -> void:
		for id in masks.keys():
			if masks[id].background: masks.erase(id)
	func cancel_photo_portrait(token: int) -> void:
		for id in masks.keys():
			if not masks[id].background and int(masks[id].token) == token: masks.erase(id)
	func complete_mask(id: int) -> void:
		var job: Dictionary = masks[id]; masks.erase(id)
		var image := Image.create(640,160,false,Image.FORMAT_R8); image.fill(Color.WHITE)
		var path := folder.path_join("matte_%d.r8" % id)
		FileAccess.open(path,FileAccess.WRITE).store_buffer(image.get_data()); matte_paths[id] = path
		var callback: Callable = portrait_preload if job.background else portrait_ready
		callback.call_deferred(id, JSON.stringify({"state":"ready","token":job.token,"strength":job.strength,
			"path":path,"width":640,"height":160,"format":"r8_sbs","strategy":"video_soft_shift_gpu"}))
	func release_photo(id: int) -> void:
		masks.erase(id)
		if matte_paths.has(id): DirAccess.remove_absolute(str(matte_paths[id])); matte_paths.erase(id)
		super.release_photo(id)
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func prime(photo: Node3D) -> void:
	photo.resource_budget.stop()
	photo.resource_budget.policy = JSON.parse_string(photo.platform.background_resource_policy())
	for i in range(200): photo.resource_budget.observe(2,3,11.1,1000.0/90,1.0/90)
func _initialize() -> void: call_deferred("run")
func pump_jobs(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		photo._process_depth_jobs(); photo._process_portrait()
		if photo._depth_thread==null and photo._depth_queue.is_empty() and photo._portrait_thread==null and photo._portrait_next.is_empty(): return
		await create_timer(.01).timeout
	check(false,"Result readers finish")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array[Dictionary] = []
	for i in range(3):
		var image := Image.create(640,480,false,Image.FORMAT_RGB8); image.fill(Color(.2,.4,.6))
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % i)); image.save_png(path)
		entries.append({"uri":"file://"+path,"title":"Portrait %d" % i})
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("modes"))
	root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth
	host.portrait_ready = photo._on_portrait; host.portrait_preload = photo._on_prefetch_portrait; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	var deadline := Time.get_ticks_msec()+5000
	while photo._pending_display.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	host.complete_depth(photo._request)
	while not photo.depth_enabled and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	photo.finish_transition()
	while Time.get_ticks_msec()<deadline:
		host.complete(); photo.finish_transition()
		if photo._prefetched.size()==2 and photo._prefetched.values().all(func(e): return e.get("decoded",false)): break
		await create_timer(.01).timeout
	check(photo._prefetched.size()==2,"Both adjacent colour sources are available")
	check(photo.set_portrait(true),"Current portrait preparation remains accessible without GPU admission")
	host.complete_mask(photo._display_request)
	while not photo.portrait_enabled and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(photo.portrait_enabled and photo._display_depth_data.has("portrait_data"),"Displayed matte is retained with its matching stereo pair")
	photo.set_process(false); photo.finish_transition(); prime(photo)
	photo._pump_depth_prefetch()
	var next_id: int = photo._prefetched[1].id
	check(photo._prefetch_depth_request==next_id,"Portrait mode admits only one neighbour depth task")
	host.complete_depth(next_id); await process_frame; await pump_jobs(photo)
	photo._pump_depth_prefetch()
	check(photo._prefetch_portrait_request==next_id and host.portrait_background_calls==1,"A ready neighbour pair admits its separate matte task")
	photo._pump_depth_prefetch()
	check(host.portrait_background_calls==1,"Matting and depth precomputation share the speculative slot")
	host.complete_mask(next_id); await process_frame; await pump_jobs(photo)
	check(photo._prefetched[1].get("depth_data",{}).has("portrait_data"),"The neighbour retains a bounded completed matte")
	var foreground_calls: int = host.portrait_calls; var depth_calls: int = host.depth_calls
	photo.navigate(1); photo._maybe_start_portrait()
	check(photo.index==1 and photo.portrait_enabled and host.portrait_calls==foreground_calls and host.depth_calls==depth_calls,
		"Forward portrait navigation reuses both generated colour and matte")
	photo.finish_transition(); photo.navigate(-1); photo._maybe_start_portrait()
	check(photo.index==0 and photo.portrait_enabled and host.portrait_calls==foreground_calls,
		"Returning reuses the previous portrait result")
	var previous: Dictionary = photo._prefetched[1].depth_data
	var wrong_source: Dictionary = previous.portrait_data.duplicate(); wrong_source.source_id = int(wrong_source.source_id) + 1000
	check(not photo._valid_cached_portrait(wrong_source,previous),"An identical-size matte from another source cannot be reused")
	check(photo.set_depth_strength(.75),"Foreground strength adjustment remains accessible")
	check(not photo._valid_cached_portrait(previous.portrait_data,previous),"A different strength invalidates the cached matte")
	photo.resource_budget.policy["retain"] = false; photo.resource_budget.policy["work"] = false
	photo._trim_depth_cache()
	check(photo._prefetched.values().all(func(e):return not e.has("depth_data")),"Memory pressure releases neighbouring portrait and depth pixels together")
	var pending_before: Dictionary = photo._portrait_next.duplicate()
	photo._on_prefetch_portrait(next_id,'{"state":"ready","token":999,"path":"missing"}')
	check(photo._portrait_next==pending_before,"A cancelled or stale portrait result cannot allocate a new mask")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.masks.is_empty(),"Close releases all portrait source leases and work")
	for failure in failures: push_error(failure)
	print("Photo portrait cache: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
