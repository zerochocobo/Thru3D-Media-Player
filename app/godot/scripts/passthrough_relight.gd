# Originally contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
# The halo, room colour, smoothing and floor shadow were rewritten for 0.18.1.1.
extends Node
## Video-driven lighting over passthrough for the flat player (regular and 3D videos):
##  1. Passthrough relight: the real room is tinted and dimmed by the picture's colour
##     (Meta XR_META_passthrough_color_lut through the Godot OpenXR Vendors plugin).
##  2. Screen halo: picture-edge colours glow around the screen (passthrough_relight_glow).
##  3. Floor contact shadow under the screen (passthrough_relight_floor).
## The maths is in passthrough_relight_model.gd.
##
## Sampling follows CinemaFilmLight: compositor-layer playback PixelCopies the layer's last
## buffer into a tiny bitmap; eye-buffer playback draws the bound frame into a small viewport.

const Model := preload("res://scripts/passthrough_relight_model.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const GLOW_SHADER := preload("res://shaders/passthrough_relight_glow.gdshader")
const FLOOR_SHADER := preload("res://shaders/passthrough_relight_floor.gdshader")

const LAYER_INTERVAL_MS := 80
const EYE_BUFFER_INTERVAL_MS := 250
## Glow plane offset along the screen normal: just behind a video panel, and behind the browser
## window's frame for a page (its layout pose sits 12 mm in front of the window), so opaque
## window parts occlude the halo. The halo is also drawn first among transparent surfaces.
const VIDEO_GLOW_Z := -0.002
const BROWSER_GLOW_Z := -0.015
## The edge dissolve lies on the picture and must be drawn after the hole that clears the eye
## buffer for the compositor layer: the video's hole has priority -128, the browser page's 25.
const EDGE_Z := 0.001
const SCENERY_DIMMING := 0.35
const VIDEO_EDGE_PRIORITY := -126
const BROWSER_EDGE_PRIORITY := 26
const BROWSER_INTERVAL_MS := 100
## Re-create the passthrough LUT at most this often, and only for a visible change.
const LUT_INTERVAL_MS := 100
const LUT_EPSILON := 1.5 / 255.0
const LUT_RESOLUTION := 16
## Floor shadow: its darkness, its depth in metres and its length as a share of the screen's
## width. It is full while the screen stands within FLOOR_NEAR of the floor (fading in over
## FLOOR_CONTACT so a screen on the floor has none), and thins to FLOOR_HIGH_SHARE by FLOOR_FAR.
const FLOOR_OPACITY := 0.13
const FLOOR_DEPTH := 0.2
const FLOOR_LENGTH := 0.65
const FLOOR_CONTACT := 0.1
const FLOOR_NEAR := 0.5
const FLOOR_FAR := 1.5
const FLOOR_HIGH_SHARE := 0.3
## The halo and shadow appear and leave over this long.
const FADE_DURATION := 0.2

var enabled := false
## Halo spread, 0 (a tight ring) to 1 (the whole room).
var reach := Model.DEFAULT_REACH
var brightness := Model.DEFAULT_BRIGHTNESS
## The picture's outer band dissolves into the halo, leaving no border between them, at the cost
## of the band itself: the glow covers it. Off, the halo stays behind a hard-edged picture.
var soft_edge := false
var samples := 0
var failures := 0
var path := ""
var lut_supported := false
## False over a panorama or an imported scene: there is no camera picture to tint.
var tint_room := true
## Outer size of the halo frame, in metres.
var glow_size := Vector2.ZERO
## Debug A/B of each part's frame cost.
var debug_parts := {"sample": true, "glow": true, "edge": true, "floor": true}
## Debug A/B of the halo's output: "encode" (bool) and "dimming" (0..1) replace the values in use.
var debug_look := {}
var lut_updates := 0

## Smoothed passthrough colour scale (white = untouched room).
var scale := Color.WHITE
var _latest := Color.WHITE
var _has_frame := false
var _bar_target := PackedVector3Array()
var _bar := PackedVector3Array()
var _visibility := 0.0

var _busy := false
var _next_ms := 0
var _last_pts := -1
var _generation := 0
var _source := 0
var _page_sampler: Object

var _passthrough: Object
## RefCounted in OpenXR Vendors 5, a Resource in earlier releases.
var _lut: RefCounted
var _lut_scale := Color.WHITE
var _lut_next_ms := 0
var _lut_active := false
var _lut_busy := false
var _lut_allowed := false

var _glow: MeshInstance3D
var _glow_material: ShaderMaterial
## The picture's edge dissolve (shader part 1): a quad of the picture's own size.
var _edge: MeshInstance3D
var _edge_material: ShaderMaterial
var _floor: MeshInstance3D
var _floor_material: ShaderMaterial


func _init() -> void:
	_bar_target.resize(Model.BAR_SIZE)
	_bar.resize(Model.BAR_SIZE)


func _ready() -> void:
	if Engine.has_singleton("OpenXRFbPassthroughExtension") and ClassDB.class_exists("OpenXRMetaPassthroughColorLut"):
		_passthrough = Engine.get_singleton("OpenXRFbPassthroughExtension")
		lut_supported = _passthrough.has_method("get_max_color_lut_resolution") \
			and bool(_passthrough.has_color_passthrough_capability()) and int(_passthrough.get_max_color_lut_resolution()) >= LUT_RESOLUTION


func set_enabled(value: bool) -> void:
	if enabled == value: return
	enabled = value
	_generation += 1
	_last_pts = -1; _next_ms = 0


func set_look(new_reach: float, new_brightness: float) -> void:
	reach = clampf(new_reach, 0.0, 1.0)
	brightness = clampf(new_brightness, 0.0, 1.0)


## Per frame. `active`: passthrough visible behind a flat video that is open.
func update(delta: float, video: Node, active: bool, floor_y: float) -> void:
	var showing: bool = enabled and active and video != null and video.media.state in ["playing", "paused", "ended"] \
		and not video.media.last_pair.is_empty()
	_use_source(video)
	if showing and not _busy and debug_parts.sample and Time.get_ticks_msec() >= _next_ms:
		_sample(video)
	var frame := {}
	var panel: MeshInstance3D = video.panel if video != null and "panel" in video else null
	if panel != null and is_instance_valid(panel):
		frame = {"transform": panel.global_transform, "size": video._flat.size,
			"flat": float(video.screen_curve) <= 0.0, "glow_z": VIDEO_GLOW_Z,
			"edge_priority": VIDEO_EDGE_PRIORITY}
	_step(delta, showing, active, frame, floor_y)


## Per frame for a web browser window (normal or focus-selected region, 2D or 3D): the page
## shown on its compositor layer lights the room the same way a video does.
func update_browser(delta: float, window: Node, active: bool, floor_y: float) -> void:
	var valid := window != null and is_instance_valid(window)
	_use_source(window if valid else null)
	var frame := {}
	var showing := false
	if valid:
		var page: Node = window.surface
		showing = enabled and active and page != null and page.hole != null and page.hole.visible and page.layer != null
		var layout: Dictionary = window.page_layout()
		# A page is read to its border, so it keeps a hard edge.
		frame = {"transform": layout.pose, "size": layout.size, "flat": true, "glow_z": BROWSER_GLOW_Z,
			"edge_priority": BROWSER_EDGE_PRIORITY, "edge": false}
		if showing and not _busy and debug_parts.sample and Time.get_ticks_msec() >= _next_ms:
			_sample_browser(window)
	_step(delta, showing, active, frame, floor_y)


func _use_source(source: Object) -> void:
	var id := source.get_instance_id() if source != null else 0
	if id == _source: return
	_source = id
	_generation += 1
	_last_pts = -1; _next_ms = 0


func _step(delta: float, showing: bool, active: bool, frame: Dictionary, floor_y: float) -> void:
	# Nothing shown and nothing left to fade: idle frames stay free while the light is on.
	if not showing and _visibility <= 0.0 and not _lut_active and not _lut_busy and scale.is_equal_approx(Color.WHITE):
		_has_frame = false
		return
	# The room returns to white whenever no video is showing.
	if showing and _has_frame:
		scale = scale.lerp(Model.color_scale(_latest), Model.ease_weight(Model.ROOM_FOLLOW, delta))
	else:
		scale = scale.lerp(Color.WHITE, Model.ease_weight(Model.ROOM_RETURN, delta))
		if not showing: _has_frame = false
	# Samples arrive a few times a second; the easing hides their steps without delaying cuts.
	var follow := Model.ease_weight(Model.HALO_FOLLOW, delta)
	for i in Model.BAR_SIZE:
		var target: Vector3 = _bar_target[i] if showing and _has_frame else Vector3.ZERO
		_bar[i] = _bar[i].lerp(target, follow)
	var fade_step := maxf(delta, 0.0) / FADE_DURATION
	_visibility = clampf(_visibility + (fade_step if showing and _has_frame else -fade_step), 0.0, 1.0)
	_apply_passthrough(active and enabled and tint_room)
	_place(frame, floor_y)


func snapshot() -> Dictionary:
	return {"enabled": enabled, "samples": samples, "failures": failures, "path": path, "lut_supported": lut_supported,
		"lut_updates": lut_updates, "reach": reach, "brightness": brightness,
		"scale": [snappedf(scale.r, .001), snappedf(scale.g, .001), snappedf(scale.b, .001)]}


func release() -> void:
	set_enabled(false)
	scale = Color.WHITE
	_apply_passthrough(false)
	for node in [_glow, _edge, _floor]:
		if node: node.queue_free()
	_glow = null; _edge = null; _floor = null


func _exit_tree() -> void:
	if _lut_active and _passthrough: _passthrough.set_passthrough_filter(0)
	_lut_active = false


# ---- passthrough colour scale -------------------------------------------------------

func _apply_passthrough(allowed: bool) -> void:
	if not lut_supported or _passthrough == null: return
	_lut_allowed = allowed
	var tint := Model.room_tint(scale, brightness)
	var neutral := absf(tint.r - 1.0) < LUT_EPSILON and absf(tint.g - 1.0) < LUT_EPSILON and absf(tint.b - 1.0) < LUT_EPSILON
	if not allowed or (neutral and not enabled):
		if _lut_active:
			_passthrough.set_passthrough_filter(0) # PASSTHROUGH_FILTER_DISABLED
			_lut_active = false
			_lut = null
			_lut_scale = Color.WHITE
		return
	var now := Time.get_ticks_msec()
	if _lut_busy or now < _lut_next_ms: return
	var change := maxf(absf(tint.r - _lut_scale.r), maxf(absf(tint.g - _lut_scale.g), absf(tint.b - _lut_scale.b)))
	if _lut_active and change < LUT_EPSILON: return
	_lut_next_ms = now + LUT_INTERVAL_MS
	_refresh_lut(tint)


## The table is 4096 entries of script, built on a worker; only the hand-over runs here.
func _refresh_lut(tint: Color) -> void:
	_lut_busy = true
	var built: Array[Image] = []
	var task := WorkerThreadPool.add_task(func() -> void: built.append(Model.scale_lut_image(tint, LUT_RESOLUTION)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	_lut_busy = false
	if not _lut_allowed or built.is_empty(): return
	var lut: RefCounted = ClassDB.class_call_static("OpenXRMetaPassthroughColorLut", "create_from_image", built[0], 3)
	if lut == null: return
	# Set the new table before the old one is released: freeing a LUT still in use makes
	# the plugin disable the filter (both run in order on the render thread).
	_passthrough.set_color_lut(1.0, lut)
	_lut = lut
	_lut_scale = tint
	_lut_active = true
	lut_updates += 1


# ---- halo and floor shadow -----------------------------------------------------------

func _place(frame: Dictionary, floor_y: float) -> void:
	if _visibility <= 0.001 or frame.is_empty():
		if _glow: _glow.visible = false
		if _edge: _edge.visible = false
		if _floor: _floor.visible = false
		return
	var xform: Transform3D = frame.transform
	var size: Vector2 = frame.size
	var unit := size.y
	_ensure_nodes()
	# A curved screen does not have the flat rectangle the halo is shaped around.
	var flat := bool(frame.flat)
	_glow.visible = flat and debug_parts.glow
	_edge.visible = flat and soft_edge and bool(frame.get("edge", true)) and debug_parts.edge
	if flat:
		var margin := Model.halo_margin(reach)
		var profile := Model.halo_profile(reach)
		glow_size = size + Vector2.ONE * margin * 2.0 * unit
		# Neither part covers the picture's interior. The halo is a grid shaded per vertex.
		var outline := [size, margin * unit]
		if _glow.mesh == null or _glow.get_meta("outline", []) != outline:
			_glow.set_meta("outline", outline)
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, Model.halo_arrays(size, margin * unit, unit))
			_glow.mesh = mesh
		_glow.global_transform = xform * Transform3D(Basis.IDENTITY, Vector3(0, 0, float(frame.glow_z)))
		_set_frame(_edge, size, (size - Vector2.ONE * Model.EDGE_BAND * 2.0 * unit).max(Vector2.ZERO))
		_edge.global_transform = xform * Transform3D(Basis.IDENTITY, Vector3(0, 0, EDGE_Z))
		_edge_material.render_priority = int(frame.edge_priority)
		for material in [_glow_material, _edge_material]:
			material.set_shader_parameter("bar", _bar)
			material.set_shader_parameter("unit", unit)
			material.set_shader_parameter("half_width", size.x * 0.5 / unit)
			material.set_shader_parameter("peak", profile.x)
			material.set_shader_parameter("width", profile.y)
			material.set_shader_parameter("power", Model.HALO_POWER)
			material.set_shader_parameter("band", Model.EDGE_BAND if _edge.visible else 0.0)
			material.set_shader_parameter("extent", margin)
			material.set_shader_parameter("display_referred", bool(debug_look.get("encode", true)))
			material.set_shader_parameter("dimming", float(debug_look.get("dimming", 1.0 if tint_room else SCENERY_DIMMING)))
			material.set_shader_parameter("strength", _visibility * Model.halo_strength(brightness))
	_place_floor(xform, size, floor_y)
	if not debug_parts.floor: _floor.visible = false


## A rectangular frame in the picture's plane, rebuilt only when its outline changes.
func _set_frame(node: MeshInstance3D, outer: Vector2, inner: Vector2) -> void:
	var outline := [outer, inner]
	if node.mesh != null and node.get_meta("outline", []) == outline: return
	node.set_meta("outline", outline)
	var o := outer * 0.5
	var i := inner * 0.5
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-o.x, -o.y, 0), Vector3(o.x, -o.y, 0), Vector3(o.x, o.y, 0), Vector3(-o.x, o.y, 0),
		Vector3(-i.x, -i.y, 0), Vector3(i.x, -i.y, 0), Vector3(i.x, i.y, 0), Vector3(-i.x, i.y, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	node.mesh = mesh


func _place_floor(xform: Transform3D, size: Vector2, floor_y: float) -> void:
	var basis := xform.basis.orthonormalized()
	var right := basis.x
	var up := basis.y
	var bottom := xform.origin - up * size.y * 0.5 * xform.basis.y.length()
	var height := bottom.y - floor_y
	if height < 0.0:
		_floor.visible = false
		return
	var share := lerpf(1.0, FLOOR_HIGH_SHARE, smoothstep(FLOOR_NEAR, FLOOR_FAR, height)) * clampf(height / FLOOR_CONTACT, 0.0, 1.0)
	var flat_right := Vector3(right.x, 0, right.z)
	if flat_right.length_squared() < 0.0001: flat_right = Vector3.RIGHT
	flat_right = flat_right.normalized()
	var forward := flat_right.cross(Vector3.UP)
	var length := size.x * xform.basis.x.length() * FLOOR_LENGTH
	_floor.visible = true
	_floor.global_transform = Transform3D(Basis(flat_right * length, forward * FLOOR_DEPTH, Vector3.UP), Vector3(bottom.x, floor_y + 0.002, bottom.z))
	_floor_material.set_shader_parameter("opacity", FLOOR_OPACITY * share * _visibility)


func _ensure_nodes() -> void:
	if _glow == null or not is_instance_valid(_glow):
		_glow = MeshInstance3D.new()
		_glow.name = "PassthroughRelightGlow"
		_glow_material = ShaderMaterial.new()
		_glow_material.shader = GLOW_SHADER
		# First among transparent surfaces (right after the video's hole, -128): the glow stores
		# straight colour for the compositor, so menus and pointers must blend over it, never under.
		_glow_material.render_priority = -126
		_glow.material_override = _glow_material
		_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_glow)
	if _edge == null or not is_instance_valid(_edge):
		_edge = MeshInstance3D.new()
		_edge.name = "PassthroughRelightEdge"
		_edge_material = ShaderMaterial.new()
		_edge_material.shader = GLOW_SHADER
		_edge_material.set_shader_parameter("part", 1)
		_edge.material_override = _edge_material
		_edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_edge)
	if _floor == null or not is_instance_valid(_floor):
		_floor = MeshInstance3D.new()
		_floor.name = "PassthroughRelightFloor"
		var plane := QuadMesh.new()
		plane.size = Vector2.ONE
		_floor.mesh = plane
		_floor_material = ShaderMaterial.new()
		_floor_material.shader = FLOOR_SHADER
		_floor_material.render_priority = 80
		_floor.material_override = _floor_material
		_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_floor)


# ---- frame sampling --------------------------------------------------------------------

func _sample(video: Node) -> void:
	var pair: Dictionary = video.media.last_pair
	var layer: bool = video._binding.layer
	_next_ms = Time.get_ticks_msec() + (LAYER_INTERVAL_MS if layer else EYE_BUFFER_INTERVAL_MS)
	if int(pair.get("pts_us", -1)) == _last_pts and _has_frame: return
	_busy = true
	var generation := _generation
	var image: Image
	if layer: image = await _layer_image(video, pair)
	else: image = await _eye_buffer_image(video, pair)
	var light := await _analyse(image)
	_busy = false
	if generation != _generation or not enabled: return
	if light.is_empty():
		failures += 1
		return
	_last_pts = int(pair.get("pts_us", -1))
	_apply(light, "layer" if layer else "eye_buffer")


func _accept(image: Image, from: String) -> void:
	_apply(_light(image), from)


func _apply(light: Dictionary, from: String) -> void:
	path = from
	samples += 1
	_latest = light.average
	_bar_target = light.bar
	_has_frame = true


static func _light(image: Image) -> Dictionary:
	var px := Model.linear_pixels(image)
	return {"average": Model.screen_average(px, image.get_width(), image.get_height()),
		"bar": Model.halo_bar(px, image.get_width(), image.get_height())}


## The perimeter blur is several milliseconds of script per sample, so it runs on a worker
## and the frame loop only waits for it. Empty when there was no picture.
func _analyse(image: Image) -> Dictionary:
	if image == null or image.is_empty(): return {}
	var out := {}
	var task := WorkerThreadPool.add_task(func() -> void: out.merge(_light(image)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return out


## Left eye of the decoded frame (the left half of a side-by-side frame).
static func eye_crop(pair: Dictionary) -> Vector4:
	var stereo := bool(pair.get("stereo_sbs", false))
	if stereo and bool(pair.get("top_bottom", false)): return Vector4(0, 0, 1, .5)
	if stereo: return Vector4(0, 0, .5, 1)
	return Vector4(0, 0, 1, 1)


func _layer_image(video: Node, pair: Dictionary) -> Image:
	var platform: Object = video.platform
	if platform == null: return null
	var crop := eye_crop(pair)
	var size := Model.SAMPLE_SIZE
	var request: int = platform.request_mpv_layer_thumbnail(int(pair.session_id), int(pair.width), int(pair.height),
		int(pair.get("surface_rotation_degrees", 0)), PackedFloat32Array([crop.x, crop.y, crop.z, crop.w]), size.x, size.y)
	if request <= 0: return null
	var deadline := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var state: String = platform.get_mpv_layer_thumbnail_state(request)
		if state == "pending": continue
		if state != "ready": return null
		var pixels: PackedByteArray = platform.take_mpv_layer_thumbnail(request)
		if pixels.size() != size.x * size.y * 4: return null
		return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, pixels)
	# Still pending: free the slot, the result store is shared with library thumbnails.
	platform.cancel_mpv_layer_snapshot(request)
	return null


func _eye_buffer_image(video: Node, pair: Dictionary) -> Image:
	var platform: Object = video.platform
	if platform == null or not platform.pin_mpv_pair(int(pair.session_id), int(pair.slot_token)): return null
	var binding := Binding.new()
	var target := ShaderMaterial.new()
	var image: Image = null
	if binding.bind(target, pair):
		var stereo := bool(pair.get("stereo_sbs", false)) or binding.warped
		var tb := stereo and bool(pair.get("top_bottom", false))
		var uv_scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
		image = await _capture_image(binding.color_texture(), str(binding.ticket.get("color_target", "")) == "external",
			stereo, Vector2(float(uv_scale[0]), float(uv_scale[1])), tb)
		binding.unbind()
	platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
	return image


## Thumbnails.capture with the viewport kept between samples: this runs four times a second
## for as long as a video plays, where a thumbnail is drawn once.
var _capture: SubViewport
var _capture_material: ShaderMaterial

func _capture_image(color: RID, decoder: bool, stereo: bool, uv_scale: Vector2, top_bottom: bool) -> Image:
	if _capture == null or not is_instance_valid(_capture):
		_capture = SubViewport.new()
		_capture.size = Model.SAMPLE_SIZE
		_capture.own_world_3d = true
		_capture.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 1.0
		camera.position = Vector3(0, 0, 1)
		_capture.add_child(camera)
		var quad := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(float(Model.SAMPLE_SIZE.x) / Model.SAMPLE_SIZE.y, 1.0)
		quad.mesh = mesh
		_capture_material = ShaderMaterial.new()
		quad.material_override = _capture_material
		_capture.add_child(quad)
		add_child(_capture)
	var shader: Shader = Thumbnails.SHADER_OES if decoder else Thumbnails.SHADER_2D
	if _capture_material.shader != shader: _capture_material.shader = shader
	_capture_material.set_shader_parameter("stereo_sbs", stereo)
	_capture_material.set_shader_parameter("top_bottom", top_bottom)
	_capture_material.set_shader_parameter("crop", Vector4(0, 0, 1, 1))
	_capture_material.set_shader_parameter("color_uv_scale", uv_scale)
	RenderingServer.material_set_param(_capture_material.get_rid(), "color_texture", color)
	_capture.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := _capture.get_texture().get_image()
	RenderingServer.material_set_param(_capture_material.get_rid(), "color_texture", null)
	return image


## The browser page has no Godot texture: GeckoView draws straight into the layer's Android
## surface. PixelCopy reads the surface's last frame, cropped to the focus-selected region
## (the whole page when nothing is focused). In 3D mode this is the flat page before the
## depth conversion, i.e. the picture the user selected.
func _sample_browser(window: Node) -> void:
	_next_ms = Time.get_ticks_msec() + BROWSER_INTERVAL_MS
	if _page_sampler == null:
		if OS.get_name() != "Android": return
		_page_sampler = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.LayerThumbnail")
		if _page_sampler == null: return
	var page: Node = window.surface
	var input: Object = page.layer.input_surface() if page.layer else null
	if input == null: return
	var crop: Rect2 = window.focus_crop()
	var size := Model.SAMPLE_SIZE
	var request: int = int(_page_sampler.requestSurface(input, int(page.pixels.x), int(page.pixels.y),
		crop.position.x, crop.position.y, crop.size.x, crop.size.y, size.x, size.y))
	JavaClassWrapper.get_exception()
	if request <= 0:
		failures += 1
		return
	_busy = true
	var generation := _generation
	var image: Image = null
	var deadline := Time.get_ticks_msec() + 500
	var pending := true
	while pending and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var state := str(_page_sampler.surfaceState(request))
		if state == "pending": continue
		pending = false
		if state == "ready":
			var pixels: PackedByteArray = _page_sampler.takeSurface(request)
			if pixels.size() == size.x * size.y * 4:
				image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, pixels)
	if pending: _page_sampler.cancelSurface(request)
	var light := await _analyse(image)
	_busy = false
	if generation != _generation or not enabled: return
	if light.is_empty():
		failures += 1
		return
	_apply(light, "browser")
