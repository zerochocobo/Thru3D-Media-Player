extends Node
## Video-driven lighting over passthrough for the flat player (regular and 3D videos):
##  1. Passthrough relight: the real room is tinted and dimmed by the picture's colour
##     (Meta XR_META_passthrough_color_lut through the Godot OpenXR Vendors plugin).
##  2. Screen halo: picture-edge colours glow around the screen (passthrough_relight_glow).
##  3. Floor contact shadow under the screen (passthrough_relight_floor).
## The maths is in passthrough_relight_model.gd; docs/PASSTHROUGH_RELIGHT.md describes the
## design and its constants.
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
## The halo bar is filtered in time at a nominal 36 Hz; samples arrive slower than that,
## so a short extra settle hides their steps without visibly delaying cuts.
const HALO_SETTLE_TAU := 0.06
## The glow quad reaches far past the picture: the glow only falls to a few percent tens
## of units out, so a tight quad would show its border.
const GLOW_MARGIN_UNITS := 29.0
## Halo profile, 0 (tight) to 1 (immersive). At 1 the glow is nearly
## opaque at the picture's edge, holds for ~0.34 units, then fades as 0.7 / (1 + 2.2 x).
const IMMERSIVE := 1.0
## Glow plane offset along the screen normal: just behind a video panel, and behind the browser
## window's frame for a page (its layout pose sits 12 mm in front of the window), so opaque
## window parts occlude the halo. The halo is also drawn first among transparent surfaces.
const VIDEO_GLOW_Z := -0.002
const BROWSER_GLOW_Z := -0.015
## The edge dissolve lies on the picture and must be drawn after the hole that clears the eye
## buffer for the compositor layer: the video's hole has priority -128, the browser page's 25.
const EDGE_Z := 0.001
const VIDEO_EDGE_PRIORITY := -126
const BROWSER_EDGE_PRIORITY := 26
const BROWSER_INTERVAL_MS := 100
## Halo units: a screen is 1.08 units tall. One unit in metres follows the screen size.
const UNIT_SCREEN_HEIGHT := 1.08
## Re-create the passthrough LUT at most this often, and only for a visible change.
const LUT_INTERVAL_MS := 66
const LUT_EPSILON := 1.5 / 255.0
const LUT_RESOLUTION := 16
## Floor shadow look.
const FLOOR_COLOR := Color(0, 0, 0, 0.18)
const FLOOR_INTENSITY := 0.72
const FLOOR_STRIP_DEPTH := 0.18
const FLOOR_STRIP_LENGTH_SCALE := 0.6667
const FLOOR_TILT_DEPTH_SCALE := 0.35
const FLOOR_MAX_TILT_DEPTH := 0.24
const FLOOR_GROUND_CONTACT_FADE := 0.08
const FLOOR_HEIGHT_FADE := Vector3(0.45, 1.6, 0.25) # start, end, minimum
const FLOOR_FADE_DURATION := 0.2

var enabled := false
var intensity := Model.DEFAULT_INTENSITY
var samples := 0
var failures := 0
var path := ""
var lut_supported := false
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
var _lut: Resource
var _lut_scale := Color.WHITE
var _lut_next_ms := 0
var _lut_active := false

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


func set_intensity(value: float) -> void:
	intensity = clampf(value, 0.0, 1.0)


## Per frame. `active`: passthrough visible behind a flat video that is open.
func update(delta: float, video: Node, active: bool, floor_y: float) -> void:
	var showing: bool = enabled and active and video != null and video.media.state in ["playing", "paused", "ended"] \
		and not video.media.last_pair.is_empty()
	_use_source(video)
	if showing and not _busy and Time.get_ticks_msec() >= _next_ms:
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
		frame = {"transform": layout.pose, "size": layout.size, "flat": true, "glow_z": BROWSER_GLOW_Z,
			"edge_priority": BROWSER_EDGE_PRIORITY}
		if showing and not _busy and Time.get_ticks_msec() >= _next_ms:
			_sample_browser(window)
	_step(delta, showing, active, frame, floor_y)


func _use_source(source: Object) -> void:
	var id := source.get_instance_id() if source != null else 0
	if id == _source: return
	_source = id
	_generation += 1
	_last_pts = -1; _next_ms = 0


func _step(delta: float, showing: bool, active: bool, frame: Dictionary, floor_y: float) -> void:
	# The room returns to white at 2 %/frame whenever no video is showing.
	if showing and _has_frame:
		scale = Model.blend(scale, Model.color_scale(_latest, intensity), Model.SCALE_KEEP, Model.SCALE_FRAME_RATE, delta)
	else:
		scale = Model.blend(scale, Color.WHITE, Model.NEUTRAL_KEEP, Model.SCALE_FRAME_RATE, delta)
		if not showing: _has_frame = false
	var keep := pow(Model.BAR_KEEP, maxf(delta, 0.0) * Model.BAR_FRAME_RATE)
	var settle := 1.0 - exp(-maxf(delta, 0.0) / HALO_SETTLE_TAU)
	for i in Model.BAR_SIZE:
		var target: Vector3 = _bar_target[i] if showing and _has_frame else Vector3.ZERO
		_bar[i] = _bar[i].lerp(_bar[i].lerp(target, 1.0 - keep), settle)
	var fade_step := maxf(delta, 0.0) / FLOOR_FADE_DURATION
	_visibility = clampf(_visibility + (fade_step if showing and _has_frame else -fade_step), 0.0, 1.0)
	_apply_passthrough(active and enabled)
	_place(frame, floor_y)


func snapshot() -> Dictionary:
	return {"enabled": enabled, "samples": samples, "failures": failures, "path": path, "lut_supported": lut_supported,
		"lut_updates": lut_updates, "intensity": intensity,
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
	var neutral := absf(scale.r - 1.0) < LUT_EPSILON and absf(scale.g - 1.0) < LUT_EPSILON and absf(scale.b - 1.0) < LUT_EPSILON
	if not allowed or (neutral and not enabled):
		if _lut_active:
			_passthrough.set_passthrough_filter(0) # PASSTHROUGH_FILTER_DISABLED
			_lut_active = false
			_lut = null
			_lut_scale = Color.WHITE
		return
	var now := Time.get_ticks_msec()
	if now < _lut_next_ms: return
	var change := maxf(absf(scale.r - _lut_scale.r), maxf(absf(scale.g - _lut_scale.g), absf(scale.b - _lut_scale.b)))
	if _lut_active and change < LUT_EPSILON: return
	var image := Model.scale_lut_image(scale, LUT_RESOLUTION)
	var lut: Resource = ClassDB.class_call_static("OpenXRMetaPassthroughColorLut", "create_from_image", image, 3)
	if lut == null: return
	# Set the new table before the old one is released: freeing a LUT still in use makes
	# the plugin disable the filter (both run in order on the render thread).
	_passthrough.set_color_lut(1.0, lut)
	_lut = lut
	_lut_scale = scale
	_lut_active = true
	_lut_next_ms = now + LUT_INTERVAL_MS
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
	var unit := size.y / UNIT_SCREEN_HEIGHT
	_ensure_nodes()
	# A curved screen does not have the flat rectangle the halo is shaped around.
	_glow.visible = bool(frame.flat)
	_edge.visible = _glow.visible
	if _glow.visible:
		(_glow.mesh as QuadMesh).size = size + Vector2.ONE * GLOW_MARGIN_UNITS * 2.0 * unit
		_glow.global_transform = xform * Transform3D(Basis.IDENTITY, Vector3(0, 0, float(frame.glow_z)))
		(_edge.mesh as QuadMesh).size = size
		_edge.global_transform = xform * Transform3D(Basis.IDENTITY, Vector3(0, 0, EDGE_Z))
		_edge_material.render_priority = int(frame.edge_priority)
		for material in [_glow_material, _edge_material]:
			material.set_shader_parameter("bar", _bar)
			material.set_shader_parameter("unit", unit)
			material.set_shader_parameter("half_width", size.x * 0.5 / unit)
			material.set_shader_parameter("half_height", size.y * 0.5 / unit)
			material.set_shader_parameter("slider_value", _slider_value())
			material.set_shader_parameter("immersive", IMMERSIVE)
			material.set_shader_parameter("strength", _visibility)
	_place_floor(xform, size, floor_y)


## The intensity through a normalised sigmoid.
func _slider_value() -> float:
	return (1.0 / (1.0 + exp(-8.0 * (intensity - 0.2))) - 0.1679816097021103) / 0.8303595781326294


func _place_floor(xform: Transform3D, size: Vector2, floor_y: float) -> void:
	var basis := xform.basis.orthonormalized()
	var right := basis.x
	var up := basis.y
	var bottom := xform.origin - up * size.y * 0.5 * xform.basis.y.length()
	var height := bottom.y - floor_y
	if height < 0.0:
		_floor.visible = false
		return
	var span := (FLOOR_HEIGHT_FADE.y - FLOOR_HEIGHT_FADE.x)
	var height_alpha := lerpf(1.0, FLOOR_HEIGHT_FADE.z, clampf((height - FLOOR_HEIGHT_FADE.x) / span, 0.0, 1.0))
	height_alpha *= clampf(height / FLOOR_GROUND_CONTACT_FADE, 0.0, 1.0)
	var flat_right := Vector3(right.x, 0, right.z)
	if flat_right.length_squared() < 0.0001: flat_right = Vector3.RIGHT
	flat_right = flat_right.normalized()
	var forward := flat_right.cross(Vector3.UP)
	var tilt := absf(basis.z.y)
	var depth := FLOOR_STRIP_DEPTH + minf(FLOOR_MAX_TILT_DEPTH, tilt * FLOOR_TILT_DEPTH_SCALE)
	var length := size.x * xform.basis.x.length() * FLOOR_STRIP_LENGTH_SCALE
	_floor.visible = true
	_floor.global_transform = Transform3D(Basis(flat_right * length, forward * depth, Vector3.UP), Vector3(bottom.x, floor_y + 0.002, bottom.z))
	var color := FLOOR_COLOR
	color.a *= FLOOR_INTENSITY * height_alpha * _visibility
	_floor_material.set_shader_parameter("projection_color", color)


func _ensure_nodes() -> void:
	if _glow == null or not is_instance_valid(_glow):
		_glow = MeshInstance3D.new()
		_glow.name = "PassthroughRelightGlow"
		_glow.mesh = QuadMesh.new()
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
		_edge.mesh = QuadMesh.new()
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
	_busy = false
	if generation != _generation or not enabled: return
	if image == null or image.is_empty():
		failures += 1
		return
	_last_pts = int(pair.get("pts_us", -1))
	_accept(image, "layer" if layer else "eye_buffer")


func _accept(image: Image, from: String) -> void:
	path = from
	samples += 1
	var px := Model.linear_pixels(image)
	_latest = Model.screen_average(px, image.get_width(), image.get_height())
	_bar_target = Model.halo_bar(px, image.get_width(), image.get_height())
	_has_frame = true


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
		image = await Thumbnails.capture(self, binding.color_texture(), str(binding.ticket.get("color_target", "")) == "external",
			stereo, Vector4(0, 0, 1, 1), Vector2(float(uv_scale[0]), float(uv_scale[1])), tb, Model.SAMPLE_SIZE)
		binding.unbind()
	platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
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
	_busy = false
	if generation != _generation or not enabled: return
	if image == null:
		failures += 1
		return
	_accept(image, "browser")
