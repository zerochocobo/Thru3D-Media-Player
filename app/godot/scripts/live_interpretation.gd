extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const TranslationClient := preload("res://scripts/comic_translation.gd")
const Memory := preload("res://scripts/file_listening_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const I18n := preload("res://scripts/i18n.gd")
const SECTION := "live_interpretation"
var video: Node3D
var memory := Memory.new()
var enabled := false
var source := "ja"
var target := "" # Explicit opt-in to online translation; empty keeps original speech.
var lead := 12
var translator: RefCounted
var report := {}
var _source := ""
var _payload := ""
var _session := 0
var _epoch := -1
var _poll_at := 0
var _received_at := 0

func _init(owner: Node3D) -> void:
	video = owner
	translator = TranslationClient.new(owner, false)
	translator.request_spacing_ms = 2000
	translator.cache_limit = 2000

func load_settings(settings: ConfigFile) -> void:
	source = str(settings.get_value(SECTION, "source", "ja"))
	if source not in ["zh", "en", "ja"]: source = "ja"
	target = str(settings.get_value(SECTION, "target", ""))
	if target not in Protocol.LANGUAGES: target = ""
	var value: Variant = settings.get_value(SECTION, "lead", 12)
	lead = int(value) if (value is int or value is float) and float(value) in [8.0, 12.0, 20.0] else 12

func save(settings: ConfigFile) -> void:
	for key in ["source", "target", "lead"]: settings.set_value(SECTION, key, get(key))
	if settings.has_section_key(SECTION, "enabled"): settings.erase_section_key(SECTION, "enabled")
	if not video.cast_token and memory.remember(_source, {"enabled": enabled}): memory.save()

func reset_source(uri: String = "") -> void:
	var same := not uri.is_empty() and uri == _source
	_source = uri; _payload = ""; _session = 0; _epoch = -1; report = {}
	translator.reset(true)
	if not same: enabled = not video.cast_token and bool(memory.lookup(uri).get("enabled", false))

func available() -> bool:
	return _allowed() and not video.media.playback.get("details", {}).get("audio_tracks", []).is_empty()

## The track list is briefly empty while a seek restarts the demuxer. It gates
## switching on only, so a running session keeps its loaded speech model.
func _allowed() -> bool:
	return video.media.session_id > 0 and not video.cast_token and not video.disc.menu_session \
		and Methods.supports(video.platform, "set_mpv_listening") and video.subtitle_tracks().is_empty() \
		and video.subtitle_files.is_empty() and video.subtitle_file_loading.is_empty()

func set_option(key: String, value: Variant) -> bool:
	match key:
		"listening_enabled":
			if not value is bool or (value and not available()): return false
			enabled = value
		"listening_source":
			if value not in ["zh", "en", "ja"]: return false
			source = value
		"listening_target":
			if value != "" and value not in Protocol.LANGUAGES: return false
			target = value
		"listening_lead":
			if not (value is int or value is float) or float(value) not in [8.0, 12.0, 20.0]: return false
			lead = int(value)
		_: return false
	translator.reset(true); report = {}; _epoch = -1; _payload = ""
	return true

func active() -> bool: return enabled and _allowed()

func tick() -> void:
	if not Methods.supports(video.platform, "set_mpv_listening") or video.media.session_id <= 0: return
	var wanted := active()
	# Recognized original text is stored per video only where per-file settings may persist.
	var media := Memory.key_for(_source)
	var payload := JSON.stringify({"enabled": wanted, "language": source, "lead": lead, "target": target,
		"media": media, "persist": not media.is_empty() and Privacy.persist_allowed(_source), "network": not Privacy.is_local(_source)})
	if payload != _payload or _session != video.media.session_id:
		if _session != video.media.session_id: report = {}; translator.reset(true)
		if video.platform.set_mpv_listening(video.media.session_id, payload):
			_payload = payload; _session = video.media.session_id
	if not wanted:
		if translator.enabled: translator.enabled = false; translator.reset(true)
		report = {}; return
	if Time.get_ticks_msec() < _poll_at: return
	_poll_at = Time.get_ticks_msec() + 100
	var incoming: Variant = JSON.parse_string(video.platform.get_mpv_listening(video.media.session_id))
	if not incoming is Dictionary: return
	report = incoming
	_received_at = Time.get_ticks_msec()
	var epoch := int(report.get("epoch", -1))
	if epoch != _epoch:
		_epoch = epoch; translator.reset() # Retain bounded translations when seeking within this video.
	var translate := not target.is_empty() and Protocol.language(source) != target
	translator.enabled = translate
	var cues: Array = report.get("cues", [])
	if translate:
		translator.observe_sentences(cues, Protocol.language(source), target)
		translator.tick(true)
	# Readiness controls subtitle availability only; the video keeps playing.
	# A failed provider falls back to original text.
	var pending: bool = not translator.current.is_empty() or not translator.jobs.is_empty()
	if report.get("buffered", false) and (not translate or not pending):
		video.platform.listening_ready(video.media.session_id, epoch)

func text_at(position: float) -> String:
	if not active() or not is_finite(position): return ""
	for cue: Dictionary in report.get("cues", []):
		if position < float(cue.get("start", -1)) or position >= float(cue.get("end", -1)): continue
		var original := str(cue.get("text", ""))
		if target.is_empty() or Protocol.language(source) == target: return original
		var key := Protocol.cache_key(Protocol.normalize(original, Protocol.language(source)), Protocol.language(source), target)
		var translated := str(translator.cache.get(key, {}).get("text", ""))
		return original if translated.is_empty() else translated.replace("\n", " ") + "\n" + original.replace("\n", " ")
	return ""

func playback_position(fallback: float) -> float:
	# Use the native audible clock, including user audio sync and playback speed.
	# Stop extrapolating stale reports instead of showing future subtitles.
	var elapsed := (Time.get_ticks_msec() - _received_at) / 1000.0 + float(report.get("age", 0.0))
	if not report.has("position") or elapsed < 0 or elapsed > 0.5: return fallback
	return float(report.position) + (elapsed * float(report.get("speed", 1.0)) if report.get("playing", false) else 0.0)

static func status_label(value: String) -> String:
	return {"preparing": "Preparing live subtitles…", "catching_up": "Live subtitles catching up…", "ready": "Live subtitles",
		"listening_error": "Live subtitles unavailable", "unsupported_audio": "Audio track unavailable",
		"source_busy": "Source connection limit reached. Try again shortly.",
		"source_error": "Unable to read audio from the source", "audio_error": "Unable to open the audio track"}.get(value, "")

func snapshot() -> Dictionary:
	return {"listening_available": available(), "listening_enabled": active(), "listening_source": source,
		"listening_target": target, "listening_lead": lead, "listening_state": report.get("state", "off"),
		"listening_caption": preparation_caption()}

func preparation_caption() -> String:
	if not active() or report.get("state", "preparing") not in ["preparing", "catching_up"]: return ""
	var phase := str(report.get("phase", "models"))
	if phase == "models":
		var progress := int(report.get("model_progress", -1))
		return I18n.t("Checking speech model…") + (" · %d%%" % progress if progress >= 0 else "")
	if phase == "model_load": return I18n.t("Loading speech model…")
	if phase == "audio_open": return I18n.t("Opening audio…")
	if report.get("buffered", false) and not target.is_empty() and Protocol.language(source) != target: return I18n.t("Preparing translation…")
	return I18n.t("Preparing live subtitles…") + " · %d%%" % clampi(int(report.get("buffer_progress", 0)), 0, 100)

## Head-locked status while the control bar is hidden: what is happening when
## no subtitle shows, and why a shown subtitle is still untranslated.
func status_caption(position: float) -> String:
	if not active(): return ""
	var preparing := preparation_caption()
	if not preparing.is_empty(): return preparing
	var state := str(report.get("state", ""))
	if state not in ["ready", "catching_up"]: return I18n.t(status_label(state))
	if not target.is_empty() and Protocol.language(source) != target:
		var waiting: int = translator.cooldown_ms()
		if waiting > 0 and translator.pending_count() > 0:
			return I18n.t("Translation busy · retrying in %d s, showing original") % ceili(waiting / 1000.0)
		if translator.failing(): return I18n.t("Some lines untranslated · showing original")
		if not text_at(position).is_empty(): return ""
		var pending: int = translator.pending_count()
		if pending > 0: return I18n.t("Translating · %d pending") % pending
	elif not text_at(position).is_empty(): return ""
	return I18n.t("Transcribing · %d s ahead") % maxi(0, int(report.get("ahead", 0.0)))

static func rows(state: Dictionary) -> Array:
	if not state.get("listening_available", false): return []
	var result := [{"title": "Live subtitles", "field": {"key": "listening_enabled", "value": state.get("listening_enabled", false), "switch": true, "hint": "Live subtitles",
		"choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}}]
	if not state.get("listening_enabled", false): return result
	result.append({"title": "Original language", "field": {"key": "listening_source", "value": state.get("listening_source", "ja"), "choices": [
		{"value": "ja", "label": "Japanese"}, {"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}]}})
	result.append({"title": "Translation", "field": {"key": "listening_target", "value": state.get("listening_target", ""), "hint": "Recognized text is sent to Microsoft", "choices": [{"value": "", "label": "No translation"}] + Protocol.target_choices()}})
	result.append({"title": "Audio lookahead", "field": {"key": "listening_lead", "value": state.get("listening_lead", 12), "choices": [
		{"value": 8, "label": "8 s"}, {"value": 12, "label": "12 s"}, {"value": 20, "label": "20 s"}]}})
	return result
