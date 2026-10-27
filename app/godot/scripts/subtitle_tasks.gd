extends RefCounted
const Methods := preload("res://scripts/platform_methods.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Memory := preload("res://scripts/file_listening_memory.gd")
const Protocol := preload("res://scripts/comic_translation_protocol.gd")
const Client := preload("res://scripts/comic_translation.gd")
const I18n := preload("res://scripts/i18n.gd")
var video: Node3D
var translator: RefCounted
var mode := "original"
var policy := "playback"
var report := {}
var _poll := 0
var _work := {}
var _stamp := ""
var _sent := {}
var notice := ""

func _init(owner: Node3D) -> void:
	video = owner
	translator = Client.new(owner, false)
	translator.priority = 0; translator.request_spacing_ms = 2000

func load_settings(settings: ConfigFile) -> void:
	mode = str(settings.get_value("subtitle_tasks", "mode", "original"))
	policy = str(settings.get_value("subtitle_tasks", "policy", "playback"))
	if mode not in ["original", "translated"]: mode = "original"
	if policy not in ["playback", "idle"]: policy = "playback"

func option(key: String, value: Variant, settings: ConfigFile) -> bool:
	match key:
		"subtitle_task_mode":
			if value not in ["original", "translated"]: return false
			mode = value; settings.set_value("subtitle_tasks", "mode", mode)
		"subtitle_task_policy":
			if value not in ["playback", "idle"]: return false
			policy = value; settings.set_value("subtitle_tasks", "policy", policy)
		_: return false
	return true

func supported() -> bool: return Methods.supports(video.platform, "subtitle_tasks_request")

func command(value: Dictionary) -> bool:
	if not supported(): return false
	var accepted: bool = video.platform.subtitle_tasks_request(JSON.stringify(value))
	notice = "" if accepted else I18n.t("Unable to add subtitle task")
	_poll = 0
	return accepted

func effective_target() -> String:
	return video.listening.target if mode == "translated" and Protocol.language(video.listening.source) != video.listening.target else ""

func enqueue() -> bool:
	if not video.listening.available(): return false
	var uri: String = video.local_uri
	return command({"operation": "enqueue", "session_id": video.media.session_id,
		"media": Memory.key_for(uri), "title": video.display_name, "language": video.listening.source,
		"target": effective_target(),
		"persist": Privacy.persist_allowed(uri), "network": not Privacy.is_local(uri)})

func tick() -> void:
	if not supported() or Time.get_ticks_msec() < _poll: return
	_poll = Time.get_ticks_msec() + 300
	var details: Dictionary = video.media.playback.get("details", {})
	var track := -1
	for row: Dictionary in details.get("audio_tracks", []):
		if int(row.get("id", -2)) == int(details.get("audio_track_id", -1)): track = int(row.get("stream_index", -1))
	command_context({"operation": "context", "session_id": video.media.session_id, "policy": policy, "memory": Privacy.file_settings,
		"media": Memory.key_for(video.local_uri), "network": not Privacy.is_local(video.local_uri),
		"playing": str(details.get("paused", "yes")) == "no", "buffering": str(details.get("paused_for_cache", "no")) == "yes",
		"listening": video.listening.active(), "language": video.listening.source, "track": track,
		"playlist": int(video.disc.playing), "position": video.listening.playback_position(float(details.get("position_seconds", 0))),
		"lead": video.listening.lead, "protected_locked": Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked})
	var next: Variant = JSON.parse_string(video.platform.subtitle_tasks_status())
	if next is Dictionary: report = next
	_translate()

func command_context(value: Dictionary) -> void:
	video.platform.subtitle_tasks_request(JSON.stringify(value))

func _translate() -> void:
	var next: Variant = JSON.parse_string(video.platform.subtitle_translation_work())
	if not next is Dictionary: next = {}
	var stamp := str([next.get("id"), next.get("cache_instance"), next.get("target")])
	if stamp != _stamp:
		translator.reset(true); _sent.clear(); _stamp = stamp
	_work = next
	translator.enabled = not _work.is_empty()
	if not translator.enabled: return
	var source := Protocol.language(str(_work.language))
	var target := str(_work.target)
	var rows: Array = _work.get("cues", [])
	# A malformed or overlong result must remain retryable, never count as translated.
	if rows.any(func(row): return Protocol.normalize(str(row.text), source).length() > 1000):
		command({"operation": "translation_error", "id": _work.id}); translator.reset(); return
	translator.observe_sentences(rows, source, target)
	if translator.failing():
		command({"operation": "translation_error", "id": _work.id}); translator.reset(); return
	translator.tick(true)
	store(video.platform, _work, rows, translator, _sent)

static func store(platform: Object, identity: Dictionary, cues: Array, client: RefCounted, sent: Dictionary) -> void:
	if not Methods.supports(platform, "subtitle_translation_store") or str(identity.get("cache_key", "")).is_empty(): return
	var rows := []
	for cue: Dictionary in cues:
		var raw := str(cue.get("text", ""))
		var key := Protocol.cache_key(Protocol.normalize(raw, client.source), client.source, client.target)
		var text := str(client.cache.get(key, {}).get("text", ""))
		if not text.is_empty() and sent.get(raw) != text and str(cue.get("translation", "")) != text:
			rows.append({"text": raw, "translation": text})
	if rows.is_empty(): return
	if platform.subtitle_translation_store(JSON.stringify({"cache_key": identity.cache_key, "cache_instance": identity.cache_instance, "target": client.target, "rows": rows})):
		for row: Dictionary in rows: sent[row.text] = row.translation
	while sent.size() > 2048: sent.erase(sent.keys()[0])

static func seed(cues: Array, client: RefCounted, source: String, target: String) -> void:
	for cue: Dictionary in cues:
		var translated := str(cue.get("translation", ""))
		if translated.is_empty(): continue
		var key := Protocol.cache_key(Protocol.normalize(str(cue.text), source), source, target)
		client.cache[key] = {"text": translated, "provider": "cache"}

func snapshot() -> Dictionary:
	var current := {}
	for job: Dictionary in report.get("jobs", []):
		if job.media == Memory.key_for(video.local_uri) and job.language == video.listening.source and job.target == effective_target() and job.get("current", true) and job.state != "cancelled": current = job; break
	return {"subtitle_tasks": report, "subtitle_task_mode": mode, "subtitle_task_policy": policy,
		"subtitle_task": current, "subtitle_task_supported": supported(), "subtitle_task_notice": notice,
		"listening_source": video.listening.source, "listening_target": video.listening.target, "listening_lead": video.listening.lead}

static func caption(job: Dictionary) -> String:
	var state := str(job.get("state", "queued"))
	var reason := str(job.get("reason", ""))
	var label: String = {"queued": "Queued", "listening": "Transcribing", "translating": "Translating", "paused": "Paused", "complete": "Complete", "cancelled": "Cancelled", "error": "Retry required"}.get(state, "Queued")
	if reason in ["playback_priority", "resources", "privacy_locked", "paused"]: label = "Waiting for playback" if reason == "playback_priority" else ("Waiting for resources" if reason == "resources" else "Paused")
	if state == "error": label = {"source_unavailable": "Unable to read audio from the source", "source_incomplete": "Audio ended unexpectedly", "source_changed": "Source changed; add the task again", "model_changed": "Speech model changed; add the task again", "cache_write_error": "Unable to save subtitle cache", "cache_full": "Subtitle cache is full", "translation_error": "Translation failed; retry"}.get(reason, label)
	var result := I18n.t(label)
	if state == "listening" and reason.is_empty():
		result = I18n.t({"models": "Checking speech model…", "model_load": "Loading speech model…", "audio_open": "Opening audio…"}.get(str(job.get("phase", "")), "Transcribing"))
	if state in ["listening", "queued"]: result += " · %d%%" % int(job.get("progress", 0))
	if state == "translating": result += " · %d/%d" % [int(job.get("translated", 0)), int(job.get("total", 0))]
	return result
