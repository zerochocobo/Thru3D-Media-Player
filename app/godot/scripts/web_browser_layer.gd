extends RefCounted
## Reuses VideoLayer's early provider registration and Android-surface lifetime protocol.
## Godot's built-in quad has no subImage rectangle; this provider crops the existing producer.
class Provider extends OpenXRExtensionWrapper:
	var entries := {}
	var frame: Array = []
	func _get_composition_layer_count() -> int:
		frame = entries.values()
		return frame.size()
	func _get_composition_layer(index: int) -> int: return frame[index][0]
	func _get_composition_layer_order(index: int) -> int: return frame[index][1]

static var api: OpenXRAPIExtension
static var provider: Provider
static var bridge: JavaClass
var id := 0
var surface: JavaObject
var session := 0
var pixels := Vector2i.ZERO
var flip_mode := -1.0
var sort_order := -7
var _sent := PackedFloat32Array()
var _space := 0
var _address := 0
var stereo := false
var alpha := false
var effects: JavaClass
var source_pixels := Vector2i.ZERO
var source_crop := Rect2(0, 0, 1, 1)
var _effect_sent := ""
var _effect_poll := 0
var _effect_error := ""
var effect_state := "preparing"

static func initialize() -> void:
	if provider or OS.get_name() != "Android": return
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if not xr or not xr.is_initialized(): return
	api = OpenXRAPIExtension.new()
	if api.is_running(): api = null; return
	bridge = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserLayerNative")
	if not bridge or JavaClassWrapper.get_exception(): api = null; return
	provider = Provider.new()
	api.register_composition_layer_provider(provider)

func create(window: int, size: Vector2i, convert: bool = false, crop: Rect2 = Rect2(0, 0, 1, 1), edge_limit: int = 1536, matte: bool = false) -> bool:
	if not api or not provider or not api.is_running(): return false
	id = window; pixels = size; source_pixels = size; session = api.get_session()
	stereo = convert; source_crop = crop
	alpha = matte
	if stereo:
		var selected := Vector2(size) * crop.size
		var limit := clampi(edge_limit, 512, 1536)
		var scale := minf(1.0, minf(float(limit) / selected.x, float(limit) / selected.y))
		pixels = Vector2i(maxi(16, roundi(selected.x * scale)) * 2, maxi(16, roundi(selected.y * scale)))
	surface = bridge.create(id, api.get_instance(), session, api.get_instance_proc_addr("xrGetInstanceProcAddr"), pixels.x, pixels.y)
	if JavaClassWrapper.get_exception() or not surface: return false
	if stereo:
		effects = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserDepthBridge")
		if not effects or JavaClassWrapper.get_exception(): destroy(); return false
		var started: bool = effects.start(id, surface, size.x, size.y, pixels.x / 2, pixels.y,
			PackedFloat32Array([crop.position.x, crop.position.y, crop.size.x, crop.size.y]), matte)
		if JavaClassWrapper.get_exception() or not started: destroy(); return false
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var flip: bool = preload("res://scripts/video_layer.gd")._surface_vertical_flip(str(xr.get_system_info().get("XRRuntimeName", "")), RenderingServer.get_current_rendering_driver_name(), OS.has_feature("pico"))
	if preload("res://scripts/video_layer.gd")._enabled("OpenXRFbCompositionLayerImageLayoutExtension"):
		flip_mode = 1.0 if flip else 0.0
	return true

func hide() -> void:
	if provider:
		provider.entries.erase(id); provider.entries.erase(-id)

func resize_decoder_producer(size: Vector2i) -> bool:
	if id not in [6, 7]: return false
	if size == pixels: return true
	var changed: bool = bridge.producerSize(id, size.x, size.y)
	if JavaClassWrapper.get_exception() or not changed: return false
	pixels = size
	return true

func destroy(asynchronous: bool = false) -> bool:
	if stereo and effects:
		if asynchronous:
			if int(effects.stopState(id)) != 1:
				effects.requestStop(id); JavaClassWrapper.get_exception(); return false
		var stopped: bool = true if asynchronous else effects.stop(id)
		if JavaClassWrapper.get_exception() or not stopped: return false
	hide()
	if surface and api and api.get_session() == session:
		bridge.destroy(id)
		JavaClassWrapper.get_exception()
	surface = null
	return true

func input_surface() -> JavaObject:
	if not stereo: return surface
	var input: JavaObject = effects.surface(id)
	JavaClassWrapper.get_exception()
	return input

func configure_effect(strength: float, position: float, identity: String, fill: bool = false, depth: bool = true) -> String:
	if not stereo or not effects: return ""
	var signature := str([strength, position, identity, fill, depth])
	if signature != _effect_sent:
		effects.configure(id, strength, position, identity, fill, depth)
		JavaClassWrapper.get_exception()
		_effect_sent = signature
	if Time.get_ticks_msec() < _effect_poll: return _effect_error
	_effect_poll = Time.get_ticks_msec() + 250
	var raw := str(effects.status(id))
	JavaClassWrapper.get_exception()
	var info: Variant = JSON.parse_string(raw)
	_effect_error = str(info.get("error", "")) if info is Dictionary else ""
	effect_state = str(info.get("state", "preparing")) if info is Dictionary else "preparing"
	return _effect_error

func present(pose: Transform3D, size: Vector2, crop: Rect2) -> bool:
	if not surface or not api or not api.is_running() or api.get_session() != session:
		hide(); return false
	# Match OpenXRCompositionLayer's world -> XROrigin -> reference-frame transform.
	var local := XRServer.get_reference_frame().affine_inverse() * XRServer.world_origin.affine_inverse() * pose
	var q := local.basis.orthonormalized().get_rotation_quaternion()
	var begin := Vector2i((crop.position * Vector2(pixels)).round())
	var end := Vector2i((crop.end * Vector2(pixels)).round())
	if stereo: begin = Vector2i.ZERO; end = pixels
	var values := PackedFloat32Array([local.origin.x, local.origin.y, local.origin.z,
		q.x, q.y, q.z, q.w, size.x, size.y, begin.x, begin.y, end.x - begin.x, end.y - begin.y, flip_mode])
	var space := api.get_play_space()
	if values != _sent or space != _space or _address == 0:
		_address = bridge.updateEyeAlpha(id, space, values, 1, alpha) if stereo else bridge.update(id, space, values)
		if JavaClassWrapper.get_exception() or _address == 0: hide(); return false
		_sent = values; _space = space
	provider.entries[id] = [_address, sort_order]
	if stereo:
		var right: int = bridge.updateEyeAlpha(id, space, values, 2, alpha)
		if JavaClassWrapper.get_exception() or right == 0: hide(); return false
		provider.entries[-id] = [right, sort_order]
	return true
