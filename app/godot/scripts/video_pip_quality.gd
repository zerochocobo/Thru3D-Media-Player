extends RefCounted
## Only atlas density changes. Magnification, source cadence and the main refresh policy are untouched.
const WIDTHS := [256, 384, 512, 768, 1024]
var tier := 2
var changed_at := 0
var busy_at := 0
var overloaded_at := -1
var recovering_at := -1

func settle(now: int) -> void:
	busy_at = now; overloaded_at = -1; recovering_at = -1

func update(now: int, desired: int, gpu_us: int, frame_p95_ms: float, refresh_hz: float, busy: bool) -> int:
	var wanted := 0
	while wanted < WIDTHS.size() - 1 and WIDTHS[wanted] < desired: wanted += 1
	if busy:
		busy_at = now; overloaded_at = -1; recovering_at = -1
		return WIDTHS[tier]
	if now - busy_at < 2000: return WIDTHS[tier]
	var budget_ms := 1000.0 / clampf(refresh_hz, 60, 144)
	# Main-video/inference/decoder stalls alone must not blur a cheap crop. Only
	# reduce density when the measured atlas itself consumes meaningful GPU time.
	var overloaded := gpu_us > budget_ms * 1000 * 0.15 or (gpu_us > budget_ms * 1000 * 0.075 and frame_p95_ms > budget_ms * 1.15)
	var spare := gpu_us > 0 and gpu_us < budget_ms * 1000 * 0.075 and frame_p95_ms < budget_ms * 1.06
	if overloaded:
		recovering_at = -1
		if overloaded_at < 0: overloaded_at = now
		if tier > 0 and now - overloaded_at >= 2500:
			tier -= 1; changed_at = now; overloaded_at = -1
	elif tier > wanted and now - changed_at >= 2500:
		tier -= 1; changed_at = now; overloaded_at = -1; recovering_at = -1
	elif spare and tier < wanted:
		overloaded_at = -1
		if recovering_at < 0: recovering_at = now
		if now - recovering_at >= 12000:
			tier += 1; changed_at = now; recovering_at = -1
	else:
		overloaded_at = -1; recovering_at = -1
	return WIDTHS[tier]
