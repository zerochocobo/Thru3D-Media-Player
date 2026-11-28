extends RefCounted
## Display-only grading. Stored custom values survive selecting another preset.
const PRESETS := ["Original", "Warm", "Cool", "Custom"]
const QiyuController := preload("res://scripts/qiyu_controller.gd")
const DEFAULTS := {"temperature": 6500.0, "tint": 0.0, "exposure": 0.0, "contrast": 1.0,
	"gamma": 1.0, "saturation": 1.0, "red_gain": 1.0, "green_gain": 1.0, "blue_gain": 1.0,
	"red_gamma": 1.0, "green_gamma": 1.0, "blue_gamma": 1.0,
	"red_offset": 0.0, "green_offset": 0.0, "blue_offset": 0.0}
const PAGES := [["temperature", "tint", "exposure", "contrast", "gamma", "saturation"],
	["red_gain", "green_gain", "blue_gain"],
	["red_gamma", "green_gamma", "blue_gamma", "red_offset", "green_offset", "blue_offset"]]
const NAMES := {"temperature": "Temperature", "tint": "Tint", "exposure": "Exposure (brightness)", "contrast": "Contrast",
	"gamma": "Gamma (shadow lift)", "saturation": "Saturation", "red_gain": "Red gain", "green_gain": "Green gain", "blue_gain": "Blue gain",
	"red_gamma": "Red gamma", "green_gamma": "Green gamma", "blue_gamma": "Blue gamma",
	"red_offset": "Red offset", "green_offset": "Green offset", "blue_offset": "Blue offset"}
## The controls a compositor layer cannot carry as a scale and bias. Video applies them in picture
## quality mode; while that mode is available but off they are locked, shown but without effect.
const CURVES := ["gamma", "saturation", "red_gamma", "green_gamma", "blue_gamma"]
var preset := "Original"
var custom: Dictionary = DEFAULTS.duplicate()
var curves_locked := false
## Monochrome film from the plugins tab, in place of the saturation (picture_glsl.h's order: 1, the weights
## of red, green and blue, the chroma lift, the S curve's power and the exponent taking its pivot to 0.5,
## the black point, paper white, the grain's amount and cell). Empty: none. Not part of the saved grade.
var mono := PackedFloat32Array()

static func limits(key: String) -> Vector3:
	match key:
		"temperature": return Vector3(2700, 9000, 100)
		"tint": return Vector3(-50, 50, 1)
		"exposure": return Vector3(-2, 2, 0.05)
		"contrast": return Vector3(0.5, 1.5, 0.01)
		"gamma", "red_gamma", "green_gamma", "blue_gamma": return Vector3(0.7, 1.4, 0.01)
		"saturation": return Vector3(0, 2, 0.01)
		"red_gain", "green_gain", "blue_gain": return Vector3(0, 2, 0.01)
	return Vector3(-0.2, 0.2, 0.005)

## Gamma sliders run the way people expect: right brightens (or adds that colour). They show and move
## 1 / gamma evenly; the grade keeps the gamma exponent itself.
const INVERTED := ["gamma", "red_gamma", "green_gamma", "blue_gamma"]

static func shown(key: String, value: float) -> float:
	return 1.0 / value if key in INVERTED and value > 0.0 else value

static func slider_fraction(key: String, value: float) -> float:
	var span := limits(key)
	if key in INVERTED: return clampf((shown(key, value) - 1.0 / span.y) / (1.0 / span.x - 1.0 / span.y), 0.0, 1.0)
	return clampf((value - span.x) / (span.y - span.x), 0.0, 1.0)

static func slider_value(key: String, fraction: float) -> float:
	var span := limits(key)
	if key in INVERTED: return clean(key, 1.0 / lerpf(1.0 / span.y, 1.0 / span.x, clampf(fraction, 0.0, 1.0)))
	return clean(key, lerpf(span.x, span.y, clampf(fraction, 0.0, 1.0)))

static func clean(key: String, value: Variant) -> float:
	var number := float(value) if value is float or value is int else float(DEFAULTS[key])
	if not is_finite(number): number = DEFAULTS[key]
	var span := limits(key)
	return roundf(clampf(snappedf(number, span.z), span.x, span.y) * 10000.0) / 10000.0

func restore(data: Variant) -> void:
	preset = "Original"
	custom = DEFAULTS.duplicate()
	if not data is Dictionary: return
	# Old Daylight saves were neutral. Keep their custom values while using the bypass.
	if data.get("preset", "") == "Daylight": preset = "Original"
	elif data.get("preset", "") in PRESETS: preset = data.preset
	var saved: Variant = data.get("custom", {})
	if saved is Dictionary:
		for key in DEFAULTS: custom[key] = clean(key, saved.get(key, DEFAULTS[key]))

func snapshot() -> Dictionary:
	return {"preset": preset, "custom": custom.duplicate()}

## The grade in effect, or with stored the values as saved (what the sliders show while locked).
func values(stored: bool = false) -> Dictionary:
	var result := custom.duplicate() if preset == "Custom" else DEFAULTS.duplicate()
	if preset != "Custom": result.temperature = {"Warm": 4000.0, "Cool": 8000.0}.get(preset, 6500.0)
	if curves_locked and not stored:
		for key in CURVES: result[key] = DEFAULTS[key]
	return result

## A saved look that uses gamma or saturation.
func uses_curves() -> bool:
	return preset == "Custom" and CURVES.any(func(key): return not is_equal_approx(float(custom[key]), float(DEFAULTS[key])))

func select(name: String) -> void:
	if name in PRESETS: preset = name

func adjust(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key): return
	# The first edit starts from the visible preset, then becomes the remembered custom look.
	if preset != "Custom": custom = values(true)
	preset = "Custom"
	custom[key] = clean(key, value)

func reset_custom() -> void:
	custom = DEFAULTS.duplicate()
	preset = "Custom"

func reset_page(page: int) -> bool:
	if page < 0 or page >= PAGES.size(): return false
	if preset != "Custom": custom = values(true)
	for key in PAGES[page]: custom[key] = DEFAULTS[key]
	preset = "Custom"
	return true

static func kelvin(k: float) -> Vector3:
	var t := k / 100.0
	var r := 255.0 if t <= 66 else 329.698727446 * pow(t - 60, -0.1332047592)
	var g := 99.4708025861 * log(t) - 161.1195681661 if t <= 66 else 288.1221695283 * pow(t - 60, -0.0755148492)
	var b := 255.0 if t >= 66 else 138.5177312231 * log(t - 10) - 305.0447927307
	return Vector3(clampf(r, 0, 255), clampf(g, 0, 255), clampf(b, 0, 255)) / 255.0

## Per-channel gain: white balance (temperature, tint), exposure and the RGB gains.
func gain() -> Vector3:
	var p := values()
	var gains := kelvin(p.temperature) / kelvin(6500)
	var magenta := maxf(p.tint, 0) / 50.0
	var green := maxf(-p.tint, 0) / 50.0
	gains *= Vector3(1 + 0.12 * magenta, 1 + 0.12 * green - 0.08 * magenta, 1 + 0.12 * magenta)
	gains /= gains.dot(Vector3(0.2126, 0.7152, 0.0722))
	return gains * pow(2, p.exposure) * Vector3(p.red_gain, p.green_gain, p.blue_gain)

## The grade as one per-channel scale and bias, which the compositor applies to a whole layer
## (XR_KHR_composition_layer_color_scale_bias): (rgb * gain - 0.5) * contrast + 0.5 + offset.
## Empty when gamma, saturation or monochrome film make it non-linear.
func linear_terms() -> Dictionary:
	if not mono.is_empty(): return {}
	if preset == "Original": return {"scale": Vector3.ONE, "bias": Vector3.ZERO}
	var p := values()
	if not is_equal_approx(p.saturation, 1.0) or not (Vector3(p.red_gamma, p.green_gamma, p.blue_gamma) * p.gamma).is_equal_approx(Vector3.ONE):
		return {}
	return {"scale": gain() * p.contrast,
		"bias": Vector3.ONE * (0.5 - 0.5 * p.contrast) + Vector3(p.red_offset, p.green_offset, p.blue_offset)}

## linear_terms() for the compositor, which scales and offsets linear light, not the display-encoded
## values the shader grades. Exact at two encoded levels (0.15, 0.6) per channel: gains (white balance,
## exposure, presets) come out within ~1/255; contrast and offsets within a few levels, mostly in shadows.
func layer_terms() -> Dictionary:
	var terms := linear_terms()
	if terms.is_empty(): return {}
	var scale := Vector3.ONE
	var bias := Vector3.ZERO
	for channel in 3:
		var low := _to_linear(clampf(terms.scale[channel] * LAYER_ANCHORS.x + terms.bias[channel], 0.0, 1.0))
		var high := _to_linear(clampf(terms.scale[channel] * LAYER_ANCHORS.y + terms.bias[channel], 0.0, 1.0))
		var from := Vector2(_to_linear(LAYER_ANCHORS.x), _to_linear(LAYER_ANCHORS.y))
		scale[channel] = (high - low) / (from.y - from.x)
		bias[channel] = low - scale[channel] * from.x
	return {"scale": scale, "bias": bias}

const LAYER_ANCHORS := Vector2(0.15, 0.6)

static func _to_linear(value: float) -> float:
	return value / 12.92 if value <= 0.04045 else pow((value + 0.055) / 1.055, 2.4)

static func _to_encoded(value: float) -> float:
	value = clampf(value, 0.0, 1.0)
	return value * 12.92 if value <= 0.0031308 else 1.055 * pow(value, 1.0 / 2.4) - 0.055

func apply(material: ShaderMaterial) -> void:
	if not material: return
	var p := values()
	material.set_shader_parameter("grade_enabled", preset != "Original" or not mono.is_empty())
	material.set_shader_parameter("grade_mono", not mono.is_empty())
	if not mono.is_empty():
		material.set_shader_parameter("grade_mono_weights", Vector4(mono[1], mono[2], mono[3], mono[4]))
		material.set_shader_parameter("grade_mono_tone", Vector4(mono[5], mono[6], mono[7], mono[8]))
		material.set_shader_parameter("grade_mono_grain", Vector3(mono[9], mono[10], 0.0))
	material.set_shader_parameter("display_decode", QiyuController.runtime and QiyuController.page_decode)
	material.set_shader_parameter("display_gamma", QiyuController.DISPLAY_GAMMA)
	material.set_shader_parameter("display_dither", QiyuController.runtime and QiyuController.page_decode and QiyuController.linear_eye_buffer)
	material.set_shader_parameter("grade_gain", gain())
	material.set_shader_parameter("grade_gamma", Vector3(p.red_gamma, p.green_gamma, p.blue_gamma) * p.gamma)
	material.set_shader_parameter("grade_offset", Vector3(p.red_offset, p.green_offset, p.blue_offset))
	material.set_shader_parameter("grade_contrast", p.contrast)
	material.set_shader_parameter("grade_saturation", p.saturation)
