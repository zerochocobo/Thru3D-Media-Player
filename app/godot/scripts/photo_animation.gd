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

func _init(owner: Node3D) -> void:
	host = owner

func available() -> bool:
	return bool(host._metadata.get("animated", false)) and not host.archive_mode and host.gallery.mode != 4 \
		and Methods.supports(host.platform, "get_photo_animation_frame")

func activate() -> void:
	request = host._display_request
	token = 0; paused = false; ended = false; failed = false

func close() -> void:
	if request > 0 and Methods.supports(host.platform, "pause_photo_animation"):
		host.platform.pause_photo_animation(request, true)
	request = 0; token = 0

func suspend() -> void:
	if request > 0 and Methods.supports(host.platform, "pause_photo_animation"):
		host.platform.pause_photo_animation(request, true)

func freeze() -> void:
	if not available(): return
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
		host.platform.restart_photo_animation(request)
		token = 0; ended = false; failed = false; paused = false
	else:
		paused = not paused
	if not paused:
		if host.portrait_requested: host.set_portrait(false)
		if host.spatial_requested: host.set_spatial(false)
		if host.depth_requested: host.set_depth(false)
		host._discard_native_depth(request)
		host._display_depth_data.clear()
		host._depth_texture = null; host._stereo_texture = null
	host.platform.pause_photo_animation(request, paused)
	host.changed.emit()

func tick() -> void:
	if request != host._display_request: return
	if not available() or host._texture == null:
		suspend(); return
	var focused: bool = app_focused.call() if app_focused.is_valid() else host.get_tree().root.has_focus()
	var suspended: bool = host.loading or host.gallery.overview() or not host.is_visible_in_tree() \
		or host.depth_requested or host.portrait_requested or host.spatial_requested \
		or not focused
	host.platform.pause_photo_animation(request, paused or suspended)
	var report: Variant = JSON.parse_string(host.platform.get_photo_animation_frame(request))
	if report is not Dictionary: return
	var next_token := int(report.get("token", 0))
	var finished := bool(report.get("ended", false))
	var error := bool(report.get("failed", false))
	if finished != ended or error != failed:
		ended = finished; failed = error; host.changed.emit()
	if next_token <= 0 or next_token == token or suspended: return
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
