extends SceneTree
const Budget := preload("res://scripts/background_resource_budget.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Fixtures := preload("res://tests/test_photo_preload.gd")
var failures: Array[String] = []
var checks := 0
var folder := "user://adaptive_photo_%d" % Time.get_ticks_usec()

class Host extends Fixtures.Host:
	var policy := {"spare_bytes":4 * 1024 * 1024 * 1024, "cache_limit":192 * 1024 * 1024, "retain":true, "work":true}
	func has_java_method(method: String) -> bool:
		return method == "background_resource_policy" or super.has_java_method(method)
	func background_resource_policy() -> String: return JSON.stringify(policy)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func prime(budget: RefCounted, policy: Dictionary) -> void:
	budget.stop(); budget.policy = policy.duplicate()
	for i in range(200): budget.observe(2.0, 3.0, 11.1, 1000.0 / 90.0, 1.0 / 90.0)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var budget := Budget.new()
	budget._accept_native(3,budget._native_generation)
	check(budget._native_gpu == 3,"A current native sample retains its measured value")
	budget._accept_native(NAN,budget._native_generation)
	check(budget._native_gpu == 0,"Non-finite native timing immediately invalidates the previous sample")
	budget._accept_native(3,budget._native_generation - 1)
	check(budget._native_gpu == 0,"An older measurement generation cannot reopen optional-work admission")
	var policy := {"spare_bytes":4 * Budget.MIB * 1024, "cache_limit":192 * Budget.MIB, "retain":true, "work":true}
	check(not budget.can_start(100), "Unknown resource state cannot start speculative work")
	prime(budget, policy)
	check(budget.can_start(1024 * Budget.MIB), "Stable measured frame headroom admits bounded work")
	check(not budget.can_start(int(policy.spare_bytes), 1), "New residents are reserved in addition to peak work")
	check(budget.resident_limit(20 * Budget.MIB) == 192 * Budget.MIB, "Cache has a separate resident cap")
	budget.observe(2, 0, 11.1, 1000.0 / 90.0, 1.0 / 90.0)
	check(not budget.can_start(1) and budget.resident_limit(20 * Budget.MIB) > 0,
		"Unknown GPU timing stops precomputation without discarding useful completed results")
	prime(budget, policy)
	for i in range(90): budget.observe(2, 8, 11.1, 1000.0 / 90.0, 1.0 / 90.0)
	check(not budget.can_start(1), "Thirty percent GPU frame reserve is enforced")
	prime(budget, policy)
	for i in range(90): budget.observe(8, 2, 11.1, 1000.0 / 90.0, 1.0 / 90.0)
	check(not budget.can_start(1), "CPU reserve is enforced independently")
	prime(budget, policy); budget.observe(2, 2, 25, 1000.0 / 90.0, 1.0 / 90.0)
	check(not budget.can_start(1), "Missed frame starts a cooldown")
	for i in range(60): budget.observe(2, 2, 11.1, 1000.0 / 90.0, 1.0 / 90.0)
	check(not budget.can_start(1), "A brief recovery does not immediately restart background work")
	for i in range(300): budget.observe(2, 2, 11.1, 1000.0 / 90.0, 1.0 / 90.0)
	check(budget.can_start(1), "Sustained recovery permits another attempt")
	budget.policy["retain"] = false
	check(budget.resident_limit(100) == 0, "Memory pressure requests cache eviction")
	var cost := Budget.photo_cost(640, 480)
	check(int(cost.peak) == 512 * Budget.MIB + 640 * 480 * 128, "Cost includes cold model and transient working buffers")
	check(Budget.photo_cost(0, 100).is_empty(), "Unknown dimensions are never speculatively allocated")
	cost = Budget.photo_cost(2147483647, 2147483647)
	check(int(cost.peak) <= 1536 * Budget.MIB, "Source dimensions cannot overflow the work estimate")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var entries: Array[Dictionary] = []
	for i in range(6):
		var image := Image.create(640, 480, false, Image.FORMAT_RGB8)
		image.fill(Color(.2 + i * .1, .3, .4))
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % i))
		image.save_png(path); entries.append({"uri":"file://" + path,"title":"Photo %d" % i})
	await photo_cache(entries)
	await four_neighbours(entries)
	for failure in failures: push_error(failure)
	print("Background resource budget: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func wait_color(photo: Node3D, host: RefCounted) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		host.complete(); photo.finish_transition()
		if photo._prefetched.size() == 2 and photo._prefetched.values().all(func(e): return e.get("decoded", false)): return
		await create_timer(.01).timeout
	check(false, "Neighbour colour decoding completes")

func finish_background(photo: Node3D, host: RefCounted, id: int) -> void:
	host.complete_depth(id)
	await process_frame
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		photo._process_depth_jobs()
		if photo._prefetch_depth_request == 0 and photo._depth_thread == null: return
		await create_timer(.01).timeout
	check(false, "Background pair handover completes")

func photo_cache(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("modes"))
	root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth
	photo.platform = host
	photo.open_image(entries[0].uri, entries[0].title, entries)
	var deadline := Time.get_ticks_msec() + 5000
	while photo._pending_display.is_empty() and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo._pending_display.is_empty(), "Foreground starts normally while GPU measurements are unavailable")
	host.complete_depth(photo._request)
	while not photo.depth_enabled and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	await wait_color(photo, host)
	check(photo.depth_enabled and host.background_depth.is_empty(), "Missing GPU readings leave normal 3D accessible")
	photo.set_process(false)
	prime(photo.resource_budget, host.policy)
	photo._pump_depth_prefetch()
	var next_id: int = photo._prefetched[1].id
	check(photo._prefetch_depth_request == next_id and host.background_depth.size() == 1,
		"Only the next photo runs speculative 3D")
	photo._pump_depth_prefetch()
	check(host.background_depth.size() == 1, "A second background job is never queued")
	await finish_background(photo, host, next_id)
	check(photo._prefetched[1].has("depth_data") and not photo._prefetched[entries.size()-1].has("depth_data"),
		"Complete result is retained only for the prepared direction")
	var calls: int = host.depth_calls
	var previous_id: int = photo._display_request
	photo.navigate(1)
	check(photo.index == 1 and photo.depth_enabled and host.depth_calls == calls,
		"Forward navigation adopts the completed pair without inference")
	check(photo._prefetched[0].has("depth_data") and host.pair_paths.has(previous_id),
		"Previous 3D remains available within the resident budget")
	photo.finish_transition(); photo.navigate(-1)
	check(photo.index == 0 and photo.depth_enabled and host.depth_calls == calls,
		"Returning adopts the previous pair without inference")
	photo.finish_transition()
	photo._drop_cached_depth(1)
	photo._navigation_direction = 1
	prime(photo.resource_budget, host.policy)
	photo._pump_depth_prefetch()
	host.complete_depth(next_id)
	await process_frame
	check(not photo._depth_queue.is_empty(), "Completed background data can wait for the reader thread")
	calls = host.depth_calls
	photo.navigate(1)
	photo.resource_budget.defer_work(); photo._trim_depth_cache()
	check(not photo._depth_queue.is_empty() and photo._promoted_depth_request == next_id,
		"A cache cooldown cannot cancel a result already promoted by the user")
	var queued_deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < queued_deadline and (photo._depth_thread or not photo._depth_queue.is_empty()):
		photo._process_depth_jobs(); await create_timer(.01).timeout
	check(photo.depth_enabled and host.depth_calls == calls, "Queued promotion consumes its original result without duplicate work")
	photo.finish_transition(); photo.navigate(-1); photo.finish_transition()
	photo.resource_budget.policy["retain"] = false
	photo.resource_budget.policy["work"] = false
	photo._trim_depth_cache()
	check(photo._prefetched.values().all(func(e): return not e.has("depth_data") and not e.get("result", {}).has("depth_data")),
		"Pressure evicts neighbouring generated data")
	check(photo.depth_enabled and photo._display_depth_data.has("stereo_image"),
		"Pressure eviction leaves the displayed photo intact")
	photo.navigate(1)
	check(host.depth_calls == calls + 1 and photo._depth_busy,
		"No available background budget can block user-requested 3D conversion")
	host.complete_depth(photo._request)
	await process_frame
	while photo._depth_thread or not photo._depth_queue.is_empty():
		photo._process_depth_jobs(); await create_timer(.01).timeout
	check(photo.depth_enabled, "Foreground conversion completes under a zero cache budget")
	photo._on_prefetch_depth(next_id + 9999, '{"state":"ready","stereo_path":"missing"}')
	check(photo._depth_queue.is_empty(), "Stale background callbacks cannot allocate or revive cache entries")
	photo.finish_transition()
	# Headless tests feed measured samples explicitly; no synthetic GPU percentage reaches product code.
	prime(photo.resource_budget, host.policy)
	var other: int = photo._neighbors(photo.index)[0]
	var extra: Dictionary = host.make_file(entries[other].uri)
	photo._prefetched[other] = {"id":extra.id,"info":{"path":extra.path,"width":640,"height":480},"decoded":true}
	photo._pump_depth_prefetch()
	check(photo._prefetch_depth_request == int(extra.id), "File-only neighbours can prepare 3D without retaining a full colour image")
	var preparing: int = photo._prefetch_depth_request
	calls = host.depth_calls
	photo.navigate(1)
	check(photo._promoted_depth_request == preparing and photo._request == preparing,
		"Explicit navigation joins an in-progress cache task")
	# The mock only transfers the source; actual Android promotion also changes the signal owner.
	host.background_depth.erase(preparing)
	host.complete_depth(preparing)
	await process_frame
	var join_deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < join_deadline and (photo._depth_thread or not photo._depth_queue.is_empty()):
		photo._process_depth_jobs(); await create_timer(.01).timeout
	check(photo._prefetch_depth_request == 0, "Promotion clears the speculative slot")
	# Finish the promoted colour decode through the regular loop, with no requirement for spare RAM.
	photo.resource_budget.policy["retain"] = false; photo.resource_budget.policy["work"] = false
	photo.set_process(true)
	while photo.loading and Time.get_ticks_msec() < join_deadline: await create_timer(.01).timeout
	check(not photo.loading and photo.depth_enabled and host.depth_calls == calls,
		"Promoted early 3D completes normally after background permission is withdrawn, without duplicate inference")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.depth_paths.is_empty() and host.background_depth.is_empty(),
		"Closing releases all cached and displayed leases")

func four_neighbours(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false; photo.cache_each = 2
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("four-modes")); root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri, entries[0].title, entries)
	var deadline := Time.get_ticks_msec()+5000
	while photo._pending_display.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	host.complete_depth(photo._request)
	while Time.get_ticks_msec()<deadline:
		host.complete(); photo.finish_transition()
		if photo._prefetched.size()==4 and photo._prefetched.values().all(func(e):return e.get("decoded",false)): break
		await create_timer(.01).timeout
	check(photo._prefetched.size()==4,"Two-per-side prepares the four unique neighbour sources")
	photo.set_process(false); prime(photo.resource_budget,host.policy)
	var order: Array[int] = []
	for i in range(4):
		photo._pump_depth_prefetch()
		var id: int = photo._prefetch_depth_request
		if id<=0: check(false,"An admitted neighbour starts"); break
		for at in photo._prefetched:
			if int(photo._prefetched[at].id)==id: order.append(int(at))
		await finish_background(photo,host,id)
	check(order==[1,5,2,4],"Both sides fill serially in distance/browsing order")
	check(photo._prefetched.values().all(func(e):return e.has("depth_data")),"All four completed results can fit when headroom permits")
	var calls: int = host.depth_calls
	photo._pump_depth_prefetch()
	check(host.depth_calls==calls,"A full window does not regenerate existing results")
	photo.resource_budget.policy["retain"] = false; photo._trim_depth_cache()
	var small_policy: Dictionary = host.policy.duplicate(); small_policy.cache_limit = 10*1024*1024
	prime(photo.resource_budget,small_policy)
	for i in range(5):
		photo._pump_depth_prefetch()
		if photo._prefetch_depth_request>0: await finish_background(photo,host,photo._prefetch_depth_request)
	calls = host.depth_calls
	for i in range(5): photo._pump_depth_prefetch()
	check(host.depth_calls==calls,"Insufficient space reduces the window without repeatedly evicting and regenerating higher-priority results")
	photo.set_cache_each(1)
	check(photo._prefetched.size()==2 and photo._prefetched.has(1) and photo._prefetched.has(5),"Reducing the setting immediately prunes the extra pair on both sides")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty(),"Closing the wider window releases every source")
