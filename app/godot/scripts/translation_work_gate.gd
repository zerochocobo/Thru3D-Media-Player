extends RefCounted
## One provider batch across live subtitles, reading and background film jobs.
static var owner: WeakRef
static var cooldown := {"Bing": 0, "Edge": 0}
static var next_at := 0
static var demand := {}

static func acquire(client: RefCounted, priority: int) -> bool:
	var now := Time.get_ticks_msec()
	demand[client.get_instance_id()] = {"priority": priority, "until": now + 600}
	if owner and owner.get_ref() != null: return owner.get_ref() == client
	if now < next_at: return false
	for id in demand.keys():
		if int(demand[id].until) < now: demand.erase(id)
		elif int(demand[id].priority) > priority: return false
	owner = weakref(client)
	demand.erase(client.get_instance_id())
	return true

static func release(client: RefCounted, spacing: int = 0) -> void:
	demand.erase(client.get_instance_id())
	if owner and owner.get_ref() == client:
		owner = null
		next_at = maxi(next_at, Time.get_ticks_msec() + spacing)
