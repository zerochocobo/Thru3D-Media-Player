extends RefCounted
## One policy for visible controls and execution (including controller shortcuts).
const HIDDEN := ["previous_video", "next_video", "favorite", "bookmarks", "disc_title", "disc_menu", "capture_screenshot", "capture_record", "voice_sample", "clone_voice", "lock_mode"]

static func capabilities(video: Node) -> Dictionary:
	var details: Dictionary = video.media.playback.get("details", {})
	if not details.has("seekable") and not video.cast_capability_cache.is_empty(): return video.cast_capability_cache.duplicate()
	var seekable: bool = video.control.duration_ms > 0 and details.get("seekable", "no") == "yes" and details.get("partially_seekable", "no") != "yes"
	var result := {"seek": seekable, "effects": seekable, "audio": details.get("audio_tracks", []).size() > 0, "multi_audio": details.get("audio_tracks", []).size() > 1}
	if details.has("seekable"): video.cast_capability_cache = result.duplicate()
	return result

static func allows(caps: Dictionary, operation: String) -> bool:
	if operation in HIDDEN: return false
	if operation in ["seek", "seek_mode", "playback_speed", "loop", "repeat_one"]: return caps.get("seek", false)
	if operation in ["depth", "depth_strength", "alpha", "color_grade"]: return caps.get("effects", false)
	if operation in ["sequence", "repeat_all"]: return false
	return true

static func apply(state: Dictionary, caps: Dictionary) -> Dictionary:
	state.cast = caps
	state.has_previous_video = false; state.has_next_video = false
	state.bookmarks = []; state.bookmark_ready = false; state.bookmark_seekable = false
	state.favorite_available = false; state.capture = {"available": false}
	state.disc_titles = []; state.disc_menu_available = false
	state.subtitle_files_available = false; state.subtitle_auto_load = false
	state.narration_clone_supported = false
	state.cast_effects_hint = "Available for seekable videos"
	return state
