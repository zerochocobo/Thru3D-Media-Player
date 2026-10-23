extends RefCounted
## Application-owned browsing history. Session entries never implicitly become disk history.
const Privacy := preload("res://scripts/media_privacy.gd")
const LIMIT := 512
var path := ""
var revision := 0
var session := {}
var persisted := {}
var pending := {}
var save_at := 0

func load_file(value: String) -> void:
	path = value
	var config := ConfigFile.new()
	if config.load(path) != OK: return
	var entries: Variant = config.get_value("browse", "entries", {})
	if entries is Dictionary:
		for key in entries:
			if key is String and key.length() == 64 and entries[key] is Dictionary:
				persisted[key] = entries[key]
	_trim(persisted)

func locked() -> bool:
	return Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked

func disk_allowed(network: bool) -> bool:
	# Directory records have no encrypted-vault schema yet. Protected sessions stay in memory.
	return not (Privacy.vault != null and Privacy.vault.protected) and \
		(Privacy.mode == Privacy.ALL or (Privacy.mode == Privacy.LOCAL and not network))

func lookup(scope: String, network: bool) -> Dictionary:
	if scope.is_empty() or locked(): return {}
	var key := scope.sha256_text()
	if session.has(key): return session[key].value.duplicate(true)
	if disk_allowed(network) and persisted.has(key) and persisted[key].get("network", true) == network:
		var value: Variant = persisted[key].get("value", {})
		if value is Dictionary: return value.duplicate(true)
	return {}

func remember(scope: String, network: bool, value: Dictionary, ticket: int) -> void:
	if scope.is_empty() or value.is_empty() or ticket != revision or locked(): return
	var key := scope.sha256_text()
	var entry := {"network": network, "value": _clean(value), "updated": Time.get_unix_time_from_system()}
	session.erase(key); session[key] = entry.duplicate(true); _trim(session)
	# Cursor/offset chains may be reused during this process, never after restart.
	if value.get("offsets") is Array: session[key].value.offsets = value.offsets.duplicate()
	if disk_allowed(network):
		pending[key] = entry; _trim(pending); save_at = Time.get_ticks_msec() + 650

func policy_changed() -> void:
	revision += 1
	pending.clear(); save_at = 0

func flush() -> bool:
	if pending.is_empty(): return true
	var next := persisted.duplicate(true)
	for key in pending:
		if disk_allowed(bool(pending[key].network)):
			next.erase(key); next[key] = pending[key]
	_trim(next)
	if next != persisted and not _write(next):
		save_at = Time.get_ticks_msec() + 2000; return false
	pending.clear(); save_at = 0
	persisted = next
	return true

func tick() -> void:
	if save_at > 0 and Time.get_ticks_msec() >= save_at: flush()

func clear_history(network_only: bool) -> bool:
	var keep_pending := pending.duplicate(true) if network_only else {}
	policy_changed()
	for key in session.keys():
		if not network_only or bool(session[key].network): session.erase(key)
	var next := persisted.duplicate(true)
	for key in keep_pending:
		if not bool(keep_pending[key].network) and disk_allowed(false): next[key] = keep_pending[key]
	for key in next.keys():
		if not network_only or bool(next[key].get("network", true)): next.erase(key)
	if not _write(next): return false
	persisted = next
	return true

func _write(entries: Dictionary) -> bool:
	if path.is_empty(): return true # Isolated menu/test instances are memory-only.
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK: return false
	var config := ConfigFile.new()
	config.set_value("browse", "entries", entries)
	return config.save(path) == OK

func _trim(entries: Dictionary) -> void:
	while entries.size() > LIMIT: entries.erase(entries.keys()[0])

func _clean(value: Dictionary) -> Dictionary:
	# Positional hints hash item identities. Picker navigation separately needs a
	# validated directory route; selected media URLs and credentials are excluded.
	var result := {}
	for field in ["index", "fraction", "line_offset", "item_offset", "columns", "page", "offset", "page_size", "filter", "scroll"]:
		if value.get(field) is int or value.get(field) is float: result[field] = value[field]
	if value.get("key") is String:
		result.key = value.key if value.get("hashed", false) else str(value.key).sha256_text()
		result.hashed = true
	if value.get("browse", false): result.browse = true
	if value.get("position") is Dictionary: result.position = _clean(value.position)
	if value.get("order") is String: result.order = str(value.order).left(64)
	if value.get("archive_directory") is String:
		var directory := str(value.archive_directory)
		if directory.length() <= 4096 and not directory.begins_with("/") and not directory.contains("\\") and not directory.to_utf8_buffer().has(0) and not Array(directory.split("/", false)).any(func(part): return part in [".", ".."]):
			result.archive_directory = directory
	if value.get("picker_location") is Dictionary:
		var location := preload("res://scripts/image_picker_location.gd").clean(value.picker_location)
		if not location.is_empty(): result.picker_location = location
	return result
