extends RefCounted
## One visible artwork surface. The menu owns the track and chooses when it may run.
var slot: Dictionary
var request := 0
var session := 0
var texture: ImageTexture
var finished := false
var _candidate := 0
var _candidates: Array
var _lookup_done := false
var _listing_request := false
var _token := 0
var _native_handle := 0
var _due: int

func _init(binding: Dictionary, due: int) -> void:
	slot = binding
	_candidates = binding.candidates.duplicate()
	_due = due

func _show(menu: Node, value: Texture2D, restoring: bool = false) -> void:
	if not is_instance_valid(slot.surface): return
	var material: Material = slot.surface.material_override
	if material is ShaderMaterial:
		var previous: Variant = material.get_shader_parameter("picture")
		if restoring and previous != texture: return
		if previous != value:
			material.set_shader_parameter("picture", value)
			var shader: Shader = slot.surface.get_meta("menu_original_shader", material.shader)
			if shader == preload("res://shaders/media_picture.gdshader"):
				material.set_shader_parameter("image_size", _fitted_size(value))
			elif shader == preload("res://shaders/menu_thumbnail.gdshader"):
				var size := _fitted_size(value)
				slot.surface.mesh.size = size
				material.set_shader_parameter("surface_size", size)
	elif material is BaseMaterial3D:
		if restoring and material.albedo_texture != texture: return
		if material.albedo_texture != value:
			material.albedo_texture = value
			slot.surface.mesh.size = _fitted_size(value)
	else: return
	menu.composition_nodes_changed.emit([slot.surface])

func _fitted_size(value: Texture2D) -> Vector2:
	if value == slot.poster: return slot.footprint
	var pixels := value.get_size()
	return pixels * minf(slot.footprint.x / pixels.x, slot.footprint.y / pixels.y)

func rebind(menu: Node, binding: Dictionary) -> void:
	if is_same(slot, binding): return
	if texture != null: _show(menu, slot.poster, true)
	slot = binding
	if texture != null: _show(menu, texture)

func close(menu: Node) -> void:
	if is_instance_valid(menu.platform):
		if request > 0: menu.platform.media_server_cancel(request)
		if session > 0: menu.platform.media_artwork_stop(session)
	if texture != null: _show(menu, slot.poster, true)
	request = 0
	session = 0
	texture = null

func tick(browser: RefCounted, stills: Dictionary, listings: Dictionary, now: int) -> void:
	if finished or request > 0 or now < _due: return
	var menu: Node = browser.menu
	if session == 0:
		while _candidate < _candidates.size():
			var candidate: Dictionary = _candidates[_candidate]
			if int(stills.get(candidate.key, 0)) <= now:
				var body: Dictionary = candidate.req.merged({"action": "cover_animation",
					"server_id": browser.server.id, "generation": browser.generation})
				request = menu.platform.media_server_request(JSON.stringify(body))
				if request <= 0: finished = true
				return
			_candidate += 1
		if not _lookup_done and not slot.lookup.is_empty():
			_lookup_done = true
			var cached: Dictionary = listings.get(slot.key, {})
			if int(cached.get("expires", 0)) > now:
				_candidates.append_array(cached.extra)
				tick(browser, stills, listings, now)
			else:
				_listing_request = true
				request = menu.platform.media_server_request(JSON.stringify({"action": "preview_backdrops",
					"scene_id": slot.lookup, "server_id": browser.server.id, "generation": browser.generation}))
				if request <= 0: finished = true
			return
		finished = true
		return
	_due = now + 33
	var raw: String = menu.platform.media_artwork_frame(session)
	var frame: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	if not frame is Dictionary or frame.get("failed", false):
		close(menu)
		_token = 0
		_native_handle = 0
		_candidate += 1
		# Try another original if this animation has a valid header but cannot decode.
		finished = _candidate >= _candidates.size() and (_lookup_done or slot.lookup.is_empty())
		return
	var token := int(frame.get("token", 0))
	if token > 0 and token != _token:
		var width := int(frame.width)
		var height := int(frame.height)
		if _native_handle == 0 or not menu.platform.media_artwork_upload(session, token, _native_handle):
			_native_handle = 0
			var pixels: PackedByteArray = menu.platform.media_artwork_pixels(session, token)
			if width <= 0 or height <= 0 or pixels.size() != width * height * 4: return
			var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
			if texture == null:
				texture = ImageTexture.create_from_image(image)
				if RenderingServer.get_current_rendering_method() == "gl_compatibility":
					_native_handle = RenderingServer.texture_get_native_handle(texture.get_rid())
			else: texture.update(image)
		_token = token
		_show(menu, texture)
	if frame.get("ended", false):
		menu.platform.media_artwork_stop(session)
		session = 0
		finished = true

func receive(browser: RefCounted, stills: Dictionary, listings: Dictionary, data: Variant, now: int) -> void:
	request = 0
	if not data is Dictionary or data.get("server_id") != browser.server.get("id") or data.get("generation") != browser.generation:
		finished = true
		return
	if _listing_request:
		_listing_request = false
		if data.get("state") != "ready":
			finished = true
			return
		var extra := []
		var known := {}
		for original in _candidates:
			if original.req.get("image_type") == "Backdrop" and original.req.scene_id == slot.lookup:
				known[original.req.image_index] = true
		for image in data.get("images", []):
			if image.get("id") != slot.lookup or image.get("image_type") != "Backdrop" or known.has(image.image_index): continue
			var req: Dictionary = browser._image_request({"cover_image": image})
			extra.append({"req": req, "key": browser._request_image_key(req)})
			known[req.image_index] = true
		if listings.size() >= 256: listings.erase(listings.keys()[0])
		listings[slot.key] = {"extra": extra, "expires": now + 300000}
		_candidates.append_array(extra)
		_due = now
		tick(browser, stills, listings, now)
		return
	if data.get("state") != "ready":
		if data.get("error") in ["Server authentication required", "Server unavailable", "Request cancelled"]:
			finished = true
			return
		# A missing original can have a usable sibling; never cache a network failure as a still.
		_candidate += 1
	else:
		var path := str(data.get("path", ""))
		if not path.is_empty():
			session = browser.menu.platform.media_artwork_start(path, slot.edge)
			if session > 0:
				_due = now
				return
		else:
			if stills.size() >= 512: stills.erase(stills.keys()[0])
			stills[_candidates[_candidate].key] = now + 300000
		_candidate += 1
	_due = now
	tick(browser, stills, listings, now)
