extends RefCounted
signal voice_choice_changed
const Methods := preload("res://scripts/platform_methods.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const I18n := preload("res://scripts/i18n.gd")
const Memory := preload("res://scripts/file_narration_memory.gd")
const Languages := preload("res://scripts/narration_languages.gd")
const VoiceStatus := preload("res://scripts/narration_voice_status.gd")
const VOICE_FIELDS := ["profile", "voice_origin", "voice_id", "zh_voice", "en_voice", "ja_voice", "voice_kind", "custom_voice"]
const BASIC_FIELDS := VOICE_FIELDS + ["language", "line", "hide_subtitles", "duck", "volume"]
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
var voice_kind := "preset"
var custom_voice := ""
var clone_state: Dictionary = {}
var _clone_poll_at := 0
var _clone_session := 0
var _clone_identity_session := 0
var _clone_saved := ""
var _clone_save_request := -1
var _clone_save_use := true
var _global_save_request := -1
var _global_save_use := false
var _personal_voices: Array = []
var _voice_catalog_revision := -1
var _clone_request := 0
var _voice_warning := ""
var _global_voice_state := {}
var _global_voice_poll_at := 0
var _global_voice_started := false
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
var _preview_ui_request := -1
var _preview_ui_busy := false
var _preview_ui_until := 0
var _preview_feedback := ""
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
	# Last-used basic preferences are defaults only; the global On bit never
	# opts every video into narration. Current-file overrides stay independent.
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
	voice_kind = str(settings.get_value("narration", "voice_kind", "preset"))
	if voice_kind not in ["preset", "custom"]: voice_kind = "preset"
	custom_voice = str(settings.get_value("narration", "custom_voice", ""))
	if not custom_voice.is_empty() and not Memory.valid_custom_voice(custom_voice): custom_voice = ""
	var default_language := default_profile(I18n.language).get_slice("_", 0)
	language = str(settings.get_value("narration", "language", default_language))
	# Earlier builds saved auto as the implicit default, which blocked untagged
	# sidecars. Preserve auto only when selected in the new explicit chooser.
	if (language != "auto" and language not in Languages.NAMES) or (language == "auto" and int(settings.get_value("narration", "language_choice_version", 0)) < 1):
		language = default_language
	for key in ["zh_voice", "en_voice", "ja_voice"]:
		var saved_voice := str(settings.get_value("narration", key, get(key)))
		if saved_voice in VOICES[key.get_slice("_", 0)]: set(key, saved_voice)
	line = int(settings.get_value("narration", "line", 0))
	if line not in [0, 1, 2]: line = 0
	hide_subtitles = bool(settings.get_value("narration", "hide_subtitles", false))
	_sync_profile()
	timing = "interrupt"
	for key in ["duck", "volume", "offset"]: set_option("narration_" + key, settings.get_value("narration", key, get(key)), false)

func save(settings: ConfigFile) -> void:
	settings.set_value("narration", "language_choice_version", 1)
	for key in Memory.FIELDS:
		if key != "enabled": settings.set_value("narration", key, _defaults[key])
	var uri := _video_source if not _video_source.is_empty() else (str(video.local_uri) if video.media.session_id > 0 else "")
	if not video.get("cast_token") and memory.remember(uri, _values()): memory.save()

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
		_voice_warning = ""
		source = -1
		preview = 0; retry = 0
		_preview_ui_request = -1; _preview_ui_busy = false; _preview_ui_until = 0
		_preview_feedback = ""
		var values := _defaults.duplicate(true)
		if not video.get("cast_token"): values.merge(memory.lookup(uri), true)
		_restore_values(values)
	_sync_profile()

func capture_reopen() -> Dictionary:
	return {"uri": video.local_uri, "values": _values()}

func restore_reopen(saved: Dictionary) -> void:
	if str(saved.get("uri", "")).is_empty() or saved.get("uri") != video.local_uri: return
	# Output changes are still the same viewing session, even with file memory off.
	# Wait for its selected text track before sending the restored configuration.
	_restoring_source = true
	_last_payload = ""; _language_source = ""
	_restore_values(saved.values)

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

func set_option(key: String, value: Variant, remember_defaults: bool = true) -> bool:
	if not FEATURE_ENABLED: return false
	if key == "narration_toggle":
		if video.media.session_id <= 0 or not available(): return false
		if not enabled:
			# A shortcut explicitly uses the latest basic preferences, even if this
			# video's saved settings are older. Track/timing remain per-video.
			for field in BASIC_FIELDS: set(field, _defaults[field])
			_voice_warning = ""
		return set_option("narration_enabled", not enabled)
	if key == "narration_clone": return clone_command(value) if value is Dictionary else false
	# A slider can release while auto-next is already opening another movie.
	# Its final value belongs to the captured source and must never modify that movie.
	if value is Dictionary:
		if key not in ["narration_duck", "narration_volume", "narration_offset"] or str(value.get("source_uri", "")) != str(video.local_uri): return false
		value = value.get("value")
	if key in ["narration_enabled", "narration_current"] and bool(value) and not current_text_subtitles(): return false
	if key == "narration_preview" and not current_text_subtitles() and not (_clone_preview_busy() or _normal_preview_busy()): return false
	if key in ["narration_source", "narration_current", "narration_language"]: _restoring_source = false
	match key:
		"narration_clone_audio": return clone_command({"operation": "candidates", "audio_id": int(value), "start": maxf(0, video.control.display_position_ms() / 1000.0 - 20)})
		"narration_voice_kind":
			if str(value) not in ["preset", "custom"]: return false
			voice_kind = str(value)
			if voice_kind == "custom" and not _personal_voices.is_empty() and not _has_voice(custom_voice): custom_voice = _fallback_voice()
		"narration_custom_voice":
			if not Memory.valid_custom_voice(str(value)): return false
			custom_voice = str(value); voice_kind = "custom"
		"narration_enabled":
			enabled = bool(value); source = -1; _sync_profile()
			if not enabled and _clone_preview_busy(): clone_command({"operation": "stop"})
		"narration_current": enabled = bool(value); source = -1; _sync_profile()
		"narration_source": source = maxi(-1, int(value))
		"narration_language":
			if str(value) != "auto" and str(value) not in Languages.NAMES: return false
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
			var origin := ""
			for lang in VOICES:
				if str(value) in VOICES[lang]: origin = lang; break
			if origin.is_empty(): return false
			profile = ""; voice_origin = origin; voice_id = str(value); voice_kind = "preset"; _sync_profile()
		"narration_duck", "narration_volume", "narration_offset":
			if not (value is float or value is int) or not is_finite(float(value)): return false
			var field := key.trim_prefix("narration_")
			var limits := Vector2(0, 100) if field in ["duck", "volume"] else Vector2(-2, 2)
			set(field, clampf(float(value), limits.x, limits.y))
		"narration_retry": retry += 1
		"narration_preview":
			if _clone_preview_busy():
				_preview_feedback = "stopped"
				return clone_command({"operation": "stop"})
			if voice_kind == "custom" and not Memory.valid_custom_voice(custom_voice): return false
			# All UI auditions use the same streaming/cache path, including presets.
			return clone_command({"operation": "preview", "id": selected_voice(), "language": resolved_language()})
		"narration_timing":
			if str(value) != "interrupt": return false
			timing = str(value)
		_: return false
	if key in ["narration_voice_kind", "narration_custom_voice", "narration_voice", "narration_voice_origin", "narration_profile"]:
		_voice_warning = ""
	if remember_defaults:
		var field := key.trim_prefix("narration_")
		if field in BASIC_FIELDS or key == "narration_voice" or (key in ["narration_enabled", "narration_current"] and enabled):
			# Keep one coherent last-used configuration, including when editing an
			# older file. Merely restoring a file must never replace these defaults.
			for basic in BASIC_FIELDS: _defaults[basic] = get(basic)
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
	if voice_kind == "custom" and Memory.valid_custom_voice(custom_voice): return custom_voice
	var origin := selected_origin()
	if voice_id in VOICES[origin]: return voice_id
	return str(get(origin + "_voice")) if str(get(origin + "_voice")) in VOICES[origin] else str(VOICES[origin][0])

func _sync_profile() -> void:
	_ui_locale = I18n.language
	if voice_kind != "custom": set(selected_origin() + "_voice", selected_voice())

func resolved_language() -> String:
	return declared_language() if language == "auto" else language

func declared_language() -> String:
	var track := selected_track()
	return Languages.canonical(str(track.get("server_language", track.get("language", ""))))

func apply() -> void:
	if not FEATURE_ENABLED: return
	_poll_clone()
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
	_poll_clone()
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
		"narration_voice_kind": voice_kind, "narration_custom_voice": custom_voice, "narration_personal_voices": _personal_voices.duplicate(true),
		"narration_clone_state": clone_state, "narration_clone_supported": Methods.supports(video.platform, "mpv_voice_clone_request"),
		"narration_sample_available": video.media.session_id > 0,
		"narration_voice_warning": _voice_warning,
		"narration_resolved_language": lang, "narration_language_required": lang.is_empty(), "narration_voice": selected_voice(), "narration_voice_origin": selected_origin(), "narration_resolved_origin": selected_origin(),
		"narration_profile": profile if not profile.is_empty() else "default", "narration_line": line, "narration_hide_subtitles": hide_subtitles,
		"narration_duck": duck, "narration_volume": volume, "narration_offset": offset,
		"narration_preview_busy": _clone_preview_busy() or _normal_preview_busy(),
		"narration_preview_status": _preview_status(report),
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

static func rows(state: Dictionary) -> Array:
	if not FEATURE_ENABLED: return []
	var result: Array = [{"title": "Subtitle narration", "field": toggle("narration_enabled", bool(state.get("narration_enabled", false)))}]
	if not state.get("narration_enabled", false): return result
	var default_lang := default_profile(I18n.language).get_slice("_", 0)
	result.append({"title": "Reading language", "field": {"key": "narration_language", "value": state.get("narration_language", default_lang), "choices": Languages.choices(), "rows": 6, "heading": "Reading language"}})
	var custom: bool = state.get("narration_voice_kind", "preset") == "custom"
	result.append({"title": "Voice type", "field": {"key": "narration_voice_kind", "value": "custom" if custom else "preset", "choices": [{"value": "preset", "label": "Preset voices"}, {"value": "custom", "label": "Cloned voices"}]}})
	var origin := str(state.get("narration_resolved_origin", default_lang))
	var voices: Array = []
	if custom:
		for voice in state.get("narration_personal_voices", []): voices.append({"value": voice.id, "label": voice.name, "literal": true})
		if not voices.is_empty(): result.append({"title": "My voices", "field": {"key": "narration_custom_voice", "value": state.get("narration_custom_voice", ""), "choices": voices, "rows": 4, "dropdown": true}})
	else:
		for lang in ["zh", "en", "ja"]:
			var native_label := I18n.t({"zh": "Native Chinese", "en": "Native English", "ja": "Native Japanese"}[lang])
			for voice in VOICES[lang]:
				var info: Array = VOICE_INFO[voice]
				voices.append({"value": voice, "label": native_label + " · " + I18n.t(str(info[0])) + " %d" % int(info[1]), "literal": true})
		result.append({"title": "Voice", "field": {"key": "narration_voice", "value": state.get("narration_voice", VOICES.get(origin, VOICES[default_lang])[0]), "choices": voices, "rows": 6, "dropdown": true}})
	var uri := str(state.get("narration_source_uri", state.get("source_uri", "")))
	result.append({"title": "Narration volume", "field": {"key": "narration_volume", "value": state.get("narration_volume", 100.0), "slider": true, "span": Vector3(0, 100, 5), "unit": "%", "source_uri": uri}})
	result.append({"title": "Lower original audio", "field": {"key": "narration_duck", "value": state.get("narration_duck", 75.0), "slider": true, "span": Vector3(0, 100, 5), "unit": "%", "source_uri": uri}})
	var lines: Array = [{"value": 0, "label": "All lines"}]
	for index in range(1, 3): lines.append({"value": index, "label": I18n.t("Line %d") % index})
	result.append({"title": "Read line", "field": {"key": "narration_line", "value": state.get("narration_line", 0), "choices": lines, "compact": true}})
	var hide := toggle("narration_hide_subtitles", bool(state.get("narration_hide_subtitles", false)))
	hide["switch"] = true; hide.hint = "Hide subtitle display"
	result.append({"title": "Hide subtitle display", "field": hide})
	return result

func hides_display() -> bool:
	return enabled and hide_subtitles and available()

static func status_label(code: String) -> String:
	if not FEATURE_ENABLED: return ""
	return {"loading": "Preparing narration…", "verifying": "Checking narration model…", "model_loading": "Loading narration model…", "preparing": "Preparing speech…", "preview_buffering": "Preparing voice preview…", "subtitle_loading": "Reading subtitle timeline…", "ready": "Narration ready", "speaking": "Reading subtitles…", "model_missing": "Narration model not installed", "model_error": "Unable to load narration model", "subtitle_required": "Choose subtitles", "language_required": "Choose language", "unsupported_subtitle": "Text subtitles required", "timeline_error": "Unable to prepare subtitles", "speech_error": "Unable to read subtitle", "line_missing": "Selected line has no text"}.get(code, "")

func clone_command(value: Dictionary) -> bool:
	if video.get("cast_token") and str(value.get("operation", "")) not in ["list", "use", "cancel", "close", "stop"]: return false
	if not Methods.supports(video.platform, "mpv_voice_clone_request") or video.media.session_id <= 0: return false
	var command := value.duplicate(true)
	var operation := str(command.get("operation", ""))
	if operation == "use": return set_option("narration_custom_voice", str(command.get("id", "")))
	if operation in ["open", "scan", "manual", "trim", "preview", "original", "clone", "save", "rename", "delete"] or (operation == "list" and command.get("pause", false)):
		video.pause_for_voice_clone()
	if operation == "preview": _preview_feedback = "clone"
	if operation == "open":
		var track := selected_track()
		if command.get("mode", "subtitles") == "subtitles" and (track.is_empty() or resolved_language().is_empty()): return false
		clone_state.opened = true
		command.merge({"subtitle_id": int(track.get("id", 0)), "line": line, "language": resolved_language() if not resolved_language().is_empty() else default_profile(I18n.language).get_slice("_", 0), "audio_id": video.audio_track_id, "position": video.control.display_position_ms() / 1000.0}, true)
		command.subtitle_delay = video.subtitle_delay if source < 0 or track.is_empty() else video.subtitle_timing.for_track(video.local_uri, Timing.track_key(track))
		command.audio_delays = {}
		for audio_track in video._raw_tracks("audio"):
			var track_id := int(audio_track.get("id", 0))
			command.audio_delays[str(track_id)] = video.audio_delay if track_id == video.audio_track_id else video.audio_timing.for_track(video.local_uri, video.AudioTiming.track_key(audio_track))
	_clone_request += 1; command.request = _clone_request
	var accepted := bool(video.platform.mpv_voice_clone_request(video.media.session_id, JSON.stringify(command)))
	if accepted and operation == "save": _clone_save_request = _clone_request; _clone_save_use = bool(command.get("apply", true))
	if accepted and Methods.supports(video.platform, "mpv_voice_clone_status"):
		var immediate: Variant = JSON.parse_string(video.platform.mpv_voice_clone_status(video.media.session_id))
		if immediate is Dictionary: clone_state = immediate
		_clone_poll_at = 0
		video.changed.emit()
	return accepted

func _poll_clone() -> void:
	if not Methods.supports(video.platform, "mpv_voice_clone_status") or video.media.session_id <= 0: return
	var now := Time.get_ticks_msec()
	if now < _clone_poll_at: return
	_clone_poll_at = now + 150
	if _clone_session != video.media.session_id:
		_clone_session = video.media.session_id; clone_state = {}
		if _clone_identity_session != video.media.session_id:
			_clone_identity_session = video.media.session_id; _clone_saved = ""; _clone_save_request = -1; _preview_feedback = ""
		clone_command({"operation": "list"})
	var parsed: Variant = JSON.parse_string(video.platform.mpv_voice_clone_status(video.media.session_id))
	if not parsed is Dictionary: return
	clone_state = parsed
	var catalog_ready := _accept_voice_catalog(clone_state)
	var saved: Dictionary = clone_state.get("saved", {})
	if _clone_save_request >= 0 and int(clone_state.get("save_request", -2)) == _clone_save_request and not saved.is_empty() and str(saved.get("id", "")) != _clone_saved:
		_clone_saved = str(saved.id)
		_clone_save_request = -1
		if _clone_save_use and set_option("narration_custom_voice", _clone_saved): voice_choice_changed.emit()
	if catalog_ready and voice_kind == "custom" and not _has_voice(custom_voice):
		var missing := not custom_voice.is_empty()
		custom_voice = _fallback_voice()
		if custom_voice.is_empty() and missing: voice_kind = "preset"
		if missing: _voice_warning = "Saved voice unavailable; using another voice"
		if missing or not custom_voice.is_empty():
			_last_payload = ""; voice_choice_changed.emit()

func _clone_preview_busy() -> bool:
	return VoiceStatus.preview_busy(clone_state)

func _preview_status(report: Dictionary) -> String:
	if _preview_feedback.is_empty(): return ""
	if not (_clone_preview_busy() or _normal_preview_busy()) and video.requested_play:
		_preview_feedback = ""; return ""
	if _preview_feedback == "stopped": return "Voice preview stopped"
	if _preview_feedback == "clone": return VoiceStatus.label(clone_state)
	if str(report.get("state", "")) in ["model_missing", "model_error", "speech_error"]: return status_label(str(report.state))
	if not _normal_preview_busy(): return "Voice preview finished"
	if int(report.get("preview_request", -1)) < _preview_ui_request: return "Preparing voice preview…"
	var code := display_status(report)
	if code in ["ready", "speaking"]: return "Playing voice preview…" if not report.get("synthesizing", false) else "Preparing voice preview…"
	return status_label(code)

func _has_voice(id: String) -> bool:
	return _personal_voices.any(func(voice): return str(voice.get("id", "")) == id)

func _fallback_voice() -> String:
	var id := str(_defaults.get("custom_voice", ""))
	return id if _has_voice(id) else (str(_personal_voices[0].id) if not _personal_voices.is_empty() else "")

func _accept_voice_catalog(state: Dictionary) -> bool:
	# A newly requested list can still contain an old empty catalog. Only a
	# completed disk read is authoritative for deletion/default repair.
	if not state.has("voices") or not state.get("voices_ready", state.get("state", "") not in ["preparing", "idle"]): return false
	var revision := int(state.get("voices_revision", -1))
	if revision >= 0 and revision < _voice_catalog_revision: return false
	_voice_catalog_revision = maxi(_voice_catalog_revision, revision)
	_personal_voices = state.voices.duplicate(true)
	_repair_voice_defaults(_personal_voices)
	return true

func _normal_preview_busy() -> bool:
	var report: Dictionary = video.media.playback.get("narration", {})
	if _preview_ui_request >= 0 and int(report.get("preview_request", -1)) < _preview_ui_request and Time.get_ticks_msec() < _preview_ui_until:
		return _preview_ui_busy
	return bool(report.get("preview", false))

func _repair_voice_defaults(voices: Array) -> void:
	var id := str(_defaults.get("custom_voice", ""))
	if _defaults.get("voice_kind", "preset") == "custom" and not id.is_empty() and not voices.any(func(voice): return str(voice.get("id", "")) == id):
		_defaults.voice_kind = "preset"; _defaults.custom_voice = ""; voice_choice_changed.emit()

func global_voice_command(value: Dictionary) -> bool:
	if not Methods.supports(video.platform, "narration_voice_manager_request"): return false
	var command := value.duplicate(true)
	_clone_request += 1; command.request = _clone_request
	if (command.get("operation", "") in ["open_source", "scan", "manual", "trim", "original", "clone", "preview", "rename", "delete", "use"] or command.get("pause", false)) and video.media.session_id > 0: video.pause_for_voice_clone()
	if command.get("operation", "") == "use":
		var id := str(command.get("id", ""))
		if not Memory.valid_custom_voice(id) or not _global_voice_state.get("voices", []).any(func(voice): return str(voice.get("id", "")) == id): return false
		_defaults.voice_kind = "custom"; _defaults.custom_voice = id; voice_choice_changed.emit(); return true
	if command.get("operation", "") == "preview": command.language = resolved_language() if not resolved_language().is_empty() else default_profile(I18n.language).get_slice("_", 0)
	var accepted := bool(video.platform.narration_voice_manager_request(JSON.stringify(command)))
	if accepted and command.get("operation", "") == "save": _global_save_request = _clone_request; _global_save_use = bool(command.get("apply", false))
	if accepted: _global_voice_poll_at = 0
	return accepted

func voice_manager_snapshot() -> Dictionary:
	var supported := Methods.supports(video.platform, "narration_voice_manager_status")
	var now := Time.get_ticks_msec()
	if supported and now >= _global_voice_poll_at:
		_global_voice_poll_at = now + 150
		if not _global_voice_started:
			_global_voice_started = true; global_voice_command({"operation": "list"})
		var parsed: Variant = JSON.parse_string(video.platform.narration_voice_manager_status())
		if parsed is Dictionary and not parsed.is_empty():
			var previous_voices: Array = _personal_voices.duplicate(true)
			_global_voice_state = parsed
			if _global_save_request >= 0 and int(parsed.get("save_request", -2)) == _global_save_request:
				_global_save_request = -1
				if _global_save_use:
					_defaults.voice_kind = "custom"; _defaults.custom_voice = str(parsed.get("saved", {}).get("id", "")); voice_choice_changed.emit()
			if _accept_voice_catalog(parsed) and _personal_voices != previous_voices and not clone_state.get("opened", false) and not _clone_preview_busy(): _clone_session = 0
	return {"source_uri": "global-voice-manager", "global_voice_manager": true, "narration_clone_supported": supported,
		"narration_current_uri": str(video.local_uri) if video.media.session_id > 0 else "", "position_ms": video.control.display_position_ms(),
		"narration_resolved_language": resolved_language() if not resolved_language().is_empty() else default_profile(I18n.language).get_slice("_", 0),
		"narration_clone_state": _global_voice_state, "narration_personal_voices": _personal_voices.duplicate(true),
		"narration_voice_kind": _defaults.get("voice_kind", "preset"), "narration_custom_voice": _defaults.get("custom_voice", ""), "narration_available": false}
