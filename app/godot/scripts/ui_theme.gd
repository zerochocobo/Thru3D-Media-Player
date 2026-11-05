extends RefCounted
## Application chrome and vector glyphs only. Never transform media or subtitle samples.
## Default entries preserve the original float expressions exactly.
class Events extends RefCounted:
	signal changed

const DEFAULT := "default"
const KEY := "color_theme"
const CUSTOM := "custom"
const CUSTOM_KEY := "custom_theme"
const EDIT_CUSTOM := "edit_custom_theme"
const Custom := preload("res://scripts/custom_palette.gd")
const OPTIONS := [
	{"value": "default", "label": "Obsidian black"},
	{"value": "pearl", "label": "Pearl"},
	{"value": "sand", "label": "Warm sand"},
	{"value": "jade", "label": "Jade mist"},
	{"value": "ocean", "label": "Deep ocean"},
	{"value": "dusk", "label": "Dusk violet"},
]
const ORIGINAL := {
	"panel": Color(0.065, 0.075, 0.095, 0.98), "tile": Color(0.105, 0.12, 0.15, 1.0),
	"accent": Color(0.54, 0.93, 0.77), "muted": Color(0.56, 0.62, 0.69),
	"text": Color(0.93, 0.95, 0.98), "label": Color.WHITE,
	"primary_ink": Color(0.045, 0.1, 0.085), "selected": Color(0.16, 0.31, 0.27),
	"hover": Color(0.23, 0.43, 0.38), "primary_hover": Color(0.67, 1.0, 0.86),
	"disabled": Color(0.085, 0.095, 0.115), "primary_disabled": Color(0.26, 0.44, 0.38),
	"disabled_ink": Color(0.56, 0.62, 0.69) * Color(0.7, 0.7, 0.7),
	"tooltip": Color(0.02, 0.025, 0.03, 0.92), "knob": Color.WHITE,
	"track": Color(0.3, 0.35, 0.4), "track_tick": Color(0.7, 0.74, 0.78),
	"divider": Color(0.17, 0.2, 0.24), "placeholder": Color(0.13, 0.15, 0.18),
	"preview_track": Color(0.22, 0.29, 0.30), "folder": Color(0.98, 0.78, 0.36),
	"provider_ink": Color(0.9, 0.9, 0.9), "active_ink": Color(0.75, 0.78, 0.80),
	"warning": Color(0.86, 0.74, 0.42, 0.9), "danger": Color(1.0, 0.45, 0.4),
	"danger_surface": Color(0.42, 0.1, 0.1, 0.9), "danger_hover": Color(0.55, 0.14, 0.14, 0.95),
	"record": Color(1.0, 0.30, 0.28), "muted_hover": Color(0.19, 0.22, 0.26),
	"editor_ink": Color(0.06, 0.18, 0.14), "account_editor_ink": Color(0.04, 0.10, 0.08),
	"inactive_scroll": Color(0.4, 0.45, 0.5), "swatch_ring": Color.WHITE,
	"swatch_check": Color("17232c"), "media_hover": Color(0.09, 0.17, 0.18),
	"outline": Color(0.72, 0.79, 0.82, 0.85), "hover_border": Color(0.38, 0.94, 0.73),
	"favorite": Color(1.0, 0.23, 0.30), "brand_ink": Color(0.87, 0.92, 0.94),
	"domain_ink": Color(0.66, 0.73, 0.78), "low_power": Color(1.0, 0.42, 0.38),
	"plugged": Color(1.0, 0.76, 0.36), "remove_surface": Color(0.24, 0.10, 0.12),
	"remove_ink": Color(1.0, 0.63, 0.63), "scene_check": Color(0.04, 0.1, 0.08),
	"music_danger": Color(1, 0.48, 0.46), "gesture_surface": Color(0.045, 0.075, 0.085),
	"gesture_ink": Color(0.90, 0.94, 0.98), "gesture_accent": Color(0.36, 0.88, 0.72),
	"gesture_target": Color(0.35, 0.48, 0.53), "pip_selected": Color(0.12, 0.25, 0.23),
	"pip_held": Color(1.0, 0.78, 0.35), "browser_feedback": Color("10141b"),
	"browser_rim": Color(0.02, 0.03, 0.04, 0.60), "browser_error": Color("ef8d80"),
	"browser_mark": Color(0.7, 0.85, 0.82), "browser_tab": Color("141a22"),
	"browser_tab_selected": Color("294b42"), "web_title": Color("f0f5fa"),
	"web_icon": Color("77bba9"), "web_input": Color("172535"),
	"web_search": Color("8fa4b8"), "web_input_ink": Color("dce9f2"),
	"web_hint": Color("91a4b7"), "web_resume": Color("d9e1eb"),
	"web_heading": Color("c7d5e3"), "web_arrow": Color("8da5b7"),
	"web_card": Color("15212e"), "web_card_hover": Color("253e4a"),
	"web_caption": Color("dbe6ef"), "web_supported": Color("70dfb6"),
	"seek_panel": Color(0.025, 0.035, 0.045, 0.78), "seek_track": Color(0.42, 0.47, 0.52, 0.85),
	"seek_origin": Color(0.75, 0.78, 0.82, 0.8), "hud_text": Color(0.9, 0.95, 0.97),
	"hud_outline": Color(0.015, 0.02, 0.03), "gauge_tick": Color(0.55, 0.62, 0.68, 0.85),
}

# Each scheme supplies every semantic family; ORIGINAL supplies alpha, never new-theme RGB.
const SCHEMES := {
	"pearl": {"light": true, "knob": "ffffff", "panel": "edf2f8", "tile": "dce5f1", "text": "182d48", "muted": "53667e",
		"accent": "285fc2", "on_accent": "ffffff", "selected": "c3d6f4", "hover": "cbdcf5",
		"accent_hover": "174caa", "disabled": "e1e7ef", "disabled_ink": "7b889a", "track": "9aaec7",
		"border": "9aaec7", "warning": "8a590b", "danger": "b33745", "danger_surface": "f1dce2", "folder": "976514"},
	"sand": {"light": true, "knob": "ffffff", "panel": "f3ece0", "tile": "e7ddcc", "text": "3d3329", "muted": "71614f",
		"accent": "9a4b30", "on_accent": "fff7ed", "selected": "e6c8b5", "hover": "ebd3c2",
		"accent_hover": "803a24", "disabled": "e9e1d6", "disabled_ink": "948878", "track": "b3a18c",
		"border": "b6a38c", "warning": "855915", "danger": "a82f3d", "danger_surface": "efdbd5", "folder": "916514"},
	"jade": {"light": true, "knob": "ffffff", "panel": "e8f1ed", "tile": "d3e4dc", "text": "203d36", "muted": "536e64",
		"accent": "186f58", "on_accent": "f4fff9", "selected": "b5d9ca", "hover": "bedfd1",
		"accent_hover": "105945", "disabled": "dce7e1", "disabled_ink": "81958b", "track": "93b3a4",
		"border": "91ad9f", "warning": "825b11", "danger": "ac354a", "danger_surface": "eddae0", "folder": "826417"},
	"ocean": {"light": false, "knob": "ffffff", "panel": "101e31", "tile": "1b304c", "text": "e6f1ff", "muted": "a1b8d4",
		"accent": "86d5ff", "on_accent": "0c2940", "selected": "294e71", "hover": "305b7d",
		"accent_hover": "b0e7ff", "disabled": "17253b", "disabled_ink": "687e9a", "track": "466483",
		"border": "57799b", "warning": "f5ce7a", "danger": "ff969e", "danger_surface": "522c40", "folder": "efc982"},
	"dusk": {"light": false, "knob": "ffffff", "panel": "241f31", "tile": "373047", "text": "f3edff", "muted": "bcb0cd",
		"accent": "d4b3ff", "on_accent": "33203f", "selected": "57426c", "hover": "604d77",
		"accent_hover": "e6cdff", "disabled": "302b3d", "disabled_ink": "81758f", "track": "6f5c83",
		"border": "8b759e", "warning": "f2cc8b", "danger": "ffa0ad", "danger_surface": "603345", "folder": "e5c58c"},
}
const FAMILIES := {
	"panel": ["panel", "tooltip", "gesture_surface", "browser_feedback"],
	"tile": ["tile", "placeholder", "web_input", "web_card", "browser_tab"],
	"text": ["text", "label", "provider_ink", "active_ink", "brand_ink", "gesture_ink", "web_title", "web_input_ink", "web_resume", "web_caption"],
	"muted": ["muted", "domain_ink", "inactive_scroll", "web_hint", "web_heading", "web_search", "web_arrow", "gesture_target"],
	"accent": ["accent", "gesture_accent", "browser_mark", "web_icon", "web_supported", "hover_border"],
	"knob": ["knob"],
	"on_accent": ["primary_ink", "editor_ink", "account_editor_ink", "swatch_check", "scene_check"],
	"selected": ["selected", "pip_selected", "browser_tab_selected"],
	"hover": ["hover", "media_hover", "muted_hover", "web_card_hover"],
	"accent_hover": ["primary_hover"], "disabled": ["disabled", "primary_disabled"],
	"disabled_ink": ["disabled_ink"], "track": ["track", "preview_track", "divider"],
	"border": ["track_tick", "outline", "swatch_ring"],
	# Playback overlays and webpage dimming have content semantics, independent of UI paper.
	"fixed": ["seek_panel", "seek_track", "seek_origin", "hud_text", "hud_outline", "gauge_tick", "browser_rim"],
	"warning": ["warning", "plugged", "pip_held"], "folder": ["folder"],
	"danger": ["danger", "record", "favorite", "low_power", "remove_ink", "music_danger", "browser_error"],
	"danger_surface": ["danger_surface", "danger_hover", "remove_surface"],
}

static var events := Events.new()
static var current := DEFAULT
static var revision := 0
static var _colors: Dictionary = ORIGINAL
static var custom_data: Dictionary = {}

static func normalize(value: Variant) -> String:
	return str(value) if value is String and (value in [DEFAULT, CUSTOM] or SCHEMES.has(value)) else DEFAULT

static func set_custom(value: Variant) -> bool:
	var data := Custom.normalize(value)
	if data == custom_data: return false
	custom_data = data
	if current == CUSTOM:
		_colors = palette(CUSTOM); revision += 1; events.changed.emit()
	return true

static func custom_seeds(data: Dictionary) -> Dictionary:
	return {"background": Color(ORIGINAL.panel, 1), "accent": ORIGINAL.accent, "text": "auto"} if data.is_empty() else data.duplicate(true)

static func custom_palette(data: Dictionary) -> Dictionary:
	if data.is_empty(): return ORIGINAL.duplicate()
	return _from_scheme(Custom.make(data))

static func save_custom(settings: ConfigFile, value: Variant) -> void:
	set_custom(value)
	settings.set_value("ui", CUSTOM_KEY, custom_data.duplicate(true))
	save_choice(settings, CUSTOM)

static func use(value: Variant) -> bool:
	var id := normalize(value)
	if current == id: return false
	current = id
	_colors = ORIGINAL if id == DEFAULT else palette(id)
	revision += 1
	events.changed.emit()
	return true

static func palette(value: Variant) -> Dictionary:
	var id := normalize(value)
	var result := ORIGINAL.duplicate()
	if id == DEFAULT: return result
	if id == CUSTOM: return custom_palette(custom_data)
	return _from_scheme(SCHEMES[id])

static func _from_scheme(scheme: Dictionary) -> Dictionary:
	var result := ORIGINAL.duplicate()
	for family in FAMILIES:
		if family == "fixed": continue
		var tone: Color = scheme[family] if scheme[family] is Color else Color(str(scheme[family]))
		for role in FAMILIES[family]: result[role] = Color(tone, ORIGINAL[role].a)
	# Preset swatches include white; their check must stay dark on the sample itself.
	result.swatch_check = ORIGINAL.swatch_check
	result.outline = Color(scheme.muted if scheme.muted is Color else Color(str(scheme.muted)), ORIGINAL.outline.a)
	return result

static func color(role: String) -> Color:
	assert(_colors.has(role), "Unknown UI theme role: " + role)
	return _colors.get(role, Color.MAGENTA)

static func load_choice(settings: ConfigFile) -> String:
	set_custom(settings.get_value("ui", CUSTOM_KEY, {}))
	return normalize(settings.get_value("ui", KEY, DEFAULT))

static func save_choice(settings: ConfigFile, value: Variant) -> String:
	var id := normalize(value)
	settings.set_value("ui", KEY, id)
	use(id)
	return id

static func row(value: Variant) -> Dictionary:
	var options := OPTIONS.duplicate(true)
	options.append({"value": CUSTOM, "label": "Custom theme"})
	for option in options:
		var colors := palette(option.value)
		option["swatch"] = Color(colors.panel, 1.0)
		option["swatch_accent"] = Color(colors.accent, 1.0)
	return {"title": "Color theme", "key": KEY, "value": normalize(value), "swatches": true, "choices": options,
		"edit": {"key": EDIT_CUSTOM, "label": "Customize"}}

static func swatch_ink(sample: Color) -> Color:
	return ORIGINAL.swatch_check if _contrast(ORIGINAL.swatch_check, sample) >= _contrast(Color.WHITE, sample) else Color.WHITE

static func light() -> bool:
	if current == CUSTOM: return not custom_data.is_empty() and Custom.luminance(custom_data.background) >= 0.179
	return bool(SCHEMES.get(current, {}).get("light", false))

static func original() -> bool:
	return current == DEFAULT or (current == CUSTOM and custom_data.is_empty())

static func slider_outline() -> Color:
	if current == CUSTOM: return ORIGINAL.swatch_check
	return color("text") if light() else color("primary_ink")

static func playback_color(role: String) -> Color:
	# The original HUD had mint fill and thumb. Preserve it exactly; new themes
	# get a white thumb on the same subdued dark playback HUD.
	if role == "knob": return ORIGINAL.accent if original() else ORIGINAL.knob
	return ORIGINAL.accent if role == "accent" else color(role)

static func site_icon_color(icon: String, source: Color) -> Color:
	if current == CUSTOM and not custom_data.is_empty():
		if icon in ["site_appletv", "site_niconico"]: return color("text")
		var surfaces: Array = []
		for role in ["web_card", "web_card_hover", "tile", "hover", "selected"]: surfaces.append(color(role))
		return Color(Custom.fit(source, surfaces, Color.BLACK if light() else Color.WHITE, 3.0), source.a)
	if not light(): return source
	if icon in ["site_appletv", "site_niconico"]: return color("text")
	# Graphics need 3:1. Keep already readable brand colors exactly, otherwise
	# find the smallest hue-preserving darkening across every card state.
	if _site_icon_readable(source): return source
	var lower := 0.0; var upper := 1.0
	for step in 12:
		var brightness := (lower + upper) * 0.5
		if _site_icon_readable(source.darkened(1.0 - brightness)): lower = brightness
		else: upper = brightness
	return source.darkened(1.0 - lower)

static func _site_icon_readable(ink: Color) -> bool:
	for role in ["web_card", "web_card_hover", "tile", "hover", "selected"]:
		if _contrast(ink, color(role)) < 3.0: return false
	return true

static func _contrast(first: Color, second: Color) -> float:
	var a := first.srgb_to_linear(); var b := second.srgb_to_linear()
	var left := a.r * 0.2126 + a.g * 0.7152 + a.b * 0.0722
	var right := b.r * 0.2126 + b.g * 0.7152 + b.b * 0.0722
	return (maxf(left, right) + 0.05) / (minf(left, right) + 0.05)
