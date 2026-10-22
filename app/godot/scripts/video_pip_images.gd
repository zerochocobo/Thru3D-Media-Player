extends Node
## Bounded static images, using the existing sampled source reader on an isolated channel.
const Info := preload("res://scripts/image_info.gd")
const Methods := preload("res://scripts/platform_methods.gd")
var platform: Object
var waiting: Array[Dictionary] = []
var active := {}
var request := 0
var thread: Thread

func _ready() -> void:
	if platform and platform.has_signal("pip_image_ready"): platform.connect("pip_image_ready", _on_ready)

func load_window(window: Node3D, uri: String) -> void:
	cancel(window)
	window.image_loading = true; window.image_error = false; window.refresh()
	waiting.append({"window": weakref(window), "uri": uri})

func cancel(window: Node3D) -> void:
	waiting = waiting.filter(func(job): return job.window.get_ref() != window)
	if not active.is_empty() and active.window.get_ref() == window:
		if request > 0 and platform: platform.cancel_pip_image(request)
		active.clear()
	window.image_loading = false

func _process(_delta: float) -> void:
	if thread and not thread.is_alive():
		var result: Image = thread.wait_to_finish(); thread = null
		var window: Node3D = active.window.get_ref() if not active.is_empty() else null
		if is_instance_valid(window) and not window.is_queued_for_deletion():
			window.image_loading = false
			if result:
				window.show_image(ImageTexture.create_from_image(result))
			else: window.image_error = true; window.refresh()
		_finish()
	if not active.is_empty() and not is_instance_valid(active.window.get_ref()):
		if request > 0 and platform: platform.cancel_pip_image(request)
		active.clear()
	if active.is_empty() and not thread:
		if request > 0: _finish()
		while not waiting.is_empty():
			active = waiting.pop_front()
			if not is_instance_valid(active.window.get_ref()): active.clear(); continue
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
	thread = Thread.new()
	if thread.start(_decode.bind(info)) != OK: thread = null; _failed()

func _failed() -> void:
	var window: Node3D = active.window.get_ref() if not active.is_empty() else null
	if is_instance_valid(window): window.image_loading = false; window.image_error = true; window.refresh()
	_finish()

func _finish() -> void:
	if request > 0 and platform: platform.release_pip_image(request)
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
