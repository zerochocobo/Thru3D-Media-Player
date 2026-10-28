extends RefCounted
## Display-only selection and alignment. Offsets are total inter-eye displacement,
## in percent of one displayed eye's width/height; neither decoding nor XR IPD changes.
const HORIZONTAL_STEP := 0.25
const VERTICAL_STEP := 0.05
const HORIZONTAL := Vector3(-10.0, 10.0, HORIZONTAL_STEP)
const VERTICAL := Vector3(-5.0, 5.0, VERTICAL_STEP)
const MODES := ["Both eyes", "Left eye", "Right eye"]

static func limits(key: String) -> Vector3:
	return HORIZONTAL if key == "stereo_horizontal" else VERTICAL

static func step(key: String) -> float:
	# Keep scalar precision: Vector3 components are float32, unlike saved numbers.
	return HORIZONTAL_STEP if key == "stereo_horizontal" else VERTICAL_STEP

static func valid(value: Dictionary) -> bool:
	if value.has("spatial_auto_disparity") and not value.spatial_auto_disparity is bool: return false
	if value.has("viewing_eye"):
		var eye: Variant = value.viewing_eye
		if not (eye is int or eye is float) or not is_finite(float(eye)) or float(eye) not in [0.0, 1.0, 2.0]: return false
	for key in ["stereo_horizontal", "stereo_vertical"]:
		if not value.has(key): continue
		var offset: Variant = value[key]
		var span := limits(key)
		if not (offset is int or offset is float) or not is_finite(float(offset)) or float(offset) < span.x or float(offset) > span.y: return false
	return true
