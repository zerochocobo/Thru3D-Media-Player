extends RefCounted
const Narration := preload("res://scripts/narration_settings.gd")
const Memory := preload("res://scripts/file_narration_memory.gd")
const SECTION := "comic_reading"
var enabled := false
var language := "auto"
var voice_kind := "preset"
var voice := "Xiaoyu"
var custom_voice := ""
var volume := 100.0
var duck := 75.0

func load_settings(settings: ConfigFile) -> void:
	var source := SECTION if settings.has_section(SECTION) else "narration"
	# One-time migration of applicable preferences; subtitle timing/track/visibility never migrate.
	voice_kind = str(settings.get_value(source, "voice_kind", "preset"))
	custom_voice = str(settings.get_value(source, "custom_voice", ""))
	var default_lang := Narration.default_profile(Narration.I18n.language).get_slice("_", 0)
	var origin := str(settings.get_value(source, "voice_origin", default_lang))
	if not Narration.VOICES.has(origin): origin = default_lang
	voice = str(settings.get_value(source, "voice" if source == SECTION else "voice_id", settings.get_value(source, origin + "_voice", Narration.VOICES[origin][0])))
	if voice.is_empty(): voice = Narration.VOICES[origin][0]
	language = str(settings.get_value(source, "language", "auto"))
	if language not in ["auto", "zh", "en", "ja"]: language = "auto"
	if voice_kind not in ["preset", "custom"]: voice_kind = "preset"
	if not Memory.valid_custom_voice(custom_voice): custom_voice = ""
	if not valid_preset(voice): voice = Narration.VOICES[default_lang][0]
	volume = number(settings.get_value(source, "volume", 100), 100)
	duck = number(settings.get_value(source, "duck", 75), 75)
	# Activation belongs to the open reading batch, never to saved preferences.
	enabled = false

static func number(value: Variant, fallback: float) -> float:
	return clampf(float(value), 0, 100) if (value is float or value is int) and is_finite(float(value)) else fallback

static func valid_preset(value: String) -> bool:
	for voices: Array in Narration.VOICES.values():
		if value in voices: return true
	return false

func selected_voice() -> String: return custom_voice if voice_kind == "custom" else voice

func set_option(key: String, value: Variant, catalog: Array = []) -> bool:
	if value is Dictionary: value = value.get("value")
	match key:
		"comic_enabled": enabled = value == true
		"comic_language":
			if str(value) not in ["auto", "zh", "en", "ja"]: return false
			language = str(value)
		"comic_voice_kind":
			if str(value) not in ["preset", "custom"]: return false
			voice_kind = str(value)
			if voice_kind == "custom" and not catalog.is_empty() and not catalog.any(func(item): return item.get("id") == custom_voice):
				for item: Dictionary in catalog:
					if Memory.valid_custom_voice(str(item.get("id", ""))): custom_voice = item.id; break
		"comic_voice":
			if not valid_preset(str(value)): return false
			voice = str(value); voice_kind = "preset"
		"comic_custom_voice":
			if not Memory.valid_custom_voice(str(value)): return false
			custom_voice = str(value); voice_kind = "custom"
		"comic_volume", "comic_duck":
			if not (value is float or value is int) or not is_finite(float(value)): return false
			set(key.trim_prefix("comic_"), clampf(float(value), 0, 100))
		_: return false
	return true

func save(settings: ConfigFile) -> void:
	if settings.has_section_key(SECTION, "enabled"): settings.erase_section_key(SECTION, "enabled")
	for key in ["language", "voice_kind", "voice", "custom_voice", "volume", "duck"]:
		settings.set_value(SECTION, key, get(key))

func snapshot(catalog: Array) -> Dictionary:
	return {"comic_enabled": enabled, "comic_language": language, "comic_voice_kind": voice_kind,
		"comic_voice": voice, "comic_custom_voice": custom_voice, "comic_volume": volume, "comic_duck": duck,
		"comic_personal_voices": catalog}

static func rows(state: Dictionary) -> Array:
	var result := [{"title": "Comic reading (Beta)", "field": Narration.toggle("comic_enabled", state.get("comic_enabled", false))},
		{"title": "Reading language", "field": {"key": "comic_language", "value": state.get("comic_language", "auto"), "choices": [
			{"value": "auto", "label": "Automatic"}, {"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}, {"value": "ja", "label": "Japanese"}]}}]
	var shared := {"narration_enabled": true, "narration_voice_kind": state.get("comic_voice_kind", "preset"),
		"narration_voice": state.get("comic_voice", "Xiaoyu"), "narration_custom_voice": state.get("comic_custom_voice", ""),
		"narration_personal_voices": state.get("comic_personal_voices", []), "narration_volume": state.get("comic_volume", 100), "narration_duck": state.get("comic_duck", 75)}
	for item: Dictionary in Narration.rows(shared):
		# Background music ducking remains automatic; it is not a reading control.
		if item.field.key not in ["narration_voice_kind", "narration_voice", "narration_custom_voice", "narration_volume"]: continue
		item = item.duplicate(true); item.field.key = str(item.field.key).replace("narration_", "comic_")
		item.field.erase("source_uri")
		result.append(item)
	return result
