extends RefCounted
## Fetch only the next playback page, independently of the visible browser.
signal completed(items: Array[Dictionary], restart: bool)
signal failed(message: String)
const Methods := preload("res://scripts/platform_methods.gd")
const Images := preload("res://scripts/image_info.gd")
const Audio := preload("res://scripts/background_audio_catalog.gd")
const Location := preload("res://scripts/media_location.gd")
const TIMEOUT_MS := 30000
var platform: Object
var context := {}
var pending := 0
var _expected := {}
var _visited := {}
var _restart := false
var _deadline := 0
var _generation := 0
var _connected: Object

func capture(menu: Node, uri: String) -> void:
	cancel(); context = {}
	if menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty() and not menu.cloud_search.active:
		if not menu._cloud_entries.any(func(item): return item.get("uri", "") == uri): return
		context = {"type": "cloud", "path": menu._cloud_path(), "order": menu.file_actions.cloud_order(),
			"cloud_id": str(menu._cloud_stack.back().get("cloud_id", "")), "next": menu._cloud_next,
			"from_first": menu._cloud_page == 0, "location": Location.capture(menu, {})}
	elif menu.section == menu.Section.MEDIA_SERVER:
		var browser: RefCounted = menu.server_browser
		if browser.loaded_page <= 0 or browser.detail.get("parts", []).any(func(item): return item.get("uri", "") == uri): return
		context = {"type": "server", "server_id": str(browser.server.get("id", "")),
			"query": browser.query.duplicate(true), "next": browser.loaded_page + 1 if not browser.end_reached else -1,
			"from_first": true, "location": Location.capture(menu, {})}
	_connect_platform()

func _connect_platform() -> void:
	if _connected == platform: return
	if is_instance_valid(_connected) and _connected.has_signal("media_list") and _connected.is_connected("media_list", receive): _connected.disconnect("media_list", receive)
	_connected = platform
	if is_instance_valid(platform) and platform.has_signal("media_list"): platform.connect("media_list", receive)

func has_more() -> bool:
	return not context.is_empty() and int(context.get("next", -1)) >= 0

func needs_first_page() -> bool:
	return not context.is_empty() and not context.get("from_first", true)

func start(restart: bool = false) -> void:
	if pending > 0 or context.is_empty(): return
	_connect_platform(); _restart = restart; _visited.clear()
	_page((0 if context.type == "cloud" else 1) if restart else int(context.get("next", -1)))

func cancel() -> void:
	if pending > 0 and is_instance_valid(platform):
		if context.get("type") == "server" and Methods.supports(platform, "media_server_cancel"): platform.media_server_cancel(pending)
		elif Methods.supports(platform, "media_cloud_cancel"): platform.media_cloud_cancel(pending)
	pending = 0; _expected.clear(); _visited.clear(); _generation += 1

func _page(cursor: int) -> void:
	if cursor < 0 or _visited.has(cursor): _fail(); return
	_visited[cursor] = true
	if context.type == "cloud":
		_expected = {"path": context.path, "order": context.order, "offset": cursor}
		if Methods.supports(platform, "media_cloud_directory_page"):
			pending = int(platform.media_cloud_directory_page(context.path, cursor, false, context.order, context.cloud_id))
		elif Methods.supports(platform, "media_cloud_sorted_page"):
			pending = int(platform.media_cloud_sorted_page(context.path, cursor, false, context.order))
		elif Methods.supports(platform, "media_cloud_page"):
			pending = int(platform.media_cloud_page(context.path, cursor, false))
	else:
		_expected = context.query.duplicate(true)
		_expected.merge({"action": "browse", "server_id": context.server_id, "generation": _generation, "page": cursor}, true)
		if Methods.supports(platform, "media_server_request"): pending = int(platform.media_server_request(JSON.stringify(_expected)))
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
	if pending <= 0: _fail()

func receive(id: int, payload: String) -> void:
	if pending <= 0 or id != pending: return
	pending = 0
	var parsed: Variant = JSON.parse_string(payload)
	if not parsed is Dictionary or parsed.get("state") != "ready" or not parsed.get("entries") is Array: _fail(); return
	var data: Dictionary = parsed
	var next: int
	if context.type == "cloud":
		if str(data.get("path", "")) != str(_expected.path) or int(data.get("offset", -1)) != int(_expected.offset): _fail(); return
		if (Methods.supports(platform, "media_cloud_sorted_page") or Methods.supports(platform, "media_cloud_directory_page")) and str(data.get("order", "")) != str(_expected.order): _fail(); return
		next = int(data.get("next_offset", -1))
		if next >= 0 and next <= int(_expected.offset): _fail(); return
	else:
		if str(data.get("server_id", "")) != str(context.server_id) or int(data.get("generation", -1)) != _generation: _fail(); return
		next = int(_expected.page) + 1 if data.entries.size() >= 48 and int(_expected.page) * 48 < int(data.get("total", 0)) else -1
	context.next = next
	if _restart: context.from_first = true
	var items: Array[Dictionary] = []
	var seen := {}
	for raw in data.entries:
		if not raw is Dictionary: _fail(); return
		var uri := str(raw.get("uri", "")); var title := str(raw.get("title", ""))
		if uri.is_empty() or raw.get("container", false) or raw.get("folder", false) or raw.get("kind", "") in ["folder", "image", "audio"] or Images.is_image(uri, title) or Audio.supported(title): continue
		if seen.has(uri): continue
		seen[uri] = true
		var metadata: Dictionary = raw.duplicate(true)
		metadata.location = context.location.duplicate(true)
		if context.type == "server": metadata.location.item_id = str(raw.get("id", ""))
		items.append({"uri": uri, "title": title, "metadata": metadata})
	if items.is_empty() and next >= 0:
		_page(next); return
	completed.emit(items, _restart)

func _fail() -> void:
	cancel(); failed.emit("Unable to load next video")

func poll() -> void:
	if pending > 0 and Time.get_ticks_msec() >= _deadline: _fail()

func dispose() -> void:
	cancel()
	if is_instance_valid(_connected) and _connected.has_signal("media_list") and _connected.is_connected("media_list", receive): _connected.disconnect("media_list", receive)
