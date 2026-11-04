extends RefCounted
## A viewing session survives decoder generations, seeks and internal close/open handoffs.
const Methods := preload("res://scripts/platform_methods.gd")
const INTERVAL_KEY := "server_report_interval_ms"
const DEFAULT_INTERVAL_MS := 10000

static func normalize_interval(value: Variant) -> int:
	if not (value is int or value is float) or not is_finite(float(value)): return DEFAULT_INTERVAL_MS
	return snappedi(int(clampf(float(value), 500, 20000)), 500)

static func load_interval(settings: ConfigFile) -> int:
	return normalize_interval(settings.get_value("media_server", "report_interval_ms", DEFAULT_INTERVAL_MS))

var uri := ""
var token := ""
var next_poll := 0
var last_state := {}
var ended := false
var seek_serial := 0

func begin(value: String) -> void:
	if value == uri and not token.is_empty(): return
	uri = value if value.begins_with("medialib://") and value.contains("/scene/") else ""
	token = str(Time.get_ticks_usec()) if not uri.is_empty() else ""
	last_state = {}; next_poll = 0; ended = false; seek_serial = 0

func poll(video: Node, force: bool = false) -> void:
	if token.is_empty() or video.local_uri != uri or not Methods.supports(video.platform, "media_server_playback"): return
	var now := Time.get_ticks_msec()
	if not force and now < next_poll: return
	next_poll = now + 250
	if video.media.state == "failed":
		if video._recover: return # A GL context handoff will reopen this same viewing session.
		finish(video.platform); return
	# Never upload a requested seek target, a stale generation, or a preview's clock.
	if video.vr_passthrough.active():
		if not last_state.is_empty() and not last_state.paused:
			last_state.paused = true
			video.platform.media_server_playback(JSON.stringify(last_state))
		return
	if video._waiting_first or not video._pending_revision.is_empty() \
		or video.control.pending or video.control.in_flight > 0: return
	var pair: Dictionary = video.media.last_pair
	if not pair.get("source_pts_verified", false) or int(pair.get("session_id", 0)) != video.media.session_id \
		or int(pair.get("generation", 0)) != video.media.generation or int(pair.get("pts_us", -1)) < 0: return
	if video.media.state not in ["playing", "paused", "buffering", "ready", "ended"]: return
	if ended:
		if video.media.state == "ended": return
		token = str(Time.get_ticks_usec()); ended = false
	var details: Dictionary = video.media.playback.get("details", {})
	var finished: bool = video.media.state == "ended" and not video.loop_enabled and video.playback_end_ready()
	var state := {"action": "state", "token": token, "uri": uri, "position_ms": int(pair.pts_us) / 1000,
		"paused": not video.requested_play or str(details.get("paused", "no")) == "yes",
		"can_seek": details.get("seekable", "no") == "yes", "muted": video.audio_muted,
		"volume": roundi(video.audio_volume), "speed": video.playback_speed, "seek": seek_serial,
		"audio_selection": str(details.get("audio_track_id", "")),
		"subtitle_selection": str(details.get("subtitle", {}).get("track_id", ""))}
	for kind in ["audio", "subtitle"]:
		var stream: Variant = stream_index(details, kind)
		if stream != null: state[kind] = stream
	video.platform.media_server_playback(JSON.stringify(state))
	last_state = state
	if finished:
		video.platform.media_server_playback(JSON.stringify({"action": "stop", "token": token}))
		ended = true

func finish(platform: Object, preserve: bool = false) -> void:
	if preserve: return
	if not token.is_empty() and Methods.supports(platform, "media_server_playback"):
		platform.media_server_playback(JSON.stringify({"action": "stop", "token": token}))
	uri = ""; token = ""; last_state = {}; ended = false

static func stream_index(details: Dictionary, kind: String) -> Variant:
	var selected := str(details.get("audio_track_id", "")) if kind == "audio" else str(details.get("subtitle", {}).get("track_id", ""))
	if selected in ["no", "0", "-1"]: return -1
	for track in details.get(kind + "_tracks", []):
		if str(track.get("id", "")) == selected:
			# MPV IDs and external-file stream indexes are not server stream indexes.
			if track.get("external", false): return null
			var index := int(track.get("stream_index", -1))
			return index if index >= 0 else null
	return null
