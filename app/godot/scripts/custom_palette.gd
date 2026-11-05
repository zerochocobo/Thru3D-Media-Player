extends RefCounted
## Generate a complete family of UI colors from user seeds. No media colors or alpha.

static func _color(value: Variant) -> Variant:
	var result: Color
	if value is Color: result = value
	elif value is String and Color.html_is_valid(value): result = Color(value)
	else: return null
	if not is_finite(result.r) or not is_finite(result.g) or not is_finite(result.b): return null
	return Color(clampf(result.r, 0, 1), clampf(result.g, 0, 1), clampf(result.b, 0, 1), 1)

static func normalize(value: Variant) -> Dictionary:
	if not value is Dictionary or value.is_empty(): return {}
	var background: Variant = _color(value.get("background"))
	var accent: Variant = _color(value.get("accent"))
	var raw_text: Variant = value.get("text", "auto")
	var text: Variant = "auto" if raw_text is String and raw_text == "auto" else _color(raw_text)
	if background == null or accent == null or text == null: return {}
	return {"background": background, "accent": accent, "text": text}

static func luminance(tone: Color) -> float:
	var linear := tone.srgb_to_linear()
	return linear.r * 0.2126 + linear.g * 0.7152 + linear.b * 0.0722

static func contrast(a: Color, b: Color) -> float:
	var left := luminance(a); var right := luminance(b)
	return (maxf(left, right) + 0.05) / (minf(left, right) + 0.05)

static func minimum(ink: Color, surfaces: Array) -> float:
	var result := INF
	for surface in surfaces: result = minf(result, contrast(ink, surface))
	return result

static func fit(ink: Color, surfaces: Array, endpoint: Color, ratio: float) -> Color:
	if minimum(ink, surfaces) >= ratio: return ink
	var low := 0.0; var high := 1.0
	for step in 16:
		var amount := (low + high) * 0.5
		if minimum(ink.lerp(endpoint, amount), surfaces) >= ratio: high = amount
		else: low = amount
	return ink.lerp(endpoint, high)

static func make(data: Dictionary) -> Dictionary:
	var panel: Color = data.background
	var light := luminance(panel) >= 0.179
	var endpoint := Color.BLACK if light else Color.WHITE
	var paper := Color.WHITE if light else Color.BLACK
	# Keep every state on the same readable side of the light/dark boundary.
	var tile := fit(panel.lerp(endpoint, 0.055), [endpoint], paper, 4.5)
	var hover := fit(panel.lerp(endpoint, 0.10), [endpoint], paper, 4.5)
	# State surfaces depend on accent hue, not its corrected brightness. Choosing
	# a suggested accent must not move the contrast boundary underneath itself.
	var tint := Color.from_hsv(data.accent.h, 0.45 if data.accent.s > 0.01 else 0.0, 0.45 if light else 0.85)
	var selected := fit(panel.lerp(tint, 0.16), [endpoint], paper, 4.5)
	var danger_surface := fit(panel.lerp(Color("c24152"), 0.16), [endpoint], paper, 4.5)
	var surfaces := [panel, tile, hover, selected, danger_surface]
	var seed: Color = Color("18232c") if light else Color("eef4fa")
	var text: Color = fit(seed if data.text is String else data.text, surfaces, endpoint, 4.5)
	var muted := fit(panel.lerp(text, 0.58), surfaces, endpoint, 4.5)
	# The shared accent also colors navigation labels, so it needs text contrast.
	var accent := fit(data.accent, surfaces, endpoint, 4.51)
	var on_accent := Color.BLACK if contrast(Color.BLACK, accent) >= contrast(Color.WHITE, accent) else Color.WHITE
	var accent_hover := fit(accent.lerp(endpoint, 0.14), surfaces, endpoint, 4.51)
	if contrast(on_accent, accent_hover) < 4.5: accent_hover = accent
	return {"light": light, "panel": panel, "tile": tile, "text": text, "muted": muted,
		"accent": accent, "on_accent": on_accent, "knob": Color.WHITE, "selected": selected,
		"hover": hover, "accent_hover": accent_hover, "disabled": panel.lerp(tile, 0.5),
		"disabled_ink": panel.lerp(text, 0.50), "track": panel.lerp(text, 0.35),
		"border": fit(panel.lerp(text, 0.40), surfaces, endpoint, 3.0),
		"warning": fit(Color("d8a946"), surfaces, endpoint, 4.5),
		"danger": fit(Color("e65b69"), surfaces, endpoint, 4.5),
		"danger_surface": danger_surface,
		"folder": fit(Color("dcb653"), surfaces, endpoint, 3.0)}

static func accents(background: Color) -> Array[Color]:
	var result: Array[Color] = []
	for shift in [0.0, 0.10, -0.10, 0.5, 0.33, -0.33]:
		var seed := Color.from_hsv(fposmod(background.h + shift, 1.0), 0.52, 0.85)
		result.append(make({"background": background, "accent": seed, "text": "auto"}).accent)
	return result

static func texts(data: Dictionary) -> Array[Color]:
	var scheme := make(data)
	var endpoint := Color.BLACK if scheme.light else Color.WHITE
	var surfaces := [scheme.panel, scheme.tile, scheme.hover, scheme.selected, scheme.danger_surface]
	var result: Array[Color] = []
	for hue in [data.background.h, 0.60, 0.12, 0.90]:
		result.append(fit(Color.from_hsv(hue, 0.28, 0.20 if scheme.light else 0.96), surfaces, endpoint, 4.5))
	return result
