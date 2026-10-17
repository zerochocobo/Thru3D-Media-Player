extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const I18n := preload("res://scripts/i18n.gd")
# Temporarily withheld from the emergency patch until player integration is validated.
const FEATURE_ENABLED := false
const VOICES := {"zh": ["Yuewen", "Junhao"], "en": ["Ava", "Adam"]}
var video: Node
var enabled := false
var source := -1
var language := "auto"
var zh_voice := "Yuewen"
var en_voice := "Ava"
var duck := 75.0
var volume := 100.0
var rate := 1.0
var offset := 0.0
var retry := 0
var preview := 0
var _last_payload := ""
var _language_source := ""

func _init(owner: Node) -> void: video = owner

func load_settings(settings: ConfigFile) -> void:
	enabled = FEATURE_ENABLED and bool(settings.get_value("narration", "enabled", false))
	zh_voice = str(settings.get_value("narration", "zh_voice", "Yuewen"))
	en_voice = str(settings.get_value("narration", "en_voice", "Ava"))
	if zh_voice not in VOICES.zh: zh_voice = "Yuewen"
	if en_voice not in VOICES.en: en_voice = "Ava"
	for key in ["duck", "volume", "rate", "offset"]: set_option("narration_" + key, settings.get_value("narration", key, get(key)))

func save(settings: ConfigFile) -> void:
	for key in ["enabled", "zh_voice", "en_voice", "duck", "volume", "rate", "offset"]:
		settings.set_value("narration", key, get(key))

func reset_source() -> void:
	source = -1; language = "auto"; _last_payload = ""; _language_source = ""

func available() -> bool:
	return FEATURE_ENABLED and Methods.supports(video.platform, "set_mpv_narration")

func set_option(key: String, value: Variant) -> bool:
	if not FEATURE_ENABLED: return false
	match key:
		"narration_enabled": enabled = bool(value)
		"narration_current": enabled = bool(value); source = -1; language = "auto"
		"narration_source": source = maxi(-1, int(value)); language = "auto"
		"narration_language":
			if str(value) not in ["auto", "zh", "en"]: return false
			language = str(value); _language_source = ""
		"narration_voice":
			var lang := resolved_language()
			if lang not in VOICES or str(value) not in VOICES[lang]: return false
			if lang == "zh": zh_voice = str(value)
			else: en_voice = str(value)
		"narration_duck", "narration_volume", "narration_rate", "narration_offset":
			if not (value is float or value is int) or not is_finite(float(value)): return false
			var field := key.trim_prefix("narration_")
			var limits := Vector2(0, 100) if field in ["duck", "volume"] else (Vector2(0.8, 1.3) if field == "rate" else Vector2(-2, 2))
			set(field, clampf(float(value), limits.x, limits.y))
		"narration_retry": retry += 1
		"narration_preview": preview += 1
		_: return false
	apply(); video.changed.emit(); return true

func selected_track() -> Dictionary:
	var id: int = video.subtitles.requested_track if source < 0 else source
	if id < 0: id = int(video.media.playback.get("details", {}).get("subtitle", {}).get("track_id", 0))
	for track in video.subtitle_tracks():
		if int(track.id) == id: return track
	return {}

func resolved_language() -> String:
	if language != "auto": return language
	var tag := str(selected_track().get("language", "")).replace("_", "-").to_lower().split("-")[0]
	if tag in ["zh", "zho", "chi", "cmn", "chs", "cht"]: return "zh"
	if tag in ["en", "eng"]: return "en"
	return ""

func apply() -> void:
	if not FEATURE_ENABLED: return
	if video.media.session_id <= 0 or (not enabled and _last_payload.is_empty()): return
	var track := selected_track()
	var identity := str(source) + ":" + str(track.get("id", source if source >= 0 else video.subtitles.requested_track))
	if not _language_source.is_empty() and identity != _language_source: language = "auto"
	_language_source = identity
	if not available() or video.media.session_id <= 0 or (not enabled and _last_payload.is_empty()): return
	var payload := {"enabled": enabled, "source": source, "language": language, "zh_voice": zh_voice, "en_voice": en_voice,
		"duck": duck / 100.0, "volume": volume / 100.0, "rate": rate, "offset": offset, "retry": retry, "preview": preview}
	if source >= 0:
		payload.source_delay = video.subtitle_timing.for_track(video.local_uri, Timing.track_key(selected_track()))
	var json := JSON.stringify(payload)
	var key := str(video.media.session_id) + ":" + json
	if key != _last_payload and video.platform.set_mpv_narration(video.media.session_id, json): _last_payload = key

func snapshot() -> Dictionary:
	if not FEATURE_ENABLED: return {"narration_available": false, "narration_enabled": false, "narration_current": false}
	var lang := resolved_language()
	var options: Array = [{"value": -1, "label": "Follow current subtitles"}]
	for track in video.subtitle_tracks():
		if not video.SubtitleState.text_codec(str(track.get("codec", ""))): continue
		var title := str(track.get("title", "")).strip_edges()
		if title.is_empty(): title = I18n.t("Subtitles") + " %d" % int(track.id)
		options.append({"value": int(track.id), "label": title})
	return {"narration_available": available(), "narration_enabled": enabled, "narration_current": enabled and source == -1,
		"narration_source": source, "narration_sources": options, "narration_language": language,
		"narration_resolved_language": lang, "narration_voice": zh_voice if lang == "zh" else en_voice,
		"narration_duck": duck, "narration_volume": volume, "narration_rate": rate, "narration_offset": offset,
		"narration_status": video.media.playback.get("narration", {}).get("state", "off")}

static func toggle(key: String, value: bool) -> Dictionary:
	return {"key": key, "value": value, "choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}

static func rows(state: Dictionary, more: bool = false) -> Array:
	if not FEATURE_ENABLED: return []
	var result: Array = [{"title": "Subtitle narration", "field": toggle("narration_enabled", bool(state.get("narration_enabled", false)))}]
	if not state.get("narration_enabled", false): return result
	result.append({"title": "Read subtitles", "field": {"key": "narration_source", "value": state.get("narration_source", -1), "choices": state.get("narration_sources", [])}})
	var lang := str(state.get("narration_resolved_language", ""))
	var automatic := I18n.t("Auto") + " · " + I18n.t("Chinese" if lang == "zh" else "English") if not lang.is_empty() else I18n.t("Choose language")
	result.append({"title": "Reading language", "field": {"key": "narration_language", "value": state.get("narration_language", "auto"),
		"display_value": I18n.t("Choose language"), "choices": [{"value": "auto", "label": automatic}, {"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}]}})
	if not lang.is_empty():
		var voices: Array = VOICES.get(lang, [])
		result.append({"title": "Voice", "field": {"key": "narration_voice", "value": state.get("narration_voice", voices[0]), "choices": [
			{"value": voices[0], "label": I18n.t("Female") + " · " + voices[0]}, {"value": voices[1], "label": I18n.t("Male") + " · " + voices[1]}]}})
	result.append({"title": "Lower original audio", "field": {"key": "narration_duck", "value": state.get("narration_duck", 75.0), "slider": true, "span": Vector3(0, 100, 5), "unit": "%"}})
	if more:
		for field in [{"key": "volume", "title": "Narration volume", "span": Vector3(0, 100, 5), "unit": "%"},
			{"key": "rate", "title": "Reading speed", "span": Vector3(0.8, 1.3, 0.1), "unit": "×"},
			{"key": "offset", "title": "Narration sync", "span": Vector3(-2, 2, 0.1), "unit": " s"}]:
			result.append({"title": field.title, "field": {"key": "narration_" + field.key, "value": state.get("narration_" + field.key, 1.0 if field.key == "rate" else (100.0 if field.key == "volume" else 0.0)), "slider": true, "span": field.span, "unit": field.unit}})
	return result

static func status_label(code: String) -> String:
	if not FEATURE_ENABLED: return ""
	return {"loading": "Preparing narration…", "model_missing": "Narration model not installed", "model_error": "Unable to load narration model", "subtitle_required": "Choose subtitles", "language_required": "Choose language", "unsupported_subtitle": "Text subtitles required", "timeline_error": "Unable to prepare subtitles", "speech_error": "Unable to read subtitle"}.get(code, "")
