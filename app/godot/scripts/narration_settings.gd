extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const I18n := preload("res://scripts/i18n.gd")
const Memory := preload("res://scripts/file_narration_memory.gd")
var memory := Memory.new()
var _defaults := {}
# Available in normal Debug and Release; text subtitle selection controls visibility.
static var FEATURE_ENABLED := true
const VOICES := {"zh": ["Xiaoyu", "Yuewen", "Lingyu", "Zhiming", "Junhao"], "en": ["Ava", "Bella", "Adam"], "ja": ["Mei", "Saki", "Mortis", "Umiri"]}
const VOICE_INFO := {"Xiaoyu": ["Female", 1], "Yuewen": ["Female", 2], "Lingyu": ["Female", 3], "Zhiming": ["Male", 1], "Junhao": ["Male", 2], "Ava": ["Female", 1], "Bella": ["Female", 2], "Adam": ["Male", 1], "Mei": ["Female", 1], "Saki": ["Female", 2], "Mortis": ["Female", 3], "Umiri": ["Neutral", 1]}
const LEGACY_VOICES := {"zh_female": "Xiaoyu", "zh_male": "Zhiming", "en_female": "Ava", "en_male": "Adam", "ja_female": "Mei", "ja_male": "Umiri"}
const PROFILES := ["zh_female", "zh_male", "en_female", "en_male", "ja_female", "ja_male"]
# Empty means follow the UI locale until the user explicitly picks a voice.
var profile := ""
var voice_origin := ""
var voice_id := ""
var line := 0
var hide_subtitles := false
var video: Node
var enabled := false
var source := -1
var language := "en"
var zh_voice := "Xiaoyu"
var en_voice := "Ava"
var ja_voice := "Mei"
var duck := 75.0
var volume := 100.0
var timing := "interrupt"
var offset := 0.0
var retry := 0
var preview := 0
var _last_payload := ""
var _language_source := ""
var _video_source := ""
var _restoring_source := false
var _ui_locale := ""
var _text_uri := ""
var _text_tracks := {}

func _init(owner: Node) -> void:
	video = owner
	language = default_profile(I18n.language).get_slice("_", 0)
	_sync_profile()
	_defaults = _values()

func load_settings(settings: ConfigFile) -> void:
	# Legacy global preferences are defaults only; the global On bit never opts
	# every video into narration. Current-file overrides are stored separately.
	_load_values(settings, false)
	_defaults = _values()
	var saved := memory.lookup(video.local_uri)
	if not saved.is_empty(): _restore_values(saved)

func _load_values(settings: ConfigFile, restore_enabled: bool = true) -> void:
	enabled = FEATURE_ENABLED and restore_enabled and bool(settings.get_value("narration", "enabled", false))
	profile = str(settings.get_value("narration", "profile", ""))
	if profile not in PROFILES: profile = ""
	voice_origin = str(settings.get_value("narration", "voice_origin", profile.get_slice("_", 0)))
	if voice_origin not in VOICES: voice_origin = ""
	voice_id = str(settings.get_value("narration", "voice_id", LEGACY_VOICES.get(profile, "")))
	var default_language := default_profile(I18n.language).get_slice("_", 0)
	language = str(settings.get_value("narration", "language", default_language))
	# Earlier builds saved auto as the implicit default, which blocked untagged
	# sidecars. Preserve auto only when selected in the new explicit chooser.
	if language not in ["auto", "zh", "en", "ja"] or (language == "auto" and int(settings.get_value("narration", "language_choice_version", 0)) < 1):
		language = default_language
	for key in ["zh_voice", "en_voice", "ja_voice"]:
		var saved_voice := str(settings.get_value("narration", key, get(key)))
		if saved_voice in VOICES[key.get_slice("_", 0)]: set(key, saved_voice)
	line = int(settings.get_value("narration", "line", 0))
	if line not in [0, 1, 2]: line = 0
	hide_subtitles = bool(settings.get_value("narration", "hide_subtitles", false))
	_sync_profile()
	timing = "interrupt"
	for key in ["duck", "volume", "offset"]: set_option("narration_" + key, settings.get_value("narration", key, get(key)))

func save(settings: ConfigFile) -> void:
	settings.set_value("narration", "language_choice_version", 1)
	for key in Memory.FIELDS:
		if key != "enabled": settings.set_value("narration", key, _defaults[key])
	var uri := _video_source if not _video_source.is_empty() else str(video.local_uri)
	if memory.remember(uri, _values()): memory.save()

	for key in ["enabled", "rate", "voice_rates"]:
		if settings.has_section_key("narration", key): settings.erase_section_key("narration", key)

func _values() -> Dictionary:
	var result := {}
	for key in Memory.FIELDS: result[key] = get(key)
	return result

func _restore_values(values: Dictionary) -> void:
	var config := ConfigFile.new()
	config.set_value("narration", "language_choice_version", 1)
	for key in values: config.set_value("narration", key, values[key])
	_load_values(config)

func reset_source(uri: String = "") -> void:
	_restoring_source = not uri.is_empty() and uri == _video_source
	_video_source = uri
	_last_payload = ""; _language_source = ""
	if not _restoring_source:
		source = -1
		preview = 0; retry = 0
		var values := _defaults.duplicate(true)
		values.merge(memory.lookup(uri), true)
		_restore_values(values)
	_sync_profile()

func available() -> bool:
	return FEATURE_ENABLED and Methods.supports(video.platform, "set_mpv_narration") and current_text_subtitles()

func current_text_subtitles() -> bool:
	if _text_uri != video.local_uri: _text_uri = video.local_uri; _text_tracks.clear()
	var tracks: Array = video.subtitle_tracks()
	# A seek/revision can temporarily omit metadata. Explicit Off still wins;
	# retain only this source's known codecs so that a seek cannot unload TTS.
	if not tracks.is_empty():
		_text_tracks.clear()
		for track in tracks: _text_tracks[int(track.id)] = video.SubtitleState.text_codec(str(track.get("codec", "")))
	var id: int = video.subtitles.requested_track
	if id < 0: id = int(video.media.playback.get("details", {}).get("subtitle", {}).get("track_id", 0))
	return id > 0 and bool(_text_tracks.get(id, false))

func set_option(key: String, value: Variant) -> bool:
	if not FEATURE_ENABLED: return false
	# A slider can release while auto-next is already opening another movie.
	# Its final value belongs to the captured source and must never modify that movie.
	if value is Dictionary:
		if key not in ["narration_duck", "narration_volume", "narration_offset"] or str(value.get("source_uri", "")) != str(video.local_uri): return false
		value = value.get("value")
	if (key in ["narration_enabled", "narration_current"] and bool(value) or key == "narration_preview") and not current_text_subtitles(): return false
	if key in ["narration_source", "narration_current", "narration_language"]: _restoring_source = false
	match key:
		"narration_enabled": enabled = bool(value); source = -1; _sync_profile()
		"narration_current": enabled = bool(value); source = -1; _sync_profile()
		"narration_source": source = maxi(-1, int(value))
		"narration_language":
			if str(value) not in ["auto", "zh", "en", "ja"]: return false
			language = str(value); _language_source = ""
		"narration_profile":
			if str(value) not in PROFILES and str(value) != "default": return false
			profile = "" if str(value) == "default" else str(value)
			voice_origin = profile.get_slice("_", 0)
			voice_id = str(LEGACY_VOICES.get(profile, "")); _sync_profile()
		"narration_voice_origin":
			if str(value) not in VOICES and str(value) != "default": return false
			profile = ""; voice_origin = "" if str(value) == "default" else str(value)
			voice_id = "" if voice_origin.is_empty() else str(get(voice_origin + "_voice")); _sync_profile()
		"narration_line":
			if not (value is int or value is float) or not is_finite(float(value)) or float(value) != int(value) or int(value) not in range(3): return false
			line = int(value)
		"narration_hide_subtitles": hide_subtitles = bool(value)
		"narration_voice":
			if str(value) not in VOICES[selected_origin()]: return false
			profile = ""; voice_id = str(value); _sync_profile()
		"narration_duck", "narration_volume", "narration_offset":
			if not (value is float or value is int) or not is_finite(float(value)): return false
			var field := key.trim_prefix("narration_")
			var limits := Vector2(0, 100) if field in ["duck", "volume"] else Vector2(-2, 2)
			set(field, clampf(float(value), limits.x, limits.y))
		"narration_retry": retry += 1
		"narration_preview": preview += 1
		"narration_timing":
			if str(value) != "interrupt": return false
			timing = str(value)
		_: return false
	apply(); video.changed.emit(); return true

func selected_track() -> Dictionary:
	var id: int = video.subtitles.requested_track if source < 0 else source
	if id < 0: id = int(video.media.playback.get("details", {}).get("subtitle", {}).get("track_id", 0))
	for track in video.subtitle_tracks():
		if int(track.id) == id: return track
	return {}

static func default_profile(locale: String) -> String:
	var tag := I18n.resolve_locale(locale)
	return ("zh" if tag.begins_with("zh") else ("ja" if tag == "ja" else "en")) + "_female"

func selected_profile() -> String:
	return profile if profile in PROFILES else default_profile(I18n.language)

func selected_origin() -> String:
	return voice_origin if voice_origin in VOICES else default_profile(I18n.language).get_slice("_", 0)

func selected_voice() -> String:
	var origin := selected_origin()
	if voice_id in VOICES[origin]: return voice_id
	return str(get(origin + "_voice")) if str(get(origin + "_voice")) in VOICES[origin] else str(VOICES[origin][0])

func _sync_profile() -> void:
	_ui_locale = I18n.language
	set(selected_origin() + "_voice", selected_voice())

func resolved_language() -> String:
	return declared_language() if language == "auto" else language

func declared_language() -> String:
	var tag := str(selected_track().get("language", "")).replace("_", "-").to_lower().split("-")[0]
	if tag in ["zh", "zho", "chi", "cmn", "chs", "cht"]: return "zh"
	if tag in ["en", "eng"]: return "en"
	if tag in ["ja", "jpn"]: return "ja"
	return ""

func apply() -> void:
	if not FEATURE_ENABLED: return
	if profile.is_empty() and _ui_locale != I18n.language: _sync_profile()
	if video.media.session_id <= 0 or (not enabled and _last_payload.is_empty()): return
	var track := selected_track()
	if _restoring_source and track.is_empty(): return
	# JSON track IDs are floats; a transient empty track during seek falls back to
	# an int. Normalize before comparing, or "2:2.0" becomes "2:2" and loses language.
	var identity := str(source) + ":" + str(int(track.get("id", source if source >= 0 else video.subtitles.requested_track)))
	if _restoring_source: _language_source = identity; _restoring_source = false
	# Voice profile stays explicit across subtitle track changes.
	_language_source = identity
	if not Methods.supports(video.platform, "set_mpv_narration") or video.media.session_id <= 0 or (not enabled and _last_payload.is_empty()): return
	var payload := {"enabled": enabled and current_text_subtitles(), "source": source, "language": language, "zh_voice": zh_voice, "en_voice": en_voice, "ja_voice": ja_voice, "voice_override": selected_voice(), "line": line,
		"duck": duck / 100.0, "volume": volume / 100.0, "offset": offset, "retry": retry, "preview": preview, "timing": timing}
	if source >= 0:
		payload.source_delay = video.subtitle_timing.for_track(video.local_uri, Timing.track_key(selected_track()))
	var json := JSON.stringify(payload)
	var key := str(video.media.session_id) + ":" + json
	if key != _last_payload and video.platform.set_mpv_narration(video.media.session_id, json): _last_payload = key

func snapshot() -> Dictionary:
	if not FEATURE_ENABLED: return {"narration_available": false, "narration_enabled": false, "narration_current": false}
	var lang := resolved_language()
	var report: Dictionary = video.media.playback.get("narration", {})
	var options: Array = [{"value": -1, "label": "Follow current subtitles"}]
	for track in video.subtitle_tracks():
		if not video.SubtitleState.text_codec(str(track.get("codec", ""))): continue
		var title := str(track.get("title", "")).strip_edges()
		if title.is_empty(): title = I18n.t("Subtitles") + " %d" % int(track.id)
		options.append({"value": int(track.id), "label": title})
	return {"narration_available": available(), "narration_enabled": enabled and available(), "narration_current": enabled and available() and source == -1,
		"narration_source": source, "narration_sources": options, "narration_language": language,
		"narration_source_uri": str(video.local_uri),
		"narration_resolved_language": lang, "narration_language_required": lang.is_empty(), "narration_voice": selected_voice(), "narration_voice_origin": selected_origin(), "narration_resolved_origin": selected_origin(),
		"narration_profile": profile if not profile.is_empty() else "default", "narration_line": line, "narration_hide_subtitles": hide_subtitles,
		"narration_duck": duck, "narration_volume": volume, "narration_offset": offset,
		"narration_preview_busy": bool(video.media.playback.get("narration", {}).get("preview", false)),
		"narration_preview_progress": int(report.get("preview_progress", -1)),
		"narration_missing": int(video.media.playback.get("narration", {}).get("missing_cues", 0)),
		"narration_miss_reason": str(report.get("last_miss_reason", "")),
		"narration_timing": timing, "narration_delay": ceili(float(video.media.playback.get("narration", {}).get("output_delay_seconds", 0))) if float(video.media.playback.get("narration", {}).get("output_delay_seconds", 0)) > 0.4 else 0,
		"narration_status": display_status(report), "narration_progress": progress_percent(report)}

static func display_status(report: Dictionary) -> String:
	var code := str(report.get("state", "off"))
	if code == "loading":
		return "verifying" if report.get("model_phase", "") == "verifying" else ("model_loading" if not report.get("model_ready", false) else "preparing")
	if code == "ready":
		if report.get("preview", false) and report.get("synthesizing", false): return "preview_buffering"
		if report.get("startup_hold", false): return "preparing"
		if report.get("timeline_reading", false): return "subtitle_loading"
		if report.get("synthesizing", false) and float(report.get("cached_seconds", 0)) < 0.1: return "preparing"
	if code in ["ready", "speaking"] and report.get("timeline_indexing", false): return "subtitle_loading"
	return code

static func progress_percent(report: Dictionary) -> int:
	var ratio := -1.0
	if display_status(report) == "verifying" and float(report.get("model_bytes", 0)) > 0:
		ratio = float(report.get("model_verified_bytes", 0)) / float(report.model_bytes)
	elif display_status(report) == "preparing" and report.get("startup_hold", false) and float(report.get("buffer_goal_seconds", 0)) > 0:
		ratio = float(report.get("buffered_seconds", 0)) / float(report.buffer_goal_seconds)
	elif display_status(report) == "subtitle_loading":
		ratio = float(report.get("timeline_index_fraction", -1))
	# Coarse progress keeps feedback moving without rebuilding the VR menu on
	# every generated chunk. ONNX session creation has no truthful percentage.
	return clampi(floori(ratio * 10) * 10, 0, 100) if is_finite(ratio) and ratio >= 0 else -1

static func toggle(key: String, value: bool) -> Dictionary:
	return {"key": key, "value": value, "choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}

static func rows(state: Dictionary, more: bool = false) -> Array:
	if not FEATURE_ENABLED: return []
	var result: Array = [{"title": "Subtitle narration", "field": toggle("narration_enabled", bool(state.get("narration_enabled", false)))}]
	if not state.get("narration_enabled", false): return result
	var default_lang := default_profile(I18n.language).get_slice("_", 0)
	result.append({"title": "Reading language", "field": {"key": "narration_language", "value": state.get("narration_language", default_lang), "choices": [{"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}, {"value": "ja", "label": "Japanese"}, {"value": "auto", "label": "From subtitles"}], "rows": 4}})
	var origins: Array = []
	for lang in ["zh", "en", "ja"]:
		origins.append({"value": lang, "label": I18n.t({"zh": "Chinese", "en": "English", "ja": "Japanese"}[lang])})
	result.append({"title": "Voice native language", "field": {"key": "narration_voice_origin", "value": state.get("narration_voice_origin", default_lang), "choices": origins, "rows": 3}})
	var origin := str(state.get("narration_resolved_origin", default_lang))
	var voices: Array = []
	for voice in VOICES.get(origin, VOICES.en):
		var info: Array = VOICE_INFO[voice]
		voices.append({"value": voice, "label": I18n.t(str(info[0])) + " %d" % int(info[1])})
	result.append({"title": "Voice", "field": {"key": "narration_voice", "value": state.get("narration_voice", VOICES[origin][0]), "choices": voices, "rows": 4}})
	result.append({"title": "Hide subtitle display", "field": toggle("narration_hide_subtitles", bool(state.get("narration_hide_subtitles", false)))})
	var lines: Array = [{"value": 0, "label": "All lines"}]
	for index in range(1, 3): lines.append({"value": index, "label": I18n.t("Line %d") % index})
	result.append({"title": "Read line", "field": {"key": "narration_line", "value": state.get("narration_line", 0), "choices": lines, "rows": 3}})
	if more:
		var uri := str(state.get("narration_source_uri", state.get("source_uri", "")))
		result.append({"title": "Lower original audio", "field": {"key": "narration_duck", "value": state.get("narration_duck", 75.0), "slider": true, "span": Vector3(0, 100, 5), "unit": "%", "source_uri": uri}})
		for field in [{"key": "volume", "title": "Narration volume", "span": Vector3(0, 100, 5), "unit": "%"},
			{"key": "offset", "title": "Narration sync", "span": Vector3(-2, 2, 0.1), "unit": " s"}]:
			result.append({"title": field.title, "field": {"key": "narration_" + field.key, "value": state.get("narration_" + field.key, 1.0 if field.key == "rate" else (100.0 if field.key == "volume" else 0.0)), "slider": true, "span": field.span, "unit": field.unit, "source_uri": uri}})
	return result

func hides_display() -> bool:
	return enabled and hide_subtitles and available()

static func status_label(code: String) -> String:
	if not FEATURE_ENABLED: return ""
	return {"loading": "Preparing narration…", "verifying": "Checking narration model…", "model_loading": "Loading narration model…", "preparing": "Preparing speech…", "preview_buffering": "Preparing voice preview…", "subtitle_loading": "Reading subtitle timeline…", "ready": "Narration ready", "speaking": "Reading subtitles…", "model_missing": "Narration model not installed", "model_error": "Unable to load narration model", "subtitle_required": "Choose subtitles", "language_required": "Choose language", "unsupported_subtitle": "Text subtitles required", "timeline_error": "Unable to prepare subtitles", "speech_error": "Unable to read subtitle", "line_missing": "Selected line has no text"}.get(code, "")
