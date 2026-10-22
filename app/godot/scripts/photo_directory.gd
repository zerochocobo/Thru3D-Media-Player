extends Node
## A captured cloud folder/order, independent of the visible library page. Metadata only;
## photos and videos share this directory scan without resolving or downloading media.
signal completed(entries: Array[Dictionary], complete: bool, error: String)
const Methods := preload("res://scripts/platform_methods.gd")
const Info := preload("res://scripts/image_info.gd")
const Audio := preload("res://scripts/background_audio_catalog.gd")
const MAX_ENTRIES := 20000
var platform: Object
var _context := {}
var _entries: Array[Dictionary] = []
var _uris := {}
var _offsets := {}
var _request := 0
var _offset := 0
var _connected: Object
var loading := false

func start(context: Dictionary) -> void:
	cancel()
	if context.is_empty(): return
	_context = context.duplicate(true); loading = true
	if _connected != platform:
		if is_instance_valid(_connected) and _connected.is_connected("media_list", receive): _connected.disconnect("media_list", receive)
		_connected = platform
		if is_instance_valid(platform) and platform.has_signal("media_list"): platform.connect("media_list", receive)
	_page(0)

func cancel() -> void:
	if _request > 0:
		if Methods.supports(platform, "media_photo_directory_cancel"): platform.media_photo_directory_cancel(_request)
		elif Methods.supports(platform, "media_cloud_cancel"): platform.media_cloud_cancel(_request)
	_request = 0; loading = false; _context = {}; _entries.clear(); _uris.clear(); _offsets.clear()

func _page(offset: int) -> void:
	if _offsets.has(offset): _finish(false, "Images unavailable"); return
	_offsets[offset] = true; _offset = offset
	if Methods.supports(platform, "media_photo_directory_page"):
		_request = int(platform.media_photo_directory_page(str(_context.path), offset, str(_context.order)))
	elif Methods.supports(platform, "media_cloud_sorted_page"):
		_request = int(platform.media_cloud_sorted_page(str(_context.path), offset, false, str(_context.order)))
	elif Methods.supports(platform, "media_cloud_page"):
		_request = int(platform.media_cloud_page(str(_context.path), offset, false))
	else: _request = -1
	if _request <= 0: _finish(false, "Images unavailable")

func receive(id: int, payload: String) -> void:
	if not loading or id != _request: return
	_request = 0
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("state") != "ready" or str(result.get("path", "")) != str(_context.path) \
		or int(result.get("offset", -1)) != _offset or ((Methods.supports(platform, "media_cloud_sorted_page") or Methods.supports(platform, "media_photo_directory_page")) and str(result.get("order", "")) != str(_context.order)):
		_finish(false, "Images unavailable"); return
	for item in result.get("entries", []):
		if not item is Dictionary or item.get("container", false) or str(item.get("uri", "")).is_empty(): continue
		var uri := str(item.uri)
		var image: bool = item.get("kind", "") == "image" or Info.is_image(uri, str(item.get("title", "")))
		var supported: bool = image if _context.get("kind", "image") == "image" else not image and item.get("kind", "") not in ["audio", "subtitle"] and not Audio.supported(str(item.get("title", "")))
		if not _uris.has(uri) and supported:
			var entry: Dictionary = item.duplicate(true)
			entry["browse_offset"] = _offset
			_uris[uri] = true; _entries.append(entry)
	var next := int(result.get("next_offset", -1))
	if next < 0: _finish(true, "")
	elif _entries.size() >= MAX_ENTRIES or _offsets.size() >= 512: _finish(false, "Images unavailable")
	else: _page(next)

func _finish(complete: bool, error: String) -> void:
	loading = false; _request = 0
	completed.emit(_entries.duplicate(true), complete, error)

func cursor(uri: String) -> Dictionary:
	for entry in _entries:
		if str(entry.uri) == uri:
			return {"path":_context.path,"order":_context.order,"offset":entry.browse_offset,"offsets":_offsets.keys(),"page_size":48}
	return {}

func _exit_tree() -> void: cancel()
