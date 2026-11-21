extends RefCounted
## Reconciles the metadata of pictures the library already has. Only an accepted fresh listing
## can invalidate a picture, and only a complete listing can prove a member disappeared.
const Cache := preload("res://scripts/thumbnail_cache.gd")
const References := preload("res://scripts/thumbnail_references.gd")
const ImageInfo := preload("res://scripts/image_info.gd")
const BATCH := 96
const AVAILABLE_PHOTO := 20
const PLAYED_VIDEO := 10

var selected: Dictionary = {}
var _job: Dictionary = {}
var _freshness: String = "unknown"
var _scope: String = ""
var _revision := 0

func busy() -> bool:
	return not _job.is_empty()

static func scope(location: Dictionary) -> String:
	match str(location.get("type", "")):
		"local": return str(location.get("path", ""))
		"smb": return address("smb", str(location.get("server_id", "")), str(location.get("path", "")))
		"dlna":
			var stack: Array = location.get("stack", [])
			return address("dlna", str(location.get("server_id", "")), str(stack.back().id) if not stack.is_empty() else "0")
		"cloud":
			var stack: Array = location.get("stack", [])
			var path := str(location.get("path", ""))
			var provider_id := str(stack.back().get("cloud_id", "")) if not stack.is_empty() else ""
			return address("cloud", path.get_slice("/", 1), provider_id if not provider_id.is_empty() else path)
	return ""

static func address(source: String, server: String, id: String) -> String:
	return "" if server.is_empty() else source + "://" + server.uri_encode() + "/" + id.uri_encode()

static func owner(folder: String) -> String:
	return folder if folder.contains("://") else "file://" + folder

static func folder_identity(folder: String) -> String:
	return "folder:" + folder

static func child_scope(location: Dictionary, entry: Dictionary) -> String:
	var id := str(entry.get("id", ""))
	if id.is_empty(): return ""
	match str(location.get("type", "")):
		"local": return id
		"smb", "dlna": return address(str(location.type), str(location.get("server_id", "")), id)
		"cloud":
			var object_id := str(entry.get("cloud_id", ""))
			return address("cloud", id.get_slice("/", 1), object_id if not object_id.is_empty() else id)
	return ""

static func descriptor(location: Dictionary, entry: Dictionary) -> Dictionary:
	if entry.get("container", false): return {}
	var uri := str(entry.get("uri", ""))
	if location.get("type") == "dlna":
		uri = address("dlna", str(location.get("server_id", "")), str(entry.get("id", "")))
	if uri.is_empty(): return {}
	var title := str(entry.get("title", ""))
	var image: bool = entry.get("kind") == "image" or ImageInfo.is_image(uri, title)
	if not image and entry.get("kind", "video") != "video": return {}
	var identity := str(entry.get("cloud_id", "")) if location.get("type") == "cloud" else str(entry.get("id", ""))
	if identity.is_empty(): identity = uri
	var art := str(entry.get("thumbnail_uri", entry.get("cover", "")))
	var version := JSON.stringify([entry.get("kind"), entry.get("version"), entry.get("etag"),
		entry.get("modified"), entry.get("size"), art.sha1_text()])
	return {"identity": identity, "uri": uri, "version": version,
		"quality": _photo_quality(title) if image else PLAYED_VIDEO}

static func _photo_quality(title: String) -> int:
	match title.get_basename().to_lower():
		"folder": return 50
		"cover": return 40
		"poster": return 30
	return AVAILABLE_PHOTO

func accept(location: Dictionary, result: Dictionary) -> void:
	var folder := scope(location)
	if folder.is_empty() or result.get("state", "ready") != "ready": return
	var freshness := str(result.get("freshness", "unknown"))
	if folder != _scope: _job.clear()
	_scope = folder
	_freshness = freshness
	if freshness != "fresh": return
	_revision += 1
	_job = {"folder": folder, "location": location, "entries": result.get("entries", []), "index": 0,
		"complete": bool(result.get("complete", false)), "best": {}, "generation": Cache.generation}

func tick(folder: String) -> bool:
	if _job.is_empty(): return false
	if folder != _job.folder or _job.generation != Cache.generation:
		_job.clear()
		return false
	if not Cache.ready() or Cache.clearing() or not References.ready(): return false
	if not _job.has("unseen"):
		_job.unseen = References.known(folder)
		_job.cover = References.cover(folder)
	var entries: Array = _job.entries
	var end := mini(entries.size(), int(_job.index) + BATCH)
	var deadline := Time.get_ticks_usec() + 1200
	for index in range(int(_job.index), end):
		if entries[index] is Dictionary: _compare(entries[index])
		_job.index = index + 1
		if Time.get_ticks_usec() >= deadline: break
	if int(_job.index) < entries.size(): return false
	if _job.complete:
		# Process a bounded number of saved members per frame, even when a directory was emptied.
		var unseen: Dictionary = _job.unseen
		for identity in unseen.keys().slice(0, BATCH):
			_invalidate(str(identity), unseen[identity])
			unseen.erase(identity)
			if Time.get_ticks_usec() >= deadline: break
		if not unseen.is_empty(): return false
		if not _job.cover.is_empty() and not _job.get("cover_seen", false):
			References.forget_cover(folder)
	var best: Dictionary = _job.best
	var current := References.cover(folder)
	if not best.is_empty() and (current.is_empty() or int(best.quality) >= int(current.get("quality", 0))):
		References.select_cover(folder, owner(folder), best)
	_job.clear()
	return true

func _compare(entry: Dictionary) -> void:
	if entry.get("container", false):
		var child := child_scope(_job.location, entry)
		if child.is_empty(): return
		var modified := int(entry.get("modified", -1))
		var identity := folder_identity(child).sha1_text()
		var prior: Dictionary = _job.unseen.get(identity, {})
		_job.unseen.erase(identity)
		if not prior.is_empty() and prior.get("version") != str(modified).sha1_text():
			References.forget_identity(_job.folder, identity)
		if modified >= 0:
			var current := References.cover(child)
			if not current.is_empty() and int(current.get("modified", -1)) != modified:
				current.pending = int(current.get("modified", -1)) >= 0
				current.modified = modified
				References.select_cover(child, owner(child), current)
		return
	var item := descriptor(_job.location, entry)
	if item.is_empty(): return
	var identity: String = item.identity.sha1_text()
	var current: Dictionary = _job.unseen.get(identity, {})
	_job.unseen.erase(identity)
	var uri: String = item.uri
	var digest := uri.sha1_text()
	var folder: String = _job.folder
	if current.is_empty():
		if Cache.has(uri):
			References.remember_fingerprint(folder, item.identity, uri, item.version, uri)
		return
	if current.get("version") != item.version.sha1_text():
		_invalidate(identity, current)
		return
	var old_picture := str(current.get("picture", ""))
	if old_picture.is_empty(): return
	if old_picture != digest:
		Cache.relocate_digest(old_picture, uri)
		current.picture = digest
	var quality := int(item.quality) if int(current.get("quality", 0)) > 0 else 0
	References.remember_fingerprint(folder, item.identity, uri, item.version, uri, 0, quality)
	if _job.cover.get("identity") == identity: _job.cover_seen = true
	if quality <= 0 or not Cache.has(uri): return
	var best: Dictionary = _job.best
	if best.is_empty() or quality > int(best.quality):
		current.identity = identity
		current.quality = quality
		current.modified = _job.cover.get("modified", -1)
		current.erase("pending")
		_job.best = current

func _invalidate(identity: String, entry: Dictionary) -> void:
	var picture := str(entry.get("picture", ""))
	if not picture.is_empty(): Cache.forget_digest(picture, false)
	if References.cover(_job.folder).get("identity") == identity: References.forget_cover(_job.folder)
	References.forget_identity(_job.folder, identity)

func allowed_picture(folder: String, item: Dictionary) -> bool:
	if folder != _scope or item.is_empty(): return true
	var previous := References.fingerprint(folder, item.identity)
	if previous.is_empty(): return _freshness == "fresh" or (References.ready() and Cache.has_played_picture(item.uri))
	return previous.get("version") == item.version.sha1_text() and previous.get("picture") == item.uri.sha1_text()

func select(uri: String, folder: String, item: Dictionary) -> void:
	selected.clear()
	if folder.is_empty() or item.is_empty() or uri != item.uri: return
	selected = {"folder": folder, "item": item.duplicate(), "generation": Cache.generation, "revision": _revision}

func observed(uri: String) -> bool:
	if selected.is_empty() or selected.item.uri != uri or selected.generation != Cache.generation:
		return false
	if not Cache.has_played_picture(uri): return false
	var selection := selected
	selected = {}
	if selection.revision != _revision and selection.folder == _scope:
		var current := References.fingerprint(selection.folder, selection.item.identity)
		if current.is_empty() or current.get("version") != selection.item.version.sha1_text(): return false
	remember(selection.folder, selection.item)
	return true

func remember(folder: String, item: Dictionary) -> void:
	var uri: String = item.uri
	var current := References.cover(folder)
	var quality := int(item.quality)
	References.remember_fingerprint(folder, item.identity, uri, item.version, uri, 0, quality)
	if current.is_empty() or quality >= int(current.get("quality", 0)) or current.get("identity") == item.identity.sha1_text():
		References.remember_cover(folder, owner(folder), item.identity, uri, uri, quality, int(current.get("modified", -1)))

static func texture(folder: String) -> Texture2D:
	var cover := References.cover(folder)
	return Cache.texture_by_digest(str(cover.get("picture", "")), bool(cover.get("local", false)))
