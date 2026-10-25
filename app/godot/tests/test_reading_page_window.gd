extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var windows: Array[Dictionary] = []
	func reading_page_window(payload: String) -> void: windows.append(JSON.parse_string(payload))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func pages(values: Array) -> Array:
	return values.map(func(uri): return str(uri).get_file().to_int())

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	var host := Host.new(); photo.platform = host
	for i in 9: photo.queue.append({"uri":"pdfpage://book/%d" % i, "size":1024})
	photo.archive_mode = true
	var window: Dictionary = photo.reading_cache.plan(4, true)
	check(pages(window.keep) == [4,5,3] and pages(window.ahead) == [5], "Single page retains three files and reads ahead one")
	photo.gallery.mode = photo.Gallery.Layout.MAGAZINE
	window = photo.reading_cache.plan(4, true)
	check(pages(window.keep) == [4,5,6,7,2,3], "Double spread owns six original page files")
	check(pages(window.ahead) == [6,7], "Double spread prepares both next pages")
	check(not photo._cache_supported(), "Older native hosts keep the file cache without enabling unsupported render prefetch")
	check(photo.reading_cache.plan(4, false).ahead.is_empty(), "Foreground spread stops speculative scheduling")
	window = photo.reading_cache.plan(0, true)
	check(pages(window.keep) == [0,1,2,3], "First spread never wraps to the end")
	window = photo.reading_cache.plan(8, true)
	check(pages(window.keep) == [8,6,7] and window.ahead.is_empty(), "Odd last page has no nonexistent forward page")
	photo._navigation_direction = -1
	window = photo.reading_cache.plan(4, true)
	check(pages(window.keep) == [4,5,2,3,6,7] and pages(window.ahead) == [2,3], "Reverse navigation changes prefetch priority")
	photo._navigation_direction = 1
	photo.magazine.single_pages["pdfpage://book/4"] = true
	window = photo.reading_cache.plan(4, true)
	check(pages(window.keep) == [4,5,6,2,3] and pages(window.ahead) == [5,6], "Single-page override keeps true adjacent pair")
	photo.magazine.single_pages.clear()
	window = photo.reading_cache.plan(3, true)
	check(pages(window.keep) == [3,4,5,6,1,2], "Manually shifted pairing follows actual spread positions")
	photo.queue[5].size = 33 * 1024 * 1024
	window = photo.reading_cache.plan(3, true)
	check(pages(window.ahead) == [6], "Oversized encoded archive page is not fetched speculatively")
	photo.reading_cache.sync(3, true); photo.reading_cache.sync(3, true)
	check(host.windows.size() == 1, "Unchanged frame does not cross JNI again")
	photo.reading_cache.clear()
	check(host.windows.back().keep.is_empty(), "Closing clears native retention")
	for layout in [photo.Gallery.Layout.SIDES, photo.Gallery.Layout.WALL, photo.Gallery.Layout.FRAGMENTS]:
		photo.gallery.mode = layout
		check(photo.reading_cache.plan(3, true).keep.is_empty(), "Other layouts release file window %d" % layout)
	photo.gallery.mode = photo.Gallery.Layout.SINGLE
	photo.queue[3].uri = "file:///ordinary.jpg"
	check(photo.reading_cache.plan(3, true).keep.is_empty(), "Ordinary photo pipeline remains independent")
	# Header-sized long 8K image must not be decoded even when its pixel count is small.
	var folder := ProjectSettings.globalize_path("res://../../build/output/reading-cache")
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("long-8k.png")
	var image := Image.create(8192,8,false,Image.FORMAT_RGB8); image.fill(Color.WHITE); image.save_png(path)
	var decoded := Photo._decode({"info":{"path":path},"prefetch":true})
	check(decoded.get("uncached",false) and not decoded.has("image"), "8K edge blocks speculative decoding even for a thin image")
	photo.platform = null; photo.queue_free(); await process_frame
	print("Reading page window: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
