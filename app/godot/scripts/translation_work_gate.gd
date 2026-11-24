extends RefCounted
## One provider batch across live subtitles, reading and background film jobs.
static var owner: WeakRef
static var cooldown := {"Bing": 0, "Edge": 0}
static var next_at := 0
static var demand := {}
## Debug A/B only: scheduling as it was before 2026-11-24 (no preemption,
## shared spacing, 12 s live timeout, any reply mismatch cools Bing down).
static var legacy := false
## Live subtitles waiting this long take the slot from a lower-priority batch.
const PREEMPT_MS := 1500

static func acquire(client: RefCounted, priority: int) -> bool:
	var now := Time.get_ticks_msec()
	var id := client.get_instance_id()
	var previous: Dictionary = demand.get(id, {})
	var since: int = int(previous.since) if not previous.is_empty() and int(previous.until) >= now else now
	demand[id] = {"priority": priority, "until": now + 600, "since": since}
	if owner and owner.get_ref() != null:
		var holder: Object = owner.get_ref()
		if holder == client: return true
		if legacy or now - since < PREEMPT_MS or not "priority" in holder or int(holder.priority) >= priority or not holder.has_method("preempt"): return false
		holder.preempt(); owner = null
	if now < next_at: return false
	for key in demand.keys():
		if int(demand[key].until) < now: demand.erase(key)
		elif int(demand[key].priority) > priority: return false
	owner = weakref(client)
	demand.erase(id)
	return true

static func release(client: RefCounted, spacing: int = 0) -> void:
	demand.erase(client.get_instance_id())
	if owner and owner.get_ref() == client:
		owner = null
		next_at = maxi(next_at, Time.get_ticks_msec() + spacing)
