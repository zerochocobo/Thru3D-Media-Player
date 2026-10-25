extends Node
## Film-driven cinema light. Samples the playing picture into left, centre and
## right linear colours that scale the baked screen-zone light (see
## tools/cinema/build_full_lighting.py). Nothing here lights in real time: the
## shaders only multiply baked irradiance by these three colours.
##
## Compositor-layer playback: the platform PixelCopies the layer surface's last
## buffer straight into a tiny bitmap (one scaled GPU draw). Eye-buffer playback:
## the bound frame is drawn into a small viewport, at a lower rate.

const Binding := preload("res://scripts/pair_texture_binding.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")

const ZONES := 3
const SAMPLE_SIZE := Vector2i(32, 18)
const LAYER_INTERVAL_MS := 100
const EYE_BUFFER_INTERVAL_MS := 250
## Seconds for colours to settle: fast enough for cuts, slow enough not to flicker.
const SMOOTHING := 0.3
## Linear grey that throws the full baked screen light. Twice a typical frame:
## real halls reflect far less than the bake, so a mid-grey frame lights at half.
const REFERENCE := 0.36
const MAX_GAIN := 2.0
## With no film the blank screen throws no light; the house lights keep a dark
## hall from going pitch black (see CinemaEnvironment.OFF_IDLE_LEVEL).
const IDLE_GLOW := Color.BLACK

## Smoothed, normalised linear colours for the three zones (shader inputs).
var colors: Array[Color] = [Color.BLACK, Color.BLACK, Color.BLACK]
var samples := 0
var failures := 0
var path := ""
var enabled := true
var _generation := 0

var _target: Array[Color] = [Color.BLACK, Color.BLACK, Color.BLACK]
var _busy := false
var _next_ms := 0
var _last_pts := -1

func set_enabled(value: bool) -> bool:
	if enabled == value: return false
	enabled = value
	_generation += 1
	_last_pts = -1; _next_ms = 0
	colors = [Color.BLACK, Color.BLACK, Color.BLACK]
	_target = colors.duplicate()
	return true


## Advances smoothing and starts a sample when due. Returns true when colours changed.
func update(delta: float, video: Node, active: bool, picture_fraction: float) -> bool:
	if not enabled: return false
	var showing: bool = active and video != null and video.media.state in ["playing", "paused", "ended"] \
		and not video.media.last_pair.is_empty()
	if not showing:
		_target = [IDLE_GLOW, IDLE_GLOW, IDLE_GLOW]; _last_pts = -1
	elif not _busy and Time.get_ticks_msec() >= _next_ms:
		_sample(video, clampf(picture_fraction, 0.0, 1.0))
	var blend := 1.0 - exp(-maxf(delta, 0.0) / SMOOTHING)
	var changed := false
	for zone in ZONES:
		var next := colors[zone].lerp(_target[zone], blend)
		if not next.is_equal_approx(colors[zone]): changed = true
		colors[zone] = next
	return changed


func snapshot() -> Dictionary:
	return {"samples": samples, "failures": failures, "path": path,
		"colors": colors.map(func(c: Color): return [snappedf(c.r, .001), snappedf(c.g, .001), snappedf(c.b, .001)])}


func _sample(video: Node, picture_fraction: float) -> void:
	var pair: Dictionary = video.media.last_pair
	var layer: bool = video._binding.layer
	_next_ms = Time.get_ticks_msec() + (LAYER_INTERVAL_MS if layer else EYE_BUFFER_INTERVAL_MS)
	# A paused frame does not change: keep its colours without copying again.
	if int(pair.get("pts_us", -1)) == _last_pts: return
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
	path = "layer" if layer else "eye_buffer"
	samples += 1
	_target = zone_colors(image, picture_fraction)


## Linear zone averages, normalised to the reference grey and scaled by how much
## of the physical screen the picture covers.
static func zone_colors(image: Image, picture_fraction: float) -> Array[Color]:
	var sums: Array[Color] = [Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0)]
	var counts := [0, 0, 0]
	var width := image.get_width()
	for y in image.get_height():
		for x in width:
			var zone := mini(ZONES - 1, x * ZONES / width)
			var pixel := image.get_pixel(x, y).srgb_to_linear()
			sums[zone] += Color(pixel.r, pixel.g, pixel.b, 0)
			counts[zone] += 1
	var result: Array[Color] = []
	for zone in ZONES:
		var average: Color = sums[zone] / maxf(1.0, counts[zone])
		var scale := picture_fraction / REFERENCE
		result.append(Color(minf(average.r * scale, MAX_GAIN), minf(average.g * scale, MAX_GAIN), minf(average.b * scale, MAX_GAIN)))
	return result


## Left eye of the decoded frame, the way the library thumbnail crops it.
static func eye_crop(pair: Dictionary) -> Vector4:
	var stereo := bool(pair.get("stereo_sbs", false))
	if stereo and bool(pair.get("top_bottom", false)): return Vector4(0, 0, 1, .5)
	if stereo: return Vector4(0, 0, .5, 1)
	return Vector4(0, 0, 1, 1)


func _layer_image(video: Node, pair: Dictionary) -> Image:
	var platform: Object = video.platform
	if platform == null: return null
	var crop := eye_crop(pair)
	var request: int = platform.request_mpv_layer_thumbnail(int(pair.session_id), int(pair.width), int(pair.height),
		int(pair.get("surface_rotation_degrees", 0)), PackedFloat32Array([crop.x, crop.y, crop.z, crop.w]), SAMPLE_SIZE.x, SAMPLE_SIZE.y)
	if request <= 0: return null
	var deadline := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var state: String = platform.get_mpv_layer_thumbnail_state(request)
		if state == "pending": continue
		if state != "ready": return null
		var pixels: PackedByteArray = platform.take_mpv_layer_thumbnail(request)
		if pixels.size() != SAMPLE_SIZE.x * SAMPLE_SIZE.y * 4: return null
		return Image.create_from_data(SAMPLE_SIZE.x, SAMPLE_SIZE.y, false, Image.FORMAT_RGBA8, pixels)
	return null


func _eye_buffer_image(video: Node, pair: Dictionary) -> Image:
	var platform: Object = video.platform
	if platform == null or not platform.pin_mpv_pair(int(pair.session_id), int(pair.slot_token)): return null
	# Own wrappers, so a close cannot detach or rebind the readback source.
	var binding := Binding.new()
	var target := ShaderMaterial.new()
	var image: Image = null
	if binding.bind(target, pair):
		var stereo := bool(pair.get("stereo_sbs", false)) or binding.warped
		var tb := stereo and bool(pair.get("top_bottom", false))
		var scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
		image = await Thumbnails.capture(self, binding.color_texture(), str(binding.ticket.get("color_target", "")) == "external",
			stereo, Vector4(0, 0, 1, 1), Vector2(float(scale[0]), float(scale[1])), tb, SAMPLE_SIZE)
		binding.unbind()
	platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
	return image
