extends RefCounted
## Each movie has two verified banks. Failed mutations leave both memory and disk unchanged.
const MAX_MARKERS := 500
const MAX_BYTES := 262144
const VERSION := 2
const MAX_LOOPS := 500
const MIN_LOOP_MS := 2000
const MAX_TIME := 2147483647
const Memory := preload("res://scripts/file_mode_memory.gd")
var directory: String
var records: Dictionary = {}
var blocked: Dictionary = {}
var undo: Dictionary = {}
var revision := 0
var last_error := ""

func _init(path: String = "user://bookmarks") -> void:
	directory = path
	load_saved()

static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) == floorf(float(value)) and float(value) >= minimum and float(value) <= maximum

static func fingerprint(basename: String, size: Variant) -> String:
	if basename.is_empty() or basename.length() > 512 or not integer(size, 1, 9007199254740991): return ""
	return JSON.stringify([basename, int(size)]).sha256_text()

func _path(id: String, bank: int) -> String:
	return directory.path_join("%s_%d.json" % [id, bank])

func _read(path: String, id: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > MAX_BYTES: return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK: return {}
	var envelope: Variant = parser.data
	if not envelope is Dictionary: return {}
	if integer(envelope.get("schema_version"), VERSION + 1, 9007199254740991):
		blocked[id] = true
		return {}
	if (envelope.get("schema_version") != 1 and envelope.get("schema_version") != VERSION) or not envelope.get("payload_json") is String: return {}
	if envelope.payload_json.sha256_text() != envelope.get("payload_sha256"): return {}
	if parser.parse(envelope.payload_json) != OK: return {}
	var value: Variant = parser.data
	if not value is Dictionary or value.get("id") != id or not integer(value.get("sequence"), 1, 9007199254740990): return {}
	if not value.get("aliases") is Array or value.aliases.size() > 64 or value.aliases.is_empty(): return {}
	for alias in value.aliases:
		if not alias is String or alias.length() != 64 or not alias.is_valid_hex_number(false): return {}
	if not value.get("fingerprint") is String or (not value.fingerprint.is_empty() and (value.fingerprint.length() != 64 or not value.fingerprint.is_valid_hex_number(false))): return {}
	if not value.get("markers") is Array or value.markers.size() > MAX_MARKERS: return {}
	var ids := {}
	for marker in value.markers:
		if not marker is Dictionary or not marker.get("id") is String or marker.id.length() != 32 or not marker.id.is_valid_hex_number(false) or ids.has(marker.id): return {}
		if not integer(marker.get("position_ms"), 0, MAX_TIME) or not integer(marker.get("created_at_ms"), 0, 9007199254740991): return {}
		marker.position_ms = int(marker.position_ms)
		marker.created_at_ms = int(marker.created_at_ms)
		ids[marker.id] = true
	if envelope.schema_version == 1: value.loops = []
	if not _valid_loops(value): return {}
	value.sequence = int(value.sequence)
	return value

func _valid_loops(record: Dictionary) -> bool:
	if not record.get("loops") is Array or record.loops.size() > MAX_LOOPS: return false
	var times := {}
	for marker in record.markers: times[marker.id] = int(marker.position_ms)
	var ids := {}; var pairs := {}
	for segment in record.loops:
		if not segment is Dictionary or not segment.get("id") is String or segment.id.length() != 32 or not segment.id.is_valid_hex_number(false) or ids.has(segment.id): return false
		if not segment.get("a") is String or not segment.get("b") is String or not times.has(segment.a) or not times.has(segment.b): return false
		if times[segment.b] - times[segment.a] < MIN_LOOP_MS: return false
		var pair: String = segment.a + segment.b
		if pairs.has(pair): return false
		ids[segment.id] = true; pairs[pair] = true
	return true

func load_saved() -> void:
	records.clear(); blocked.clear(); undo.clear()
	var dir := DirAccess.open(directory)
	if not dir: return
	for filename in dir.get_files():
		if filename.length() != 71 or not filename.ends_with(".json") or filename.substr(64, 2) not in ["_0", "_1"]: continue
		var id := filename.left(64)
		if not id.is_valid_hex_number(false): continue
		var record := _read(directory.path_join(filename), id)
		if not record.is_empty() and int(record.sequence) > int(records.get(id, {}).get("sequence", 0)):
			records[id] = record
	revision += 1

func _commit(staged: String, target: String) -> Error:
	return DirAccess.rename_absolute(staged, target)

func _save(record: Dictionary) -> bool:
	last_error = "Bookmark save failed"
	var id: String = record.id
	if blocked.has(id): return false
	var sequence := int(records.get(id, {}).get("sequence", 0)) + 1
	if sequence > 9007199254740990: return false
	var proposed := record.duplicate(true)
	if not proposed.has("loops"): proposed.loops = []
	proposed.sequence = sequence
	var payload := JSON.stringify(proposed)
	var encoded := JSON.stringify({"schema_version": VERSION, "payload_json": payload, "payload_sha256": payload.sha256_text()})
	if encoded.to_utf8_buffer().size() > MAX_BYTES: return false
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return false
	var path := _path(id, sequence % 2)
	var staged := path + ".tmp"
	var file := FileAccess.open(staged, FileAccess.WRITE)
	if not file: return false
	file.store_string(encoded); file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or _read(staged, id).get("sequence", 0) != sequence or _commit(staged, path) != OK: return false
	records[id] = proposed
	revision += 1
	last_error = ""
	return true

## Pure lookup: opening videos does not write records or evict other movies.
func resolve(uri: String, basename: String = "", size: Variant = -1) -> String:
	var alias := Memory.key_for(uri)
	if alias.is_empty(): return ""
	var feature := fingerprint(basename, size)
	var candidates: Array[String] = []
	for id in records:
		var record: Dictionary = records[id]
		if alias in record.aliases and (feature.is_empty() or record.fingerprint.is_empty() or feature == record.fingerprint): return id
		if not feature.is_empty() and record.fingerprint == feature: candidates.append(id)
	if candidates.size() == 1: return candidates[0]
	# A changed file at the same URI gets its own record. Unknown metadata never matches globally.
	return JSON.stringify([alias, feature]).sha256_text()

func relocate(old_uri: String, new_uri: String, basename: String, size: int = -1) -> bool:
	var old_alias := Memory.key_for(old_uri)
	var new_alias := Memory.key_for(new_uri)
	for id in records.keys():
		var record: Dictionary = records[id].duplicate(true)
		if old_alias not in record.aliases: continue
		var feature := fingerprint(basename, size)
		# A parent-folder rename preserves the basename and the existing content fingerprint.
		if feature.is_empty() and basename == old_uri.get_file().uri_decode(): feature = str(record.fingerprint)
		if feature.is_empty(): return false
		var copied := record.duplicate(true)
		copied.id = JSON.stringify([new_alias, feature]).sha256_text()
		copied.aliases = [new_alias]; copied.fingerprint = feature
		if not _save(copied): return false
		if record.aliases.size() > 1: record.aliases.erase(old_alias)
		else:
			record.markers = [] # Persist an empty old record; its old hash must not recover the moved markers.
			record.loops = []
		if not _save(record): return false
		if not undo.is_empty() and str(undo.get("media_id", "")) == id: undo.media_id = copied.id
		return true
	return true

func list_markers(id: String) -> Array:
	var markers: Array = records.get(id, {}).get("markers", []).duplicate(true)
	markers.sort_custom(func(a, b): return a.position_ms < b.position_ms if a.position_ms != b.position_ms else a.id < b.id)
	return markers

func add(uri: String, basename: String, size: Variant, position_ms: int) -> Dictionary:
	last_error = "Bookmark save failed"
	var id := resolve(uri, basename, size)
	if id.is_empty() or position_ms < 0 or position_ms > MAX_TIME: return {}
	var record: Dictionary = records.get(id, {"id": id, "sequence": 0, "aliases": [], "fingerprint": "", "markers": []}).duplicate(true)
	var alias := Memory.key_for(uri)
	if alias not in record.aliases:
		if record.aliases.size() >= 64: return {}
		record.aliases.append(alias)
	var feature := fingerprint(basename, size)
	if record.fingerprint.is_empty(): record.fingerprint = feature
	for marker in record.markers:
		if absi(int(marker.position_ms) - position_ms) <= 1000:
			if not _save(record): return {}
			return marker.duplicate(true)
	if record.markers.size() >= MAX_MARKERS:
		last_error = "Bookmark limit reached"
		return {}
	var marker := {"id": Crypto.new().generate_random_bytes(16).hex_encode(), "position_ms": position_ms,
		"created_at_ms": int(Time.get_unix_time_from_system() * 1000)}
	record.markers.append(marker)
	return marker.duplicate(true) if _save(record) else {}

func remove(id: String, marker_id: String) -> bool:
	if not records.has(id): return false
	var record: Dictionary = records[id].duplicate(true)
	for index in record.markers.size():
		if record.markers[index].id != marker_id: continue
		var marker: Dictionary = record.markers[index].duplicate(true)
		var removed: Array = record.get("loops", []).filter(func(segment): return segment.a == marker_id or segment.b == marker_id)
		record.loops = record.get("loops", []).filter(func(segment): return segment.a != marker_id and segment.b != marker_id)
		record.markers.remove_at(index)
		if not _save(record): return false
		undo = {"media_id": id, "marker": marker, "loops": removed, "until": Time.get_ticks_msec() + 8000}
		return true
	return false

func can_undo() -> bool:
	return not undo.is_empty() and Time.get_ticks_msec() < int(undo.until)

func restore() -> bool:
	if not can_undo(): return false
	var record: Dictionary = records[undo.media_id].duplicate(true)
	if not undo.marker.is_empty():
		if record.markers.size() >= MAX_MARKERS: return false
		# Another add near the deleted time must not make undo create duplicate IDs.
		if record.markers.any(func(item): return item.id == undo.marker.id): return false
		record.markers.append(undo.marker.duplicate(true))
	record.loops = record.get("loops", []) + undo.get("loops", []).duplicate(true)
	# Keep legacy definitions readable, but undo must not reintroduce a shared A.
	for restored in undo.get("loops", []):
		if record.loops.any(func(item): return item.id != restored.id and item.a == restored.a):
			last_error = "Loop restore conflict"
			return false
	if not _valid_loops(record):
		last_error = "Loop restore conflict"
		return false
	if not _save(record): return false
	undo.clear()
	return true

func list_loops(id: String) -> Array:
	var record: Dictionary = records.get(id, {})
	var times := {}
	for marker in record.get("markers", []): times[marker.id] = int(marker.position_ms)
	var result: Array = record.get("loops", []).duplicate(true)
	for segment in result:
		segment.a_ms = times[segment.a]; segment.b_ms = times[segment.b]
	result.sort_custom(func(a, b): return a.a_ms < b.a_ms if a.a_ms != b.a_ms else (a.b_ms < b.b_ms if a.b_ms != b.b_ms else a.id < b.id))
	return result

## Only IDs are saved; inserting a marker can never retarget an existing segment.
func save_loop(id: String, a: String, b: String, loop_id: String = "") -> Dictionary:
	last_error = "Invalid loop range"
	if not records.has(id): return {}
	var record: Dictionary = records[id].duplicate(true)
	var segments: Array = record.get("loops", [])
	if not loop_id.is_empty() and not segments.any(func(item): return item.id == loop_id): return {}
	for segment in segments:
		if segment.a == a and segment.id != loop_id and segment.b != b:
			last_error = "Start bookmark already used"
			return {}
		if segment.a == a and segment.b == b:
			if loop_id.is_empty() or segment.id == loop_id: return segment.duplicate(true)
			last_error = "Loop already exists"
			return {}
	var item := {"id": Crypto.new().generate_random_bytes(16).hex_encode() if loop_id.is_empty() else loop_id, "a": a, "b": b}
	if loop_id.is_empty(): segments.append(item)
	else:
		for index in segments.size():
			if segments[index].id == loop_id: segments[index] = item
	record.loops = segments
	if not _valid_loops(record): return {}
	return item.duplicate(true) if _save(record) else {}

func remove_loop(id: String, loop_id: String) -> bool:
	if not records.has(id): return false
	var record: Dictionary = records[id].duplicate(true)
	for segment in record.get("loops", []):
		if segment.id != loop_id: continue
		record.loops = record.loops.filter(func(item): return item.id != loop_id)
		if not _save(record): return false
		undo = {"media_id": id, "marker": {}, "loops": [segment.duplicate(true)], "until": Time.get_ticks_msec() + 8000}
		return true
	return false
