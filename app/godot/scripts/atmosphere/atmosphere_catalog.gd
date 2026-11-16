extends RefCounted
## Atmosphere themes: a set of particle layers with a matching field recording. One theme at a
## time. Everything is drawn by shaders/atmosphere_particles.gdshader; there are no textures.
const DOT := 0
const STREAK := 1
const LEAF := 2
const PETAL := 3
const BUBBLE := 4
## Viewer's choice of how much falls: fewer, standard, more.
const AMOUNTS := [0.5, 1.0, 1.6]
const DEFAULT_AMOUNT := 1
## Adreno 6xx headsets (Quest 2, PICO Neo3) draw half of every layer.
const LOW_END_SCALE := 0.5
const SOUND_GAIN_DB := -12.0

## Layer fields mirror the shader's uniforms; `lift` moves the box's centre above the head.
const THEMES := [
	{"id": "rain", "label": "Rain", "icon": "rain", "sound": "gentle_rain", "layers": [
		{"count": 700, "shape": STREAK, "size": Vector2(0.009, 0.36), "spread": 0.45, "box": Vector3(8, 6, 8),
			"velocity": Vector3(0.7, -7.5, 0.25), "tint_a": Color(0.78, 0.86, 1.0, 0.40), "tint_b": Color(0.92, 0.96, 1.0, 0.55)}]},
	{"id": "snow", "label": "Snow", "icon": "snow", "sound": "forest_wind", "gain_db": -18.0, "layers": [
		{"count": 520, "shape": DOT, "size": Vector2(0.050, 0.050), "spread": 0.5, "box": Vector3(8, 5, 8),
			"velocity": Vector3(0.18, -0.60, 0.06), "sway": Vector3(0.28, 0.0, 0.28), "sway_rate": 0.8,
			"tint_a": Color(1, 1, 1, 0.80), "tint_b": Color(0.90, 0.95, 1.0, 0.60)},
		{"count": 180, "shape": DOT, "size": Vector2(0.090, 0.090), "spread": 0.35, "box": Vector3(7, 5, 7),
			"velocity": Vector3(0.12, -0.42, 0.04), "sway": Vector3(0.35, 0.0, 0.35), "sway_rate": 0.6,
			"tint_a": Color(1, 1, 1, 0.55), "tint_b": Color(1, 1, 1, 0.40)}]},
	{"id": "leaves", "label": "Falling leaves", "icon": "leaf", "sound": "forest_wind", "layers": [
		{"count": 160, "shape": LEAF, "size": Vector2(0.090, 0.140), "spread": 0.4, "box": Vector3(7, 5, 7),
			"velocity": Vector3(0.30, -0.55, 0.12), "sway": Vector3(0.40, 0.05, 0.40), "sway_rate": 0.7, "tumble": 2.2,
			"tint_a": Color(0.86, 0.33, 0.08, 0.95), "tint_b": Color(0.95, 0.72, 0.16, 0.95)}]},
	{"id": "petals", "label": "Petals", "icon": "petal", "sound": "mountain_stream", "gain_db": -16.0, "layers": [
		{"count": 260, "shape": PETAL, "size": Vector2(0.060, 0.075), "spread": 0.35, "box": Vector3(7, 5, 7),
			"velocity": Vector3(0.22, -0.32, 0.08), "sway": Vector3(0.32, 0.06, 0.32), "sway_rate": 0.6, "tumble": 1.6,
			"tint_a": Color(1.0, 0.62, 0.74, 0.92), "tint_b": Color(1.0, 0.86, 0.90, 0.92)}]},
	{"id": "fireflies", "label": "Fireflies", "icon": "firefly", "sound": "summer_night", "layers": [
		{"count": 150, "shape": DOT, "size": Vector2(0.150, 0.150), "spread": 0.3, "box": Vector3(7, 2.8, 7), "lift": -0.25,
			"velocity": Vector3(0.02, 0.0, 0.015), "sway": Vector3(0.9, 0.35, 0.9), "sway_rate": 0.25, "pulse": 1.3, "glow": 0.8,
			"tint_a": Color(0.80, 1.0, 0.30, 1.0), "tint_b": Color(1.0, 0.92, 0.35, 1.0)}]},
	{"id": "underwater", "label": "Underwater", "icon": "bubbles", "sound": "ocean_waves", "lowpass_hz": 520.0, "layers": [
		{"count": 260, "shape": BUBBLE, "size": Vector2(0.075, 0.075), "spread": 0.75, "box": Vector3(7, 5, 7),
			"velocity": Vector3(0.0, 0.45, 0.0), "sway": Vector3(0.06, 0.0, 0.06), "sway_rate": 2.0,
			"tint_a": Color(0.80, 0.95, 1.0, 0.70), "tint_b": Color(0.95, 1.0, 1.0, 0.90)},
		{"count": 300, "shape": DOT, "size": Vector2(0.024, 0.024), "spread": 0.5, "box": Vector3(6, 4, 6),
			"velocity": Vector3(0.03, 0.02, 0.01), "sway": Vector3(0.15, 0.10, 0.15), "sway_rate": 0.3, "glow": 0.5,
			"tint_a": Color(0.55, 0.85, 1.0, 0.45), "tint_b": Color(0.80, 1.0, 0.95, 0.60)}]},
]

static func ids() -> Array:
	return THEMES.map(func(row): return row.id)

static func theme(id: String) -> Dictionary:
	for row in THEMES:
		if row.id == id: return row
	return {}

## "" is the off choice; anything unknown is off too.
static func clean(id: Variant) -> String:
	return str(id) if id is String and not theme(str(id)).is_empty() else ""

static func clean_amount(value: Variant) -> int:
	return clampi(int(value), 0, AMOUNTS.size() - 1) if value is int or value is float else DEFAULT_AMOUNT

static func instances(layer: Dictionary, amount: int, low_end: bool) -> int:
	return maxi(1, roundi(int(layer.count) * float(AMOUNTS[clean_amount(amount)]) * (LOW_END_SCALE if low_end else 1.0)))

static func sound_path(row: Dictionary) -> String:
	return "res://assets/audio/%s.ogg" % row.sound if not str(row.get("sound", "")).is_empty() else ""
