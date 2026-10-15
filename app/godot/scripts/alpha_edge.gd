extends RefCounted
## Alpha mask edge from the player settings: feather (how wide the soft edge is) and shrink (how far the
## edge moves into the person, which removes a fringe of the video's background). Both become one range
## of mask values mapped to [0, 1], used by the eye-buffer shader and the compositor mask alike.

const FEATHER_DEFAULT := 100.0 # percent: the model's own soft edge
const SHRINK_DEFAULT := 40.0 # removes the usual fringe of the video's background at the edge

## Mask values below x become transparent, above y opaque. Feather 100 % with shrink 0 % gives (0, 1):
## the mask unchanged.
## y never exceeds 1, so a fully opaque person stays opaque however far the edge shrinks.
static func bounds(feather: float, shrink: float) -> Vector2:
	var half := lerpf(0.01, 0.5, clampf(feather, 0.0, 100.0) / 100.0)
	var centre := lerpf(0.5, 0.9, clampf(shrink, 0.0, 100.0) / 100.0)
	var low := clampf(centre - half, 0.0, 0.98)
	return Vector2(low, clampf(centre + half, low + 0.02, 1.0))
