extends RefCounted

static func decode_path(value: String) -> String:
	# Godot's decoder treats + as a form-space and only handles uppercase escapes.
	if not value.contains("%") and not value.contains("+"): return value
	var normalized := ""
	var index := 0
	while index < value.length():
		if value[index] == "%":
			if index + 2 >= value.length() or value[index + 1] not in "0123456789abcdefABCDEF" or value[index + 2] not in "0123456789abcdefABCDEF": return ""
			normalized += value.substr(index, 3).to_upper()
			index += 3
		else:
			normalized += "%2B" if value[index] == "+" else value[index]
			index += 1
	return normalized.uri_decode()

static func filename(location: String) -> String:
	# Ordinary SMB library identities carry the literal path. The manual subtitle
	# picker uses encoded URIs and parses those through SubtitleSources instead.
	if not location.contains("://") or location.begins_with("smb://"):
		return location.get_file()
	return decode_path(location.get_slice("?", 0).get_slice("#", 0).get_file())
