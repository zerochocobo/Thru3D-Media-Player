extends RefCounted
## Files live once in the library; playlists contain stable references only.
const Catalog := preload("res://scripts/background_audio_catalog.gd")
var directory := "user://background_audio"
var imports: Array[Dictionary] = []
var playlists: Array[Dictionary] = []
var error := ""
var revision := 0
var _index := {}
var _indexed_size := -1

func load_library() -> void:
	var store := ConfigFile.new()
	var path := directory.path_join("library.cfg")
	if store.load(path) != OK:
		if store.load(path + ".bak") != OK: store.load(directory.path_join("imports.cfg"))
	imports.clear(); playlists.clear(); _indexed_size = -1
	var records: Variant = store.get_value("audio", "entries", [])
	var seen := {}
	if records is Array:
		for row in records:
			if not row is Dictionary: continue
			var id := str(row.get("id", "")); var local := str(row.get("path", ""))
			if not id.begins_with("import_") or seen.has(id) or not Catalog.supported(local) or not FileAccess.file_exists(local): continue
			seen[id] = true
			imports.append({"id": id, "path": local, "label": str(row.get("label", local.get_file())).left(160), "bytes": int(row.get("bytes", 0))})
	var lists: Variant = store.get_value("audio", "playlists", [])
	seen.clear()
	if lists is Array:
		for row in lists:
			if not row is Dictionary: continue
			var id := str(row.get("id", ""))
			if not id.begins_with("list_") or seen.has(id): continue
			seen[id] = true
			playlists.append({"id": id, "label": str(row.get("label", "Playlist")).left(80), "tracks": valid_ids(row.get("tracks", [])), "builtin": false})
	revision += 1

func resolve(id: String) -> Dictionary:
	if _indexed_size != imports.size():
		_index.clear()
		for kind in ["music", "ambience"]:
			for row in Catalog.entries(kind): _index[str(row.id)] = Catalog.builtin(row.id, kind)
		for row in imports: _index[str(row.id)] = row
		_indexed_size = imports.size()
	return _index.get(id, {}).duplicate(true)

func valid_ids(values: Variant) -> Array[String]:
	var result: Array[String] = []
	var seen := {}
	if values is Array:
		for value in values:
			var id := str(value)
			if not seen.has(id) and not resolve(id).is_empty(): result.append(id); seen[id] = true
	return result

func all_tracks() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for kind in ["music", "ambience"]:
		for row in Catalog.entries(kind): result.append(Catalog.builtin(row.id, kind))
	result.append_array(imports.duplicate(true))
	return result

func all_playlists() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for style in ["Calm", "Joyful", "Focus"]:
		var tracks: Array[String] = []
		for row in Catalog.MUSIC:
			if row.style == style: tracks.append(row.id)
		result.append({"id": style.to_lower(), "label": style, "tracks": tracks, "builtin": true})
	result.append({"id": "ambience", "label": "Ambience", "tracks": Catalog.AMBIENCE.map(func(row): return str(row.id)), "builtin": true})
	result.append_array(playlists.duplicate(true))
	return result

func playlist(id: String) -> Dictionary:
	for row in all_playlists():
		if row.id == id: return row
	return {}

func commit(entries: Array, lists: Array) -> bool:
	error = ""
	if DirAccess.make_dir_recursive_absolute(directory) != OK: error = "Could not save audio library"; return false
	var store := ConfigFile.new()
	store.set_value("audio", "entries", entries); store.set_value("audio", "playlists", lists)
	var path := directory.path_join("library.cfg"); var pending := path + ".pending"
	if store.save(pending) != OK: error = "Could not save audio library"; return false
	# Keep the last complete record recoverable after an interrupted replacement.
	if FileAccess.file_exists(path) and DirAccess.copy_absolute(path, path + ".bak") != OK:
		error = "Could not save audio library"; return false
	if DirAccess.rename_absolute(pending, path) != OK: error = "Could not save audio library"; return false
	imports.assign(entries.duplicate(true)); playlists.assign(lists.duplicate(true)); _indexed_size = -1; revision += 1
	return true

func create_playlist(label: String, tracks: Array = []) -> String:
	label = label.strip_edges().left(80)
	if label.is_empty(): return ""
	var id := "list_%d_%d" % [Time.get_ticks_usec(), randi()]
	var lists := playlists.duplicate(true)
	lists.append({"id": id, "label": label, "tracks": valid_ids(tracks), "builtin": false})
	return id if commit(imports, lists) else ""

func rename_playlist(id: String, label: String) -> bool:
	label = label.strip_edges().left(80)
	if label.is_empty(): return false
	var lists := playlists.duplicate(true)
	for row in lists:
		if row.id == id: row.label = label; return commit(imports, lists)
	return false

func delete_playlist(id: String) -> bool:
	if playlist(id).get("builtin", true): return false
	return commit(imports, playlists.filter(func(row): return row.id != id))

func set_tracks(id: String, tracks: Array) -> bool:
	var lists := playlists.duplicate(true)
	for row in lists:
		if row.id == id: row.tracks = valid_ids(tracks); return commit(imports, lists)
	return false

func add_track(id: String, track: String) -> bool:
	var row := playlist(id)
	if row.is_empty() or row.builtin or resolve(track).is_empty(): return false
	var tracks: Array = row.tracks.duplicate()
	if tracks.has(track): return true
	tracks.append(track); return set_tracks(id, tracks)

func remove_track(id: String, track: String) -> bool:
	var row := playlist(id)
	return false if row.is_empty() or row.builtin else set_tracks(id, row.tracks.filter(func(value): return value != track))

func move_track(id: String, track: String, delta: int) -> bool:
	var row := playlist(id)
	if row.is_empty() or row.builtin: return false
	var tracks: Array = row.tracks.duplicate(); var index := tracks.find(track)
	if index < 0 or index + delta < 0 or index + delta >= tracks.size(): return false
	tracks.remove_at(index); tracks.insert(index + delta, track); return set_tracks(id, tracks)

func add_import(entry: Dictionary, destination: String = "") -> bool:
	var entries := imports.duplicate(true)
	var exists := entries.any(func(row): return row.id == entry.id)
	if not exists: entries.append({"id": str(entry.id), "path": str(entry.path), "label": str(entry.label), "bytes": int(entry.get("bytes", 0))})
	var lists := playlists.duplicate(true)
	var added := false
	for row in lists:
		if row.id == destination and not row.tracks.has(entry.id): row.tracks.append(str(entry.id)); added = true
	# Publish file metadata and its destination reference in the same transaction.
	return true if exists and not added else commit(entries, lists)

func references(id: String) -> Array[String]:
	var names: Array[String] = []
	for row in playlists:
		if row.tracks.has(id): names.append(str(row.label))
	return names

func forget_import(id: String) -> bool:
	var lists := playlists.duplicate(true)
	for row in lists: row.tracks = row.tracks.filter(func(value): return value != id)
	return commit(imports.filter(func(row): return row.id != id), lists)
