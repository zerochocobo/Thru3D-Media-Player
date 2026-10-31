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

func create(window: int, size: Vector2i) -> bool:
	if not api or not provider or not api.is_running(): return false
	id = window; pixels = size; session = api.get_session()
	surface = bridge.create(id, api.get_instance(), session, api.get_instance_proc_addr("xrGetInstanceProcAddr"), size.x, size.y)
	if JavaClassWrapper.get_exception() or not surface: return false
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var flip: bool = preload("res://scripts/video_layer.gd")._surface_vertical_flip(str(xr.get_system_info().get("XRRuntimeName", "")), RenderingServer.get_current_rendering_driver_name(), OS.has_feature("pico"))
	if preload("res://scripts/video_layer.gd")._enabled("OpenXRFbCompositionLayerImageLayoutExtension"):
		flip_mode = 1.0 if flip else 0.0
	return true

func hide() -> void:
	if provider: provider.entries.erase(id)

func destroy() -> void:
	hide()
	if surface and api and api.get_session() == session:
		bridge.destroy(id)
		JavaClassWrapper.get_exception()
	surface = null

func present(pose: Transform3D, size: Vector2, crop: Rect2) -> bool:
	if not surface or not api or not api.is_running() or api.get_session() != session:
		hide(); return false
	# Match OpenXRCompositionLayer's world -> XROrigin -> reference-frame transform.
	var local := XRServer.get_reference_frame().affine_inverse() * XRServer.world_origin.affine_inverse() * pose
	var q := local.basis.orthonormalized().get_rotation_quaternion()
	var begin := Vector2i((crop.position * Vector2(pixels)).round())
	var end := Vector2i((crop.end * Vector2(pixels)).round())
	var values := PackedFloat32Array([local.origin.x, local.origin.y, local.origin.z,
		q.x, q.y, q.z, q.w, size.x, size.y, begin.x, begin.y, end.x - begin.x, end.y - begin.y, flip_mode])
	var space := api.get_play_space()
	if values != _sent or space != _space or _address == 0:
		_address = bridge.update(id, space, values)
		if JavaClassWrapper.get_exception() or _address == 0: hide(); return false
		_sent = values; _space = space
	provider.entries[id] = [_address, sort_order]
	return true
