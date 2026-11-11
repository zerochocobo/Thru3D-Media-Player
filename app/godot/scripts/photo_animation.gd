extends RefCounted
## One focused picture owns playback. Gallery previews and page layouts stay still.
const Methods := preload("res://scripts/platform_methods.gd")
var host: Node3D
var request := 0
var token := 0
var paused := false
var ended := false
var failed := false
var app_focused: Callable
var depth_mode := false
var _depth_running := false
var _depth_token := 0
var _depth_loop := -1
var depth_stats := {}

func _init(owner: Node3D) -> void:
	host = owner

func available() -> bool:
	return bool(host._metadata.get("animated", false)) and not host.archive_mode and host.gallery.mode != 4 \
		and Methods.supports(host.platform, "get_photo_animation_frame")

func activate() -> void:
	stop_depth()
	request = host._display_request
	token = 0; paused = false; ended = false; failed = false

func close() -> void:
	stop_depth()
	if request > 0 and Methods.supports(host.platform, "pause_photo_animation"):
		host.platform.pause_photo_animation(request, true)
	request = 0; token = 0

func suspend() -> void:
	_configure_depth(false)
	if request > 0 and Methods.supports(host.platform, "pause_photo_animation"):
		host.platform.pause_photo_animation(request, true)

func freeze() -> void:
	if not available(): return
	stop_depth()
	paused = true
	host.platform.pause_photo_animation(request, true)
	if token > 0:
		var pixels: PackedByteArray = host.platform.photo_animation_pixels(request, token)
		var width := int(host._size.x); var height := int(host._size.y)
		if width > 0 and height > 0 and pixels.size() == width * height * 4:
			var frame := Image.create_from_data(width,height,false,Image.FORMAT_RGBA8,pixels)
			frame.generate_mipmaps()
			host._full_image = frame
			host._display_result["image"] = frame

func toggle() -> void:
	if not available(): return
	if ended or failed:
		_configure_depth(false)
		_clear_depth()
		host.platform.restart_photo_animation(request)
		token = 0; ended = false; failed = false; paused = false
	else:
		paused = not paused
	if not paused:
		if host.portrait_requested: host.set_portrait(false)
		if host.spatial_requested: host.set_spatial(false)
		if not depth_mode:
			if host.depth_requested: host.set_depth(false)
			host._discard_native_depth(request)
			host._display_depth_data.clear()
			host._depth_texture = null; host._stereo_texture = null
	host.platform.pause_photo_animation(request, paused)
	host.changed.emit()

func tick() -> void:
	if request != host._display_request: return
	if not available() or host._texture == null:
		stop_depth()
		suspend(); return
	var focused: bool = app_focused.call() if app_focused.is_valid() else host.get_tree().root.has_focus()
	var suspended: bool = host.loading or host.gallery.overview() or not host.is_visible_in_tree() \
		or (host.depth_requested and not depth_mode) or host.portrait_requested or host.spatial_requested \
		or not focused
	_configure_depth(depth_mode and host.depth_requested and not suspended)
	host.platform.pause_photo_animation(request, paused or suspended)
	var report: Variant = JSON.parse_string(host.platform.get_photo_animation_frame(request))
	if report is not Dictionary: return
	var next_token := int(report.get("token", 0))
	var finished := bool(report.get("ended", false))
	var error := bool(report.get("failed", false))
	if finished != ended or error != failed:
		if error:
			host.error = "Not enough memory to open image" if report.get("error") == "PHOTO_OUT_OF_MEMORY" else "Image unavailable"
			if report.get("error") == "PHOTO_MEMORY_UNAVAILABLE": host.error = "Unable to check available memory"
		ended = finished; failed = error; host.changed.emit()
	if next_token <= 0 or suspended: return
	if next_token == token:
		_poll_depth(report)
		return
	host._ensure_full_texture()
	var image: Image = host._display_result.get("image")
	var mipmaps: bool = image != null and image.has_mipmaps()
	var texture := RenderingServer.texture_get_native_handle(host._texture.get_rid())
	var uploaded: bool = host.platform.upload_photo_animation_frame(request, next_token, texture, mipmaps)
	if not uploaded:
		var pixels: PackedByteArray = host.platform.photo_animation_pixels(request, next_token)
		var width := int(report.get("width", 0)); var height := int(report.get("height", 0))
		if width <= 0 or height <= 0 or pixels.size() != width * height * 4: return
		var frame := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, pixels)
		if mipmaps: frame.generate_mipmaps()
		host._texture.update(frame)
	token = next_token
	_poll_depth(report)

func supports_depth() -> bool:
	return available() and Methods.supports(host.platform, "set_photo_animation_depth") \
		and Methods.supports(host.platform, "photo_animation_depth_pixels")

## Moving images never enter the still-photo model, stereo generator or depth cache.
func set_depth(enabled: bool) -> bool:
	if enabled and (not supports_depth() or host.geometry != 0 or host.stereo_sbs or host._display_request <= 0 \
		or host._metadata.get("native_stereo", false) or host._metadata.get("magazine_unregistered", false)): return false
	if enabled != host.depth_requested: host._unlock_mode()
	host.auto_depth = enabled
	host.depth_requested = enabled
	host._depth_busy = false; host._depth_rebuild_seconds = 0.0
	host.depth_error = ""
	host._spatial_auto_due = false
	host.render_cache.cancel()
	host._cancel_depth_prefetch()
	host._discard_native_depth(request)
	host._display_depth_data.clear()
	host._display_result.erase("depth_data")
	_clear_depth()
	depth_mode = enabled
	if not enabled: _configure_depth(false)
	host._apply_geometry(); host.changed.emit()
	return true

func stop_depth() -> void:
	_configure_depth(false)
	if depth_mode: _clear_depth()
	depth_mode = false

func _configure_depth(enabled: bool) -> void:
	if enabled == _depth_running: return
	if request > 0 and Methods.supports(host.platform, "set_photo_animation_depth"):
		var accepted: bool = host.platform.set_photo_animation_depth(request, enabled)
		_depth_running = enabled and accepted
		if enabled and not accepted and host.depth_error.is_empty():
			host.depth_error = "3D unavailable"; host.changed.emit()
	if not enabled: _clear_depth()

func _clear_depth() -> void:
	_depth_token = 0; _depth_loop = -1
	if not depth_mode: return
	host.depth_enabled = false
	host._depth_texture = null; host._stereo_texture = null
	host._apply_geometry()

func _poll_depth(report: Dictionary) -> void:
	if not depth_mode or not host.depth_requested: return
	var loop_id := int(report.get("loop", -1))
	if loop_id != _depth_loop:
		_clear_depth()
		_depth_loop = loop_id
	var depth: Dictionary = report.get("depth", {})
	depth_stats = depth
	if depth.get("state") == "failed":
		if host.depth_error.is_empty():
			_clear_depth(); host.depth_error = "3D unavailable"; host.changed.emit()
		return
	var next := int(depth.get("token", 0))
	if depth.get("state") != "ready" or next <= 0 or next == _depth_token or int(depth.get("loop", -2)) != loop_id \
		or int(depth.get("frame_id", -1)) > int(report.get("frame_id", -2)): return
	var width := int(depth.get("width", 0)); var height := int(depth.get("height", 0))
	var rect: Variant = depth.get("rect")
	if width < 1 or height < 1 or width > 1024 or height > 1024 or not rect is Array or rect.size() != 4: return
	for value in rect:
		if not (value is int or value is float) or not is_finite(float(value)): return
	if rect[0] < 0 or rect[1] < 0 or rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > width or rect[1] + rect[3] > height: return
	var pixels: PackedByteArray = host.platform.photo_animation_depth_pixels(request, next)
	if pixels.size() != width * height * 4: return
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RF, pixels)
	if host._depth_texture == null or host._depth_texture.get_width() != width or host._depth_texture.get_height() != height:
		host._depth_texture = ImageTexture.create_from_image(image)
	else: host._depth_texture.update(image)
	host._depth_rect = Vector4(float(rect[0]) / width, float(rect[1]) / height, float(rect[2]) / width, float(rect[3]) / height)
	var was_enabled: bool = host.depth_enabled
	host.depth_enabled = true; host.depth_error = ""
	_depth_token = next
	host._apply_geometry()
	if not was_enabled: host.changed.emit()
