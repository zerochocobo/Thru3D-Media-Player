extends "res://scripts/file_mode_memory.gd"

# Separate banks let track choices survive independently of projection and play history.
# Only hashed original file identities and track metadata are persisted, never proxy URLs.
const UNRESOLVED := -2
const CHANNELS := ["audio", "subtitle"]

func _bank_path(bank: int) -> String:
	return directory.path_join("file_tracks_%d.json" % bank)

func _value_field() -> String:
	return "tracks"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.is_empty() or value.size() > 2: return false
	for channel in value:
		if channel not in CHANNELS or not valid_choice(value[channel]): return false
	return true

func _normalize_value(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	for channel in result:
		result[channel].id = int(result[channel].id)
		if result[channel].has("matches"): result[channel].matches = int(result[channel].matches)
	return result

static func valid_choice(value: Variant) -> bool:
	if not value is Dictionary: return false
	var id: Variant = value.get("id")
	if not (id is int or id is float) or not is_finite(float(id)) \
		or float(id) != floorf(float(id)) or float(id) < -1 or float(id) > 2147483647: return false
	if int(id) <= 0: return value.size() == 1
	for key in ["title", "language", "codec"]:
		if not value.get(key) is String or value[key].length() > 1024: return false
	var matches: Variant = value.get("matches")
	if not (matches is int or matches is float) or not is_finite(float(matches)) \
		or float(matches) != floorf(float(matches)) or float(matches) < 1 or float(matches) > 4096: return false
	return (value.size() == 7 or (value.size() == 8 and value.get("external", false) and valid_file(value.get("file")))) and value.get("external") is bool and value.get("layout") is String \
		and value.layout.length() == 64 and value.layout.is_valid_hex_number(false)

static func valid_file(value: Variant) -> bool:
	if not value is String or value.length() < 1 or value.length() > 1024 or value.begins_with(".") or value.contains("/") or value.contains("\\"): return false
	for index in value.length():
		if value.unicode_at(index) < 32: return false
	return true

static func identity(track: Dictionary) -> Dictionary:
	return {"title": str(track.get("title", "")).left(1024),
		"language": str(track.get("language", "")).to_lower().left(1024),
		"codec": str(track.get("codec", "")).to_lower().left(1024), "external": bool(track.get("external", false))}

static func layout(tracks: Array) -> String:
	var rows: Array = []
	for track in tracks:
		if track is Dictionary and int(track.get("id", 0)) > 0:
			var row := identity(track)
			row.id = int(track.id)
			rows.append(row)
	rows.sort_custom(func(a, b): return int(a.id) < int(b.id))
	return JSON.stringify(rows).sha256_text()

static func describe(id: int, tracks: Array) -> Dictionary:
	if id in [-1, 0]: return {"id": id}
	for track in tracks:
		if track is Dictionary and int(track.get("id", 0)) == id:
			var result := identity(track)
			result.id = id
			result.layout = layout(tracks)
			result.matches = tracks.filter(func(t): return t is Dictionary and int(t.get("id", 0)) > 0 and identity(t) == identity(track)).size()
			if bool(track.get("external", false)) and valid_file(track.get("source_file")): result.file = track.source_file
			return result
	return {}

static func resolve(choice: Dictionary, tracks: Array) -> int:
	if not valid_choice(choice): return UNRESOLVED
	if int(choice.id) <= 0: return int(choice.id)
	if choice.has("file"):
		for track in tracks:
			if track is Dictionary and track.get("external", false) and track.get("source_file", "") == choice.file: return int(track.id)
		return UNRESOLVED
	var matches: Array[int] = []
	for track in tracks:
		if track is Dictionary and int(track.get("id", 0)) > 0 and identity(track) == identity(choice):
			matches.append(int(track.id))
	if matches.size() == 1 and int(choice.matches) == 1: return matches[0]
	# Duplicate unnamed/language-identical tracks need the unchanged complete layout;
	# otherwise waiting/default is safer than selecting an arbitrary matching track.
	if matches.has(int(choice.id)) and layout(tracks) == choice.layout: return int(choice.id)
	return UNRESOLVED
