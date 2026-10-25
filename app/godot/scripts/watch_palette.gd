extends RefCounted
## One hue for the dial, projection and controls. IDs are persisted in watch/color.
const DEFAULT := "mint"
const OPTIONS := [
	{"value": "mint", "label": "Mint", "swatch": Color("8aedc4")},
	{"value": "blue", "label": "Sky blue", "swatch": Color("78caff")},
	{"value": "violet", "label": "Violet", "swatch": Color("c4a0ff")},
	{"value": "amber", "label": "Amber", "swatch": Color("ffd080")},
	{"value": "white", "label": "White", "swatch": Color("edf2f7")},
]

static func normalize(value: Variant) -> String:
	for option in OPTIONS:
		if option.value == value: return option.value
	return DEFAULT

static func color(value: Variant) -> Color:
	var id := normalize(value)
	for option in OPTIONS:
		if option.value == id: return option.swatch
	return OPTIONS[0].swatch

static func load_choice(settings: ConfigFile) -> String:
	return normalize(settings.get_value("watch", "color", DEFAULT))

static func row(value: Variant) -> Dictionary:
	return {"title": "Watch color", "key": "watch_color", "value": normalize(value),
		"choices": OPTIONS, "swatches": true}
