extends Node
## Application scenery owns its texture independently of the image viewer's current photo.
signal changed
signal custom_saved(path: String, title: String, orientation: int)
const Info := preload("res://scripts/image_info.gd")
const CinemaFeature := preload("res://scripts/environments/cinema_feature.gd")
const BELFAST := "res://backgrounds/belfast_sunset_puresky.jpg"
const MORNING := "res://backgrounds/kloppenheim_06_puresky.jpg"
const NIGHT := "res://backgrounds/eso0932a.jpg"
const BUILTINS := {"belfast": BELFAST, "morning": MORNING, "night": NIGHT}
const CHOICES := ["belfast", "morning", "night", "dark", "passthrough", "custom", "cinema"]
var directory := "user://backgrounds"
var choice := "belfast"
var custom_path := ""
var custom_title := ""
var custom_orientation := 1
var yaw := 0.0
var brightness := 1.0
var loading := false
var error := ""
var sky := Sky.new()
var _material := PanoramaSkyMaterial.new()
var _builtin: Texture2D
var _custom: Texture2D
var _custom_source := {}
var _builtin_requested := ""
var _thread: Thread
var _job := {}
var _generation := 0

func _ready() -> void:
	sky.sky_material = _material
	# Background only; no need for a large reflection cubemap.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	_material.filter = true
	if not select(choice): select("belfast")

func select(value: String) -> bool:
	if value not in CHOICES: return false
	if value == "cinema" and not CinemaFeature.enabled(): return false
	if value == "custom" and not has_custom(): return false
	_generation += 1
	choice = value
	error = ""
	# Keep only the selected built-in texture; finish an older async request
	# before dispatching the latest selection so rapid switches cannot apply it.
	if choice in BUILTINS and _builtin and _builtin.resource_path != BUILTINS[choice]: _builtin = null
	_request_builtin()
	if choice == "custom" and not _custom and not _thread:
		_start_custom(custom_path, custom_orientation, false, custom_title)
	_apply()
	return true

func _request_builtin() -> void:
	var path: String = BUILTINS.get(choice, "")
	if path.is_empty() or _builtin or not _builtin_requested.is_empty(): return
	if ResourceLoader.load_threaded_request(path, "Texture2D") == OK:
		_builtin_requested = path
	else:
		error = "Background unavailable"

func has_custom() -> bool:
	return _custom != null or (_owns_custom(custom_path) and FileAccess.file_exists(custom_path))

func matches_photo(source: Dictionary) -> bool:
	return not source.is_empty() and source == _custom_source and choice == "custom" and has_custom() and not loading and error.is_empty()

func is_loading_custom() -> bool:
	return _thread != null

func _owns_custom(path: String) -> bool:
	var clean := path.simplify_path()
	return clean.get_base_dir() == directory.simplify_path() and clean.get_file().begins_with("custom_") and clean.ends_with(".image")

func remove_custom() -> bool:
	if _thread: return false
	# Only the application's private copy belongs to this action, never the source photo.
	if _owns_custom(custom_path) and FileAccess.file_exists(custom_path) and DirAccess.remove_absolute(custom_path) != OK:
		error = "Background unavailable"; changed.emit(); return false

	_generation += 1
	_custom = null; custom_path = ""; custom_title = ""; custom_orientation = 1
	_custom_source.clear()
	if choice == "custom": select("belfast")
	else: error = ""; _apply()
	return true

func import_photo(source: Dictionary, title: String) -> bool:
	if _thread or source.is_empty(): return false
	error = ""
	_generation += 1
	return _start_custom(str(source.path), int(source.get("orientation", 1)), true, title, source)

func _start_custom(path: String, orientation: int, copy: bool, title: String, source: Dictionary = {}) -> bool:
	# Open before dispatch: an Android photo cache may be unlinked on the next selection.
	var input := FileAccess.open(path, FileAccess.READ)
	if not input or input.get_length() > 256 * 1024 * 1024:
		error = "Background unavailable"; changed.emit(); return false
	var destination := directory.path_join("custom_%d_%d.image" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]) if copy else path
	_job = {"path": destination, "orientation": orientation, "copy": copy, "title": title, "generation": _generation}
	_job["source"] = source.duplicate(true)
	_job["stereo"] = bool(source.get("stereo", false))
	_job["top_bottom"] = bool(source.get("top_bottom", false))
	_job["swap_eyes"] = bool(source.get("swap_eyes", false))
	_job["geometry"] = int(source.get("geometry", 3))
	_thread = Thread.new()
	if _thread.start(_read_custom.bind(input, _job.duplicate(true))) != OK:
		_thread = null; error = "Background unavailable"; changed.emit(); return false
	loading = true
	changed.emit()
	return true

static func _read_custom(input: FileAccess, job: Dictionary) -> Dictionary:
	var path := str(job.path)
	if job.copy:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var output := FileAccess.open(path, FileAccess.WRITE)
		if not output: return {}
		while input.get_position() < input.get_length():
			var bytes := input.get_buffer(mini(65536, input.get_length() - input.get_position()))
			if bytes.is_empty(): return {}
			output.store_buffer(bytes)
		output.close()
	input.close()
	var header := Info.read_header(path)
	if header.is_empty() or header.width > 8192 or header.height > 8192 or int(header.width) * int(header.height) > 32 * 1024 * 1024: return {}
	var data := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var result := image.load_jpg_from_buffer(data) if header.codec == "jpg" else (image.load_png_from_buffer(data) if header.codec == "png" else image.load_webp_from_buffer(data))
	if result != OK: return {}
	Info.orient(image, int(job.orientation))
	var half_sky: bool = job.copy and int(job.get("geometry", 3)) == 1
	if job.copy and not source_supported(image.get_size(), int(job.get("geometry", 3)), job.stereo, job.top_bottom): return {}
	if job.copy and job.stereo:
		# Application skies are mono. Match the viewer's left eye, including swapped pairs.
		var size := image.get_size()
		if (size.y if job.top_bottom else size.x) % 2 != 0: return {}
		var eye := Vector2i(size.x, size.y / 2) if job.top_bottom else Vector2i(size.x / 2, size.y)
		var offset := (Vector2i(0, eye.y) if job.top_bottom else Vector2i(eye.x, 0)) if job.swap_eyes else Vector2i.ZERO
		image = image.get_region(Rect2i(offset, eye))
		var aspect := float(eye.x) / eye.y
		if not half_sky and absf(aspect - 2.0) > 0.02:
			# Half-resolution stereo packs both views into a 2:1 frame. Restore its eye aspect.
			if absf(float(size.x) / size.y - 2.0) > 0.02: return {}
			var width := mini(8192, maxi(eye.x, eye.y * 2))
			image.resize(width, width / 2, Image.INTERPOLATE_CUBIC)
	if half_sky:
		# A VR180 eye covers the front hemisphere, not the entire sphere. Bound the
		# generated sky to 4096x2048 for the minimum supported headsets.
		var edge := mini(2048, maxi(image.get_width(), image.get_height()))
		image.resize(edge, edge, Image.INTERPOLATE_CUBIC)
		var dark := Color(0.025, 0.03, 0.04)
		var fade := maxi(1, edge / 30)
		for x in fade:
			var weight := smoothstep(0.0, float(fade), float(x))
			for y in edge:
				image.set_pixel(x, y, dark.lerp(image.get_pixel(x, y), weight))
				image.set_pixel(edge - 1 - x, y, dark.lerp(image.get_pixel(edge - 1 - x, y), weight))
		var panorama := Image.create(edge * 2, edge, false, Image.FORMAT_RGB8)
		panorama.fill(dark)
		image.convert(Image.FORMAT_RGB8)
		panorama.blit_rect(image, Rect2i(0, 0, edge, edge), Vector2i(edge / 2, 0))
		image = panorama
	if job.copy and (job.stereo or half_sky):
		if image.save_png(path) != OK: return {}
	if absf(float(image.get_width()) / image.get_height() - 2.0) > 0.02: return {}
	image.generate_mipmaps()
	return {"image": image, "orientation": 1 if job.copy and (job.stereo or half_sky) else int(job.orientation)}

static func source_supported(size: Vector2, geometry: int, stereo: bool, top_bottom: bool) -> bool:
	if geometry not in [1, 3] or size.x <= 0 or size.y <= 0: return false
	var aspect := size.x / size.y
	var eye_aspect := aspect * (2.0 if top_bottom else 0.5) if stereo else aspect
	var wanted := 1.0 if geometry == 1 else 2.0
	# Full eyes, or a half-resolution pair whose packed aspect matches one eye.
	return absf(eye_aspect - wanted) < 0.02 or (stereo and absf(aspect - wanted) < 0.02)

func _process(_delta: float) -> void:
	if not _builtin_requested.is_empty():
		var path := _builtin_requested
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var texture := ResourceLoader.load_threaded_get(path) as Texture2D
			_builtin_requested = ""
			if path == BUILTINS.get(choice, "") or choice not in BUILTINS: _builtin = texture
			else: _request_builtin()
			_apply()
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_builtin_requested = ""
			if path == BUILTINS.get(choice, ""): error = "Background unavailable"
			else: _request_builtin()
			_apply()
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if result.has("image"):
			_custom = ImageTexture.create_from_image(result.image)
			_custom_source = _job.source
			if _job.copy:
				var previous := custom_path
				custom_path = str(_job.path); custom_title = str(_job.title); custom_orientation = int(result.orientation)
				if int(_job.generation) == _generation: choice = "custom"
				# Persist the new reference before removing the old private copy.
				custom_saved.emit(custom_path, custom_title, custom_orientation)
				if _owns_custom(previous) and previous != custom_path: DirAccess.remove_absolute(previous)
		else:
			error = "Background unavailable"
			if _job.copy: DirAccess.remove_absolute(str(_job.path))
		_apply()

func _apply() -> void:
	_material.panorama = _builtin if choice in BUILTINS else (_custom if choice == "custom" else null)
	_material.energy_multiplier = brightness
	loading = _thread != null or (choice in BUILTINS and not _builtin_requested.is_empty())
	changed.emit()

func ready_sky() -> Sky:
	return sky if _material.panorama != null else null

func rotate_sky() -> void:
	yaw = fposmod(yaw + 45.0, 360.0)
	changed.emit()

func cycle_brightness() -> void:
	brightness = 0.5 if brightness >= 1.25 else brightness + 0.25
	_apply()

func set_yaw(value: float) -> void:
	if not is_finite(value): return
	yaw = fposmod(value, 360.0)
	changed.emit()

func set_brightness(value: float) -> void:
	if not is_finite(value): return
	brightness = clampf(value, 0.5, 1.25)
	_apply()

func _exit_tree() -> void:
	if _thread: _thread.wait_to_finish()
	if not _builtin_requested.is_empty(): ResourceLoader.load_threaded_get(_builtin_requested)
