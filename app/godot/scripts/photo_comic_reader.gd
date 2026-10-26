extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Dwell := preload("res://scripts/photo_comic_dwell.gd")
var dwell := Dwell.new()
const Settings := preload("res://scripts/comic_reading_settings.gd")
var preferences := Settings.new()
var speech_state := "idle"
var ready_audio := 0
var latency := {}
var read_requests := 0
var _configured := ""
var _geometry_key := ""
var photo: Node3D
var enabled := false
var epoch := 0
var revision := -1
var state := "off"
var pages := []
var rects := [Rect2(0, 0, 1, 1)]
var worker: Thread
var pending := {}
var poll_at := 0
var blocked := true
var voice_key := ""
var marker: MeshInstance3D
var ink: StandardMaterial3D
var guide: MeshInstance3D
var _guide_key := ""
var _ahead_key := ""
var _ready_at := -1
var translation: RefCounted
var _speech_enabled: Variant = null
var _speech_mode := ""
var _speech_payload := ""
var _speech_ready := {}
var _speech_sync_at := 0

func _init(owner: Node3D) -> void:
	photo = owner
	translation = preload("res://scripts/comic_translation.gd").new(owner)

func active() -> bool: return enabled or translation.enabled

func refresh_mode() -> void:
	configure()
	if not active(): clear(); return
	if pages.is_empty() and pending.is_empty() and state in ["off", "idle", "unavailable"]:
		if not photo._display_result.is_empty(): accept(photo._display_result)
		else: photo.magazine.reload()

func supported() -> bool:
	return Methods.supports(photo.platform, "comic_reader_begin") and photo.platform.narration_supported()

func set_enabled(value: bool) -> void:
	enabled = value and supported()
	preferences.enabled = enabled
	if not enabled: stop()
	refresh_mode()

func configure() -> void:
	if not supported(): return
	var mode := str([translation.target, translation.source, translation.generation]) if translation.enabled else "original"
	if mode != _speech_mode:
		stop(); _speech_ready.clear(); _speech_payload = ""; _speech_sync_at = 0
		if Methods.supports(photo.platform, "comic_reader_translation_mode"):
			if photo.platform.comic_reader_translation_mode(mode, translation.speech_language() if translation.enabled else ""):
				_speech_mode = mode
		elif not translation.enabled: _speech_mode = mode
	if _speech_enabled != enabled and Methods.supports(photo.platform, "comic_reader_speech_enabled"):
		photo.platform.comic_reader_speech_enabled(enabled); _speech_enabled = enabled
	var selected := preferences.selected_voice()
	var language: String = translation.speech_language() if translation.enabled else preferences.language
	var identity := selected + "/" + language
	if identity == _configured: return
	if photo.platform.comic_reader_configure(selected, language):
		_configured = identity
		_ahead_key = ""

func preview() -> void:
	if not supported(): return
	configure()
	photo.platform.comic_reader_preview(preferences.selected_voice(), translation.speech_language() if translation.enabled else preferences.language, preferences.volume / 100.0)

func sync_speech(now: int) -> void:
	if not translation.enabled or now < _speech_sync_at: return
	_speech_sync_at = now + 100
	if not Methods.supports(photo.platform, "comic_reader_translations"): return
	var rows: Array = translation.speech_rows(pages, epoch)
	var payload := JSON.stringify(rows)
	if payload == _speech_payload: return
	if photo.platform.comic_reader_translations(epoch, _speech_mode, payload):
		_speech_payload = payload; _speech_ready.clear()
		for row: Dictionary in rows: _speech_ready[str(row.page) + ":" + str(row.id)] = true

func stop() -> void:
	dwell.reset()
	speech_state = "idle"
	if marker: marker.visible = false
	if Methods.supports(photo.platform, "comic_reader_stop"): photo.platform.comic_reader_stop()

func clear(release_models: bool = false) -> void:
	epoch += 1; revision = -1; pages = []; pending = {}; state = "idle" if active() else "off"
	translation.reset(release_models or not translation.enabled)
	_speech_payload = ""; _speech_ready.clear(); _speech_sync_at = 0
	_ahead_key = ""
	_ready_at = -1
	stop()
	if guide: guide.visible = false
	if (release_models or not active()) and Methods.supports(photo.platform, "comic_reader_release"): photo.platform.comic_reader_release()
	elif Methods.supports(photo.platform, "comic_reader_clear"): photo.platform.comic_reader_clear()
	if active() and not release_models and Methods.supports(photo.platform, "comic_reader_warm"): photo.platform.comic_reader_warm()

func accept(result: Dictionary) -> void:
	clear()
	if not active(): return
	if not supported(): state = "unavailable"; return
	if photo.geometry != 0 or photo.stereo_sbs: state = "unsupported"; return
	# OCR always reads the original decoded image; starting it must not change 2D/3D mode.
	configure()
	if not photo.platform.comic_reader_begin(epoch): state = "unavailable"; return
	rects = result.get("comic_rects", [Rect2(0, 0, 1, 1)])
	pending = {"image": result.image, "rects": rects.duplicate(), "epoch": epoch}
	state = "recognizing"

static func prepare(job: Dictionary) -> Dictionary:
	var source: Image = job.image
	var output := []
	for rect: Rect2 in job.rects:
		var left := roundi(rect.position.x * source.get_width())
		var right := roundi(rect.end.x * source.get_width())
		var page := source.get_region(Rect2i(left, 0, right - left, source.get_height()))
		page.clear_mipmaps()
		var ratio := minf(1.0, 1600.0 / maxf(page.get_width(), page.get_height()))
		page.resize(maxi(16, roundi(page.get_width() * ratio)), maxi(16, roundi(page.get_height() * ratio)), Image.INTERPOLATE_BILINEAR)
		page.convert(Image.FORMAT_RGB8)
		output.append({"width": page.get_width(), "height": page.get_height(), "rgb": page.get_data()})
	return {"epoch": job.epoch, "pages": output, "ahead": job.get("ahead", false), "key": job.get("key", "")}

func poll(now: int) -> void:
	if worker and not worker.is_alive():
		var result: Dictionary = worker.wait_to_finish(); worker = null
		if active() and int(result.epoch) == epoch:
			for index in result.pages.size():
				var page: Dictionary = result.pages[index]
				if result.get("ahead", false):
					if str(result.key) == _ahead_key: photo.platform.comic_reader_ahead(epoch, index, page.width, page.height, page.rgb)
				elif not photo.platform.comic_reader_page(epoch, index, page.width, page.height, page.rgb): state = "unavailable"
	if not worker and not pending.is_empty():
		var job := pending; pending = {}; worker = Thread.new()
		if worker.start(prepare.bind(job)) != OK: worker = null; state = "unavailable"
	if not supported() or now < poll_at: return
	poll_at = now + 100
	var result: Variant = JSON.parse_string(photo.platform.comic_reader_status(epoch, revision))
	if not result is Dictionary: return
	speech_state = str(result.get("speech", "idle")); ready_audio = int(result.get("ready_audio", 0))
	latency = {"first_audio_ms": result.get("first_audio_ms", -1), "hover_audio_ms": result.get("hover_audio_ms", -1), "warm_hit": result.get("warm_hit", false)}
	if int(result.get("epoch", -1)) != epoch: return
	revision = int(result.get("revision", revision)); state = str(result.get("state", state))
	if result.has("pages"):
		pages = result.pages
		translation.observe(pages, rects, epoch)
	if state == "ready" and not pages.any(func(page): return page.get("blocks", []).any(func(block): return block.get("eligible", false))): state = "no_dialogue"
	if result.get("speech") == "error": state = "speech_error"
	prefetch_next()

func prefetch_next(now: int = -1) -> void:
	# Reuse the existing decoded neighbour window (including its spread geometry).
	# Never fetch files independently or compete with foreground image preparation.
	if not active() or worker or not pending.is_empty() or state not in ["ready", "no_dialogue"]: return
	if not Methods.supports(photo.platform, "comic_reader_ahead"): return
	if photo.loading or photo.geometry != 0 or photo.stereo_sbs or photo.index < 0: return
	if now < 0: now = Time.get_ticks_msec()
	if _ready_at < 0: _ready_at = now
	# Give foreground synthesis a head start, but a failed/long bubble must not
	# prevent neighbour OCR forever. Audio jobs themselves retain foreground order.
	if enabled and ready_audio == 0 and readable_count() > 0 and now - _ready_at < 1500: return
	if speech_state in ["preparing", "speaking"]: return
	var target: int = photo.magazine.target_from(photo.index, photo._navigation_direction) if photo.magazine.active() else photo.index + photo._navigation_direction
	var entry: Dictionary = photo._prefetched.get(target, {})
	if not entry.get("decoded", false) or not photo.reading_render.complete(entry): return
	var result: Dictionary = entry.get("result", {})
	var source: Image = result.get("image")
	if source == null: return
	var regions: Array = result.get("comic_rects", [Rect2(0, 0, 1, 1)])
	var key := str([source.get_instance_id(), regions, target])
	if key == _ahead_key: return
	_ahead_key = key
	pending = {"image": source, "rects": regions.duplicate(), "epoch": epoch, "ahead": true, "key": key}

static func hit(pages_data: Array, regions: Array, uv: Vector2) -> Dictionary:
	var matches := []
	var fallback_matches := []
	for page: Dictionary in pages_data:
		var index := int(page.get("page", -1))
		if index < 0 or index >= regions.size(): continue
		var region: Rect2 = regions[index]
		if not region.has_point(uv): continue
		var size: Array = page.get("page_size", [])
		if size.size() != 2: continue
		var point := (uv - region.position) / region.size * Vector2(size[0], size[1])
		for block: Dictionary in page.get("blocks", []):
			if not block.get("eligible", false): continue
			var bounds: Array = block.hit_rect
			var box := Rect2(bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1])
			if not box.has_point(point): continue
			var row := int(floor(point.y)) - int(bounds[1])
			var spans: Array = block.get("hit_rows", [])
			var debug_rect: bool = OS.is_debug_build() and block.get("verified", true) == false and spans.is_empty()
			if not debug_rect and (row < 0 or row >= spans.size() or point.x < spans[row][0] or point.x >= spans[row][1]): continue
			var target := {"key": "%d:%d" % [index, block.id], "page": index, "id": int(block.id),
				"rect": Rect2(region.position + box.position / Vector2(size[0], size[1]) * region.size, box.size / Vector2(size[0], size[1]) * region.size)}
			# Debug text rectangles can overlap a complete balloon. Prefer its
			# verified contour, while genuine contour conflicts still select none.
			if block.get("geometry_verified", block.get("verified", true)): matches.append(target)
			else: fallback_matches.append(target)
	if matches.is_empty(): matches = fallback_matches
	return matches[0] if matches.size() == 1 else {}

func tick(rays: Array, allowed: bool, voice: String, volume: float, active_view: bool = true) -> void:
	var now := Time.get_ticks_msec()
	configure() if active() else null
	poll(now)
	if translation.enabled and (translation.epoch != epoch or translation._signature.is_empty()): translation.observe(pages, rects, epoch)
	translation.tick(active_view and not photo.loading and photo.panel.visible and photo.geometry == 0 and not photo.stereo_sbs \
		and not photo.spatial_requested and not photo.portrait_requested and photo.gallery.mode in [0, 4])
	if active(): configure(); sync_speech(now)
	# Translation-only reading: reveal the original under a ray without triggering speech.
	var peek_points := []
	if translation.enabled and not enabled and allowed and active_view and not photo.inspect:
		for ray: Variant in rays:
			if ray != null: peek_points.append(photo._inspect_uv(ray[0], ray[1]))
	translation.overlay.peek(peek_points)
	var key := voice + "/" + str(volume)
	var inactive: bool = not enabled or not allowed or voice.is_empty() or volume <= 0 or photo.loading or photo.inspect or photo.geometry != 0 or photo.stereo_sbs \
		or photo.spatial_requested or photo.portrait_requested or not photo.gallery.mode in [0, 4] \
		or not photo.panel.visible or photo._transition_active or photo._reveal_seconds > 0
	if key != voice_key: stop(); voice_key = key
	if inactive:
		if guide: guide.visible = false
		if not blocked: stop()
		blocked = true; return
	blocked = false
	if OS.is_debug_build(): draw_guides()
	var selected := {}
	for ray: Variant in rays:
		if ray == null: continue
		selected = hit(pages, rects, photo._inspect_uv(ray[0], ray[1]))
		if not selected.is_empty(): break
	# Do not consume the dwell while a translation is pending; re-arm when it arrives.
	if translation.enabled and not selected.is_empty() and not _speech_ready.has(selected.key):
		if not dwell.target.is_empty(): stop()
		draw_marker(selected.rect, 0.0)
		return
	var fire := dwell.update(str(selected.get("key", "")), now)
	if dwell.switched:
		photo.platform.comic_reader_stop()
		photo.platform.comic_reader_prepare(epoch, selected.page, selected.id)
	if marker: marker.visible = not selected.is_empty()
	if selected.is_empty(): return
	draw_marker(selected.rect, dwell.progress)
	if fire:
		read_requests += 1
		photo.platform.comic_reader_read(epoch, selected.page, selected.id, voice, volume)

func position(uv: Vector2) -> Vector3:
	var x: float = (uv.x - 0.5) * photo._flat.size.x
	var y: float = (0.5 - uv.y) * photo._flat.size.y
	if photo.screen_curve <= 0: return Vector3(x, y, 0.004)
	var radius: float = photo._curve_radius()
	return Vector3(sin(x / radius) * radius, y, radius * (1.0 - cos(x / radius)) + 0.004)

func readable_count() -> int:
	var count := 0
	for page: Dictionary in pages:
		for block: Dictionary in page.get("blocks", []):
			if block.get("eligible", false): count += 1
	return count

func candidate_count() -> int:
	var count := 0
	for page: Dictionary in pages: count += page.get("blocks", []).size()
	return count

func draw_guides() -> void:
	# Debug testers can see the regions that are actually safe to point at.
	# Geometry is rebuilt only for a changed page/projection, not on each frame.
	var key := str([epoch, readable_count(), photo._flat.size, photo.screen_curve])
	if key == _guide_key:
		if guide: guide.visible = readable_count() > 0
		return
	_guide_key = key
	if readable_count() == 0:
		if guide: guide.visible = false
		return
	if not guide:
		guide = MeshInstance3D.new(); photo.panel.add_child(guide)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true; material.render_priority = 28
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(0.4, 0.8, 1.0, 0.55); guide.material_override = material
	var mesh := ImmediateMesh.new(); mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for page: Dictionary in pages:
		var index := int(page.get("page", -1)); var size: Array = page.get("page_size", [])
		if index < 0 or index >= rects.size() or size.size() != 2: continue
		for block: Dictionary in page.get("blocks", []):
			if not block.get("eligible", false): continue
			var b: Array = block.hit_rect; var region: Rect2 = rects[index]
			var scale := Vector2(size[0], size[1])
			var rect := Rect2(region.position + Vector2(b[0], b[1]) / scale * region.size, Vector2(b[2] - b[0], b[3] - b[1]) / scale * region.size)
			var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y), rect.position]
			for edge in 4:
				for step in 8:
					mesh.surface_add_vertex(position(corners[edge].lerp(corners[edge + 1], step / 8.0)))
					mesh.surface_add_vertex(position(corners[edge].lerp(corners[edge + 1], (step + 1) / 8.0)))
	mesh.surface_end(); guide.mesh = mesh; guide.visible = true

func draw_marker(rect: Rect2, progress: float) -> void:
	if not marker:
		marker = MeshInstance3D.new(); photo.panel.add_child(marker)
		ink = StandardMaterial3D.new(); ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ink.no_depth_test = true; ink.render_priority = 30; marker.material_override = ink
	ink.albedo_color = Color(0.25, 1.0, 0.7) if progress >= 1 else Color(0.4, 0.8, 1.0)
	var geometry_key := str(rect) + str(photo._flat.size) + str(photo.screen_curve) + str(roundi(progress * 20))
	if geometry_key == _geometry_key: marker.visible = true; return
	_geometry_key = geometry_key
	var mesh := ImmediateMesh.new(); mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y), rect.position]
	for edge in 4:
		for step in 8:
			mesh.surface_add_vertex(position(corners[edge].lerp(corners[edge + 1], step / 8.0)))
			mesh.surface_add_vertex(position(corners[edge].lerp(corners[edge + 1], (step + 1) / 8.0)))
	# A second short line grows along the top edge while dwelling.
	mesh.surface_add_vertex(position(rect.position - Vector2(0, 0.006)))
	mesh.surface_add_vertex(position(rect.position + Vector2(rect.size.x * progress, -0.006)))
	mesh.surface_end(); marker.mesh = mesh; marker.visible = true

func end_batch() -> void:
	# Page/layout reloads use clear(); only closing/replacing the album resets switches.
	enabled = false
	preferences.enabled = false
	translation.enabled = false
	clear(true)
	_speech_enabled = null
	_speech_mode = ""

func close() -> void:
	end_batch()
	translation.close()
	if worker: worker.wait_to_finish(); worker = null
