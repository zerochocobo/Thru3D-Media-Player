extends RefCounted
## Nominal screen envelopes; fit the source aspect without stretching or cropping.
## TV diagonals assume 16:9. Giant screens use a 1.43:1 envelope, not IMAX certification.
const ITEMS := [
	{"id": "tv100", "title": "100-inch TV", "size": Vector2(2.213802, 1.245264), "distance": 3.05, "eye_level": 0.5, "detail": "100\" · 3.05 m"},
	{"id": "home150", "title": "Home cinema", "size": Vector2(3.320703, 1.867896), "distance": 4.6, "eye_level": 0.5, "detail": "150\" · 4.6 m"},
	{"id": "giant22", "title": "Giant screen", "size": Vector2(22, 22.0 / 1.43), "distance": 18.0, "eye_level": 1.0 / 3.0, "detail": "22 m · 18 m"},
	{"id": "giant32", "title": "Grand screen", "size": Vector2(32, 32.0 / 1.43), "distance": 24.0, "eye_level": 1.0 / 3.0, "detail": "32 m · 24 m"},
]

static func find(id: String) -> Dictionary:
	for item in ITEMS:
		if item.id == id: return item
	return {}

static func scale_for(id: String, base: Vector2) -> float:
	var item := find(id)
	if item.is_empty() or base.x <= 0 or base.y <= 0: return 1.0
	return minf(item.size.x / base.x, item.size.y / base.y)

## Preserve useful precision for TV distances and sizes while allowing theatre-scale values.
static func slider_fraction(value: float, span: Vector3) -> float:
	return clampf(log(maxf(value, span.x) / span.x) / log(span.y / span.x), 0.0, 1.0)

static func slider_value(fraction: float, span: Vector3) -> float:
	return clampf(snappedf(span.x * pow(span.y / span.x, clampf(fraction, 0, 1)), span.z), span.x, span.y)
