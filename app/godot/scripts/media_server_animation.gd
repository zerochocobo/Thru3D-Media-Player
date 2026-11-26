extends RefCounted

const Methods := preload("res://scripts/platform_methods.gd")
const DWELL_MS := 250
const POLL_MS := 33
var _owner: WeakRef
var focus := {}
var autoplay := {} # The visible backdrop or the open picture, rebuilt with the menu.
var active := {}
var foreground := true
var _checked := {} # Recently confirmed stills. Keys include server, item and image tag.
var _due := 0
var _request := 0
var _session := 0
var _token := 0
var _texture: ImageTexture
var _native_handle := 0
var _rebind_until := 0

func _init(browser: RefCounted) -> void:
	_owner = weakref(browser)

func binding(node: Dictionary, surface: MeshInstance3D, poster: Texture2D) -> Dictionary:
	var browser = _owner.get_ref()
	var req: Dictionary = browser._image_request(node)
	if str(req.scene_id).is_empty(): return {}
	# These providers return the same original at every poster size. Share its
	# probe and disk cache when opening a thumbnail in the picture viewer.
	if req.has("max_width") and browser.server.get("provider") in ["emby", "jellyfin"]:
		req.max_width = 512
	var edge := 640 if browser.view in ["detail", "metadata", "picture"] else 512
	return {"key": browser._request_image_key(req), "req": req, "surface": surface, "poster": poster,
		"edge": edge, "material_id": surface.material_override.get_instance_id()}

func _show(slot: Dictionary, value: Texture2D, restoring: bool = false) -> void:
	if slot.is_empty() or not is_instance_valid(slot.surface): return
	var material: Material = slot.surface.material_override
	if material is ShaderMaterial:
		if restoring and material.get_shader_parameter("picture") != _texture: return
		if material.get_shader_parameter("picture") != value:
			material.set_shader_parameter("picture", value)
	elif material is BaseMaterial3D:
		if restoring and material.albedo_texture != _texture: return
		if material.albedo_texture != value: material.albedo_texture = value
	else: return
	_owner.get_ref().menu.composition_nodes_changed.emit([slot.surface])

func stop() -> void:
	# Untyped: a platform freed first (teardown) must reach the validity checks below, not fail on assignment.
	var platform: Variant = _owner.get_ref().menu.platform
	if _request > 0 and is_instance_valid(platform): platform.media_server_cancel(_request)
	if _session > 0 and is_instance_valid(platform): platform.media_artwork_stop(_session)
	if _texture != null and not active.is_empty(): _show(active, active.poster, true)
	_request = 0
	_session = 0
	_texture = null
	_native_handle = 0
	_token = 0
	_due = 0
	_rebind_until = 0
	active = {}

func clear() -> void:
	stop()
	focus = {}
	autoplay = {}

func clear_cache() -> void:
	clear()
	_checked.clear()

func tick(now: int) -> void:
	if focus.is_empty() and autoplay.is_empty() and active.is_empty(): return
	var browser = _owner.get_ref()
	var menu: Node = browser.menu
	var wanted: Dictionary = autoplay if browser.view == "picture" or focus.is_empty() else focus
	if not foreground or not menu.is_visible_in_tree() or menu.section != menu.Section.MEDIA_SERVER \
		or menu.release_notes.opened or menu.archives.browsing or browser.settings_open \
		or not browser.keyboard.is_empty() or not browser.detail_actions.is_empty() or browser.sorting() \
		or not browser.gallery.capture.is_empty() or absf(menu._fling) > 0.4:
		if not active.is_empty(): stop()
		return
	# Rebuilding buttons clears both rays for a frame. Wait for the replacement
	# card before switching back to the backdrop or closing its decoder.
	if focus.is_empty() and browser.view != "picture" and not active.is_empty() and not is_instance_valid(active.surface):
		if _rebind_until == 0: _rebind_until = now + 40
		if now < _rebind_until: return
	if wanted.is_empty() or not is_instance_valid(wanted.surface) or not wanted.surface.is_visible_in_tree():
		if not active.is_empty(): stop()
		return
	_rebind_until = 0
	if active.get("key") != wanted.key or active.edge != wanted.edge:
		stop()
		active = wanted
		_due = now if browser.view == "picture" else now + DWELL_MS
	elif active != wanted:
		if _texture != null: _show(active, active.poster, true)
		active = wanted
		if _texture != null: _show(active, _texture)
	if _due == 0 or now < _due: return
	if _session == 0:
		_due = 0
		if int(_checked.get(active.key, 0)) > now or not Methods.supports(menu.platform, "media_artwork_start"): return
		var body: Dictionary = active.req.duplicate()
		body.merge({"action": "cover_animation", "server_id": browser.server.id, "generation": browser.generation})
		_request = menu.platform.media_server_request(JSON.stringify(body))
		return
	_due = maxi(_due + POLL_MS, now + 1)
	var raw: String = menu.platform.media_artwork_frame(_session)
	var frame: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if frame == null or frame.get("failed", false):
		var slot := active
		stop()
		active = slot # Keep its ordinary poster until focus changes.
		return
	var token := int(frame.get("token", 0))
	if token > 0 and token != _token:
		var width := int(frame.width)
		var height := int(frame.height)
		if _native_handle == 0 or not menu.platform.media_artwork_upload(_session, token, _native_handle):
			_native_handle = 0
			var pixels: PackedByteArray = menu.platform.media_artwork_pixels(_session, token)
			if width <= 0 or height <= 0 or pixels.size() != width * height * 4: return
			var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
			if _texture == null:
				_texture = ImageTexture.create_from_image(image)
				if RenderingServer.get_current_rendering_method() == "gl_compatibility":
					_native_handle = RenderingServer.texture_get_native_handle(_texture.get_rid())
			else: _texture.update(image)
		_token = token
		_show(active, _texture)
	if frame.get("ended", false):
		menu.platform.media_artwork_stop(_session)
		_session = 0
		_due = 0

func receive(id: int, payload: String) -> bool:
	if id <= 0 or id != _request: return false
	_request = 0
	var browser = _owner.get_ref()
	var requested_key: String = active.key
	var requested_edge: int = active.edge
	# A response can arrive between the pointer/visibility change and the next UI tick.
	tick(Time.get_ticks_msec())
	var data: Variant = JSON.parse_string(payload)
	if active.get("key") != requested_key or active.edge != requested_edge or not data is Dictionary or data.get("state") != "ready" \
		or data.get("server_id") != browser.server.get("id") or data.get("generation") != browser.generation: return true
	var path := str(data.get("path", ""))
	if path.is_empty():
		if _checked.size() >= 256: _checked.erase(_checked.keys()[0])
		_checked[active.key] = Time.get_ticks_msec() + 300000
	else:
		_session = browser.menu.platform.media_artwork_start(path, active.edge)
		if _session > 0: _due = Time.get_ticks_msec()
	return true
