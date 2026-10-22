extends RefCounted
## Local presentation only: never fetch metadata or change playback/history.
const I18n := preload("res://scripts/i18n.gd")
const Location := preload("res://scripts/media_location.gd")

static func mode(value: Variant) -> String:
	return "list" if value == "list" else "grid"

static func key(row: Dictionary) -> String:
	for field in ["scene", "container_node", "container", "search_result"]:
		if row.get(field) is Dictionary:
			var node: Dictionary = row[field]
			return str(node.get("uri", node.get("id", node.get("relative_path", node.get("search_token", "")))))
	return str(row.get("uri", row.get("id", "")))

static func anchor(rows: Array, scroll: float, columns: int) -> Dictionary:
	var index := mini(maxi(0, floori(scroll + 0.001) * columns), maxi(0, rows.size() - 1))
	return {"key": key(rows[index]) if not rows.is_empty() else "", "index": index, "fraction": scroll - floorf(scroll + 0.001)}

static func position(rows: Array, saved: Dictionary, columns: int) -> float:
	var index := int(saved.get("index", 0))
	var found := anchor_index(rows, saved)
	if found >= 0: index = found
	var offset := float(saved.get("line_offset", 0.0))
	if int(saved.get("columns", columns)) != columns:
		offset = float(int(saved.get("item_offset", 0)) / columns)
	return float(maxi(0, index) / columns) - offset + clampf(float(saved.get("fraction", 0.0)), 0.0, 0.99)

static func anchor_index(rows: Array, saved: Dictionary) -> int:
	var identity := str(saved.get("key", ""))
	if not identity.is_empty():
		for i in rows.size():
			var candidate := browse_key(rows[i]) if saved.get("browse", false) else key(rows[i])
			if (candidate.sha256_text() if saved.get("hashed", false) else candidate) == identity:
				return i
	return -1

static func browse_key(row: Dictionary) -> String:
	var node: Dictionary = row.get("container", row)
	var native_id := str(node.get("cloud_id", row.get("cloud_id", "")))
	if not native_id.is_empty(): return "cloud-id:" + native_id
	# DLNA object IDs survive changes to temporary HTTP resource URLs.
	if not str(node.get("id", "")).is_empty(): return "id:" + str(node.id)
	return key(row)

## Keep the opened folder at its previous screen row even if siblings were inserted.
static func folder_anchor(rows: Array, scroll: float, columns: int, row: Dictionary) -> Dictionary:
	var saved := anchor(rows, scroll, columns)
	var identity := key(row)
	for i in rows.size():
		if key(rows[i]) == identity:
			saved.item_offset = i - int(saved.index); saved.columns = columns
			saved.key = identity; saved.index = i
			saved.line_offset = float(i / columns) - floorf(scroll + 0.001)
			break
	return saved

static func time(ms: int) -> String:
	var seconds := maxi(0, ms / 1000)
	return "%d:%02d:%02d" % [seconds / 3600, seconds / 60 % 60, seconds % 60] if seconds >= 3600 else "%d:%02d" % [seconds / 60, seconds % 60]

static func size(bytes: int) -> String:
	if bytes <= 0: return ""
	if bytes >= 1073741824: return "%.1f GB" % (bytes / 1073741824.0)
	if bytes >= 1048576: return "%.1f MB" % (bytes / 1048576.0)
	return "%d KB" % maxi(1, ceili(bytes / 1024.0))

static func date(ms: int) -> String:
	if ms <= 0: return ""
	var local := ms / 1000 + int(Time.get_time_zone_from_system().bias) * 60
	return Time.get_datetime_string_from_unix_time(local).left(10)

static func source(uri: String) -> String:
	if uri.is_empty(): return ""
	if uri.begins_with("dlna://"): return "DLNA"
	if uri.begins_with("smb://"): return "SMB"
	if uri.begins_with("cloud://"): return I18n.t("Cloud drives")
	if uri.begins_with("medialib://"): return I18n.t("Media servers")
	if uri.begins_with("http://") or uri.begins_with("https://"): return "DLNA / HTTP"
	return I18n.t("Local files")

static func local_record(catalog: RefCounted, uri: String) -> Dictionary:
	if not catalog or uri.is_empty(): return {}
	if catalog.has_method("lookup"): return catalog.lookup(uri)
	if catalog.has_method("list_recent"):
		for item in catalog.list_recent():
			if item.get("uri", "") == uri: return item
	return {}

static func info(row: Dictionary, catalog: RefCounted = null, recent: bool = false) -> Dictionary:
	var node: Dictionary = row.get("scene", row.get("container_node", row.get("container", row.get("search_result", row))))
	var folder: bool = row.has("container") or row.has("container_node") or row.get("folder", false) or row.get("kind") == "folder"
	var photo: bool = row.get("kind", node.get("kind", "video")) == "image"
	var uri := str(node.get("uri", row.get("uri", "")))
	var bytes := size(int(node.get("size", row.get("size", -1)))) if not folder else ""
	var modified := date(int(node.get("modified", row.get("modified", -1))))
	var duration := int(node.get("duration_ms", row.get("duration_ms", -1)))
	var position_ms := int(node.get("position_ms", row.get("position_ms", 0)))
	var local := local_record(catalog, uri)
	if not local.is_empty():
		position_ms = int(local.get("position_ms", 0))
		if int(local.get("duration_ms", -1)) > 0: duration = int(local.duration_ms)
		elif int(node.get("part_count", 1)) > 1: duration = -1
	var parts: Array[String] = []
	if row.has("search_result"):
		var path := str(node.get("relative_path", "")).get_base_dir().trim_prefix("/")
		if not path.is_empty(): parts.append(path)
		if not bytes.is_empty(): parts.append(bytes)
	elif recent:
		var origin := Location.folder_path(Location.clean(row.get("location", {}))) if folder else source(uri)
		if not origin.is_empty(): parts.append(origin)
		if duration > 0 and not photo and not folder: parts.append(time(duration))
	elif folder:
		var count := int(node.get("child_count", -1))
		if bool(node.get("volume", false)) and bool(node.get("removable", false)):
			parts.append(I18n.t("App managed" if bool(node.get("managed_usb", false)) else "System mounted"))
			parts.append(I18n.t("Read-only"))
		elif count >= 0: parts.append(I18n.t("%d items") % count)
		elif not modified.is_empty(): parts.append(modified)
	elif row.has("scene"):
		var year := int(node.get("year", 0))
		if year > 0: parts.append(str(year))
		if duration > 0: parts.append(time(duration))
		if not bytes.is_empty(): parts.append(bytes)
		if year <= 0 and int(node.get("height", 0)) > 0: parts.append("%dp" % int(node.height))
	else:
		if not bytes.is_empty(): parts.append(bytes)
		if photo and int(node.get("width", 0)) > 0 and int(node.get("height", 0)) > 0:
			parts.append("%d × %d" % [int(node.width), int(node.height)])
		elif duration > 0: parts.append(time(duration))
		if not photo and bytes.is_empty() and int(node.get("height", 0)) > 0: parts.append("%dp" % int(node.height))
		if not modified.is_empty(): parts.append(modified)
	var status := ""
	var ratio := -1.0
	if not folder and not photo:
		if position_ms > 0:
			status = time(position_ms) + " / " + time(duration) if duration > 0 else I18n.t("Played to %s") % time(position_ms)
			if duration > 0: ratio = clampf(float(position_ms) / duration, 0.0, 1.0)
		elif local.is_empty() and node.get("watched", false): status = I18n.t("Watched")
	var badges: Array[String] = []
	if not bytes.is_empty(): badges.append(bytes)
	if position_ms > 0 and not photo and not folder: badges.append(time(position_ms))
	elif badges.is_empty() and duration > 0 and not photo and not folder: badges.append(time(duration))
	var card_parts := parts.duplicate()
	if row.has("scene") and not status.is_empty():
		card_parts.append(time(position_ms) if position_ms > 0 else status)
	return {"subtitle": " · ".join(parts), "status": status, "ratio": ratio, "badge": " · ".join(badges), "card_detail": " · ".join(card_parts), "folder": folder}
