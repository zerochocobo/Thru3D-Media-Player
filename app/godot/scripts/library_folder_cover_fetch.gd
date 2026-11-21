extends RefCounted
## Downloads one declared DLNA cover for a visible file or folder at a time.
const Cache := preload("res://scripts/thumbnail_cache.gd")
const Info := preload("res://scripts/image_info.gd")
const BYTE_LIMIT := 512 * 1024
const FILE_BYTE_LIMIT := 2 * 1024 * 1024
const SETTLE_MS := 300
const FAILURE_MS := 120000
var menu: Node
var requests := 0
var _http: HTTPRequest
var _active: Dictionary = {}
var _failed: Dictionary = {}
var _decode_task := -1
var _encoded := PackedByteArray()
var _candidate := ""
var _eligible_at := 0
var _visit := ""
var _visit_requests := 0
var _last_start := -1000
var _recent_by_server: Dictionary = {}

func _init(host: Node) -> void:
	menu = host

func tick() -> void:
	if _decode_task >= 0 and WorkerThreadPool.is_task_completed(_decode_task):
		WorkerThreadPool.wait_for_task_completion(_decode_task)
		_decode_task = -1
		if _current():
			var stored := false
			if not _encoded.is_empty():
				stored = Cache.store_encoded(str(_active.key), _encoded, true)
				if stored: Cache.texture(str(_active.key))
			if stored: _failed.erase(_active.key)
			else: _fail(str(_active.key))
			var outcome := "stored" if stored else ("decode_failed" if _encoded.is_empty() else "cache_failed")
			menu.thumbnail_prefetch.record_declared_cover(_active.kind, outcome, 200, _active.bytes, _active.started)
		_encoded.clear()
		_active = {}
	if not _permitted():
		cancel()
		return
	var visit: String = menu._artwork_scope()
	if visit != _visit:
		_visit = visit
		_visit_requests = 0
		cancel()
	if not _active.is_empty():
		if not _current(): cancel()
		return
	if _decode_task >= 0 or not menu._covers.is_empty() or not menu.thumbnail_prefetch._job.is_empty(): return
	var choice := _next_visible()
	var key := str(choice.get("key", ""))
	var now := Time.get_ticks_msec()
	if _visit_requests >= 4 or now - _last_start < 1000: return
	var host: String = menu._dlna_server
	var starts: Array = _recent_by_server.get(host, []).filter(func(time): return now - int(time) < 60000)
	if starts.size() >= 12: return
	if key != _candidate:
		_candidate = key
		_eligible_at = now + SETTLE_MS
		return
	if not key.is_empty() and now >= _eligible_at:
		_visit_requests += 1
		_last_start = now
		starts.append(now)
		_recent_by_server.erase(host)
		_recent_by_server[host] = starts
		if _recent_by_server.size() > 16: _recent_by_server.erase(_recent_by_server.keys().front())
		_begin(choice)

func _permitted() -> bool:
	return (menu.visible and not menu.compact and menu.section == menu.Section.DLNA
		and not menu._dlna_server.is_empty() and not Cache.clearing() and Cache.ready() and not Cache._locked()
		and not menu.has_pointer_capture() and absf(menu._fling) <= 0.4 and not menu.file_actions.editing
		and Time.get_ticks_msec() - menu._stick_ms >= SETTLE_MS
		and not menu._pending.values().has("dlna_browse"))

func _next_visible() -> Dictionary:
	var now := Time.get_ticks_msec()
	for button in menu._buttons:
		var row: Dictionary = button.get("thumbnail_row", {})
		var key := _cover_key(row)
		if key.is_empty() or Cache.has(key) or now < int(_failed.get(key, 0)): continue
		var kind := "folder" if row.has("folder_cover_key") else str(row.get("kind", "video"))
		return {"key": key, "url": str(row.get("folder_cover_url", key)), "kind": kind, "generation": Cache.generation}
	return {}

static func _cover_key(row: Dictionary) -> String:
	return str(row.get("folder_cover_key", row.get("cover", "")))

## An unsuccessful XML URL can fall back to the same bounded path as an absent URL.
func awaiting_cover(row: Dictionary) -> bool:
	var key := _cover_key(row)
	return not key.is_empty() and (not _failed.has(key) or Cache.has(key))

func _current() -> bool:
	if not _permitted() or _active.is_empty() or int(_active.generation) != Cache.generation:
		return false
	for button in menu._buttons:
		if _cover_key(button.get("thumbnail_row", {})) == _active.key: return true
	return false

func _begin(choice: Dictionary) -> void:
	_active = choice
	_active.started = Time.get_ticks_msec()
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.body_size_limit = BYTE_LIMIT if choice.kind == "folder" else FILE_BYTE_LIMIT
	_http.max_redirects = 0
	_http.accept_gzip = false
	_http.timeout = 5.0
	menu.add_child(_http)
	_http.request_completed.connect(_received.bind(_http))
	if _http.request(choice.url) == OK:
		requests += 1
	else:
		menu.thumbnail_prefetch.record_declared_cover(_active.kind, "request_failed", 0, 0, _active.started)
		_fail(choice.key)
		cancel()

func _received(result: int, status_code: int, _headers: PackedStringArray, bytes: PackedByteArray, request: HTTPRequest) -> void:
	if request != _http: return
	_http.queue_free()
	_http = null
	if not _current():
		_active = {}
		return
	if result != HTTPRequest.RESULT_SUCCESS or status_code != 200:
		menu.thumbnail_prefetch.record_declared_cover(_active.kind, menu.ThumbnailPrefetch.declared_cover_failure(result),
			status_code, bytes.size(), _active.started)
		_fail(str(_active.key))
		_active = {}
		return
	_active.bytes = bytes.size()
	_decode_task = WorkerThreadPool.add_task(_decode.bind(bytes, 2048 if _active.kind == "folder" else 4096))

func _decode(bytes: PackedByteArray, max_dimension: int) -> void:
	var header := Info.inspect_header(bytes)
	if header.is_empty() or int(header.width) > max_dimension or int(header.height) > max_dimension: return
	var image := Image.new()
	var code := FAILED
	match str(header.codec):
		"jpg": code = image.load_jpg_from_buffer(bytes)
		"png": code = image.load_png_from_buffer(bytes)
		"webp": code = image.load_webp_from_buffer(bytes)
	if code == OK and not image.is_empty(): _encoded = Cache.encode(image)

func _fail(key: String) -> void:
	_failed.erase(key)
	_failed[key] = Time.get_ticks_msec() + FAILURE_MS
	if _failed.size() > 256: _failed.erase(_failed.keys().front())

func cancel() -> void:
	if is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
		_http = null
	_active = {}
	_candidate = ""

func finish() -> void:
	cancel()
	if _decode_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_decode_task)
		_decode_task = -1
	_encoded.clear()
