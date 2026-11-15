extends RefCounted
## Captions that follow the view. They rest in the video while the view stays near them and glide
## back under it once it has turned further away, so reading with small head movements does not
## drag the text along.
## The view centre has to leave the captions' reference by START before they move; they then glide
## with TIME until SETTLE remains. Past JUMP they were out of sight and are simply put there.
const START := deg_to_rad(10.0)
const SETTLE := deg_to_rad(0.5)
const JUMP := deg_to_rad(70.0)
const TIME := 0.2
const MAX_PITCH := deg_to_rad(75.0)
## The captions' reference: (to the right, up) in radians, in the video's axes.
var centre := Vector2.ZERO
var _placed := false
var _moving := false

static func direction(angles: Vector2) -> Vector3:
	return Vector3(sin(angles.x) * cos(angles.y), sin(angles.y), -cos(angles.x) * cos(angles.y))

func reset() -> void:
	_placed = false
	_moving = false

## [forward]: the view direction in the video's axes.
func tick(forward: Vector3, delta: float) -> void:
	var towards := forward.normalized()
	var view := Vector2(atan2(towards.x, -towards.z), clampf(asin(clampf(towards.y, -1.0, 1.0)), -MAX_PITCH, MAX_PITCH))
	var gap := direction(centre).angle_to(direction(view))
	if not _placed or gap > JUMP:
		centre = view
		_placed = true
		_moving = false
		return
	if gap > START: _moving = true
	if not _moving: return
	var step := 1.0 - exp(-maxf(delta, 0.0) / TIME)
	centre = Vector2(wrapf(centre.x + wrapf(view.x - centre.x, -PI, PI) * step, -PI, PI), centre.y + (view.y - centre.y) * step)
	if gap * (1.0 - step) < SETTLE: _moving = false
