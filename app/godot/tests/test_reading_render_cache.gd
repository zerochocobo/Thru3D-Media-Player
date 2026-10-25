extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Fixture := preload("res://tests/test_photo_preload.gd")
var checks := 0
var failures: Array[String] = []
var folder := ProjectSettings.globalize_path("res://../../build/output/reading-cache/display")

class Host extends Fixture.Host:
	var originals := {}
	var available := true
	var reading_uris: Array[String] = []
	var reading_activations: Array[String] = []
	var memory_policy := {"budget":192*1024*1024,"color":true,"retain":true}
	func has_java_method(method: String) -> bool:
		return method in ["reading_render_policy", "preload_reading_photo", "reading_page_cached", "reading_page_window", "activate_reading_photo"] or super.has_java_method(method)
	func reading_render_policy(_double: bool) -> String: return JSON.stringify(memory_policy)
	func activate_reading_photo(id: int, uri: String) -> bool:
		reading_activations.append(uri)
		return activate_photo(id)
	func reading_page_window(_payload: String) -> void: pass
	func reading_page_cached(_uri: String) -> bool: return available
	func preload_reading_photo(uri: String) -> int:
		reading_uris.append(uri)
		return preload_photo(uri)
	func make_file(uri: String) -> Dictionary:
		return super.make_file(str(originals.get(uri, uri)))
	func pdf_close(_session: String) -> void: pass
	func archive_close(_session: String) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func _initialize() -> void: run.call_deferred()

func settle(photo: Node3D, host: Host, target: int = -1) -> void:
	var until := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < until:
		host.complete()
		for id in host.depth_pending.keys(): host.complete_depth(id)
		if target < 0 and not photo.loading: break
		if target >= 0:
			photo.finish_transition(); photo._reveal_seconds = 0; photo._placeholder.visible = false
			photo._pump_prefetch()
			var entry: Dictionary = photo._prefetched.get(target, {})
			if entry.get("stage") == "done" and entry.get("result", {}).has("ready_texture"): break
		await create_timer(.01).timeout
	if target < 0: check(not photo.loading and photo.error.is_empty(), "Foreground completes without error")
	else:
		var entry: Dictionary = photo._prefetched.get(target, {})
		check(entry.get("stage") == "done" and entry.get("result", {}).has("ready_texture"), "Neighbour colour is decoded and uploaded")

func make_photo(double: bool, scheme: String) -> Array:
	var photo := Photo.new(); photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("modes"))
	root.add_child(photo)
	photo.magazine.cache_directory = folder.path_join("spreads")
	var host := Host.new(); host.folder = folder; host.use_stereo = true
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth
	photo.platform = host; photo.archive_mode = scheme != "file"
	photo.gallery.mode = photo.Gallery.Layout.MAGAZINE if double else photo.Gallery.Layout.SINGLE
	for i in 8:
		var source := folder.path_join("original-%d.png" % i)
		var image := Image.create(80 + i * 2, 120, false, Image.FORMAT_RGB8)
		image.fill(Color.RED if i % 2 == 0 else Color.BLUE); image.save_png(source)
		var uri := "%s://book/%d" % [scheme, i] if scheme != "file" else "file://" + source
		host.originals[uri] = "file://" + source
		photo.queue.append({"uri":uri,"title":"Page %d" % i})
	return [photo, host]

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	for double in [false, true]:
		for scheme in ["comic", "pdfpage", "file"]:
			if not double and scheme == "file": continue # Existing ordinary single-photo suite covers it.
			var pair := make_photo(double, scheme)
			var photo: Node3D = pair[0]; var host: Host = pair[1]
			host.available = false
			photo.auto_depth = true
			photo._select(0); await settle(photo, host)
			var next := 2 if double else 1
			photo.finish_transition(); photo._reveal_seconds = 0
			photo._pump_prefetch()
			if scheme != "file": check(host.preloads == 0, "Render prefetch waits for original file cache")
			host.available = true
			await settle(photo, host, next)
			var entry: Dictionary = photo._prefetched[next]
			var texture: Texture2D = entry.result.ready_texture
			check(not entry.has("depth_data") and host.background_depth.is_empty(), "Neighbour prepares no depth or stereo")
			var opens := host.opens; var depth_calls := host.depth_calls
			check(host.reading_uris.size() == (3 if double else 1), "Spread prepares two original pages and one joined source")
			if double: check(host.reading_uris.back().ends_with(".jpg" if scheme == "pdfpage" else ".png"), "PDF prefetch uses the foreground JPEG codec; other spread sources stay lossless")
			photo._select(next, 1)
			check(not photo.loading and photo.index == next, "Ready neighbour displays synchronously at selection")
			check(not photo.depth_enabled and photo._stereo_texture == null and photo._texture == texture, "Cached colour appears immediately while current-page 3D starts")
			check(host.opens == opens and host.depth_calls == depth_calls + 1, "Cache hit reuses the source and starts exactly one current-page conversion")
			check(host.reading_activations.back() == str(photo.queue[next].uri), "Promotion advances the original-file selection as well as the native source")
			check(not photo.placeholder_visible() and not photo._transition_active and photo._reveal_seconds == 0, "Cache hit has no blank placeholder or reveal delay")
			if double:
				check(photo._size == Vector2(170,120), "Prepared spread contains both full-resolution pages")
				var pixels: Image = photo._texture.get_image()
				check(pixels.get_pixel(10,60).r > .8 and pixels.get_pixel(150,60).b > .8, "Spread shows the correct left and right pages")
			await settle(photo, host, next * 2)
			check(photo._prefetched.has(0), "Previous page/spread remains within the window")
			photo._select(next * 2, 1)
			check(not photo._prefetched.has(0) and photo._recent_files.is_empty(), "Outside spread is released without a hidden recent-file cache")
			# Turning back immediately reuses the complete spread and its generated depth.
			opens = host.opens; depth_calls = host.depth_calls
			photo._select(next, -1)
			check(not photo.loading and not photo.depth_enabled and host.opens == opens and host.depth_calls == depth_calls + 1, "Reverse turn reuses colour and recomputes only its current-page 3D")
			check(photo._prefetched.values().all(func(value): return not value.has("depth_data") and not value.get("result", {}).has("depth_data")), "Previous page retains no 3D resources")
			photo._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
			check(photo._prefetched.is_empty(), "Backgrounding releases neighbouring render resources")
			photo._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
			photo.close_image(); photo.free()
			check(host.held.is_empty(), "Closing releases all native page/spread sources")
	# Cancellation while only the first half of a spread is ready cannot promote half a page.
	var pair := make_photo(true, "pdfpage")
	var photo: Node3D = pair[0]; var host: Host = pair[1]
	photo._select(0); await settle(photo, host)
	photo.finish_transition(); photo._reveal_seconds = 0; photo._pump_prefetch()
	check(photo._prefetched.has(2) and not photo.reading_render.complete(photo._prefetched[2]), "Incomplete spread is marked non-promotable")
	photo._select(6, 1); await settle(photo, host)
	host.complete(); await process_frame
	check(photo.index == 6 and not photo._prefetched.has(2), "Late cancelled preload cannot replace a distant selection")
	photo.close_image(); photo.free()
	# Refuse a huge second original before composition or speculative depth conversion.
	pair = make_photo(true, "comic"); photo = pair[0]; host = pair[1]
	host.available = false; photo.auto_depth = true
	var huge := Image.create(8192,8,false,Image.FORMAT_RGB8); huge.fill(Color.WHITE)
	var huge_path := folder.path_join("huge-page.png"); huge.save_png(huge_path); huge = null
	host.originals["comic://book/3"] = "file://" + huge_path
	photo._select(0); await settle(photo, host)
	var before_depth := host.depth_calls
	host.available = true; photo.finish_transition(); photo._reveal_seconds = 0
	var reject_until := Time.get_ticks_msec() + 5000
	while not photo._prefetch_failed.has(2) and Time.get_ticks_msec() < reject_until:
		host.complete(); photo._pump_prefetch(); await create_timer(.01).timeout
	check(photo._prefetch_failed.has(2) and not photo._prefetched.has(2), "8K second page discards the partial spread")
	check(host.depth_calls == before_depth and host.held.size() == 1, "Rejected spread neither runs 3D nor leaks either source")
	photo.close_image(); photo.free()
	# Late neighbour results never read potentially huge stereo files or change selection.
	pair = make_photo(false, "pdfpage"); photo = pair[0]; host = pair[1]
	photo.auto_depth = true; photo._select(0); await settle(photo, host)
	await settle(photo, host, 1)
	var entry: Dictionary = photo._prefetched[1]
	var id := int(entry.id)
	var calls := host.depth_calls
	photo._on_prefetch_depth(id, JSON.stringify({"state":"ready","stereo_path":"missing-8192.rgba"}))
	check(photo._depth_queue.is_empty() and not entry.has("depth_data") and host.depth_calls == calls, "Legacy neighbour 3D result is ignored before file loading")
	photo._select(1,1)
	check(not photo.loading and not photo.depth_enabled and photo._stereo_texture == null, "3D-enabled cache hit first displays ordinary colour")
	await settle(photo,host)
	var until := Time.get_ticks_msec()+5000
	while not photo.depth_enabled and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(photo.depth_enabled and photo._stereo_texture != null, "Only the selected page receives generated 3D")
	check(not host.depth_paths.has(int(photo._prefetched[0].id)), "Leaving a converted page discards its native generated files")
	photo.close_image(); photo.free()
	# Admission and eviction have different watermarks: using reserved working memory
	# must not evict an already prepared page or cancel a running conversion.
	pair = make_photo(true, "pdfpage"); photo = pair[0]; host = pair[1]
	host.memory_policy = {"budget":96*1024*1024,"color":true,"retain":true}
	photo.auto_depth = true
	photo._select(0); await settle(photo, host)
	await settle(photo, host, 2)
	check(photo.reading_render.budget_bytes() == 96*1024*1024, "Low-memory double-page policy reaches the display cache")
	var low_calls := host.depth_calls
	photo._pump_prefetch()
	check(host.depth_calls == low_calls and not photo._prefetched[2].has("depth_data"), "Memory admission prepares colour without background 3D")
	var current_texture: Texture2D = photo._texture
	var cached_texture: Texture2D = photo._prefetched[2].result.ready_texture
	host.memory_policy.color = false; photo.reading_render.policy_poll_at = 0
	photo.reading_render.refresh_policy()
	check(photo._prefetched[2].result.ready_texture == cached_texture, "Admission watermark preserves an already allocated neighbour")
	host.memory_policy.retain = false; host.memory_policy.budget = 0; photo.reading_render.policy_poll_at = 0
	photo.reading_render.refresh_policy()
	check(photo._prefetched.is_empty() and photo._texture == current_texture and photo.depth_enabled, "Pressure watermark releases neighbours while preserving current 3D")
	host.memory_policy.color = true; host.memory_policy.retain = true; host.memory_policy.budget = 96*1024*1024
	photo.reading_render.policy_poll_at = 0; photo.reading_render.refresh_policy(); photo._pump_prefetch()
	check(photo._prefetched.is_empty() and photo.reading_render.resume_at > Time.get_ticks_msec(), "Pressure recovery waits before restarting speculative work")
	photo.reading_render.resume_at = 0
	await settle(photo, host, 2)
	photo._select(2, 1)
	check(not photo.loading and not photo.depth_enabled, "Recovered low-memory cache promotes colour without a 3D cache")
	photo.close_image(); photo.free()
	print("Reading render cache: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
