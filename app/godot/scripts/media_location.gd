extends RefCounted
## Store browser identities and paths, never a resolved stream, login token or credential.
static func clean(value: Variant) -> Dictionary:
	if not value is Dictionary: return {}
	if value.get("type") == "archive":
		var source := str(value.get("source_uri", ""))
		var path := str(value.get("path", ""))
		if preload("res://scripts/file_mode_memory.gd").key_for(source).is_empty() or path.length() > 8192 \
			or path.begins_with("/") or path.contains("\\") or path.split("/").has("..") or path.split("/").has("."): return {}
		var parent: Variant = value.get("parent", {})
		return {"type":"archive", "source_uri":source, "source_file":cloud_file(value.get("source_file", {}), source), "source_title":str(value.get("source_title", "")).left(256), "path":path.trim_suffix("/"),
			"parent":clean(parent) if parent is Dictionary and parent.get("type") != "archive" else {}}
	var result := {}
	for key in ["type", "server_id", "path", "title", "item_id", "library_id"]:
		if value.get(key) is String and value[key].length() <= 8192: result[key] = value[key]
	for key in ["stack", "folder_path"]:
		if not value.get(key) is Array: continue
		var stack: Array = []
		for item in value[key].slice(0, 64):
			if item is Dictionary and item.get("id") is String and item.get("title", "") is String:
				var folder := {"id": str(item.id).left(8192), "title": str(item.get("title", "")).left(256)}
				var cloud_id: Variant = item.get("cloud_id")
				if result.get("type") == "cloud" and cloud_id is String and not cloud_id.is_empty() and cloud_id.length() <= 2048 and not cloud_id.contains("\n") and not cloud_id.contains("\r") and not cloud_id.contains("://"):
					folder["cloud_id"] = cloud_id
				stack.append(folder)
		result[key] = stack
	var kind := str(result.get("type", ""))
	if kind not in ["local", "smb", "cloud", "dlna", "server"]: return {}
	if kind in ["local", "cloud"] and str(result.get("path", "")).is_empty(): return {}
	if kind in ["smb", "dlna", "server"] and str(result.get("server_id", "")).is_empty(): return {}
	if kind == "smb" and not result.has("path"): result.path = ""
	return result

static func cloud_file(value: Variant, uri: String) -> Dictionary:
	if not uri.begins_with("cloud://") or not value is Dictionary or value.get("uri") != uri: return {}
	var id := str(value.get("id", ""))
	if id.is_empty() or id.length() > 2048 or id.contains("://"): return {}
	for i in id.length():
		if id.unicode_at(i) < 32 or id.unicode_at(i) == 127: return {}
	var size := int(value.get("size", 0))
	if size <= 0: return {}
	return {"uri":uri, "id":id, "size":size, "modified":int(value.get("modified", -1))}

static func infer(uri: String) -> Dictionary:
	if uri.begins_with("dlna://"):
		return {"type": "dlna", "server_id": uri.trim_prefix("dlna://").get_slice("/", 0).uri_decode(), "item_id": uri.get_file().uri_decode()}
	if uri.begins_with("file://"):
		var path := uri.trim_prefix("file://").uri_decode().get_base_dir()
		return {"type": "local", "path": path, "stack": [{"id": path, "title": path.get_file()}]}
	for scheme in ["smb", "cloud"]:
		if not uri.begins_with(scheme + "://"): continue
		var rest := uri.trim_prefix(scheme + "://")
		var server := rest.get_slice("/", 0)
		if server.is_empty(): return {}
		var path := rest.substr(server.length()).trim_prefix("/").get_base_dir().uri_decode()
		if scheme == "smb": return {"type": scheme, "server_id": server, "path": path}
		var parent := "/" + server + ("/" + path if not path.is_empty() else "")
		return {"type": scheme, "path": parent, "stack": [{"id": parent, "title": path.get_file() if not path.is_empty() else server}]}
	if uri.begins_with("medialib://"):
		return {"type": "server", "server_id": uri.trim_prefix("medialib://").get_slice("/", 0), "item_id": uri.get_slice("?", 0).get_file()}
	return {}

static func capture(menu: Node, row: Dictionary) -> Dictionary:
	if row.has("location"): return clean(row.location)
	match menu.section:
		menu.Section.LOCAL:
			return clean({"type": "local", "path": menu._local_path(), "stack": menu._local_stack})
		menu.Section.SMB:
			return clean({"type": "smb", "server_id": menu._smb_server, "path": menu._smb_path})
		menu.Section.CLOUD:
			return infer(str(row.get("uri", ""))) if menu.cloud_search.active else clean({"type": "cloud", "path": menu._cloud_path(), "stack": menu._cloud_stack})
		menu.Section.DLNA:
			return clean({"type": "dlna", "server_id": menu._dlna_server, "stack": menu._dlna_stack, "item_id": str(row.get("id", ""))})
		menu.Section.MEDIA_SERVER:
			var node: Dictionary = row.get("scene", row)
			var path: Array = menu.server_browser.folder_path.duplicate(true)
			var parent := str(node.get("season_id", node.get("parent_id", node.get("series_id", ""))))
			if not parent.is_empty() and (path.is_empty() or str(path.back().id) != parent):
				path.append({"id": parent, "title": str(node.get("series_title", parent))})
			return clean({"type": "server", "server_id": str(menu.server_browser.server.get("id", "")), "library_id": menu.server_browser.library_id,
				"folder_path": path, "item_id": str(node.get("id", ""))})
	return infer(str(row.get("uri", "")))

static func folder_uri(location: Dictionary) -> String:
	if location.get("type") == "archive": return "folder://" + JSON.stringify(["archive", location.get("source_uri", ""), location.get("path", "")]).sha256_text()
	var stack: Array = location.get("stack", location.get("folder_path", []))
	var container := str(stack.back().id) if not stack.is_empty() else "0"
	return "folder://" + JSON.stringify([location.get("type", ""), location.get("server_id", ""), location.get("path", ""), location.get("library_id", ""), container]).sha256_text()

static func folder_title(location: Dictionary, fallback: String = "") -> String:
	if location.get("type") == "archive":
		return str(location.get("source_title", fallback)) + (" / " + str(location.path).get_file() if not str(location.get("path", "")).is_empty() else "")
	var stack: Array = location.get("stack", location.get("folder_path", []))
	if not stack.is_empty() and not str(stack.back().get("title", "")).strip_edges().is_empty(): return str(stack.back().title)
	var path := str(location.get("path", "")).trim_suffix("/")
	if not path.is_empty() and not path.contains("://"): return path.get_file()
	var title := str(location.get("title", ""))
	return title if not title.is_empty() else fallback

static func folder_path(location: Dictionary) -> String:
	if location.get("type") == "archive": return str(location.get("source_title", "")) + (" / " + str(location.path) if not str(location.get("path", "")).is_empty() else "")
	var path := str(location.get("path", ""))
	if not path.is_empty() and not path.contains("://") and location.get("type") in ["local", "smb"]: return path
	var stack: Array = location.get("stack", location.get("folder_path", []))
	var names: Array[String] = []
	for item in stack:
		if not str(item.get("title", "")).is_empty(): names.append(str(item.title))
	return " / ".join(names)
