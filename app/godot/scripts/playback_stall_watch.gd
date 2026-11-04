extends RefCounted
## Playing, unpaused and not buffering while MPV's playback clock stands still: a decoder or
## audio-clock stall (sound may play on while the picture freezes). Reports it once; recovery is
## bounded to one attempt per minute, so a source that keeps stalling is never reopened in a loop.
## A stall that returns at the position a reopen already restarted from is reported as stuck:
## another reopen cannot help (e.g. the system stopped consuming the app's audio).
const TIMEOUT_MS := 4000
const RETRY_MS := 60000
## The clock must move this far past the recovered position before a later stall counts as new.
const SAME_POSITION_S := 1.0
const NONE := ""
const RECOVER := "recover"
const STUCK := "stuck"
var position := -1.0
var since_ms := 0
var retry_after_ms := 0
var recovered_at := -1.0

func reset() -> void:
	position = -1.0
	since_ms = 0

## A different file was opened: earlier recoveries say nothing about it.
func forget() -> void:
	reset()
	retry_after_ms = 0
	recovered_at = -1.0

## active: the user wants playback and MPV reports it unpaused, not buffering, not at EOF,
## with no seek or decoder revision pending. Returns RECOVER when a reopen should start,
## STUCK when the stall repeats where the last reopen restarted.
func observe(active: bool, seconds: float, now_ms: int) -> String:
	if not active or not is_finite(seconds) or seconds < 0.0:
		reset()
		return NONE
	if recovered_at >= 0.0 and absf(seconds - recovered_at) > SAME_POSITION_S:
		recovered_at = -1.0
	if since_ms == 0 or seconds != position:
		position = seconds
		since_ms = now_ms
		return NONE
	if now_ms - since_ms < TIMEOUT_MS:
		return NONE
	if recovered_at >= 0.0:
		forget()
		return STUCK
	if now_ms < retry_after_ms:
		return NONE
	reset()
	recovered_at = seconds
	retry_after_ms = now_ms + RETRY_MS
	return RECOVER
