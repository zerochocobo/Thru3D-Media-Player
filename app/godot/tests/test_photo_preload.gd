extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
var folder := "user://photo_preload_%d" % Time.get_ticks_usec()
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	var ready: Callable
	var folder := ""
	var next_id := 100
	var opens := 0
	var preloads := 0
	var held := {}
	var pending := {}
	var cancelled: Array[int] = []
	var activated: Array[int] = []
	var depth: Callable
	var preload_depth: Callable
	var depth_pending := {}
	var background_depth := {}
	var depth_paths := {}
	var depth_values := {}
	var depth_calls := 0
	var model_calls := 0
	var use_stereo := false
	var strengths := {}
	var pair_paths := {}
	var runtime_releases := 0
	func has_java_method(method: String) -> bool:
		return method in ["preload_photo", "activate_photo", "prepare_photo_depth", "prepare_preloaded_photo_depth", "cancel_preloaded_photo_depth", "discard_photo_depth"] \
			or method == "release_photo_depth_runtime" \
			or (use_stereo and method in ["prepare_photo_3d", "prepare_preloaded_photo_3d", "update_photo_3d_strength"])
	func make_file(uri: String) -> Dictionary:
		next_id += 1
		var path := folder.path_join("cache_%d.jpg" % next_id)
		DirAccess.copy_absolute(uri.trim_prefix("file://"), path)
		held[next_id] = path
		return {"id": next_id, "path": path}
	func open_photo(uri: String) -> int:
		opens += 1
		var file := make_file(uri)
		ready.call_deferred(file.id, JSON.stringify({"state":"ready", "path":file.path, "cache_bytes":4096}))
		return int(file.id)
	func preload_photo(uri: String) -> int:
		preloads += 1
		var file := make_file(uri)
		pending[file.id] = file.path
		return int(file.id)
	func complete() -> void:
		for id in pending.keys():
			ready.call_deferred(int(id), JSON.stringify({"state":"ready", "path":pending[id], "cache_bytes":4096}))
		pending.clear()
	func activate_photo(id: int) -> bool:
		if not held.has(id): return false
		activated.append(id)
		return true
	func release_photo(id: int) -> void:
		if held.has(id): DirAccess.remove_absolute(str(held[id])); held.erase(id)
		if depth_paths.has(id): DirAccess.remove_absolute(str(depth_paths[id])); depth_paths.erase(id)
		if pair_paths.has(id): DirAccess.remove_absolute(str(pair_paths[id])); pair_paths.erase(id)
		depth_pending.erase(id); background_depth.erase(id)
	func cancel_photo(id: int) -> void: cancelled.append(id); release_photo(id)
	func discard_photo_depth(id: int) -> void:
		depth_pending.erase(id); background_depth.erase(id)
		if depth_paths.has(id): DirAccess.remove_absolute(str(depth_paths[id])); depth_paths.erase(id)
		if pair_paths.has(id): DirAccess.remove_absolute(str(pair_paths[id])); pair_paths.erase(id)
	func prepare_photo_depth(id: int) -> bool:
		if not held.has(id): return false
		if depth_pending.has(id): return true
		depth_calls += 1; depth_pending[id] = true
		if not depth_paths.has(id): model_calls += 1
		return true
	func prepare_preloaded_photo_depth(id: int) -> bool:
		if not prepare_photo_depth(id): return false
		background_depth[id] = true
		return true
	func prepare_photo_3d(id: int, strength: float) -> bool:
		strengths[id] = strength
		return prepare_photo_depth(id)
	func prepare_preloaded_photo_3d(id: int, strength: float) -> bool:
		strengths[id] = strength
		return prepare_preloaded_photo_depth(id)
	func cancel_preloaded_photo_depth() -> void:
		for id in background_depth: depth_pending.erase(id)
		background_depth.clear()
	func update_photo_3d_strength(strength: float) -> void:
		for id in depth_pending: strengths[id] = strength
	func release_photo_depth_runtime() -> void: runtime_releases += 1
	func complete_depth(id: int, success: bool = true) -> void:
		var callback: Callable = preload_depth if background_depth.has(id) else depth
		depth_pending.erase(id); background_depth.erase(id)
		if not success:
			callback.call_deferred(id, '{"state":"error"}')
			return
		var image := Image.create(518,518,false,Image.FORMAT_RF)
		var value := .2 + float(id % 6) * .1
		image.fill(Color(value,0,0))
		var path := folder.path_join("depth_%d.bin" % id)
		FileAccess.open(path,FileAccess.WRITE).store_buffer(image.get_data())
		depth_paths[id] = path; depth_values[id] = value
		var payload := {"state":"ready", "path":path, "width":518, "height":518, "rect":[76.0/518.0,0,366.0/518.0,1]}
		if use_stereo:
			var pair := Image.create(640,160,false,Image.FORMAT_RGB8)
			pair.fill(Color(value,.3,.4))
			var pair_path := folder.path_join("pair_%d.png" % id)
			pair.save_png(pair_path); pair_paths[id] = pair_path
			payload.merge({"stereo_path":pair_path,"stereo_width":640,"stereo_height":160,"stereo_strength":strengths[id],"stereo_strategy":"video_soft_shift_gpu"})
		callback.call_deferred(id, JSON.stringify(payload))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func settle(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo.loading, "Foreground settles")

func warm(photo: Node3D, host: RefCounted) -> void:
	photo.finish_transition()
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		host.complete()
		for id in host.depth_pending.keys(): host.complete_depth(int(id))
		photo._pump_prefetch()
		if preloads_ready(photo,host): break
		await create_timer(.01).timeout
	check(preloads_ready(photo,host), "Adjacent preloads settle at the selected strength")

func preloads_ready(photo: Node3D, host: RefCounted) -> bool:
	for target in photo._neighbors(photo.index):
		if not photo._prefetched.has(target): return false
		var entry: Dictionary = photo._prefetched[target]
		if not entry.get("decoded", false): return false
	return true

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array[Dictionary] = []
	for i in 4:
		var image := Image.create(320,160,false,Image.FORMAT_RGB8)
		image.fill(Color(float(i)/4.0,.4,.6))
		var path := ProjectSettings.globalize_path(folder.path_join("photo_%d.jpg" % i))
		image.save_jpg(path)
		entries.append({"uri":"file://"+path, "title":"photo_%d.jpg" % i, "kind":"image"})
	var photo := Photo.new()
	photo.mode_memory = Memory.new(folder.path_join("modes")); photo.history_enabled = false
	root.add_child(photo)
	var host := Host.new(); host.folder = ProjectSettings.globalize_path(folder); host.ready = photo._on_ready
	photo.platform = host
	photo.open_image(entries[0].uri, entries[0].title, entries)
	await settle(photo); await warm(photo,host)
	check(host.opens == 1 and host.preloads == 2, "Initial display preloads next and wrapping previous through independent API")
	check(photo._prefetched.has(1) and photo._prefetched.has(3) and photo._prefetched.size() == 2, "Only two circular neighbours retained")
	check(Thumbnails.has(entries[1].uri) and Thumbnails.has(entries[3].uri), "Preloading persists thumbnails before neighbours are viewed")
	check(photo._prefetched[3].result.get("thumbnail_cached", false), "Cached decoded data remembers its persisted thumbnail")
	DirAccess.remove_absolute(Thumbnails.path_for(entries[3].uri))
	var first_request: int = photo._display_request
	var count: int = host.opens
	photo.spatial_preferred = false
	photo.navigate(-1)
	check(not photo.loading and photo.index == 3 and host.opens == count, "First-to-last uses decoded cache without foreground transfer")
	check(not photo.spatial_preferred,"Decoded-cache navigation preserves the global static-photo preference")
	check(photo._transition_direction == -1, "Wrapping previous still enters from left")
	check(Thumbnails.has(entries[3].uri), "Cache hit restores a thumbnail removed by cache cleanup")
	await warm(photo,host)
	check(photo._prefetched.has(0) and int(photo._prefetched[0].id) == first_request, "Departing photo keeps its source and decoded data for return")
	photo.spatial_preferred = true
	photo.navigate(1)
	check(photo.index == 0 and not photo.loading and host.opens == count and photo._transition_direction == 1, "Last-to-first returns from cache with right entry")
	check(photo.spatial_preferred,"Returning from the decoded cache preserves the global spatial-photo preference")
	await warm(photo,host)
	photo.navigate(-1); photo.navigate(-1); photo.navigate(1)
	await settle(photo)
	check(photo.index == 3 and photo.pending_index == -1, "Rapid reversal back to displayed photo cancels stale request")
	host.complete(); await create_timer(.05).timeout
	check(photo.index == 3, "Late preload/foreground responses cannot overwrite chosen photo")
	await warm(photo,host)
	var invalid_id: int = photo._prefetched[2].id
	host.release_photo(invalid_id)
	count = host.opens
	photo.navigate(-1); await settle(photo)
	check(photo.index == 2 and host.opens == count + 1, "Missing cached source retries through normal foreground loading")
	await warm(photo,host)
	# A cancelled decoder owns its file until the worker returns.
	while photo._thread: await create_timer(.01).timeout
	photo.set_process(false)
	var neighbour: int = photo._neighbors(photo.index)[0]
	var id: int = photo._prefetched[neighbour].id
	var source_path: String = host.held[id]
	var entered := Semaphore.new(); var release := Semaphore.new()
	photo._decoding = {"id":id, "index":neighbour, "prefetch":true, "epoch":photo._cache_epoch}
	photo._thread = Thread.new()
	photo._thread.start(func(): entered.post(); release.wait(); return {"uncached":true})
	entered.wait()
	photo._drop_prefetch(neighbour)
	check(FileAccess.file_exists(source_path) and photo._deferred_release_ids.has(id), "Pruning does not unlink an active decoder source")
	release.post()
	while photo._thread.is_alive(): await create_timer(.01).timeout
	photo._process(0)
	check(not FileAccess.file_exists(source_path) and not photo._deferred_release_ids.has(id), "Worker completion releases the cancelled file lease")
	photo.set_process(true)
	photo.set_projection(3)
	photo._pump_prefetch()
	check(photo._prefetched.is_empty() and not photo.navigate(5), "Panorama keeps bounded navigation and has no background neighbour cache")
	photo.close_image()
	check(host.held.is_empty() and photo._prefetched.is_empty(), "Closing releases displayed and neighbouring sources")
	photo.open_image(entries[0].uri, entries[0].title)
	await settle(photo)
	count = host.preloads
	check(not photo.navigate(-1) and not photo.navigate(1) and not photo.snapshot().can_next, "Single-photo queue cannot navigate to itself")
	photo._pump_prefetch(); check(host.preloads == count, "Single photo starts no redundant preload")
	photo.open_image(entries[0].uri, entries[0].title, entries.slice(0,2))
	await settle(photo); await warm(photo,host)
	check(photo._prefetched.size() == 1, "Two-photo queue deduplicates previous/next to one preload")
	photo.navigate(-1)
	check(photo.index == 1 and photo._transition_direction == -1, "Two-photo reverse direction survives identical neighbour target")
	photo.queue_free(); await process_frame
	check(host.held.is_empty(), "Exiting releases all cache file ownership")
	# Large sources are retained as files; their tiny preview can still be cached.
	var large := Image.create(1,1,false,Image.FORMAT_RGB8).save_png_to_buffer()
	large[16]=0; large[17]=0; large[18]=32; large[19]=0
	large[20]=0; large[21]=0; large[22]=16; large[23]=0
	var large_path := ProjectSettings.globalize_path(folder.path_join("large-header.png"))
	FileAccess.open(large_path, FileAccess.WRITE).store_buffer(large)
	var bounded := Photo._decode({"prefetch":true, "info":{"path":large_path, "thumbnail_path":str(entries[0].uri).trim_prefix("file://"), "orientation":6}})
	check(bounded.get("uncached", false) and not bounded.has("image"), "8K predecode is skipped before allocating pixels above the cache budget")
	check(bounded.has("thumbnail") and bounded.thumbnail.get_height() > bounded.thumbnail.get_width(), "Large-file thumbnail remains available with EXIF orientation")
	await check_converted(entries)
	await check_baked(entries)
	await check_joined(entries, false)
	await check_joined(entries, true)
	await check_recent_files(entries)
	for failure in failures: push_error(failure)
	print("Photo preload/cycle: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func wait_depth(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while photo._pending_display.is_empty() and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo._pending_display.is_empty(), "Decoded photo waits for its conversion result")

func current_depth(photo: Node3D, host: RefCounted) -> void:
	host.complete_depth(photo._request)
	var until := Time.get_ticks_msec()+4000
	while not photo.depth_enabled and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(photo.depth_enabled, "Current page conversion completes")

func check_converted(entries: Array[Dictionary]) -> void:
	await check_current_only(entries, false)

func check_baked(entries: Array[Dictionary]) -> void:
	await check_current_only(entries, true)

func check_current_only(entries: Array[Dictionary], baked: bool) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("current_%s_modes" % baked)); root.add_child(photo)
	var host := Host.new(); host.use_stereo = baked; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo); host.complete_depth(photo._request); await settle(photo)
	check(photo.depth_enabled, "First selected photo still supports 3D")
	await warm(photo,host)
	var previous_id: int = photo._display_request
	var calls: int = host.depth_calls
	check(calls == 1 and host.background_depth.is_empty(), "Warming neighbours never runs 3D")
	photo.navigate(-1)
	check(photo.index == 3 and not photo.loading and not photo.depth_enabled and host.depth_calls == calls + 1, "Cached colour is adopted before current-page conversion")
	check(photo.placeholder_visible() and photo.snapshot().loading and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Cached 3D selection stays covered while converting")
	check(photo._stereo_texture == null and photo._depth_texture == null, "Old GPU depth/stereo are not used by incoming colour")
	check(not host.depth_paths.has(previous_id) and not host.pair_paths.has(previous_id), "Previous generated files are discarded")
	check(photo._prefetched.values().all(func(entry): return not entry.has("depth_data") and not entry.get("result", {}).has("depth_data")), "No neighbouring entry retains generated data")
	await current_depth(photo,host)
	var current: Texture2D = photo._stereo_texture if baked else photo._depth_texture
	photo.set_hand_scale(2); photo.pan_hand(Vector2(.1,.05))
	check((photo._stereo_texture if baked else photo._depth_texture) == current and host.depth_calls == calls + 1, "Zoom/pan reuse only the currently displayed 3D")
	if baked:
		photo.set_depth_strength(.75); await create_timer(.2).timeout
		check(host.strengths[photo._display_request] == .75, "Current strength adjustment remains supported")
		host.complete_depth(photo._display_request)
		var until := Time.get_ticks_msec()+4000
		while photo.snapshot().render_strength != .75 and Time.get_ticks_msec()<until: await create_timer(.01).timeout
		check(photo.snapshot().render_strength == .75, "Rebuilt current pair uses the new strength")
	await warm(photo,host)
	calls = host.depth_calls
	photo.navigate(1)
	check(photo.index == 0 and not photo.loading and not photo.depth_enabled and host.depth_calls == calls+1, "Returning reuses colour but recomputes 3D")
	check(photo.placeholder_visible() and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Returning also waits behind the cover for its own 3D")
	host.complete_depth(photo._request,false); await process_frame
	check(photo.panel.visible and not photo.loading and not photo.depth_enabled and photo.depth_error == "3D unavailable", "Failed current 3D leaves colour visible")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.depth_paths.is_empty() and host.pair_paths.is_empty(), "Close releases sources and current 3D")

func check_joined(entries: Array[Dictionary], baked: bool) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("late_%s_modes" % baked)); root.add_child(photo)
	var host := Host.new(); host.use_stereo = baked; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo); host.complete_depth(photo._request); await settle(photo); await warm(photo,host)
	photo.navigate(1)
	var late: int = photo._request
	photo.navigate(-1)
	photo._on_prefetch_depth(late, '{"state":"error"}')
	check(photo.index == 0 and not photo.loading and photo._depth_queue.is_empty(), "Rapid reversal ignores stale neighbour conversions")
	await current_depth(photo,host)
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.depth_pending.is_empty(), "Rapid turns release sources and pending work")

func check_recent_files(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("recent_modes")); root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo); host.complete_depth(photo._request); await settle(photo); await warm(photo,host)
	var original: int = photo._display_request
	photo.navigate(1); await warm(photo,host)
	photo.navigate(1); await warm(photo,host)
	check(photo._recent_files.has(0) and int(photo._recent_files[0].id) == original, "Recently viewed source survives outside the adjacent window")
	check(not photo._recent_files[0].has("result") and not photo._recent_files[0].has("depth_data"), "Recent cache retains files without decoded images")
	var opens: int = host.opens; var models: int = host.model_calls
	photo._select(0,-1); await settle(photo)
	await current_depth(photo,host)
	check(photo.index == 0 and photo._display_request == original and host.opens == opens and host.model_calls == models+1,
		"Returning to a recent file reuses its source but regenerates discarded depth")
	photo.finish_transition()
	var neighbours: Array = photo._neighbors(photo.index)
	await warm(photo,host)
	for target in neighbours:
		photo._prefetched[target].info.cache_bytes = Photo.RECENT_FILE_BYTES
		photo._remember_files(int(target))
	check(photo._recent_files.size() == 1, "Recent disk cache evicts older files at its byte limit")
	photo.close_image()
	check(host.held.is_empty() and photo._recent_files.is_empty(), "Closing removes recent source and converted files")
	for target in range(10,16):
		var cached: Dictionary = host.make_file(entries[0].uri)
		photo._prefetched[target] = {"id":cached.id, "info":{"path":cached.path,"cache_bytes":4096}}
		photo._remember_files(target)
	check(photo._recent_files.size() == Photo.RECENT_FILE_COUNT and not photo._recent_files.has(10), "Recent file count evicts the oldest entries")
	photo.close_image()
	check(host.held.is_empty(), "Count-evicted and retained file leases all close")
	photo.queue_free(); await process_frame
