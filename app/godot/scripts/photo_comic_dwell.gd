extends RefCounted
## Monotonic milliseconds; tracking gaps pause accumulation. No button binding.
const DWELL_MS := 600
const JITTER_MS := 150
const REARM_MS := 300
var target := ""
var elapsed := 0
var last := -1
var missing := -1
var fired := false
var progress := 0.0
var switched := false

func reset() -> void:
	target = ""; elapsed = 0; last = -1; missing = -1; fired = false; progress = 0.0; switched = false

func update(hit: String, now: int) -> bool:
	switched = false
	if hit.is_empty():
		if missing < 0: missing = now
		if now - missing >= REARM_MS: reset(); missing = now
		last = now
		return false
	if hit != target:
		switched = true
		target = hit; elapsed = 0; fired = false; last = now; missing = -1; progress = 0.0
		return false
	if missing >= 0:
		if now - missing >= REARM_MS: fired = false; elapsed = 0
		elif now - missing > JITTER_MS and not fired: elapsed = 0
		missing = -1
	elif last >= 0 and not fired:
		# A stalled frame is a tracking gap, never an instant dwell completion.
		if now - last <= JITTER_MS: elapsed += maxi(0, now - last)
		else: elapsed = 0
	last = now
	progress = clampf(float(elapsed) / DWELL_MS, 0, 1)
	if elapsed >= DWELL_MS and not fired: fired = true; return true
	return false
