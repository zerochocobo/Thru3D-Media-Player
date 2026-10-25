extends "res://scripts/file_mode_memory.gd"

# Private recent-file catalog. Unlike per-file mode keys, reopening requires
# retaining the original URI. Permissions are checked again before each open.
const RECENT_LIMIT := 32
const Location := preload("res://scripts/media_location.gd")
var suppressed := {}
var undo := {}
var legacy_pending := true
var legacy_ignored := {}

func load_saved() -> void:
	super()
	var bank := _read_bank(_bank_path(active_bank)) if active_bank >= 0 else {}
	legacy_pending = bool(bank.get("legacy_pending", true))
	legacy_ignored = bank.get("legacy_ignored", {}).duplicate()

func _payload(serial: int) -> Dictionary:
	var value := super(serial)
	value.legacy_pending = legacy_pending; value.legacy_ignored = legacy_ignored.keys()
	return value

func _bank_path(bank: int) -> String:
	return directory.path_join("recent_files_%d.json" % bank)

static func valid_entry(entry: Variant, serial: int) -> bool:
	if not entry is Dictionary or not entry.get("uri") is String or key_for(entry.uri).is_empty():
		return false
	if not entry.get("title") is String or entry.title.length() > 256 or not entry.get("persisted") is bool:
		return false
	if entry.has("cover") and not valid_cover(entry.cover): return false
	for name in ["position_ms", "duration_ms", "opened"]:
		var number: Variant = entry.get(name)
		if not (number is int or number is float) or not is_finite(float(number)) or floorf(float(number)) != float(number):
			return false
	return int(entry.position_ms) >= 0 and int(entry.position_ms) <= 2147483647 \
		and int(entry.duration_ms) >= -1 and int(entry.duration_ms) <= 2147483647 \
		and int(entry.opened) >= 1 and int(entry.opened) <= serial

func _read_bank(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > MAX_BYTES:
		return {}
	var envelope: Variant = _decode(file.get_as_text())
	if not envelope is Dictionary:
		return {}
	var version: Variant = envelope.get("schema_version")
	if (version is int or version is float) and is_finite(float(version)) and float(version) > VERSION:
		return {"unsupported_schema": true}
	if version != VERSION:
		return {}
	var serial: Variant = envelope.get("sequence")
	if not (serial is int or serial is float) or not is_finite(float(serial)) or floorf(float(serial)) != float(serial) \
		or float(serial) < 1 or float(serial) > 9007199254740990.0:
		return {}
	var encoded: Variant = envelope.get("payload_json")
	if not encoded is String or encoded.sha256_text() != envelope.get("payload_sha256"):
		return {}
	var payload: Variant = _decode(encoded)
	if not payload is Dictionary or payload.get("sequence") != serial or not payload.get("entries") is Dictionary \
		or payload.entries.size() > RECENT_LIMIT:
		return {}
	var result: Dictionary = {}
	for key in payload.entries:
		var entry: Variant = payload.entries[key]
		if not valid_entry(entry, int(serial)) or key != key_for(str(entry.uri)):
			continue
		var value: Dictionary = entry.duplicate(true)
		for name in ["position_ms", "duration_ms", "opened"]:
			value[name] = int(value[name])
		result[key] = value
	var ignored := {}
	var ignored_keys: Variant = payload.get("legacy_ignored", [])
	if not ignored_keys is Array or ignored_keys.size() > 2048 or not payload.get("legacy_pending", true) is bool: return {}
	for key in ignored_keys:
		if not key is String or key.length() != 64 or not key.is_valid_hex_number(false): return {}
		ignored[key] = true
	return {"sequence": int(serial), "entries": result, "legacy_pending": payload.get("legacy_pending", true), "legacy_ignored": ignored}

func lookup(uri: String) -> Dictionary:
	return entries.get(key_for(uri), {}).duplicate(true)

func list_recent() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in entries.values():
		result.append(value.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left: float = float(a.get("opened_at", 0)); var right: float = float(b.get("opened_at", 0))
		if left != right: return left > right
		return int(a.opened) > int(b.opened) if a.opened != b.opened else str(a.uri) < str(b.uri))
	return result

func opened(uri: String, title: String, persisted: bool, kind: String = "video") -> bool:
	suppressed.erase(key_for(uri))
	if not Privacy.record_allowed(uri): return false
	var key := key_for(uri)
	if key.is_empty():
		return false
	var old := lookup(uri)
	entries[key] = {"uri": uri, "title": title.replace("\n", " ").replace("\r", " ").replace("\t", " ").left(256),
		"kind": kind if kind in ["image", "archive", "pdf"] else "video",
		"persisted": persisted, "position_ms": int(old.get("position_ms", 0)),
		"duration_ms": int(old.get("duration_ms", -1)), "opened": sequence + 1, "opened_at": Time.get_unix_time_from_system()}
	if valid_cover(old.get("cover", "")): entries[key]["cover"] = old.cover
	if old.has("location"): entries[key].location = old.location.duplicate(true)
	# Reserve room for the checksummed JSON envelope and its escaped payload.
	while entries.size() > RECENT_LIMIT or JSON.stringify(entries).to_utf8_buffer().size() > MAX_BYTES / 3:
		var oldest: String = str(entries.keys()[0])
		for candidate in entries:
			if int(entries[candidate].opened) < int(entries[oldest].opened): oldest = str(candidate)
		entries.erase(oldest)
	dirty = true
	return true

static func valid_cover(value: Variant) -> bool:
	return value is String and value.length() <= 2048 and (value.begins_with("http://") or value.begins_with("https://"))

## Called only after a contained image/page has reached the display.
func opened_container(entry: Dictionary) -> bool:
	var uri := str(entry.get("uri", ""))
	var kind := str(entry.get("kind", ""))
	if kind not in ["archive", "pdf"] or not opened(uri, str(entry.get("title", "")), bool(entry.get("persisted", false)), kind): return false
	set_location(uri, entry.get("location", Location.infer(uri)))
	return true

func relocate(old_uri: String, new_uri: String, title: String = "") -> bool:
	if not super(old_uri, new_uri, title): return false
	var entry: Dictionary = entries[key_for(new_uri)]
	if entry.get("location", {}).get("type") == "archive":
		entry.location.source_uri = new_uri
		if not title.is_empty(): entry.location.source_title = title
		entry.location.parent = Location.infer(new_uri)
	return true

func set_cover(uri: String, cover: String) -> bool:
	if not Privacy.record_allowed(uri): return false
	var key := key_for(uri)
	if not entries.has(key) or not valid_cover(cover) or entries[key].get("cover", "") == cover: return false
	var old: Dictionary = entries[key]
	var updated := old.duplicate(true)
	updated["cover"] = cover
	entries[key] = updated
	if JSON.stringify(entries).to_utf8_buffer().size() > MAX_BYTES / 3:
		entries[key] = old
		return false
	dirty = true
	return true

func progress(uri: String, position_ms: int, duration_ms: int, ended: bool = false) -> bool:
	if suppressed.has(key_for(uri)) or not Privacy.record_allowed(uri): return false
	var key := key_for(uri)
	if not entries.has(key) or position_ms < 0 or duration_ms < -1:
		return false
	var position := mini(position_ms, 2147483647)
	var duration := mini(duration_ms, 2147483647)
	if ended or (duration >= 0 and position >= maxi(0, duration - 2000)):
		position = 0
	var value: Dictionary = entries[key]
	if value.position_ms == position and value.duration_ms == duration:
		return true
	value.position_ms = position
	value.duration_ms = duration
	dirty = true
	return true

## Every entry, and with them the resume positions.
func clear_all() -> bool:
	undo.clear()
	for entry in list_recent(): suppressed[key_for(entry.uri)] = true
	legacy_pending = false; legacy_ignored.clear()
	entries.clear()
	dirty = true
	return true

func forget(uri: String) -> bool:
	var entry := lookup(uri)
	if entry.is_empty(): return false
	undo = {"entry": entry, "until": Time.get_ticks_msec() + 8000}
	suppressed[key_for(uri)] = true
	if legacy_pending and Privacy.vault != null and Privacy.vault.protected:
		legacy_ignored[key_for(uri)] = true
		if legacy_ignored.size() > 2048: legacy_pending = false; legacy_ignored.clear()
	if Privacy.vault != null and Privacy.vault.has_record(uri): Privacy.vault.private_remember(uri, "recent", {})
	if not entries.erase(key_for(uri)):
		return false
	dirty = true
	return true

func resume_position(uri: String) -> int:
	var value := lookup(uri)
	if value.is_empty():
		return 0
	var position := int(value.position_ms)
	var duration := int(value.duration_ms)
	return position if duration < 0 or position < maxi(0, duration - 2000) else 0

func set_location(uri: String, location: Dictionary) -> void:
	var entry := lookup(uri)
	if entry.is_empty() or location.is_empty() or not Privacy.record_allowed(uri): return
	if entries.has(key_for(uri)):
		entries[key_for(uri)].location = Location.clean(location); dirty = true

func restore() -> bool:
	if undo.is_empty() or Time.get_ticks_msec() > int(undo.until): return false
	var entry: Dictionary = undo.entry
	legacy_ignored.erase(key_for(entry.uri))
	entries[key_for(entry.uri)] = entry.duplicate(true); dirty = true
	if not save(): return false
	suppressed.erase(key_for(entry.uri)); undo.clear(); return true

func can_undo() -> bool: return not undo.is_empty() and Time.get_ticks_msec() < int(undo.until)

## Older versions put recent entries inside the PIN vault. Move them once it is unlocked;
## save the independent banks first, and retain deletion markers across interrupted upgrades.
func import_legacy(vault: RefCounted) -> bool:
	if not vault or vault.locked: return true
	var cleanup: Array[String] = []
	var proposed := entries.duplicate(true)
	var remaining := false
	for favorite in vault.list_records():
		var old: Variant = favorite.get("private", {}).get("recent", {})
		if not old is Dictionary: remaining = true; continue
		if old.is_empty(): continue
		var uri := str(favorite.uri)
		var key := key_for(uri)
		if not legacy_pending or legacy_ignored.has(key): cleanup.append(uri); continue
		if not Privacy.record_allowed(uri): remaining = true; continue
		var value: Dictionary = old.duplicate(true); value.opened = sequence + 1
		if old.get("uri") != uri or not valid_entry(value, sequence + 1): remaining = true; continue
		value.opened_at = float(value.get("opened_at", 0))
		if not is_finite(value.opened_at): value.opened_at = 0.0
		if not proposed.has(key): proposed[key] = value
		cleanup.append(uri)
	if cleanup.is_empty() and (remaining or not legacy_pending): return true
	var ordered: Array = proposed.values()
	ordered.sort_custom(func(a, b):return float(a.get("opened_at", 0)) > float(b.get("opened_at", 0)) if a.get("opened_at", 0) != b.get("opened_at", 0) else int(a.opened) > int(b.opened))
	entries.clear()
	for value in ordered:
		if entries.size() >= RECENT_LIMIT: break
		entries[key_for(value.uri)] = value
	while JSON.stringify(entries).to_utf8_buffer().size() > MAX_BYTES / 3 and not entries.is_empty(): entries.erase(entries.keys().back())
	legacy_pending = remaining
	if not remaining: legacy_ignored.clear()
	dirty = true
	if not save(): return false
	return vault.clear_recent_records(cleanup)
