extends RefCounted
## Playing, unpaused and not buffering while MPV's playback clock stands still: a decoder or
## audio-clock stall (sound may play on while the picture freezes). Reports it once; recovery is
## bounded to one attempt per minute, so a source that keeps stalling is never reopened in a loop.
const TIMEOUT_MS := 4000
const RETRY_MS := 60000
var position := -1.0
var since_ms := 0
var retry_after_ms := 0

func reset() -> void:
	position = -1.0
	since_ms = 0

## active: the user wants playback and MPV reports it unpaused, not buffering, not at EOF,
## with no seek or decoder revision pending. Returns true when a recovery should start.
func observe(active: bool, seconds: float, now_ms: int) -> bool:
	if not active or not is_finite(seconds) or seconds < 0.0:
		reset()
		return false
	if since_ms == 0 or seconds != position:
		position = seconds
		since_ms = now_ms
		return false
	if now_ms - since_ms < TIMEOUT_MS or now_ms < retry_after_ms:
		return false
	reset()
	retry_after_ms = now_ms + RETRY_MS
	return true
