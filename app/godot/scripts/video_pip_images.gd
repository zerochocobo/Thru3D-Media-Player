extends Node
signal container_opened(entry: Dictionary)
## Bounded static images, using the existing sampled source reader on an isolated channel.
const Info := preload("res://scripts/image_info.gd")
const Methods := preload("res://scripts/platform_methods.gd")
var platform: Object
var waiting: Array[Dictionary] = []
var active := {}
var request := 0
var thread: Thread
var loaded := {}
var documents := {}

func release_document(document: Dictionary) -> void:
	if not document.is_empty() and Methods.supports(platform, "pdf_close"): platform.pdf_close(str(document.session))

func turn_page(window: Node3D, direction: int) -> void:
	if window.image_loading or window.pdf_document.is_empty(): return
	var document: Dictionary = window.pdf_document.duplicate()
	document.page = int(document.page) + direction
	if document.page < 0 or document.page >= int(document.pages): return
	load_window(window, "pdfpage://%s/%d" % [document.session, document.page], document)

func unload(window: Node3D) -> void:
	var previous: int = int(window.capture_image.get("id", 0))
	if previous > 0 and platform: platform.release_pip_image(previous)
	loaded.erase(window.get_instance_id())
	window.capture_image.clear()
	release_document(documents.get(window.get_instance_id(), {}))
	documents.erase(window.get_instance_id()); window.pdf_document.clear()

func _ready() -> void:
	if platform and platform.has_signal("pip_image_ready"): platform.connect("pip_image_ready", _on_ready)

func load_window(window: Node3D, uri: String, document: Dictionary = {}) -> void:
	if not document.is_empty():
		if not Methods.supports(platform, "pdf_retain") or not platform.pdf_retain(str(document.session)):
			window.image_error = true; window.refresh(); return
	cancel(window)
	window.image_loading = true; window.image_error = false; window.refresh()
	waiting.append({"window": weakref(window), "uri": uri, "document":document.duplicate()})

func cancel(window: Node3D) -> void:
	for job in waiting:
		if job.window.get_ref() == window: release_document(job.get("document", {}))
	waiting = waiting.filter(func(job): return job.window.get_ref() != window)
	if not active.is_empty() and active.window.get_ref() == window:
		if request > 0 and platform: platform.cancel_pip_image(request)
		release_document(active.get("document", {})); active.clear()
	window.image_loading = false

func _process(_delta: float) -> void:
	if thread and not thread.is_alive():
		var result: Image = thread.wait_to_finish(); thread = null
		var window: Node3D = active.window.get_ref() if not active.is_empty() else null
		if is_instance_valid(window) and not window.is_queued_for_deletion():
			window.image_loading = false
			if result:
				var keep_size: bool = not window.pdf_document.is_empty() and window.pdf_document.get("session") == active.get("document", {}).get("session")
				var previous_size: Vector2 = window.size
				unload(window)
				window.capture_image = {"id": request, "orientation": int(active.get("orientation", 1))}
				if request > 0: loaded[window.get_instance_id()] = request
				window.show_image(ImageTexture.create_from_image(result))
				window.pdf_document = active.get("document", {}).duplicate()
				if not window.pdf_document.is_empty(): documents[window.get_instance_id()] = window.pdf_document.duplicate()
				active.erase("document") # Transfer its reference to the displayed window.
				if keep_size:
					var extent := maxf(previous_size.x, previous_size.y)
					window.set_size(window.size * extent / maxf(window.size.x, window.size.y))
				window.refresh()
				if window.pdf_document.has("source"): container_opened.emit(window.pdf_document.source.duplicate(true))
				request = 0 # The displayed window now owns this local preview.
			else: window.image_error = true; window.refresh()
		_finish()
	if not active.is_empty() and not is_instance_valid(active.window.get_ref()):
		if request > 0 and platform: platform.cancel_pip_image(request)
		release_document(active.get("document", {})); active.clear()
	if active.is_empty() and not thread:
		if request > 0: _finish()
		while not waiting.is_empty():
			active = waiting.pop_front()
			if not is_instance_valid(active.window.get_ref()):
				release_document(active.get("document", {})); active.clear(); continue
			if Methods.supports(platform, "open_pip_image"):
				request = int(platform.open_pip_image(str(active.uri)))
				if request <= 0: _failed()
			else: _start({"path": str(active.uri).trim_prefix("file://").uri_decode()})
			break

func _on_ready(id: int, payload: String) -> void:
	if id != request or active.is_empty():
		if platform: platform.release_pip_image(id)
		return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state") != "ready": _failed(); return
	_start(info)

func _start(info: Dictionary) -> void:
	active["orientation"] = int(info.get("orientation", 1))
	thread = Thread.new()
	if thread.start(_decode.bind(info)) != OK: thread = null; _failed()

func _failed() -> void:
	var window: Node3D = active.window.get_ref() if not active.is_empty() else null
	if is_instance_valid(window): window.image_loading = false; window.image_error = true; window.refresh()
	_finish()

func _finish() -> void:
	if request > 0 and platform: platform.release_pip_image(request)
	release_document(active.get("document", {}))
	request = 0; active.clear()

static func _decode(info: Dictionary) -> Image:
	var path := str(info.get("path", ""))
	var header := Info.read_header(path)
	if header.is_empty() or int(header.width) * int(header.height) > 32 * 1024 * 1024: return null
	var image := Image.new()
	if image.load(path) != OK or image.is_empty(): return null
	Info.orient(image, int(info.get("orientation", header.get("orientation", 1))))
	var ratio := minf(1, 2048.0 / maxf(image.get_width(), image.get_height()))
	if ratio < 1: image.resize(maxi(1, roundi(image.get_width() * ratio)), maxi(1, roundi(image.get_height() * ratio)), Image.INTERPOLATE_LANCZOS)
	image.generate_mipmaps()
	return image

func _exit_tree() -> void:
	if request > 0 and platform: platform.cancel_pip_image(request)
	if thread: thread.wait_to_finish(); thread = null
	_finish()
	if platform:
		for id in loaded.values(): platform.release_pip_image(int(id))
	loaded.clear()
	for document in documents.values(): release_document(document)
	documents.clear()
	for job in waiting: release_document(job.get("document", {}))
	waiting.clear()
