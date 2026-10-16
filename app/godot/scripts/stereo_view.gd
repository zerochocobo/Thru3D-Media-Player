extends RefCounted
## Display-only selection and alignment. Offsets are total inter-eye displacement,
## in percent of one displayed eye's width/height; neither decoding nor XR IPD changes.
const LIMIT := 5.0
const STEP := 0.05
const MODES := ["Both eyes", "Left eye", "Right eye"]

static func valid(value: Dictionary) -> bool:
	if value.has("spatial_auto_disparity") and not value.spatial_auto_disparity is bool: return false
	if value.has("viewing_eye"):
		var eye: Variant = value.viewing_eye
		if not (eye is int or eye is float) or not is_finite(float(eye)) or float(eye) not in [0.0, 1.0, 2.0]: return false
	for key in ["stereo_horizontal", "stereo_vertical"]:
		if not value.has(key): continue
		var offset: Variant = value[key]
		if not (offset is int or offset is float) or not is_finite(float(offset)) or absf(float(offset)) > LIMIT: return false
	return true
