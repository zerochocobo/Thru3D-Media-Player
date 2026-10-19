extends RefCounted
signal changed
signal locking
signal lock_changed
const Memory := preload("res://scripts/file_mode_memory.gd")
const Location := preload("res://scripts/media_location.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const MAX_BYTES := 8 * 1024 * 1024
var directory: String
var entries: Dictionary = {}
var protected := false
var locked := false
var busy := false
var platform: Object
var last_error := ""
var revision := 0
var read_only := false
var undo := {}
var lock_level := "relaxed"
var away_since := -1

func _init(path: String = "user://favorites") -> void:
	directory = path
	load_saved()

static func key_for(uri: String) -> String:
	return uri.sha256_text() if uri.begins_with("folder://") and uri.length() <= 8192 else Memory.key_for(uri)

func _plain() -> String: return directory.path_join("favorites.json")
func _secure() -> String: return ProjectSettings.globalize_path(directory.path_join("favorites.vault"))

func _decode(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK: return {}
	var data: Variant = parser.data
	if not data is Dictionary or data.get("version") != 1 or not data.get("entries") is Dictionary: return {}
	for key in data.entries:
		var entry: Variant = data.entries[key]
		if not entry is Dictionary or not entry.get("uri") is String or key != key_for(entry.uri) or not entry.get("title") is String: return {}
		if str(key).is_empty() or not entry.get("added") is float and not entry.get("added") is int: return {}
		if not is_finite(float(entry.added)) or entry.get("kind", "") not in ["video", "image", "folder"]: return {}
		if not entry.get("private", {}) is Dictionary or not entry.get("location", {}) is Dictionary: return {}
	return data

func load_saved() -> void:
	entries.clear()
	read_only = false
	protected = FileAccess.file_exists(_secure())
	locked = protected
	if protected: return
	if FileAccess.file_exists(_plain()):
		var file := FileAccess.open(_plain(), FileAccess.READ)
		if not file or file.get_length() > MAX_BYTES: last_error = "Favorites unavailable"; read_only = true; return
		var data := _decode(file.get_as_text())
		if data.is_empty(): last_error = "Favorites unavailable"; read_only = true; return
		entries = data.entries

func contains(uri: String) -> bool: return has_record(uri) and entries[key_for(uri)].get("favorite", true)
func has_record(uri: String) -> bool: return not locked and entries.has(key_for(uri))
func can_undo() -> bool: return not locked and not undo.is_empty() and Time.get_ticks_msec() < int(undo.until)
func lookup(uri: String) -> Dictionary: return entries.get(key_for(uri), {}).duplicate(true) if not locked else {}
func list_favorites() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if locked: return result
	for value in entries.values(): result.append(value.duplicate(true))
	result.assign(result.filter(func(value): return bool(value.get("favorite", true))))
	result.sort_custom(func(a, b): return float(a.added) > float(b.added) if a.added != b.added else str(a.uri) < str(b.uri))
	return result

func list_records() -> Array:
	return entries.values().duplicate(true) if not locked else []

func _serialize(proposed: Dictionary) -> String: return JSON.stringify({"version": 1, "entries": proposed})

func _save(proposed: Dictionary) -> bool:
	last_error = "Favorites save failed"
	if locked or busy or read_only: return false
	var text := _serialize(proposed)
	if text.to_utf8_buffer().size() > MAX_BYTES: return false
	if protected:
		if not platform or not platform.favorites_vault_save(_secure(), text): return false
	elif not _write_plain(text): return false
	entries = proposed
	revision += 1; last_error = ""; changed.emit()
	return true

func _write_plain(text: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return false
	var file := FileAccess.open(_plain() + ".tmp", FileAccess.WRITE)
	if not file: return false
	file.store_string(text); file.flush()
	var error := file.get_error(); file.close()
	if error != OK or _decode(FileAccess.get_file_as_string(_plain() + ".tmp")).is_empty(): return false
	if DirAccess.rename_absolute(_plain() + ".tmp", _plain()) != OK: return false
	return true

func toggle(uri: String, title: String, kind: String, location: Dictionary = {}) -> bool:
	if contains(uri): return remove(uri)
	var key := key_for(uri)
	if key.is_empty(): return false
	var proposed := entries.duplicate(true)
	var record := lookup(uri)
	if record.is_empty(): record = {"private": {}}
	record.merge({"uri": uri, "title": title.replace("\n", " ").left(256), "kind": kind,
		"location": Location.clean(location), "added": Time.get_unix_time_from_system(), "favorite": true}, true)
	proposed[key] = record
	return _save(proposed)

func remove(uri: String) -> bool:
	return remove_many([uri])

func remove_many(uris: Array) -> bool:
	var removed := []
	var proposed := entries.duplicate(true)
	for uri in uris:
		if not contains(str(uri)): continue
		var old := lookup(str(uri)); removed.append(old)
		proposed.erase(key_for(str(uri)))
		if not old.get("private", {}).is_empty():
			var retained := old.duplicate(true); retained.favorite = false; proposed[key_for(str(uri))] = retained
	if removed.is_empty(): return false
	if not _save(proposed): return false
	undo = {"entries": removed, "until": Time.get_ticks_msec() + 8000}
	return true

func restore() -> bool:
	if undo.is_empty() or Time.get_ticks_msec() > int(undo.until) or locked: return false
	var proposed := entries.duplicate(true)
	for entry in undo.get("entries", []): proposed[key_for(entry.uri)] = entry.duplicate(true)
	if not _save(proposed): return false
	undo.clear(); return true

## Restore a recently toggled card without reviving a stale copy of private history.
func restore_favorite(entry: Dictionary) -> bool:
	var uri := str(entry.get("uri", ""))
	var key := key_for(uri)
	if key.is_empty() or locked: return false
	var record := lookup(uri)
	if record.is_empty(): record = {"private": {}}
	for field in ["uri", "title", "kind", "location", "added"]:
		if entry.has(field): record[field] = entry[field]
	record.favorite = true
	var proposed := entries.duplicate(true); proposed[key] = record
	if not _save(proposed): return false
	if not undo.is_empty():
		undo.entries = undo.get("entries", []).filter(func(item):return str(item.uri) != uri)
		if undo.entries.is_empty(): undo.clear()
	return true

func private_lookup(uri: String, field: String) -> Dictionary:
	return lookup(uri).get("private", {}).get(field, {}).duplicate(true)

func private_remember(uri: String, field: String, value: Dictionary) -> bool:
	if not has_record(uri): return false
	if private_lookup(uri, field) == value: return true
	var proposed := entries.duplicate(true)
	proposed[key_for(uri)].get_or_add("private", {})[field] = value.duplicate(true)
	if not proposed[key_for(uri)].get("favorite", true) and proposed[key_for(uri)].get("private", {}).values().all(func(item): return item is Dictionary and item.is_empty()):
		proposed.erase(key_for(uri))
	return _save(proposed)

func clear_private_records(network_only: bool, preserve_history: bool = false) -> bool:
	if locked: return false
	var proposed := entries.duplicate(true)
	for key in proposed.keys():
		if network_only and Memory.Privacy.is_local(str(proposed[key].uri)): continue
		var recent: Dictionary = proposed[key].get("private", {}).get("recent", {}).duplicate(true) if preserve_history else {}
		if proposed[key].get("favorite", true) or not recent.is_empty():
			proposed[key].private = {"recent": recent} if not recent.is_empty() else {}
		else: proposed.erase(key)
	if not _save(proposed): return false
	undo.clear(); return true

func clear_recent_records(uris: Array) -> bool:
	if locked: return false
	var proposed := entries.duplicate(true)
	var changed := false
	for uri in uris:
		var key := key_for(str(uri))
		if not proposed.has(key) or not proposed[key].get("private", {}).has("recent"): continue
		proposed[key].private.erase("recent"); changed = true
		if not proposed[key].get("favorite", true) and proposed[key].private.values().all(func(value):return value is Dictionary and value.is_empty()): proposed.erase(key)
	return _save(proposed) if changed else true

func lock() -> void:
	if not protected or locked or busy: return
	locking.emit()
	entries.clear(); undo.clear(); locked = true; away_since = -1
	if platform: platform.favorites_vault_lock()
	revision += 1; lock_changed.emit(); changed.emit()

func focus_changed(focused: bool, now: int) -> void:
	if focused:
		tick(now); away_since = -1
	elif away_since < 0: away_since = now
	if lock_level == "strict" and not focused: lock()

func tick(now: int) -> void:
	var timeout := {"relaxed": 15 * 60000, "balanced": 2 * 60000, "strict": 0, "manual": -1}
	var delay: int = timeout.get(lock_level, 15 * 60000)
	if away_since >= 0 and delay >= 0 and now - away_since >= delay: lock()

## All JNI calls stay on the Godot thread. Kotlin owns password derivation and atomic writes.
func begin_password(operation: String, password: String) -> int:
	if busy: last_error = "Loading…"; return -1
	if read_only: last_error = "Favorites unavailable"; return -1
	if not PlatformMethods.supports(platform, "favorites_vault_begin") or not PlatformMethods.supports(platform, "favorites_vault_result"):
		last_error = "PIN service unavailable. Update the app." if platform else "Headset only"; return -1
	var create := operation in ["enable", "change"]
	var id: int = platform.favorites_vault_begin("create" if create else "open", _secure(), password, _serialize(entries) if create else "")
	busy = id > 0
	last_error = "" if busy else "Favorites save failed"
	return id if busy else -1

func password_result(id: int) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(str(platform.favorites_vault_result(id))) != OK or not parser.data is Dictionary: return {"error":"Favorites unavailable"}
	return parser.data

func finish_password(_operation: String, result: Dictionary) -> bool:
	busy = false
	if not result.get("ok", false): last_error = str(result.get("error", "Incorrect password")); return false
	var data := _decode(str(result.get("data", "")))
	if data.is_empty(): last_error = "Favorites unavailable"; return false
	entries = data.entries; protected = true; locked = false
	# Also recover an interrupted enable whose native write completed before UI reconciliation.
	for path in [_plain(), _plain() + ".tmp"]:
		if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
			last_error = "Favorites save failed"; return false
	last_error = ""; revision += 1
	lock_changed.emit(); changed.emit(); return true

func disable_password() -> bool:
	if locked or not protected: return false
	if not _write_plain(_serialize(entries)): last_error = "Favorites save failed"; return false
	if DirAccess.remove_absolute(_secure()) != OK:
		DirAccess.remove_absolute(_plain()); last_error = "Favorites save failed"; return false
	if platform: platform.favorites_vault_lock()
	protected = false; last_error = ""; revision += 1
	lock_changed.emit(); changed.emit(); return true

func reset_locked() -> bool:
	if not protected or not locked or busy: return false
	for path in [_plain(), _plain() + ".tmp", _secure() + ".tmp"]:
		if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK: return false
	if DirAccess.remove_absolute(_secure()) != OK: return false
	if platform: platform.favorites_vault_lock()
	entries.clear(); undo.clear(); protected = false; locked = false; read_only = false; revision += 1
	lock_changed.emit(); changed.emit(); return true

func relocate(old_uri: String, new_uri: String, title: String) -> bool:
	if not has_record(old_uri): return true
	var proposed := entries.duplicate(true)
	var entry := lookup(old_uri); proposed.erase(key_for(old_uri))
	entry.uri = new_uri; entry.title = title; entry.location = Location.infer(new_uri)
	proposed[key_for(new_uri)] = entry
	return _save(proposed)
