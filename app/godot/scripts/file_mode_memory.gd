extends RefCounted

# Two checksummed generations keep the previous valid configuration available
# while the older bank is replaced. One writer, owned by the video controller.
const VERSION := 1
const Privacy := preload("res://scripts/media_privacy.gd")
const LIMIT := 128
const MAX_BYTES := 262144
const StereoView := preload("res://scripts/stereo_view.gd")
const ImmersiveAdjustments := preload("res://scripts/immersive_adjustments.gd")
const PROFILES := ["320x320", "384x216", "512x288", "384x384", "512x512", "256x144", "256x256"]
var directory := "user://settings"
var entries: Dictionary = {}
var sequence := 0
var active_bank := -1
var dirty := false
var read_only := false
var last_error := OK
var identity_aliases: Dictionary = {}

func _init(path: String = "user://settings") -> void:
	directory = path

static func key_for(uri: String) -> String:
	if uri.is_empty() or uri.length() > 8192:
		return ""
	# Network library URIs are stable (smb://<server id>/..., DLNA http media URLs); the
	# loopback SMB proxy URL is per run and never stored.
	var network := uri.begins_with("dlna://") or uri.begins_with("smb://") or uri.begins_with("cloud://") or uri.begins_with("medialib://") or ((uri.begins_with("http://") or uri.begins_with("https://")) 		and not uri.begins_with("http://127.0.0.1"))
	if not (uri.begins_with("content://") or uri.begins_with("file://") or uri.begins_with("usb://") or network):
		return ""
	# Android document identifiers and file paths can be case-sensitive.
	return uri.sha256_text()

static func valid_mode(value: Variant) -> bool:
	if not value is Dictionary or not value.get("profile") in PROFILES:
		return false
	var geometry: Variant = value.get("geometry")
	if not (geometry is int or geometry is float) or not is_finite(float(geometry)) \
		or float(geometry) != floorf(float(geometry)) or int(geometry) not in [0, 1, 2, 3]:
		return false
	for name in ["stereo_sbs", "swap_eyes", "alpha_requested"]:
		if not value.get(name) is bool:
			return false
	for name in ["top_bottom", "stereo_half", "depth_requested", "packed_mask", "portrait_auto", "portrait_auto_explicit", "portrait_enhanced"]:
		if value.has(name) and not value[name] is bool:
			return false
	if value.has("portrait_strength"):
		var strength: Variant = value.portrait_strength
		if not (strength is float or strength is int) or not is_finite(float(strength)) or float(strength) < 0.0 or float(strength) > 1.0: return false
	return StereoView.valid(value) and ImmersiveAdjustments.valid(value)

func _bank_path(bank: int) -> String:
	return directory.path_join("file_modes_%d.json" % bank)

func _value_field() -> String:
	return "mode"

func _valid_value(value: Variant) -> bool:
	return valid_mode(value)

func _normalize_value(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.geometry = int(result.geometry)
	return result

func _recover_saved_value(value: Variant) -> Variant:
	if _valid_value(value): return _normalize_value(value)
	# Only display alignment and placement may be repaired. Preserve the projection/layout and all
	# other valid per-file choices; other stores derived from this class keep strict reads.
	if _value_field() != "mode" or not value is Dictionary: return null
	var repaired: Dictionary = value.duplicate(true)
	for field in ["viewing_eye", "stereo_horizontal", "stereo_vertical", "spatial_auto_disparity"] + ImmersiveAdjustments.KEYS: repaired.erase(field)
	if not valid_mode(repaired): return null
	for field in ["viewing_eye", "stereo_horizontal", "stereo_vertical", "spatial_auto_disparity"]:
		if value.has(field):
			repaired[field] = value[field] if StereoView.valid({field: value[field]}) else (true if field == "spatial_auto_disparity" else 0)
	for field in ImmersiveAdjustments.KEYS:
		if value.has(field): repaired[field] = value[field] if ImmersiveAdjustments.valid({field: value[field]}) else 0.0
	return _normalize_value(repaired)

static func _decode(text: String) -> Variant:
	var parser := JSON.new()
	return parser.data if parser.parse(text) == OK else null

func _read_bank(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > _max_bytes():
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
	if not (serial is int or serial is float) or not is_finite(float(serial)) \
		or float(serial) != floorf(float(serial)) or float(serial) < 1 or float(serial) > 9007199254740990.0:
		return {}
	var encoded: Variant = envelope.get("payload_json")
	if not encoded is String or encoded.sha256_text() != envelope.get("payload_sha256"):
		return {}
	var payload: Variant = _decode(encoded)
	if not payload is Dictionary or payload.get("sequence") != serial \
		or not payload.get("entries") is Dictionary or payload.entries.size() > LIMIT:
		return {}
	var result: Dictionary = {}
	for key in payload.entries:
		var entry: Variant = payload.entries[key]
		if not key is String or key.length() != 64 or not key.is_valid_hex_number(false) \
			or not entry is Dictionary:
			continue
		var recovered: Variant = _recover_saved_value(entry.get(_value_field()))
		if recovered == null: continue
		var updated: Variant = entry.get("updated")
		if not (updated is int or updated is float) or not is_finite(float(updated)) \
			or float(updated) != floorf(float(updated)) or float(updated) < 1 or float(updated) > float(serial):
			continue
		result[key] = {_value_field(): recovered, "updated": int(updated)}
		if entry.get("network") is bool: result[key].network = entry.network
	return {"sequence": int(serial), "entries": result}

func load_saved() -> void:
	entries = {}
	sequence = 0
	active_bank = -1
	dirty = false
	read_only = false
	for bank in 2:
		var value := _read_bank(_bank_path(bank))
		if value.get("unsupported_schema", false):
			read_only = true
			continue
		if not value.is_empty() and int(value.sequence) > sequence:
			sequence = int(value.sequence)
			entries = value.entries
			active_bank = bank

func lookup(uri: String) -> Dictionary:
	if not Privacy.settings_allowed(uri): return {}
	if Privacy.protected_uri(uri): return Privacy.private_lookup(uri, directory.get_file() + "/" + _value_field())
	var value: Dictionary = entries.get(entry_key(uri), {})
	return value.get(_value_field(), {}).duplicate(true)

func remember(uri: String, mode: Dictionary) -> bool:
	if not Privacy.settings_allowed(uri): return false
	if Privacy.protected_uri(uri): return Privacy.private_remember(uri, directory.get_file() + "/" + _value_field(), mode) if _valid_value(mode) else false
	var key := entry_key(uri)
	if key.is_empty() or not _valid_value(mode):
		return false
	if lookup(uri) == mode:
		return true
	entries[key] = {_value_field(): _normalize_value(mode), "updated": sequence + 1, "network": not Privacy.is_local(uri)}
	while entries.size() > LIMIT:
		var oldest := str(entries.keys()[0])
		for candidate in entries:
			if int(entries[candidate].updated) < int(entries[oldest].updated):
				oldest = candidate
		entries.erase(oldest)
	dirty = true
	return true

func entry_key(uri: String) -> String:
	return key_for(str(identity_aliases.get(uri, uri)))

func _max_bytes() -> int: return MAX_BYTES

func register_usb_identity(uri: String, identity: String) -> bool:
	if not uri.begins_with("usb://") or not identity.begins_with("usb://stable/") or identity.length() > 8192: return false
	var volume := identity.trim_prefix("usb://stable/").get_slice("/", 0)
	if volume.length() != 64 or not volume.is_valid_hex_number(false): return false
	if identity_aliases.get(uri, "") == identity: return false
	identity_aliases[uri] = identity
	return true

func _commit(staged: String, target: String) -> Error:
	return DirAccess.rename_absolute(staged, target)

## Rewrite both banks so deleted private data cannot return through recovery.
func purge_keys(keys: Array) -> bool:
	for key in keys: entries.erase(str(key))
	dirty = true
	if not save(): return false
	dirty = true
	return save()

func relocate(old_uri: String, new_uri: String, title: String = "") -> bool:
	var old_key := entry_key(old_uri)
	var new_key := entry_key(new_uri)
	if old_key.is_empty() or new_key.is_empty() or not entries.has(old_key): return false
	var value: Dictionary = entries[old_key].duplicate(true)
	if value.has("uri"): value.uri = new_uri
	if value.has("title") and not title.is_empty(): value.title = title.left(256)
	entries[new_key] = value; entries.erase(old_key); dirty = true
	return true

func _payload(serial: int) -> Dictionary:
	return {"sequence": serial, "entries": entries}

func save() -> bool:
	if not dirty:
		return true
	if read_only:
		last_error = ERR_UNAVAILABLE
		return false
	if sequence >= 9007199254740990:
		last_error = ERR_OUT_OF_MEMORY
		return false
	last_error = DirAccess.make_dir_recursive_absolute(directory)
	if last_error != OK:
		return false
	var next_bank := 0 if active_bank != 0 else 1
	var target := _bank_path(next_bank)
	var staged := target + ".tmp"
	var encoded := JSON.stringify(_payload(sequence + 1))
	var serialized := JSON.stringify({"schema_version": VERSION, "sequence": sequence + 1,
		"payload_json": encoded, "payload_sha256": encoded.sha256_text()})
	if serialized.to_utf8_buffer().size() > _max_bytes():
		last_error = ERR_OUT_OF_MEMORY
		return false
	var file := FileAccess.open(staged, FileAccess.WRITE)
	if not file:
		last_error = FileAccess.get_open_error()
		return false
	file.store_string(serialized)
	file.flush()
	last_error = file.get_error()
	file.close()
	if last_error != OK:
		return false
	if _read_bank(staged).get("sequence", 0) != sequence + 1:
		last_error = ERR_FILE_CORRUPT
		return false
	last_error = _commit(staged, target)
	if last_error != OK:
		return false
	sequence += 1
	active_bank = next_bank
	dirty = false
	return true
