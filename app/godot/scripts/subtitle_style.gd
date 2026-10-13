extends RefCounted
## Shared appearance for flat labels, projected patches and settings previews.
const DEFAULT := "white_black"
const PRESETS := [
	{"value": "white_black", "label": "Subtitle sample", "hint": "White / black outline", "text_color": Color.WHITE, "outline_color": Color.BLACK},
	{"value": "yellow_black", "label": "Subtitle sample", "hint": "Yellow / black outline", "text_color": Color("ffe066"), "outline_color": Color.BLACK},
	{"value": "cyan_black", "label": "Subtitle sample", "hint": "Cyan / black outline", "text_color": Color("80eaff"), "outline_color": Color.BLACK},
	{"value": "green_black", "label": "Subtitle sample", "hint": "Green / black outline", "text_color": Color("a7f08b"), "outline_color": Color.BLACK},
	{"value": "black_white", "label": "Subtitle sample", "hint": "Black / white outline", "text_color": Color("171b22"), "outline_color": Color.WHITE}]

static func normalize(value: Variant) -> String:
	if not value is String: return DEFAULT
	for preset in PRESETS:
		if value == preset.value: return preset.value
	return DEFAULT

static func colors(value: Variant) -> Dictionary:
	var id := normalize(value)
	for preset in PRESETS:
		if preset.value == id: return preset
	return PRESETS[0]

static func size_ratio(value: float) -> float:
	return clampf(value, 0.5, 2.0) if is_finite(value) else 1.0

static func size_row(percent: float) -> Dictionary:
	return {"key": "subtitle_size", "value": size_ratio(percent / 100.0) * 100.0,
		"slider": true, "span": Vector3(50, 200, 5), "unit": "%"}

static func style_row(value: Variant) -> Dictionary:
	return {"key": "subtitle_style", "value": normalize(value), "choices": PRESETS, "compact": true}
