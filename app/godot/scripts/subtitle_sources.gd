extends RefCounted
## Shared picker policy; native MPV still verifies the loaded file's actual codec.
const EXTENSIONS := ["srt", "ass", "ssa", "vtt", "smi", "sami", "sub"]

static func supported(filename: String) -> bool:
	return filename.length() > 0 and filename.length() <= 1024 and not filename.begins_with(".") and not filename.contains("/") and not filename.contains("\\") and filename.get_extension().to_lower() in EXTENSIONS

static func decode_uri(value: String) -> String:
	# The pinned engine decodes uppercase hex only. Normalize escapes, not filename case.
	var normalized := ""
	var index := 0
	while index < value.length():
		if value[index] == "%":
			if index + 2 >= value.length() or value[index + 1] not in "0123456789abcdefABCDEF" or value[index + 2] not in "0123456789abcdefABCDEF": return ""
			normalized += value.substr(index, 3).to_upper(); index += 3
		else:
			normalized += value[index]; index += 1
	return normalized.uri_decode()

static func filename(uri: String) -> String:
	var path := decode_uri(uri.get_slice("?", 0).get_slice("#", 0))
	if path.begins_with("content://") and path.contains("/document/"):
		path = path.get_slice("/document/", 1)
		path = path.substr(path.find(":") + 1)
	return path.get_file()

static func valid_uri(uri: Variant) -> bool:
	if not uri is String or uri.length() > 4096 or not uri.contains("://") or uri.contains("?") or uri.contains("#"): return false
	var scheme: String = uri.get_slice("://", 0)
	if scheme not in ["file", "smb", "cloud", "usb", "content"]: return false
	var rest: String = uri.get_slice("://", 1)
	if not rest.contains("/"): return false
	var authority: String = rest.get_slice("/", 0)
	if scheme == "file":
		if not authority.is_empty(): return false
	elif authority.is_empty() or authority.contains("@") or authority.contains(":"): return false
	if scheme == "content" and authority != "com.android.externalstorage.documents": return false
	var decoded := decode_uri(rest)
	if decoded.is_empty(): return false
	if decoded.contains("\\"): return false
	for index in decoded.length():
		if decoded.unicode_at(index) < 32: return false
	for part in decoded.split("/"):
		if part in [".", ".."]: return false
	return supported(filename(uri))
