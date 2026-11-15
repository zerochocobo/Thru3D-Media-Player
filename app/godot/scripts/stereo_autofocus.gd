extends RefCounted
## Automatic stereo focus: a few times a second the platform measures how far apart the two eyes'
## pictures of whatever sits at the centre of the view are (StereoFocusProbe, on the layer surface).
## With each eye's sphere centred on that eye, those pictures meet at the eye separation divided by
## that angle, whatever the camera spacing was. The result is smoothed as an inverse distance.
## A fisheye frame is measured on the decoder's texture, its lens straightened around the view centre.

const INTERVAL_MS := 200
## A measurement counts when the match is this good and the patch has something to match.
const MIN_PEAK := 0.6
const MIN_CONTRAST := 4.0
const SETTLE_SECONDS := 0.4
const LIMITS := Vector2(0.3, 50.0)
## Half of each eye's copied patch in degrees, as StereoFocusProbe reads it.
const REACH := Vector2(14.5, 6.0)
## The view centre must stay this far inside the poles for a horizontal match to mean depth.
const MAX_LATITUDE := deg_to_rad(60.0)
## A lens patch's corners lie this far from the view centre; past LENS_LONGITUDE the camera pair is
## nearly end on.
const LENS_REACH := deg_to_rad(16.0)
const LENS_LONGITUDE := deg_to_rad(75.0)
## distance only moves by steps of this ratio, so a settled value does not keep redrawing.
const STEP := 0.01

## Metres to where the viewed thing's two pictures meet; 0 until something was measured.
var distance := 0.0
## The last finished measurement, for diagnostics.
var report := {}

var _recent: Array[float] = []
var _inverse := 0.0
var _sequence := -1.0
var _session := 0
var _requested_ms := -INTERVAL_MS
var _pending := false
var _direction := Vector2.ZERO
var _full_sphere := false

func reset() -> void:
	distance = 0.0
	_inverse = 0.0
	_recent.clear()
	report = {}

## (u, v) of the view centre in one eye's equirect picture and its (longitude, latitude), radians;
## [forward] is the view direction in the video's own axes (-Z ahead), [span] the picture's longitude.
static func gaze(forward: Vector3, span: float) -> Array:
	var direction := forward.normalized()
	var longitude := atan2(direction.x, -direction.z)
	var latitude := asin(clampf(direction.y, -1.0, 1.0))
	return [Vector2(0.5 + longitude / span, 0.5 - latitude / PI), Vector2(longitude, latitude)]

## Whether both eyes' patches around [eye_uv] lie inside the picture.
static func measurable(eye_uv: Vector2, angles: Vector2, span: float) -> bool:
	var reach := Vector2(deg_to_rad(REACH.x) / span, deg_to_rad(REACH.y) / PI)
	return absf(angles.y) <= MAX_LATITUDE and eye_uv.x - reach.x >= 0.0 and eye_uv.x + reach.x <= 1.0 \
		and eye_uv.y - reach.y >= 0.0 and eye_uv.y + reach.y <= 1.0

## StereoFocusProbe's parameters: the shown left and right eyes' gaze points as frame UV, then the
## degrees the whole frame spans across and down.
static func probe(eye_uv: Vector2, span: float, top_bottom: bool, swap: bool) -> PackedFloat32Array:
	var left := 1.0 if swap else 0.0
	var right := 1.0 - left
	if top_bottom:
		return PackedFloat32Array([eye_uv.x, (left + eye_uv.y) * 0.5, eye_uv.x, (right + eye_uv.y) * 0.5, rad_to_deg(span), 360.0])
	return PackedFloat32Array([(left + eye_uv.x) * 0.5, eye_uv.y, (right + eye_uv.x) * 0.5, eye_uv.y, rad_to_deg(span) * 2.0, 180.0])

## Whether both eyes' patches around the view centre lie inside a fisheye lens of [fov] degrees.
static func lens_measurable(forward: Vector3, angles: Vector2, fov: float) -> bool:
	return absf(angles.y) <= MAX_LATITUDE and absf(angles.x) <= LENS_LONGITUDE \
		and acos(clampf(-forward.normalized().z, -1.0, 1.0)) + LENS_REACH <= deg_to_rad(fov * 0.5)

## StereoFocusProbe's lens parameters: the frame's layout, half-width eyes, lens degrees, frame size,
## texture UV scale, the view centre's longitude and latitude, swapped eyes.
static func lens_probe(angles: Vector2, lens: Dictionary, top_bottom: bool, swap: bool) -> PackedFloat32Array:
	return PackedFloat32Array([2.0 if top_bottom else 1.0, 1.0 if lens.half else 0.0, lens.fov, lens.size.x, lens.size.y,
		lens.scale.x, lens.scale.y, angles.x, angles.y, 1.0 if swap else 0.0])

## Inverse metres to where two pictures [disparity] radians of longitude apart meet for eyes [ipd]
## apart. A 180 camera pair's spacing shrinks towards the sides (cos longitude); a 360 pair turns with
## the view. Longitude lines close in towards the poles (cos latitude).
static func inverse_distance(disparity: float, ipd: float, angles: Vector2, full_sphere: bool) -> float:
	var across := 1.0 if full_sphere else maxf(cos(angles.x), 0.05)
	return clampf(disparity * cos(angles.y) / (maxf(ipd, 0.001) * across), 1.0 / LIMITS.y, 1.0 / LIMITS.x)

## [forward]: the view direction in the video's axes; [offset]: the stereo alignment's shown disparity
## as a fraction of the eye picture. [lens]: a fisheye frame's texture (handle), external, fov degrees,
## half (half-width eyes), size and UV scale; empty for an equirect picture on the layer surface.
## Returns whether [distance] changed.
func tick(platform: Object, session: int, frame: Vector2i, forward: Vector3, span: float, top_bottom: bool, swap: bool,
		offset: float, ipd: float, delta: float, lens := {}) -> bool:
	if session != _session:
		reset()
		_session = session
	if _pending:
		var result: PackedFloat32Array = platform.mpv_stereo_focus_result()
		if result.size() >= 6 and result[0] != _sequence:
			_sequence = result[0]
			_pending = false
			_observe(result, span, offset, ipd)
	var now := Time.get_ticks_msec()
	# A copy that never reports back (a closed surface) is given up after a second.
	if (not _pending or now - _requested_ms >= 1000) and now - _requested_ms >= INTERVAL_MS:
		var view := gaze(forward, span)
		var asked := false
		if lens.is_empty():
			asked = measurable(view[0], view[1], span) and platform.request_mpv_stereo_focus(session, frame.x, frame.y, probe(view[0], span, top_bottom, swap))
		else:
			asked = lens_measurable(forward, view[1], lens.fov) \
				and platform.request_lens_stereo_focus(lens.texture, lens.external, lens_probe(view[1], lens, top_bottom, swap))
		if asked:
			_requested_ms = now
			_pending = true
			_sequence = platform.mpv_stereo_focus_result()[0] # only a later result is this request's
			_direction = view[1]
			_full_sphere = lens.is_empty() and is_equal_approx(span, TAU)
	return _settle(delta)

func _observe(result: PackedFloat32Array, span: float, offset: float, ipd: float) -> void:
	var valid := result[1] > 0.5 and result[3] >= MIN_PEAK and result[5] >= MIN_CONTRAST
	report = {"state": int(result[1]), "disparity_degrees": result[2], "peak": result[3], "other": result[4], "contrast": result[5], "valid": valid}
	if not valid: return
	_recent.append(inverse_distance(deg_to_rad(result[2]) + offset * span, ipd, _direction, _full_sphere))
	if _recent.size() > 3: _recent.pop_front()

func _settle(delta: float) -> bool:
	if _recent.is_empty(): return false
	# The middle of the last three: one mismatched frame never moves the focus.
	var target := _recent[0]
	if _recent.size() == 3:
		var sorted := _recent.duplicate()
		sorted.sort()
		target = sorted[1]
	_inverse = target if _inverse <= 0.0 else lerpf(_inverse, target, 1.0 - exp(-delta / SETTLE_SECONDS))
	var settled := 1.0 / _inverse
	if distance > 0.0 and absf(settled - distance) < distance * STEP: return false
	distance = settled
	return true
