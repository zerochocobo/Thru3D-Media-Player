extends RefCounted
## Only successful full listings are remembered. Consume before an automatic reload:
## a crash, changed directory or interrupted reload must not create a startup loop.
var path := "user://cloud_directory_modes.cfg"
const MAX_DIRECTORIES := 512

func key(location: String, folder_id: String) -> String:
	return (location + "\n" + folder_id).sha256_text()

func _read() -> ConfigFile:
	var config := ConfigFile.new()
	var file := FileAccess.open(path, FileAccess.READ)
	if file and file.get_length() <= 128 * 1024:
		config.load(path)
	return config

func contains(id: String) -> bool:
	return _read().has_section_key("complete", id)

func forget(id: String) -> bool:
	var config := _read()
	if not config.has_section_key("complete", id): return true
	config.erase_section_key("complete", id)
	return config.save(path) == OK

func remember(id: String) -> bool:
	var config := _read()
	config.set_value("complete", id, int(Time.get_unix_time_from_system()))
	var keys: Array = Array(config.get_section_keys("complete"))
	keys.sort_custom(func(a, b): return int(config.get_value("complete", a)) < int(config.get_value("complete", b)))
	while keys.size() > MAX_DIRECTORIES: config.erase_section_key("complete", keys.pop_front())
	return config.save(path) == OK
