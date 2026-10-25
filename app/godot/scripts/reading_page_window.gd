extends RefCounted
## Container files only: current spread plus one real spread on either side.
## No wraparound, thumbnails, decoded pixels, joined images or generated 3D.
const Methods := preload("res://scripts/platform_methods.gd")
const Pages := preload("res://scripts/pdf_pages.gd")
const PAGE_BYTES := 32 * 1024 * 1024
var photo: Node3D
var signature := ""

func _init(owner: Node3D) -> void:
	photo = owner

func plan(at: int, ready: bool) -> Dictionary:
	var result := {"keep": [], "ahead": []}
	if at < 0 or at >= photo.queue.size() or photo.gallery.mode not in [photo.Gallery.Layout.SINGLE, photo.Gallery.Layout.MAGAZINE]: return result
	if not Pages.container_page(str(photo.queue[at].uri)): return result
	var double: bool = photo.magazine.active()
	var current_count: int = photo.magazine.count(at) if double else 1
	var previous: int = photo.magazine.target_from(at, -1) if double else at - 1
	var following := at + current_count
	var preferred: int = previous if photo._navigation_direction < 0 else following
	var other: int = following if photo._navigation_direction < 0 else previous
	for start in [at, preferred, other]:
		if start < 0 or start >= photo.queue.size(): continue
		var count: int = photo.magazine.count(start) if double else 1
		for page in range(start, mini(start + count, photo.queue.size())):
			var item: Dictionary = photo.queue[page]
			var uri := str(item.uri)
			if not Pages.container_page(uri) or uri.get_slice("/", 2) != str(photo.queue[at].uri).get_slice("/", 2): continue
			if uri not in result.keep: result.keep.append(uri)
			# Keep the last spread if visited; do not fetch an unseen trailing spread on a jump.
			if ready and start == preferred and page not in range(at, at + current_count) and int(item.get("size", 0)) <= PAGE_BYTES:
				result.ahead.append(uri)
	return result

func sync(at: int, ready: bool) -> void:
	if not Methods.supports(photo.platform, "reading_page_window"): return
	var payload := JSON.stringify(plan(at, ready))
	if payload == signature: return
	signature = payload
	photo.platform.reading_page_window(payload)

func clear() -> void:
	signature = ""
	if Methods.supports(photo.platform, "reading_page_window"):
		photo.platform.reading_page_window('{"keep":[],"ahead":[]}')
