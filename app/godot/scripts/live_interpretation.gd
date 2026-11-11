extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const TranslationClient := preload("res://scripts/comic_translation.gd")
const Memory := preload("res://scripts/file_listening_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const I18n := preload("res://scripts/i18n.gd")
const Tasks := preload("res://scripts/subtitle_tasks.gd")
const CastCapabilities := preload("res://scripts/cast_capabilities.gd")
const SECTION := "live_interpretation"
const FAILURES := ["listening_error", "unsupported_audio", "source_busy", "source_error", "audio_error"]
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
var _stored := {}
var _cache_instance := -1
var _cast_token := 0
var _source_session := 0
var _failure_state := ""
var _failure_until := 0
# Presentation-only debounce; never participates in recognition or readiness.
var _empty_caption_since := -1
var _caption_epoch := -1
var _caption_position := -1.0
var _mirror_sequence := -1
var _mirror_cues: Array = []

func is_mirror() -> bool:
	return _source.begins_with("airplayvideo://")

func _init(owner: Node3D) -> void:
	video = owner
	translator = TranslationClient.new(owner, false)
	translator.priority = 2
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
	if not is_cast_source() and memory.remember(_source, {"enabled": enabled}): memory.save()

## The renderer clears ownership before closing its player. Keep the old source
## ephemeral until reset_source, including any pending save in that interval.
func is_cast_source() -> bool:
	return _cast_token > 0 or video.cast_token > 0

func reset_source(uri: String = "") -> void:
	if is_mirror() and Methods.supports(video.platform, "airplay_receiver_captions"):
		video.platform.airplay_receiver_captions(_cast_token, "")
	var token := int(video.cast_token) if not uri.is_empty() else 0
	var session := int(video.media.session_id) if not uri.is_empty() else 0
	var same := not uri.is_empty() and uri == _source and token == _cast_token and (token == 0 or session == _source_session)
	_source = uri; _payload = ""; _session = 0; _epoch = -1; report = {}
	_cast_token = token; _source_session = session
	_failure_state = ""; _failure_until = 0; _poll_at = 0; _received_at = 0; _cache_instance = -1
	translator.reset(true)
	_stored.clear()
	_mirror_sequence = -1; _mirror_cues.clear()
	if not same: enabled = not is_cast_source() and bool(memory.lookup(uri).get("enabled", false))

func available() -> bool:
	if not _allowed() or video.media.playback.get("details", {}).get("audio_tracks", []).is_empty(): return false
	if not is_cast_source(): return true
	if is_mirror(): return Methods.supports(video.platform, "airplay_receiver_captions")
	return (_source.begins_with("http://") or _source.begins_with("https://")) and CastCapabilities.capabilities(video).get("seek", false)

## MPV processing revisions replace the presentation session over the same Host.
## Only the successful player revision may transfer this binding; arbitrary new
## sessions still fail _allowed() until reset_source establishes their identity.
func processing_revised(previous_session: int, next_session: int) -> void:
	if _cast_token > 0 and video.cast_token == _cast_token and _source_session == previous_session \
		and _source == video.local_uri and next_session > 0 and video.media.session_id == next_session:
		_source_session = next_session

## The track list is briefly empty while a seek restarts the demuxer. It gates
## switching on only, so a running session keeps its loaded speech model.
func _allowed() -> bool:
	if video.media.session_id <= 0 or video.disc.menu_session or not Methods.supports(video.platform, "set_mpv_listening"): return false
	return not is_cast_source() or (_cast_token > 0 and video.cast_token == _cast_token and video.media.session_id == _source_session)

func set_option(key: String, value: Variant) -> bool:
	match key:
		"listening_enabled":
			if not value is bool or (value and not available()): return false
			enabled = value
			if not value and is_cast_source(): translator.enabled = false
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
	_failure_state = ""; _failure_until = 0
	translator.reset(true); _stored.clear(); report = {}; _epoch = -1; _payload = ""
	return true

func active() -> bool: return enabled and _allowed()

func _configure(wanted: bool) -> bool:
	if is_mirror():
		var language := source if wanted else ""
		if _payload != "mirror:" + language:
			if not video.platform.airplay_receiver_captions(_cast_token, language): return false
			_payload = "mirror:" + language
			_mirror_sequence = -1; _mirror_cues.clear()
		_session = video.media.session_id
		return true
	# Recognized original text is stored per video only where per-file settings may persist.
	var media := "" if is_cast_source() else Memory.key_for(_source)
	var payload := JSON.stringify({"enabled": wanted, "language": source, "lead": lead, "target": target,
		"media": media, "persist": not media.is_empty() and Privacy.persist_allowed(_source), "network": is_cast_source() or not Privacy.is_local(_source)})
	if payload != _payload or _session != video.media.session_id:
		if _session != video.media.session_id: report = {}; translator.reset(true)
		if video.platform.set_mpv_listening(video.media.session_id, payload):
			_payload = payload; _session = video.media.session_id
		else: return false
	return true

func _stop_cast(state: String = "") -> void:
	set_option("listening_enabled", false)
	_failure_state = state; _failure_until = Time.get_ticks_msec() + 6000
	_configure(false)

func _failure_notice() -> String:
	return I18n.t(status_label(_failure_state)) if is_cast_source() and _allowed() and Time.get_ticks_msec() < _failure_until else ""

func tick() -> void:
	if not Methods.supports(video.platform, "set_mpv_listening") or video.media.session_id <= 0: return
	if is_cast_source() and enabled and not _allowed(): _stop_cast()
	var wanted := active()
	if not _configure(wanted) and wanted and is_cast_source():
		_stop_cast("listening_error"); return
	if not wanted:
		if translator.enabled: translator.enabled = false; translator.reset(true)
		report = {}; return
	if Time.get_ticks_msec() < _poll_at: return
	_poll_at = Time.get_ticks_msec() + 100
	var incoming: Variant = JSON.parse_string(video.platform.airplay_receiver_caption_status(_cast_token) if is_mirror() else video.platform.get_mpv_listening(video.media.session_id))
	if not incoming is Dictionary: return
	if is_mirror(): incoming = _mirror_report(incoming)
	report = incoming
	if is_cast_source() and str(report.get("state", "")) in FAILURES:
		_stop_cast(str(report.state)); return
	if int(report.get("cache_instance", -1)) != _cache_instance:
		_cache_instance = int(report.get("cache_instance", -1)); _stored.clear()
	_received_at = Time.get_ticks_msec()
	var epoch := int(report.get("epoch", -1))
	if epoch != _epoch:
		_epoch = epoch; translator.reset() # Retain bounded translations when seeking within this video.
	var translate := not target.is_empty() and Protocol.language(source) != target
	translator.enabled = translate
	var cues: Array = report.get("cues", [])
	if translate:
		Tasks.seed(cues, translator, Protocol.language(source), target)
		translator.observe_sentences(cues, Protocol.language(source), target)
		translator.tick(true)
		Tasks.store(video.platform, report, cues, translator, _stored)
	# Readiness controls subtitle availability only; the video keeps playing.
	# A failed provider falls back to original text.
	var pending: bool = not translator.current.is_empty() or not translator.jobs.is_empty()
	if not is_mirror() and report.get("buffered", false) and (not translate or not pending):
		video.platform.listening_ready(video.media.session_id, epoch)

## Live speech cannot be read ahead. Present each new result against the active
## player's clock; retain it across polling and processing revisions, never on disk.
func _mirror_report(incoming: Dictionary) -> Dictionary:
	var position: float = video.control.observed_position_ms / 1000.0
	var sequence := int(incoming.get("sequence", -1))
	if sequence != _mirror_sequence:
		_mirror_sequence = sequence
		var lines := PackedStringArray()
		for cue: Dictionary in incoming.get("cues", []):
			var line := str(cue.get("text", "")).strip_edges()
			if not line.is_empty(): lines.append(line)
		if not lines.is_empty(): _mirror_cues = [{"start": position, "end": position + 6.0, "text": " ".join(lines)}]
	return {"state": incoming.get("state", "off"), "phase": "recognition", "epoch": incoming.get("generation", 0), "cues": _mirror_cues,
		"position": position, "playing": true, "buffered": true, "cache_persistent": false}

## -1 when no line shows at [position], 0 when it shows untranslated, 1 when translated.
func translation_at(position: float) -> int:
	if not active() or not is_finite(position): return -1
	for cue: Dictionary in report.get("cues", []):
		if position < float(cue.get("start", -1)) or position >= float(cue.get("end", -1)): continue
		var key := Protocol.cache_key(Protocol.normalize(str(cue.get("text", "")), Protocol.language(source)), Protocol.language(source), target)
		return 0 if str(translator.cache.get(key, {}).get("text", "")).is_empty() else 1
	return -1

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
	var notice := _failure_notice()
	var can_start := available() or active()
	var cast_entry := is_cast_source() and _allowed() and (is_mirror() or _source.begins_with("http://") or _source.begins_with("https://"))
	var hint := ""
	if cast_entry and not can_start:
		hint = "Audio track unavailable" if video.media.playback.get("details", {}).get("audio_tracks", []).is_empty() else "Available for seekable videos"
	var position := playback_position(float(report.get("position", 0.0)))
	return {"listening_available": can_start, "listening_visible": can_start or cast_entry, "listening_unavailable_hint": hint,
		"listening_enabled": active(), "listening_source": source, "listening_live_source": is_mirror(),
		"listening_target": target, "listening_lead": lead, "listening_state": _failure_state if not notice.is_empty() else report.get("state", "off"),
		"listening_notice": notice,
		"listening_caption": preparation_caption(), "listening_status_caption": status_caption(position),
		"listening_detail_caption": detail_caption(position), "listening_cache_complete": report.get("cache_complete", false),
		"listening_cache_persistent": report.get("cache_persistent", false), "listening_translation_complete": report.get("translation_complete", false)}

func preparation_caption() -> String:
	if not active() or report.get("state", "preparing") not in ["preparing", "catching_up"]: return ""
	var phase := str(report.get("phase", "models"))
	if phase == "task": return I18n.t("Pre-generating · %d%%") % clampi(int(report.get("cache_progress", 0)), 0, 100)
	if phase == "models":
		var progress := int(report.get("model_progress", -1))
		return I18n.t("Checking speech model…") + (" · %d%%" % progress if progress >= 0 else "")
	if phase == "model_load": return I18n.t("Loading speech model…")
	if phase == "audio_open": return I18n.t("Opening audio…")
	if report.get("buffered", false) and not target.is_empty() and Protocol.language(source) != target:
		var queued: int = translator.pending_count()
		return I18n.t("Translating · %d pending") % queued if queued > 0 else I18n.t("Preparing translation…")
	return I18n.t("Recognizing speech…")

## Head-locked status while the control bar is hidden: what is happening when
## no subtitle shows, and why a shown subtitle is still untranslated.
func status_caption(position: float) -> String:
	if not active():
		_empty_caption_since = -1
		return _failure_notice()
	var epoch := int(report.get("epoch", -1))
	if epoch != _caption_epoch or absf(position - _caption_position) > 2.0:
		_empty_caption_since = -1
	_caption_epoch = epoch; _caption_position = position
	var state := str(report.get("state", ""))
	if state in FAILURES:
		_empty_caption_since = -1
		return I18n.t(status_label(state))
	var shown := translation_at(position)
	if shown >= 0: _empty_caption_since = -1
	# Current text wins over preparation of future lines. These observations do
	# not change the native ready handshake, queue, or subtitle display timing.
	if shown == 1 or (shown == 0 and (target.is_empty() or Protocol.language(source) == target)): return ""
	if shown < 0:
		var preparing := preparation_caption()
		if not preparing.is_empty():
			_empty_caption_since = -1
			return preparing
		if state != "ready": return I18n.t(status_label(state))
		for cue: Dictionary in report.get("cues", []):
			if float(cue.get("start", -1)) > position and not str(cue.get("text", "")).is_empty():
				_empty_caption_since = -1
				return I18n.t("Waiting for next subtitle")
		if _empty_caption_since == -1: _empty_caption_since = Time.get_ticks_msec()
		return I18n.t("No text recognized for this segment") if Time.get_ticks_msec() - _empty_caption_since >= 4000 else ""
	if not target.is_empty() and Protocol.language(source) != target:
		var waiting: int = translator.cooldown_ms()
		if waiting > 0 and translator.pending_count() > 0:
			return I18n.t("Translation busy · retrying in %d s, showing original") % ceili(waiting / 1000.0)
		if translator.failing(): return I18n.t("Some lines untranslated · showing original")
		var pending: int = translator.pending_count()
		if pending > 0: return I18n.t("Translating · %d pending") % pending
		if shown == 0: return I18n.t("Some lines untranslated · showing original")
	return ""

## Read-only report summary. Audio progress is not a promise of subtitle coverage.
func detail_caption(position: float) -> String:
	if not active(): return ""
	var originals := 0
	var translations := 0
	var translate := not target.is_empty() and Protocol.language(source) != target
	for cue: Dictionary in report.get("cues", []):
		if float(cue.get("end", -1)) <= position or str(cue.get("text", "")).is_empty(): continue
		originals += 1
		var key := Protocol.cache_key(Protocol.normalize(str(cue.text), Protocol.language(source)), Protocol.language(source), target)
		if translate and not str(translator.cache.get(key, {}).get("text", "")).is_empty(): translations += 1
	var lines := I18n.t("Upcoming · %d original / %d translated") % [originals, translations] if translate else I18n.t("Upcoming · %d original") % originals
	return I18n.t("Audio processed · %d s ahead") % maxi(0, int(report.get("ahead", 0.0))) + "\n" + lines

static func rows(state: Dictionary) -> Array:
	if not state.get("listening_visible", state.get("listening_available", false)): return []
	var result := [{"title": "Live captions", "field": {"key": "listening_enabled", "value": state.get("listening_enabled", false), "switch": true, "hint": "Live captions",
		"choices": [{"value": false, "label": "Off"}, {"value": true, "label": "On"}]}}]
	result.append({"title": "Original language", "field": {"key": "listening_source", "value": state.get("listening_source", "ja"), "choices": [
		{"value": "ja", "label": "Japanese"}, {"value": "zh", "label": "Chinese"}, {"value": "en", "label": "English"}]}})
	result.append({"title": "Translation", "field": {"key": "listening_target", "value": state.get("listening_target", ""), "hint": "Recognized text is sent to Microsoft", "choices": [{"value": "", "label": "No translation"}] + Protocol.target_choices()}})
	if not state.get("listening_live_source", false):
		result.append({"title": "Audio lookahead", "field": {"key": "listening_lead", "value": state.get("listening_lead", 12), "choices": [
			{"value": 8, "label": "8 s"}, {"value": 12, "label": "12 s"}, {"value": 20, "label": "20 s"}]}})
	if state.get("listening_enabled", false) and state.has("listening_detail_caption"): result.append({"listening_detail": true})
	if state.get("subtitle_task_supported", false) and state.get("listening_enabled", false):
		result.append({"subtitle_task": true})
		if not state.get("subtitle_task", {}).is_empty() or state.get("listening_cache_complete", false) or not str(state.get("subtitle_task_notice", "")).is_empty(): result.append({"subtitle_task_status": true})
	return result
