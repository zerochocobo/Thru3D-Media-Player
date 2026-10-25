extends RefCounted
## Sequential source requests reuse PhotoDisplay's decoder, cancellation and compositor.
## Pair corrections belong to the current album session, never to global file-mode memory.
var single_pages := {}
var right_to_left := false # Global reading preference; reset() clears only album-specific pairing.
var first := {}
var first_request := 0
var transfer := {}
var cache_directory := OS.get_cache_dir().path_join("thru3d-photo-spreads")
var photo: Node3D

func _init(owner: Node3D) -> void:
	photo = owner

func active() -> bool:
	return photo.gallery.mode == photo.Gallery.Layout.MAGAZINE

func single(at: int) -> bool:
	return at >= 0 and at < photo.queue.size() and single_pages.has(str(photo.queue[at].uri))

func count(at: int) -> int:
	if at < 0 or at >= photo.queue.size(): return 0
	return 1 if single(at) or at + 1 >= photo.queue.size() or single(at + 1) else 2

func target(direction: int) -> int:
	var at: int = photo.pending_index if photo.pending_index >= 0 else photo.index
	return target_from(at, direction)

func target_from(at: int, direction: int) -> int:
	if direction > 0: return at + count(at)
	if at <= 0: return -1
	return at - 1 if single(at - 1) or (at >= 2 and single(at - 2)) else maxi(0, at - 2)

func cancel() -> void:
	first.clear()
	if first_request > 0 and first_request != photo._display_request: photo._release_photo(first_request, true)
	first_request = 0
	if not transfer.is_empty():
		remove_file(str(transfer.path)); transfer = {}

func reset() -> void:
	cancel(); single_pages.clear()

func reload() -> void:
	var at: int = photo.pending_index if photo.pending_index >= 0 else photo.index
	if at < 0: return
	photo._release_full_photo(true, false) # Pairing changes can reuse the original page files.
	photo._select(at)

func toggle_single() -> void:
	if not active() or photo.loading or photo.index < 0: return
	var uri: String = photo.queue[photo.index].uri
	if not single_pages.erase(uri): single_pages[uri] = true
	reload()

func shift(direction: int) -> void:
	if not active(): return
	var at: int = photo.pending_index if photo.pending_index >= 0 else photo.index
	photo.select_image(at + direction, direction)

## Called before accepting a decoded source. Never request both pages concurrently:
## Android's foreground photo bridge has one current request.
func prepare(result: Dictionary, job: Dictionary) -> bool:
	if not active() or result.has("error"):
		cancel(); return false
	if result.get("magazine_registered", false): return false
	if result.get("magazine", false):
		cancel()
		if not job.has("magazine_path"): return false
		# Native depth and person masks must read the entire joined spread, never page two.
		var registered_job := job.duplicate(); registered_job.erase("magazine_first")
		transfer = {"result":result, "job":registered_job, "path":job.magazine_path}
		photo._request = photo.platform.open_photo("file://" + str(job.magazine_path)) if FileAccess.file_exists(job.magazine_path) else 0
		photo._release_photo(int(job.id))
		transfer["id"] = photo._request
		if photo._request <= 0: ready(photo._request, {"state":"error"})
		return true
	if count(int(job.index)) == 1: return false
	first = result
	first_request = int(job.id)
	var uri := str(photo.queue[int(job.index) + 1].uri)
	photo._request = photo.platform.open_photo(uri) if photo.platform else -int(job.id)
	if photo._request <= 0 and photo.platform:
		photo.loading = false; photo.error = "Image unavailable"; photo._restore_display(); cancel(); photo.changed.emit()
	elif not photo.platform:
		photo._on_ready(photo._request, JSON.stringify({"state": "ready", "path": uri.trim_prefix("file://").uri_decode()}))
	return true

func decorate(job: Dictionary) -> void:
	if first.is_empty(): return
	job["magazine_first"] = first.duplicate() # Cancellation must not clear the worker's source snapshot.
	job["magazine_rtl"] = right_to_left
	if photo.Methods.supports(photo.platform, "prepare_photo_3d") or photo.Methods.supports(photo.platform, "prepare_photo_depth"):
		DirAccess.make_dir_recursive_absolute(cache_directory)
		var at := int(job.get("index", -1))
		var pdf: bool = at >= 0 and at < photo.queue.size() and preload("res://scripts/pdf_pages.gd").page(str(photo.queue[at].uri))
		job["magazine_path"] = cache_directory.path_join("spread-%d-%d-%d.%s" % [Time.get_ticks_usec(), photo.get_instance_id(), photo._serial, "jpg" if pdf else "png"])

func ready(id: int, info: Variant) -> bool:
	if transfer.is_empty() or id != int(transfer.id): return false
	if info is Dictionary and info.get("state") == "metadata": return true
	var pending := transfer; transfer = {}
	remove_file(str(pending.path)) # PhotoBridge owns its own source copy after ready.
	if int(pending.job.serial) != photo._serial or not active(): return true
	var result: Dictionary = pending.result
	result["magazine_registered"] = true
	if info is Dictionary and info.get("state") == "ready":
		result.info = info.duplicate()
		result.info["panorama"] = false
		result.info["native_stereo"] = false
		pending.job.id = id
	else:
		# The readable spread still works if native registration fails.
		result["depth_failed"] = true; pending.job.id = 0
		result.info["magazine_unregistered"] = true
		if id > 0: photo._release_photo(id, true)
		photo._request = 0
	photo._prepare_display(result, pending.job)
	return true

func cleanup_job(job: Dictionary) -> void:
	var path := str(job.get("magazine_path", ""))
	for entry in photo._prefetched.values():
		if path == str(entry.get("spread_path", "")): return
	if not path.is_empty() and path != str(transfer.get("path", "")): remove_file(path)

static func remove_file(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path): DirAccess.remove_absolute(path)

## Equal-height pages with no crop or gap. Bound the finished spread to 8192 x 4096.
static func compose(left: Image, right: Image, rtl: bool) -> Image:
	var ratio := float(left.get_width()) / left.get_height() + float(right.get_width()) / right.get_height()
	var height := maxi(1, mini(4096, mini(maxi(left.get_height(), right.get_height()), int(8192.0 / ratio))))
	# These are uncached decoder-owned images; consume them without two full-size copies.
	var pages: Array[Image] = [left, right]
	for page in pages:
		page.clear_mipmaps()
		page.convert(Image.FORMAT_RGBA8)
		page.resize(maxi(1, int(float(page.get_width()) * height / page.get_height())), height, Image.INTERPOLATE_CUBIC)
	var width := pages[0].get_width() + pages[1].get_width()
	if width > 8192:
		for page in pages: page.resize(maxi(1, int(page.get_width() * 8192.0 / width)), height, Image.INTERPOLATE_CUBIC)
	if rtl: pages.reverse()
	var joined := Image.create(pages[0].get_width() + pages[1].get_width(), height, false, Image.FORMAT_RGBA8)
	joined.blit_rect(pages[0], Rect2i(Vector2i.ZERO, pages[0].get_size()), Vector2i.ZERO)
	joined.blit_rect(pages[1], Rect2i(Vector2i.ZERO, pages[1].get_size()), Vector2i(pages[0].get_width(), 0))
	return joined
