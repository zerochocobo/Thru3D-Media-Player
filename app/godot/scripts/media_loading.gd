extends RefCounted
const I18n := preload("res://scripts/i18n.gd")
const PHASES := {"connecting": "Connecting…", "reading": "Reading media…", "reading_disc": "Reading disc…", "preparing": "Preparing playback…", "buffering": "Buffering…"}

static func remote(uri: String) -> bool:
	return uri.get_slice(":", 0).to_lower() in ["http", "https", "smb", "cloud", "medialib"]

static func caption(status: Dictionary) -> String:
	if not status.get("remote", false): return ""
	var phase := str(PHASES.get(str(status.get("phase", "connecting")), "Reading media…"))
	var text := I18n.t(phase) + " · %d s" % maxi(0, int(status.get("elapsed_ms", 0)) / 1000)
	if status.has("bytes_per_second"):
		var speed := maxf(0, float(status.bytes_per_second))
		if is_finite(speed): text += " · " + ("%.1f MB/s" % (speed / 1000000) if speed >= 1000000 else "%.0f KB/s" % (speed / 1000))
	return text
