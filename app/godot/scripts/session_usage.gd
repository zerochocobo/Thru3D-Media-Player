extends RefCounted
## Process-local foreground time. Never persisted with viewing history.
static var _elapsed := 0
static var _since := 0
static var _blocks := {}

static func start(now: int = Time.get_ticks_msec()) -> void:
	_elapsed = 0; _since = now; _blocks.clear()

static func suspend(reason: String, value: bool, now: int = Time.get_ticks_msec()) -> void:
	if _blocks.has(reason) == value: return
	if _blocks.is_empty(): _elapsed += maxi(0, now - _since)
	if value: _blocks[reason] = true
	else: _blocks.erase(reason)
	_since = now

static func milliseconds(now: int = Time.get_ticks_msec()) -> int:
	return _elapsed + (maxi(0, now - _since) if _blocks.is_empty() else 0)
