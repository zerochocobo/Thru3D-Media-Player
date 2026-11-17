extends RefCounted
## Some OpenXR runtimes give no floor: the play space starts at the head (iQIYI's QIYIVR Monado
## reports a head about 0.15 m above the origin). Decided once, when the head is first tracked; the
## viewer is then taken to be standing, with eyes this far above the floor the scenes stand on.
const EYE_HEIGHT := 1.6
## A runtime with a floor puts a seated or standing head well above this.
const FLOORLESS_BELOW := 0.5
static var floorless := false

static func detect(head_height: float) -> void:
	floorless = is_finite(head_height) and head_height < FLOORLESS_BELOW

## How far the real floor is below the tracking origin.
static func offset() -> float:
	return EYE_HEIGHT if floorless else 0.0
