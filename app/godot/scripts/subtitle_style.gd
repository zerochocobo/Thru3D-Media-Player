extends RefCounted
## Shared appearance for flat labels, projected patches and settings previews.
const DEFAULT := "white_black"
const LINE_CHOICES := [{"value": 0, "label": "All"}, {"value": 1, "label": "First line"}, {"value": 2, "label": "Second line"}]
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
		"slider": true, "span": Vector3(50, 200, 5), "unit": "%", "reset_value": 100.0}

static func style_row(value: Variant) -> Dictionary:
	return {"key": "subtitle_style", "value": normalize(value), "choices": PRESETS, "compact": true}

static func normalize_line(value: Variant) -> int:
	return int(value) if (value is int or value is float) and value in [0, 1, 2] else 0

static func line_row(value: Variant) -> Dictionary:
	return {"key": "subtitle_line", "value": normalize_line(value), "choices": LINE_CHOICES, "compact": true}

static func display_text(text: String, line: int) -> String:
	if normalize_line(line) == 0: return text
	# Use authored, nonblank lines, before the renderer wraps or rotates the text.
	var lines: Array[String] = []
	for part in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		if not part.strip_edges().is_empty(): lines.append(part)
	# A one-line cue must remain readable even when the second line is selected.
	return lines[line - 1] if lines.size() >= line else text
