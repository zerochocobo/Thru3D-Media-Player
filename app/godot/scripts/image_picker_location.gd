extends RefCounted
## Only provider navigation IDs belong here, never selected media URLs or credentials.
const SCOPE := "image-picker:last-location"

static func clean(value: Variant) -> Dictionary:
	if not value is Dictionary or value.get("source", "") not in ["local", "smb", "dlna", "cloud"]: return {}
	var result := {"source": value.source}
	if value.source in ["smb", "dlna"]:
		if not value.get("server") is String or value.server.length() > 512: return {}
		result.server = value.server
	if value.source == "smb":
		if not value.get("path") is String or value.path.length() > 4096: return {}
		result.path = value.path
	else:
		if not value.get("folders") is Array or value.folders.size() > 64: return {}
		result.folders = []
		for folder in value.folders:
			if not folder is Dictionary or not folder.get("id") is String or folder.id.length() > 4096: return {}
			result.folders.append({"id": folder.id, "title": str(folder.get("title", "")).left(160),
				"cloud_id": str(folder.get("cloud_id", "")).left(512), "provider": str(folder.get("provider", "")).left(64)})
	return result
