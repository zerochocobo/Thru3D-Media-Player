extends RefCounted
## One policy is consulted at the write boundary, including delayed work.
const ALL := "all"
const LOCAL := "local"
const NONE := "none"
static var mode := ALL
static var vault: RefCounted
static var sources: Dictionary = {}

static func configure(value: String) -> void:
	mode = value if value in [ALL, LOCAL, NONE] else NONE

static func is_local(uri: String) -> bool:
	if sources.has(uri): return bool(sources[uri])
	if uri.get_file().get_slice("?", 0).to_lower().ends_with(".strm"): return false
	return uri.begins_with("file://") or uri.begins_with("usb://") or uri.begins_with("content://media/") or uri.begins_with("content://com.android.externalstorage.documents/")

static func record_allowed(uri: String) -> bool:
	return mode == ALL or (mode == LOCAL and is_local(uri))

static func protected_uri(uri: String) -> bool:
	return vault != null and vault.protected and (vault.locked or vault.has_record(uri))

static func persist_allowed(uri: String) -> bool:
	return record_allowed(uri) and not protected_uri(uri)

static func cache_allowed(uri: String) -> bool:
	return record_allowed(uri) and not (vault != null and vault.protected)

static func private_lookup(uri: String, field: String) -> Dictionary:
	return vault.private_lookup(uri, field) if vault != null and protected_uri(uri) and not vault.locked else {}

static func private_remember(uri: String, field: String, value: Dictionary) -> bool:
	return vault != null and record_allowed(uri) and protected_uri(uri) and not vault.locked and vault.private_remember(uri, field, value)
