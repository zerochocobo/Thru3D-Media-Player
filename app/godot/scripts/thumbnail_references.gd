extends RefCounted
## Bounded metadata for cached pictures, failed lookups and directory covers.
## Use digests for identities and versions. The index never stores a source URL.

const Privacy := preload("res://scripts/media_privacy.gd")
const PATH := "user://thumbnails/references.bin"
const STAGED := PATH + ".pending"
const MAX_FINGERPRINTS := 16384
const MAX_COVERS := 1024
const MAX_TRANSIENT := 256
const MAX_INDEX_BYTES := 8 * 1024 * 1024

static var _loaded := false
static var load_revision := 0
static var _load_task := -1
static var _loaded_tables: Dictionary = {}
static var _pending_changes: Array[Callable] = []
static var _save_at := 0
static var _save_task := -1
static var _save_epoch := -1
static var _epoch := 0
static var _save_ok := false
static var _save_empty := false
static var _clearing := false
static var _entries: Dictionary = {}
static var _covers: Dictionary = {}
static var _transient: Dictionary = {}
static var _transient_covers: Dictionary = {}

static func ready() -> bool:
	if _loaded or not _disk_visible(): return true
	_start_load()
	return false

static func clearing() -> bool:
	return _clearing

static func _disk_visible() -> bool:
	return Privacy.mode != Privacy.NONE and (Privacy.vault == null or not Privacy.vault.protected)

static func _start_load() -> void:
	if _load_task < 0 and not _loaded:
		_load_task = WorkerThreadPool.add_task(_read_disk)

static func _load_or_defer(change: Callable = Callable()) -> bool:
	if _loaded: return true
	_start_load()
	if change.is_valid() and _pending_changes.size() < MAX_TRANSIENT: _pending_changes.append(change)
	return false

static func _read_disk() -> void:
	_loaded_tables = {"entries": {}, "covers": {}}
	for path in [STAGED, PATH + ".tmp"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	var file := FileAccess.open(PATH, FileAccess.READ)
	if not file or file.get_length() > MAX_INDEX_BYTES: return
	var data: Variant = file.get_var()
	if not data is Dictionary: return
	for section in ["entries", "covers"]:
		if not data.get(section) is Dictionary: continue
		var table: Dictionary = _loaded_tables[section]
		var limit := MAX_FINGERPRINTS if section == "entries" else MAX_COVERS
		for key in data[section].keys().slice(-limit):
			var entry: Variant = data[section][key]
			if key is String and entry is Dictionary: table[key] = entry

static func _complete_load() -> void:
	WorkerThreadPool.wait_for_task_completion(_load_task)
	_load_task = -1
	_entries = _loaded_tables.entries
	_covers = _loaded_tables.covers
	_loaded_tables = {}
	_loaded = true
	for change in _pending_changes: change.call()
	_pending_changes.clear()
	load_revision += 1

static func _blocked() -> bool:
	return Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked

static func _remember(table: Dictionary, key: String, entry: Dictionary, limit: int) -> void:
	table.erase(key)
	table[key] = entry
	if table.size() > limit: table.erase(table.keys()[0])

static func _find(key: String, persistent: Dictionary, transient: Dictionary, limit: int) -> Dictionary:
	if _blocked() or _clearing: return {}
	if transient.has(key):
		var entry: Dictionary = transient[key]
		_remember(transient, key, entry, MAX_TRANSIENT)
		return entry.duplicate()
	if not _disk_visible() or not ready(): return {}
	var entry: Dictionary = persistent.get(key, {})
	if entry.is_empty() or (Privacy.mode == Privacy.LOCAL and not entry.get("local", false)): return {}
	_remember(persistent, key, entry, limit)
	return entry.duplicate()

static func fingerprint(scope: String, identity: String) -> Dictionary:
	return _find(scope.sha1_text() + ":" + identity.sha1_text(), _entries, _transient, MAX_FINGERPRINTS)

static func remember_fingerprint(scope: String, identity: String, owner_uri: String, version: String,
		picture: String = "", failed_until: int = 0, quality: int = 0, failure_policy: int = 0) -> void:
	if scope.is_empty() or identity.is_empty() or owner_uri.is_empty() or _blocked() or _clearing: return
	var key := scope.sha1_text() + ":" + identity.sha1_text()
	var entry := {"version": version.sha1_text(), "picture": picture.sha1_text() if not picture.is_empty() else "",
		"local": Privacy.is_local(owner_uri), "failed_until": failed_until, "quality": quality}
	if failure_policy > 0: entry["failure_policy"] = failure_policy
	if Privacy.cache_allowed(owner_uri):
		_store_fingerprint(key, entry)
	else:
		_remember(_transient, key, entry, MAX_TRANSIENT)

static func _store_fingerprint(key: String, entry: Dictionary) -> void:
	if not _load_or_defer(_store_fingerprint.bind(key, entry)): return
	_transient.erase(key)
	var changed: bool = _entries.get(key) != entry
	_remember(_entries, key, entry, MAX_FINGERPRINTS)
	if changed: _dirty()

static func cover(scope: String) -> Dictionary:
	return _find(scope.sha1_text(), _covers, _transient_covers, MAX_COVERS)

static func known(scope: String) -> Dictionary:
	if _blocked() or _clearing: return {}
	var prefix := scope.sha1_text() + ":"
	var result := {}
	if _disk_visible() and ready():
		for key: String in _entries:
			if key.begins_with(prefix) and (Privacy.mode == Privacy.ALL or _entries[key].get("local", false)):
				result[key.trim_prefix(prefix)] = _entries[key].duplicate()
	for key: String in _transient:
		if key.begins_with(prefix): result[key.trim_prefix(prefix)] = _transient[key].duplicate()
	return result

static func forget_identity(scope: String, identity_digest: String) -> void:
	if _blocked(): return
	var key := scope.sha1_text() + ":" + identity_digest
	_transient.erase(key)
	_erase_fingerprint(key)

static func _erase_fingerprint(key: String) -> void:
	if _load_or_defer(_erase_fingerprint.bind(key)) and _entries.erase(key): _dirty()

static func remember_cover(scope: String, directory_uri: String, identity: String, owner_uri: String,
		picture: String, quality: int, modified: int = -1) -> void:
	if scope.is_empty() or directory_uri.is_empty() or owner_uri.is_empty() or picture.is_empty() or _blocked(): return
	var entry := {"identity": identity.sha1_text(), "picture": picture.sha1_text(), "quality": quality,
		"modified": modified, "local": Privacy.is_local(owner_uri)}
	select_cover(scope, directory_uri, entry)

static func select_cover(scope: String, directory_uri: String, picture: Dictionary) -> void:
	if scope.is_empty() or directory_uri.is_empty() or _blocked() or _clearing: return
	var key := scope.sha1_text()
	var entry := picture.duplicate()
	entry.local = Privacy.is_local(directory_uri) and bool(entry.get("local", false))
	if Privacy.cache_allowed(directory_uri) and (entry.local or Privacy.mode == Privacy.ALL):
		_store_cover(key, entry)
	else:
		_remember(_transient_covers, key, entry, MAX_TRANSIENT)

static func _store_cover(key: String, entry: Dictionary) -> void:
	if not _load_or_defer(_store_cover.bind(key, entry)): return
	_transient_covers.erase(key)
	var changed: bool = _covers.get(key) != entry
	_remember(_covers, key, entry, MAX_COVERS)
	if changed: _dirty()

static func forget_cover(scope: String) -> void:
	if _blocked(): return
	var key := scope.sha1_text()
	_transient_covers.erase(key)
	_erase_cover(key)

static func _erase_cover(key: String) -> void:
	if _load_or_defer(_erase_cover.bind(key)) and _covers.erase(key): _dirty()

static func forget_picture(picture_key: String) -> void:
	forget_digest(picture_key.sha1_text())

static func forget_digest(digest: String) -> void:
	if not _load_or_defer(forget_digest.bind(digest)): return
	var changed := false
	for table in [_entries, _covers, _transient, _transient_covers]:
		for key in table.keys():
			if table[key].get("picture") != digest: continue
			table.erase(key)
			if is_same(table, _entries) or is_same(table, _covers): changed = true
	if changed: _dirty()

static func relocate_picture(old_uri: String, new_uri: String) -> void:
	if not _load_or_defer(relocate_picture.bind(old_uri, new_uri)): return
	var previous := old_uri.sha1_text()
	var next := new_uri.sha1_text()
	var identities := {previous: next}
	if old_uri.begins_with("file://") and new_uri.begins_with("file://"):
		identities[old_uri.trim_prefix("file://").uri_decode().sha1_text()] = new_uri.trim_prefix("file://").uri_decode().sha1_text()
	elif old_uri.begins_with("smb://") and new_uri.begins_with("smb://"):
		var old_path := old_uri.trim_prefix("smb://").split("/", true, 1)
		var new_path := new_uri.trim_prefix("smb://").split("/", true, 1)
		if old_path.size() == 2 and new_path.size() == 2:
			identities[old_path[1].sha1_text()] = new_path[1].sha1_text()
	for table in [_entries, _transient]:
		for key: String in table.keys():
			if table[key].get("picture") != previous: continue
			var record: Dictionary = table[key].duplicate()
			var identity := key.get_slice(":", 1)
			var target := str(identities.get(identity, identity))
			var scoped := key.get_slice(":", 0) + ":" + target
			record.picture = next
			table.erase(key)
			table[scoped] = record
	for table in [_covers, _transient_covers]:
		for key: String in table:
			var record: Dictionary = table[key]
			if record.get("picture") != previous: continue
			record = record.duplicate()
			record.picture = next
			record.identity = identities.get(record.identity, record.identity)
			table[key] = record
	_dirty()

static func clear_memory() -> void:
	_transient.clear()
	_transient_covers.clear()

static func clear(network_only: bool = false) -> void:
	clear_memory()
	_epoch += 1
	_clearing = true
	_apply_clear(network_only)

static func _apply_clear(network_only: bool) -> void:
	if not _loaded:
		_start_load()
		_pending_changes.append(_apply_clear.bind(network_only))
		return
	for table in [_entries, _covers]:
		if not network_only:
			table.clear()
			continue
		for key in table.keys():
			if not table[key].get("local", false): table.erase(key)
	_save_at = maxi(1, Time.get_ticks_msec())

static func poll() -> void:
	if _load_task >= 0:
		if not WorkerThreadPool.is_task_completed(_load_task): return
		_complete_load()
	elif not ready(): return
	if _save_task >= 0:
		if not WorkerThreadPool.is_task_completed(_save_task): return
		_complete_save()
	if _save_at > 0 and Time.get_ticks_msec() >= _save_at: _start_save()

static func finish() -> void:
	if _load_task >= 0: _complete_load()
	if _save_task >= 0: _complete_save()
	if _save_at > 0:
		_start_save()
		_complete_save()

static func _dirty() -> void:
	if _save_at == 0: _save_at = Time.get_ticks_msec() + 1200

static func _start_save() -> void:
	_save_at = 0
	_save_epoch = _epoch
	_save_empty = _entries.is_empty() and _covers.is_empty()
	_save_task = WorkerThreadPool.add_task(_write_snapshot.bind(_entries.duplicate(), _covers.duplicate(), _save_empty))

static func _write_snapshot(entries: Dictionary, covers: Dictionary, empty: bool) -> void:
	_save_ok = false
	if empty:
		_save_ok = true
		return
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var file := FileAccess.open(STAGED, FileAccess.WRITE)
	if not file: return
	file.store_var({"entries": entries, "covers": covers})
	_save_ok = file.get_error() == OK and file.get_position() <= MAX_INDEX_BYTES
	file.close()

static func _complete_save() -> void:
	WorkerThreadPool.wait_for_task_completion(_save_task)
	_save_task = -1
	if _save_epoch != _epoch or not _save_ok:
		if FileAccess.file_exists(STAGED): DirAccess.remove_absolute(STAGED)
		if _save_epoch == _epoch and _clearing: _remove_cached_index()
		return
	if _save_empty:
		_remove_cached_index()
	elif DirAccess.rename_absolute(STAGED, PATH) == OK:
		_clearing = false
	else:
		DirAccess.remove_absolute(STAGED)
		if _clearing: _remove_cached_index()

static func _remove_cached_index() -> void:
	var removed := not FileAccess.file_exists(PATH) or DirAccess.remove_absolute(PATH) == OK
	if removed:
		_clearing = false
	elif _clearing:
		_save_at = Time.get_ticks_msec() + 5000
