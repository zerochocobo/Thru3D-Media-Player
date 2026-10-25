extends RefCounted

# Subtitle centre uses horizontal/vertical angles, independent of plane distance.
const DEFAULT := 5.0
# Include near-field distances while verifying the physical per-eye projection.
const LIMITS := Vector2(0.1, 5.0)
const DEFAULT_POSITION := 0.0
const POSITION_LIMITS := Vector2(-60.0, 60.0)

static func position(value: float) -> float:
	return clampf(value, POSITION_LIMITS.x, POSITION_LIMITS.y) if is_finite(value) else DEFAULT_POSITION

static func elevation(value: float) -> float:
	return deg_to_rad(position(value))

# Slider grows bottom-to-top horizontally, and left-to-right for vertical text.
static func anchor(value: float, vertical: bool = false) -> Basis:
	return Basis(Vector3.UP, -elevation(value)) if vertical else Basis(Vector3.RIGHT, elevation(value))

# Yaw then pitch keeps the text upright along the local meridian.
static func center_anchor(center: Vector2) -> Basis:
	return Basis(Vector3.UP, -elevation(center.x)) * Basis(Vector3.RIGHT, elevation(center.y))

static func restore_center(settings: ConfigFile, vertical: bool) -> Vector2:
	var legacy := restore_position(settings)
	var center := Vector2(legacy, 0) if vertical else Vector2(0, legacy)
	var prefix := "vertical_center_" if vertical else "horizontal_center_"
	for axis in 2:
		var value: Variant = settings.get_value("subtitles", prefix + ("x_degrees" if axis == 0 else "y_degrees"), center[axis])
		if (value is float or value is int) and is_finite(float(value)): center[axis] = position(float(value))
	return center

static func save_centers(settings: ConfigFile, horizontal: Vector2, vertical: Vector2) -> void:
	for entry in [["horizontal_center_", horizontal], ["vertical_center_", vertical]]:
		settings.set_value("subtitles", entry[0] + "x_degrees", position(entry[1].x))
		settings.set_value("subtitles", entry[0] + "y_degrees", position(entry[1].y))

static func direction_row(value: int) -> Dictionary:
	return {"key": "subtitle_direction", "value": clampi(value, 0, 1), "choices": [
		{"value": 0, "label": "Horizontal"}, {"value": 1, "label": "Vertical"}]}

static func restore_position(settings: ConfigFile) -> float:
	if settings.has_section_key("subtitles", "elevation_degrees"):
		return position(float(settings.get_value("subtitles", "elevation_degrees")))
	if settings.has_section_key("subtitles", "position"):
		return rad_to_deg([0.488, 0.244, 0.0, -0.244, -0.488][clampi(int(settings.get_value("subtitles", "position")), 0, 4)])
	return DEFAULT_POSITION

static func slider_row(key: String, value: float) -> Dictionary:
	var is_position := key in ["subtitle_position", "subtitle_horizontal_position", "subtitle_vertical_position"]
	return {"key": key, "value": position(value) if is_position else distance(value),
		"slider": true, "span": Vector3(POSITION_LIMITS.x, POSITION_LIMITS.y, 1) if is_position else Vector3(LIMITS.x, LIMITS.y, 0.1),
		"unit": "°" if is_position else " m", "midpoint": is_position,
		"reset_value": DEFAULT_POSITION if is_position else DEFAULT}

static func distance(value: float) -> float:
	return clampf(value, LIMITS.x, LIMITS.y) if is_finite(value) else DEFAULT

static func slider_fraction(value: float) -> float:
	return inverse_lerp(LIMITS.x, LIMITS.y, distance(value))

static func slider_distance(fraction: float) -> float:
	return distance(snappedf(lerpf(LIMITS.x, LIMITS.y, clampf(fraction, 0, 1)), 0.1))
