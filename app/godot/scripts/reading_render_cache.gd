extends RefCounted
## Ready-to-display neighbours. Original files remain owned by ReadingPageWindow/Android.
## Spreads prepare colour only. Generated depth/stereo belong exclusively to the displayed page.
const Pages := preload("res://scripts/pdf_pages.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const IMAGE_BYTES := 64 * 1024 * 1024
var photo: Node3D
var poll_at := 0
var suspended := false
var policy_poll_at := 0
var policy := {} # Empty on desktop/older hosts, which use the existing fixed bounds.
var resume_at := 0

func refresh_policy() -> void:
	if not Methods.supports(photo.platform, "reading_render_policy") or Time.get_ticks_msec() < policy_poll_at: return
	policy_poll_at = Time.get_ticks_msec() + 1000
	var value: Variant = JSON.parse_string(photo.platform.reading_render_policy(photo.magazine.active()))
	policy = value if value is Dictionary else {"budget":0,"color":false,"retain":false}
	if not policy.get("color", false):
		resume_at = Time.get_ticks_msec() + 3000
	# Admission headroom includes the next allocation; eviction uses a lower watermark.
	# Otherwise a running job can cancel itself simply by consuming its reserved space.
	if not policy.get("retain", false):
		photo._pause_prefetch()
		for at in photo._prefetched.keys(): photo._drop_prefetch(at)
	trim()

func budget_bytes() -> int:
	return mini(int(policy.get("budget", 1 << 30)), (192 if photo.magazine.active() else 128) * 1024 * 1024)

func _init(owner: Node3D) -> void: photo = owner

func active() -> bool: return photo.archive_mode or photo.magazine.active()

func complete(entry: Dictionary) -> bool:
	return not entry.has("stage") or entry.stage == "done"

func activate(id: int, at: int) -> bool:
	if not photo.platform: return true
	if active() and Methods.supports(photo.platform, "activate_reading_photo"):
		return photo.platform.activate_reading_photo(id, str(photo.queue[at].uri))
	return photo.platform.activate_photo(id)

func pause() -> void:
	for at in photo._prefetched.keys():
		if not complete(photo._prefetched[at]): photo._drop_prefetch(at)

func cleanup(entry: Dictionary) -> void:
	var path := str(entry.get("spread_path", ""))
	if photo._thread and path == str(photo._decoding.get("magazine_path", "")): return
	photo.Magazine.remove_file(path)

func fail(at: int) -> void:
	photo._prefetch_failed[at] = true
	photo._drop_prefetch(at)

func open_page(at: int, entry: Dictionary, uri: String) -> void:
	photo._prefetch_sequence += 1
	var id: int = photo.platform.preload_reading_photo(uri) if photo.platform else -photo._prefetch_sequence
	entry.id = id; entry.erase("info"); entry["decoded"] = false
	photo._prefetch_request = id
	if photo.platform and id <= 0: fail(at); return
	if not photo.platform:
		ready.call_deferred(id, {"state":"ready", "path":uri.trim_prefix("file://").uri_decode()})

func ready(id: int, info: Variant) -> bool:
	for at in photo._prefetched:
		var entry: Dictionary = photo._prefetched[at]
		if not entry.has("stage") or int(entry.id) != id: continue
		if info is Dictionary and info.get("state") == "metadata": return true
		photo._prefetch_request = 0
		if not info is Dictionary or info.get("state") != "ready": fail(at); return true
		entry.info = info
		if entry.stage == "register":
			cleanup(entry); entry.erase("spread_path")
			entry.result.info = info
			entry.result["magazine_registered"] = true
			entry.stage = "done"; entry.decoded = true
		return true
	return false

func decoded(result: Dictionary, job: Dictionary) -> bool:
	var at := int(job.index)
	var entry: Dictionary = photo._prefetched.get(at, {})
	if not entry.has("stage") or int(entry.id) != int(job.id): return false
	if not result.has("image") or result.image.get_data_size() > IMAGE_BYTES: fail(at); return true
	if entry.stage == "first" and photo.magazine.active() and photo.magazine.count(at) == 2:
		entry["first"] = result; entry.stage = "second"
		photo._release_photo(int(entry.id))
		open_page(at, entry, str(photo.queue[at + 1].uri))
	elif entry.stage in ["first", "second"]:
		entry.erase("first"); entry.result = result; entry.info = result.info; entry.decoded = true
		if result.get("magazine", false) and photo.platform:
			entry.stage = "register"
			photo._release_photo(int(entry.id))
			open_page(at, entry, "file://" + str(entry.spread_path))
		else:
			entry.stage = "done"
			# A cached desktop spread must not be composed for a second time on promotion.
			if result.get("magazine", false): result["magazine_registered"] = true
	trim()
	return true

func pump() -> void:
	refresh_policy()
	photo._prune_prefetch()
	if suspended or not photo._cache_supported() or photo.index < 0 or photo.geometry != 0: return
	if not policy.get("color", true) or Time.get_ticks_msec() < resume_at: return
	if photo._depth_busy or photo._depth_thread or photo._thread or photo._prefetch_request != 0 or photo._prefetch_depth_request != 0: return
	trim()
	var neighbors: Array = photo._neighbors(photo.index)
	for at in neighbors:
		var entry: Dictionary = photo._prefetched.get(at, {})
		if entry.is_empty():
			# Only speculate in the travel direction; the previous spread is retained when left.
			var preferred: int = photo.magazine.target_from(photo.index, photo._navigation_direction) if photo.magazine.active() else photo.index + photo._navigation_direction
			if at != preferred or photo._prefetch_failed.has(at): continue
			if Time.get_ticks_msec() < poll_at: return
			poll_at = Time.get_ticks_msec() + 100
			var count: int = photo.magazine.count(at) if photo.magazine.active() else 1
			for page in range(at, at + count):
				var uri := str(photo.queue[page].uri)
				if Pages.container_page(uri) and (not Methods.supports(photo.platform, "reading_page_cached") or not photo.platform.reading_page_cached(uri)): return
			entry = {"stage":"first", "id":0, "decoded":false}
			photo._prefetched[at] = entry
			open_page(at, entry, str(photo.queue[at].uri))
			return
		if not entry.has("info"): return
		if not entry.get("decoded", false):
			# Reserve the incoming resident pixels before decoding, rather than evicting only
			# after the large allocation. Working-buffer headroom is checked by Android separately.
			var reserve := mini(IMAGE_BYTES, int(entry.info.get("width", 3072)) * int(entry.info.get("height", 2048)) * 16 / 3) + 8 * 1024 * 1024
			if entry.get("stage") == "second": reserve = maxi(0, IMAGE_BYTES - memory(entry.first, {}))
			trim(reserve, at)
			if not photo._prefetched.has(at): return
			var job := {"id":entry.id,"index":at,"info":entry.info,"prefetch":true,"epoch":photo._cache_epoch,"reading":true}
			if entry.get("stage") == "second":
				job["magazine_first"] = entry.first.duplicate()
				job["magazine_rtl"] = photo.magazine.right_to_left
				if photo.platform:
					DirAccess.make_dir_recursive_absolute(photo.magazine.cache_directory)
					var codec := "jpg" if Pages.page(str(photo.queue[at].uri)) else "png"
					entry["spread_path"] = photo.magazine.cache_directory.path_join("ahead-%d-%d.%s" % [photo.get_instance_id(), Time.get_ticks_usec(), codec])
					job["magazine_path"] = entry.spread_path
			photo._prefetch_decode = job
			return
		if not complete(entry) or not entry.get("result", {}).has("image"): continue
		var uploaded := warm(at, entry)
		trim()
		if uploaded: return

## At most one colour upload per idle frame. No neighbouring depth/stereo work.
func warm(at: int, entry: Dictionary) -> bool:
	var result: Dictionary = entry.result
	if not result.has("ready_texture"):
		var proxy: Image = result.get("proxy")
		var use_proxy: bool = proxy != null and photo._layer_possible(0)
		var image: Image = proxy if use_proxy else result.image
		trim(image.get_data_size(), at)
		if not photo._prefetched.has(at): return false
		result["ready_texture"] = ImageTexture.create_from_image(image)
		result["ready_proxy"] = use_proxy
		return true
	return false

static func memory(value: Variant, seen: Dictionary) -> int:
	if value is Image or value is ImageTexture:
		var id: int = value.get_instance_id()
		if seen.has(id): return 0
		seen[id] = true
		if value is Image: return value.get_data_size()
		# Conservative RGBA+mips estimate, also for small R8 depth textures.
		return int(value.get_width() * value.get_height() * 16.0 / 3.0)
	var total := 0
	if value is Dictionary:
		for item in value.values(): total += memory(item, seen)
	return total

func trim(reserve: int = 0, protect: int = -1) -> void:
	var budget := budget_bytes()
	var seen := {}; var total := memory(photo._prefetched, seen)
	var targets: Array = photo._neighbors(photo.index)
	targets.reverse() # Keep the forward spread first when the previous one cannot fit.
	if protect in targets: targets.erase(protect); targets.append(protect)
	for at in targets:
		if total + reserve <= budget: break
		if not photo._prefetched.has(at): continue
		fail(at)
		seen.clear(); total = memory(photo._prefetched, seen)
