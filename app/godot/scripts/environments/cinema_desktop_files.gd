extends Node
## Read-only Windows/local browsing through the production LibraryMenu protocol.
signal media_list(id: int, payload: String)
const VIDEO_EXTENSIONS := ["mp4", "mkv", "mov", "m4v", "avi", "webm", "mpeg", "mpg", "ts", "m2ts", "mts", "wmv", "flv", "ogv", "ogg"]
const MAX_ENTRIES := 10000
var _serial := 0
var _workers := {}
var _closing := false

func media_local_browse(path: String) -> int:
	_serial += 1
	var id := _serial
	var worker := Thread.new()
	_workers[id] = worker
	if worker.start(_read.bind(id, path)) != OK:
		_workers.erase(id)
		_deliver.call_deferred(id, {"state": "error", "path": path, "error": "Folder unavailable"})
	return id

func _read(id: int, path: String) -> void:
	var volumes := _volumes()
	var result := {"source": "local", "state": "ready", "path": path, "all_files": true, "volumes": volumes, "entries": []}
	if path.is_empty():
		result.entries = volumes
	else:
		var directory := DirAccess.open(path)
		if directory == null or directory.list_dir_begin() != OK:
			result.state = "error"; result.error = "Folder unavailable"
		else:
			var name := directory.get_next()
			while not name.is_empty():
				if name not in [".", ".."]:
					var full_path := path.path_join(name)
					if directory.current_is_dir():
						result.entries.append({"id": full_path, "title": name, "container": true, "can_delete": false, "can_rename": false})
					elif name.get_extension().to_lower() in VIDEO_EXTENSIONS:
						var file := FileAccess.open(full_path, FileAccess.READ)
						result.entries.append({"id": full_path, "title": name, "container": false, "kind": "video",
							"uri": video_uri(full_path), "size": file.get_length() if file else 0,
							"can_delete": false, "can_rename": false})
					if result.entries.size() > MAX_ENTRIES:
						result.state = "error"; result.error = "Too many files in this folder"; result.entries.clear(); break
				name = directory.get_next()
			directory.list_dir_end()
			result.entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if bool(a.container) != bool(b.container): return bool(a.container)
				return str(a.title).naturalnocasecmp_to(str(b.title)) < 0)
	_deliver.call_deferred(id, result)

func _volumes() -> Array:
	var volumes := []
	for index in DirAccess.get_drive_count():
		var drive := DirAccess.get_drive_name(index).replace("\\", "/")
		if not drive.ends_with("/"): drive += "/"
		volumes.append({"id": drive, "title": drive, "container": true, "volume": true, "removable": false, "can_delete": false, "can_rename": false})
	return volumes

static func video_uri(path: String) -> String:
	return "file://" + path.replace("\\", "/").uri_encode()

func _deliver(id: int, result: Dictionary) -> void:
	if _workers.has(id):
		var worker: Thread = _workers[id]
		worker.wait_to_finish(); _workers.erase(id)
	if not _closing: media_list.emit(id, JSON.stringify(result))

func media_local_refresh_storage() -> void:
	(func(): media_list.emit(0, JSON.stringify({"source": "local_storage", "state": "changed", "volumes": _volumes()}))).call_deferred()

func _unsupported(source: String) -> int:
	_serial += 1
	var id := _serial
	(func(): media_list.emit(id, JSON.stringify({"source": source, "state": "error", "error": "Source unavailable"}))).call_deferred()
	return id

func media_smb_servers() -> int: return _unsupported("smb")
func media_smb_discover() -> int: return _unsupported("smb")
func media_dlna_servers() -> int: return _unsupported("dlna")
func media_dlna_discover() -> int: return _unsupported("dlna")
func media_cloud_browse(_path: String, _refresh: bool) -> int: return _unsupported("cloud")
func media_cloud_accounts() -> int: return _unsupported("cloud_accounts")

func _exit_tree() -> void:
	_closing = true
	for worker: Thread in _workers.values(): worker.wait_to_finish()
	_workers.clear()
