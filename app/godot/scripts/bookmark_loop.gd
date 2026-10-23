extends RefCounted
## Session-only activation. All jumps use the player's revision / frame ownership path.
var player: Node3D
var selected := ""
var active := false
var scope := ""
var revision := -1
var segments: Array = []
var landing_sequence := -1

func _init(owner: Node3D) -> void:
	player = owner

func reset() -> void:
	selected = ""; active = false; scope = ""; revision = -1; segments.clear(); landing_sequence = -1

func sync() -> void:
	if scope != player.bookmark_scope():
		reset(); scope = player.bookmark_scope()
	if revision == player.bookmark_store.revision: return
	revision = player.bookmark_store.revision
	segments = player.bookmark_store.list_loops(player._bookmark_media_id)
	if current().is_empty(): selected = ""; active = false; landing_sequence = -1

func current() -> Dictionary:
	for segment in segments:
		if segment.id == selected: return segment
	return {}

func valid(segment: Dictionary) -> bool:
	return not segment.is_empty() and int(segment.a_ms) >= 0 and int(segment.b_ms) < player.control.duration_ms

func snapshot() -> Dictionary:
	sync()
	return {"bookmark_loops": segments, "bookmark_loop": current(), "bookmark_loop_active": active}

func stop() -> void:
	active = false; landing_sequence = -1

func manual_seek(target_ms: int) -> void:
	sync()
	var segment := current()
	if active and (not valid(segment) or target_ms < int(segment.a_ms) or target_ms >= int(segment.b_ms)): stop()
	# A user's replacement seek owns its completion, even when replacing a loop jump.
	landing_sequence = -1

func start(loop_id: String) -> bool:
	sync()
	var previous := selected
	selected = loop_id
	if not valid(current()) or not player.bookmark_seekable():
		selected = previous
		return false
	active = true
	return _return_to_a()

func _return_to_a() -> bool:
	if not player.seek_absolute(int(current().a_ms), player.SeekPolicy.EXACT, true):
		stop(); return false
	landing_sequence = player.control.sequence
	return true

func action(operation: String, payload: Dictionary, media_scope: String) -> String:
	if media_scope != player.bookmark_scope(): return ""
	sync()
	var id := str(payload.get("id", ""))
	match operation:
		"save":
			if not player.bookmark_seekable(): return "Loop unavailable"
			var times := {}
			for marker in player.bookmark_store.list_markers(player._bookmark_media_id): times[marker.id] = marker.position_ms
			var a := str(payload.get("a", "")); var b := str(payload.get("b", ""))
			if not times.has(a) or not times.has(b) or int(times[b]) >= player.control.duration_ms: return "Invalid loop range"
			var segment: Dictionary = player.bookmark_store.save_loop(player._bookmark_media_id, a, b, id)
			if segment.is_empty(): return player.bookmark_store.last_error
			if id == selected and (current().get("a") != a or current().get("b") != b): stop()
			sync()
			return "Loop saved"
		"start":
			if bool(player.narration.clone_state.get("opened", false)): return "Loop unavailable"
			var was_playing: bool = player.requested_play
			player.requested_play = true
			if start(id): return "Loop enabled"
			player.requested_play = was_playing
			return "Loop unavailable"
		"end":
			# Resolve the endpoint from saved definitions, never a supplied timestamp.
			for segment in segments:
				if segment.b != str(payload.get("marker", "")): continue
				if not valid(segment): return "Loop unavailable"
				if not player.bookmark_seekable():
					if active: stop(); return "Loop disabled"
					return "Loop unavailable"
				stop()
				return "" if player.seek_absolute(int(segment.b_ms), player.SeekPolicy.EXACT) else "Bookmark jump failed"
			return "Loop unavailable"
		"toggle":
			if active and id == selected: stop(); return "Loop disabled"
			return "Loop enabled" if start(id) else "Loop unavailable"
		"select":
			stop()
			selected = id
			if not valid(current()): selected = ""; return "Loop unavailable"
			return "" if player.seek_absolute(int(current().a_ms), player.SeekPolicy.EXACT) else "Bookmark jump failed"
		"delete":
			if not player.bookmark_store.remove_loop(player._bookmark_media_id, id): return "Bookmark save failed"
			sync()
			return "Loop deleted"
	return ""

func tick() -> void:
	sync()
	if not active: return
	if player.media.state in ["closed", "failed"] or not player.media.error.is_empty(): stop(); return
	var segment := current()
	# Duration/details can be temporarily unavailable while a revision is loading.
	if player._waiting_first or not player._pending_revision.is_empty() or player.control.pending or player.control.in_flight > 0: return
	if not valid(segment): stop(); return
	if player._is_frozen(): return
	var position: int = player.control.observed_position_ms
	if landing_sequence >= 0:
		landing_sequence = -1
		# A failed/incorrect landing must not cause an unbounded seek storm.
		if position < int(segment.a_ms) - 250 or position >= int(segment.b_ms): stop(); return
	if not player.requested_play: return
	if position >= int(segment.b_ms) or player.playback_end_ready(): _return_to_a()
