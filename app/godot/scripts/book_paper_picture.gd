extends Node
## A picture of the reader's own under the words: fetched once from wherever it lives, turned into a
## grey texture the shape of a page and kept in the app's files. The pages then print it in the
## paper's own colours, lighter than the type, so any paper (day or night, any brightness) still reads as paper.
const Info := preload("res://scripts/image_info.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const PATH := "user://book/paper_picture.png"
## Half the page's own resolution and not blurred: the reader chose this picture and should still know
## it under the type (a 42x57 blur left nothing of it to recognise, 2026-11-28).
const SIZE := Vector2i(600, 800)
## Pixels at either end of the histogram left out when stretching it, so one bright window or a black
## border does not flatten the rest.
const CLIP := 0.02

signal finished(ok: bool)

var platform: Object
var busy := false
var _request := 0
var _connected: Object
var _thread: Thread

## The texture is there to print.
static func present() -> bool: return FileAccess.file_exists(PATH)

static func absolute() -> String: return ProjectSettings.globalize_path(PATH)

## Fetches [uri] (a file, SMB, DLNA or cloud picture) and makes the texture from it.
func choose(uri: String) -> bool:
	if busy: return false
	busy = true
	if Methods.supports(platform, "open_background_image"):
		if _connected != platform:
			_connected = platform; platform.connect("background_image_ready", _on_ready)
		_request = int(platform.open_background_image(uri))
		if _request > 0: return true
	elif uri.begins_with("file://") or uri.is_absolute_path():
		var path := preload("res://scripts/media_uri.gd").decode_path(uri.trim_prefix("file://"))
		if FileAccess.file_exists(path): return _start({"path": path})
	busy = false
	finished.emit(false)
	return false

func _on_ready(id: int, payload: String) -> void:
	if id != _request: return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state", "") != "ready": _done(false); return
	_start(info)

func _start(info: Dictionary) -> bool:
	_thread = Thread.new()
	if _thread.start(_make.bind(info)) != OK: _thread = null; _done(false); return false
	return true

func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		var ok: bool = _thread.wait_to_finish(); _thread = null
		_done(ok)

func _done(ok: bool) -> void:
	if _request > 0 and Methods.supports(platform, "release_background_image"): platform.release_background_image(_request)
	_request = 0; busy = false
	finished.emit(ok)

static func _make(info: Dictionary) -> bool:
	var path := str(info.get("path", ""))
	var header := Info.read_header(path)
	if header.is_empty() or int(header.width) * int(header.height) > 64 * 1024 * 1024: return false
	var image := _read(path, str(header.get("codec", "")))
	if image == null or image.is_empty(): return false
	Info.orient(image, int(info.get("orientation", header.get("orientation", 1))))
	var texture := texture_from(image)
	if texture == null: return false
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	return texture.save_png(PATH) == OK

## The platform hands over the picture's own bytes in a file with no extension, so it is read by what
## its header says it is, not by its name (Image.load goes by the name and refused it, 2026-11-28).
static func _read(path: String, codec: String) -> Image:
	if codec == "rgba": return preload("res://scripts/raw_image.gd").read(path, 2048)
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty(): return null
	var image := Image.new()
	var error: int = ERR_FILE_UNRECOGNIZED
	match codec:
		"png": error = image.load_png_from_buffer(bytes)
		"jpg": error = image.load_jpg_from_buffer(bytes)
		"webp": error = image.load_webp_from_buffer(bytes)
	return image if error == OK else null

## Grey, cut to the page's shape from the middle, its tones stretched across the whole range.
static func texture_from(source: Image) -> Image:
	if source == null or source.is_empty(): return null
	var image := source.duplicate() as Image
	if image.is_compressed() and image.decompress() != OK: return null
	image.convert(Image.FORMAT_L8)
	var aspect := float(SIZE.x) / SIZE.y
	var width := image.get_width(); var height := image.get_height()
	var crop := Rect2i(0, 0, width, height)
	if float(width) / height > aspect: crop.size.x = maxi(1, roundi(height * aspect)); crop.position.x = (width - crop.size.x) / 2
	else: crop.size.y = maxi(1, roundi(width / aspect)); crop.position.y = (height - crop.size.y) / 2
	image = image.get_region(crop)
	image.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	_stretch(image)
	return image

static func _stretch(image: Image) -> void:
	var data := image.get_data()
	var counts := PackedInt32Array(); counts.resize(256)
	for value in data: counts[value] += 1
	var skip := int(data.size() * CLIP)
	var low := 0; var high := 255; var seen := 0
	while low < 255 and seen + counts[low] <= skip: seen += counts[low]; low += 1
	seen = 0
	while high > 0 and seen + counts[high] <= skip: seen += counts[high]; high -= 1
	if high - low < 8: return
	var scale := 255.0 / (high - low)
	for i in data.size(): data[i] = clampi(roundi((data[i] - low) * scale), 0, 255)
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_L8, data)

func _exit_tree() -> void:
	if _thread: _thread.wait_to_finish(); _thread = null
	if _request > 0 and Methods.supports(platform, "release_background_image"): platform.release_background_image(_request)
	_request = 0
