extends RefCounted
## Normal video playback on OpenXR compositor layers: the decoder writes into one Android-surface
## swapchain (native/xr-layer) and the runtime samples it once at display time, instead of the video
## being drawn into the eye buffers. This script registers itself with Godot's frame end as a
## composition layer provider and keeps the layer shapes in step with the video surface.
## Stereo uses two layers (left/right eye visibility) over the halves of the same swapchain.

const Geometry := preload("res://scripts/video_geometry.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const STRIDE := 20 # floats per layer, see VideoLayerNative.setLayers
const SURFACE_SIZE := 4096.0 # nominal swapchain units (MpvVideoBridge.LAYER_SURFACE_SIZE)
const ORDER := -8 # beneath the menu layers (-6..-3) and eye buffers; the video panel punches the hole
## Layer sources: the decoder's surface, or the RGBA picture swapchain (2D->3D pairs, photos).
const SURFACE := 0
const PICTURE := 1

class Provider extends OpenXRExtensionWrapper:
	## Read by Godot's frame end. Android runs Godot's frame and rendering on one thread.
	var count := 0
	var addresses := PackedInt64Array([0, 0])
	var debug_order := 0 # debug builds: a positive order draws the layers over the eye buffers
	func _get_composition_layer_count() -> int:
		return count
	func _get_composition_layer(index: int) -> int:
		return addresses[index] if index >= 0 and index < count else 0
	func _get_composition_layer_order(_index: int) -> int:
		return debug_order if debug_order != 0 else ORDER

var platform: Object
var _api: OpenXRAPIExtension
var _provider: Provider
var _session := 0
var _space := 0
var _types := {} # Geometry -> natively supported
var bound := false
## Bumped on every session bind: a new session destroyed the previous swapchain and its surface.
var generation := 0
## Availability of XR_FB_composition_layer_image_layout; uploaded GL pictures require it.
## Decoder Surface orientation is runtime-specific and independent of picture uploads.
var _flip := false
var _surface_flip := true
## Debug builds only: force the image-layout field for every layer (-1 omit, 0 no flip, 1 flip;
## -2 the runtime policy) to observe what a runtime actually does with it.
var debug_image_layout := -2
var _settings := false
const NORMAL_SUPER_SAMPLING := 1
const NORMAL_SHARPENING := 4
const QUALITY_SHARPENING := 8
var _sent := PackedFloat32Array()
var _sent_count := -1
## Video and photo share the one provider: whoever showed the layers last owns them, and only the
## owner's per-frame hide removes them.
var _owner: Object
## Size of the dynamic picture swapchain (2D->3D pairs): it is recreated, and its layers dropped, on change.
var picture_size := Vector2.ZERO

func _init(target_platform: Object) -> void:
	platform = target_platform
	# Godot accepts providers only before the session runs: register while the scene starts.
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if not xr or not xr.is_initialized() or not PlatformMethods.supports(platform, "bind_video_layer"):
		return
	_api = OpenXRAPIExtension.new()
	if _api.is_running():
		DiagnosticLog.record("video_layer_unavailable", {"reason": "session_already_running"})
		_api = null
		return
	_provider = Provider.new()
	_api.register_composition_layer_provider(_provider)
	# Godot's own layer nodes report whether the runtime enabled each layer extension.
	for probe in [["quad", OpenXRCompositionLayerQuad.new()], ["cylinder", OpenXRCompositionLayerCylinder.new()],
			["equirect", OpenXRCompositionLayerEquirect.new()]]:
		_types[probe[0]] = probe[1].is_natively_supported()
		probe[1].free()

## Normal playback can use layers on this runtime (session bound, swapchain functions present).
func available() -> bool:
	return bound and _flip

static func _enabled(singleton: String) -> bool:
	if not Engine.has_singleton(singleton):
		return false
	var wrapper := Engine.get_singleton(singleton)
	return wrapper.has_method("is_enabled") and bool(wrapper.is_enabled())

## Android Surface swapchains have different orientation conventions across runtimes/backends.
## GodotVR's MediaPlayer example documents PICO as upright on GLES and Oculus as bottom-up:
## https://github.com/GodotVR/godot-openxr-android-surface-javaclasswrapper-example/blob/main/main.gd
## Unknown runtimes retain the existing flip; this policy does not apply to our uploaded GL pictures.
static func _surface_vertical_flip(runtime_name: String, driver: String, pico_build: bool = false, system_name: String = "") -> bool:
	var runtime := runtime_name.strip_edges().to_lower()
	if runtime.begins_with("oculus") or runtime.begins_with("meta"):
		return driver == "opengl3" or driver == "opengl3_es"
	# The PICO export carries this feature. Do not lose its convention when the runtime name
	# has a vendor prefix, is empty, or changes between PICO system versions.
	if runtime.contains("pico") or runtime.begins_with("pxr") or pico_build or system_name.to_lower().contains("pico"):
		return driver == "vulkan"
	return true

func supports(geometry: int, curved: bool) -> bool:
	match geometry:
		Geometry.Geometry.FLAT:
			return _types.get("cylinder" if curved else "quad", false)
		Geometry.Geometry.HALF_EQUIRECT, Geometry.Geometry.EQUIRECT_360:
			return _types.get("equirect", false)
	return false

## Call every frame: binds the provider to the running session.
func update_session() -> void:
	if not _api or not _api.is_running():
		return
	var session := _api.get_session()
	var space := _api.get_play_space()
	if session == _session and space == _space:
		return
	if session != _session:
		generation += 1 # the native side drops the old session's swapchain on this bind
	_session = session
	_space = space
	_flip = _enabled("OpenXRFbCompositionLayerImageLayoutExtension")
	_settings = _enabled("OpenXRFbCompositionLayerSettingsExtension")
	bound = platform.bind_video_layer(_api.get_instance(), session, _api.get_instance_proc_addr("xrGetInstanceProcAddr"), space)
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var info := xr.get_system_info() if xr else {}
	var runtime_name := str(info.get("XRRuntimeName", ""))
	var system_name := str(info.get("OpenXRSystemName", ""))
	var pico_build := OS.has_feature("pico")
	var driver := RenderingServer.get_current_rendering_driver_name()
	_surface_flip = _surface_vertical_flip(runtime_name, driver, pico_build, system_name)
	_sent_count = -1
	DiagnosticLog.record("video_layer_bound", {"bound": bound, "types": _types, "vertical_flip": _flip,
		"surface_vertical_flip": _surface_flip, "runtime": runtime_name, "system": system_name,
		"pico_build": pico_build, "driver": driver, "settings": _settings})
	if PlatformMethods.supports(platform, "video_layer_runtime_extensions"):
		# Layer features the runtime offers (colour scale, blending, swapchain state...): one short line.
		var layer_extensions := Array(str(platform.video_layer_runtime_extensions()).split(" ", false)).filter(func(name: String):
			return name.contains("composition_layer") or name.contains("swapchain") or name.contains("passthrough") or name.contains("color") or name.contains("space_warp"))
		DiagnosticLog.record("xr_layer_extensions", {"names": " ".join(PackedStringArray(layer_extensions))})

## A picture swapchain was replaced: the native layers were dropped, send them again.
func invalidate() -> void:
	_sent_count = -1
	if _provider: _provider.count = 0

func hide(owner: Object = null) -> void:
	if owner != null and _owner != null and owner != _owner and _sent_count > 0:
		return
	_apply(0, PackedFloat32Array())

## surface: the video or photo node (media_surface); origin: the XR origin the play space belongs to.
## source PICTURE shows the picture swapchain of [size] pixels; stereo: 1 side by side whatever the
## surface says (a 2D->3D pair), 0 mono, -1 as the surface.
func show(surface: Node3D, origin: XROrigin3D, source: int = SURFACE, size := Vector2(SURFACE_SIZE, SURFACE_SIZE), stereo: int = -1,
		inset := Vector2.ZERO, pano := Vector4(0, 0, 1, 1)) -> bool:
	var values := layer_values(surface, origin, source, size, stereo, inset, pano)
	_owner = surface
	return _apply(values.size() / STRIDE, values)

## STRIDE floats per layer (one, or left and right). The video sharpness setting becomes the
## compositor's own sharpening (no shader on this path).
## inset: the fraction of a flat screen's width/height left to the eye buffers on each side (a photo's
## soft edge drawn there); the layer shows the inner part of the screen and of each eye's picture.
func layer_values(surface: Node3D, origin: Node3D, source_kind: int = SURFACE, image := Vector2(SURFACE_SIZE, SURFACE_SIZE),
		stereo: int = -1, inset := Vector2.ZERO, pano := Vector4(0, 0, 1, 1)) -> PackedFloat32Array:
	var sbs: bool = surface.stereo_sbs if stereo < 0 else stereo == 1
	var top_bottom: bool = surface.top_bottom and stereo < 0
	var viewing: int = int(surface.get("viewing_eye")) if surface.get("viewing_eye") != null else 0
	var filters := 0
	if _settings:
		filters = NORMAL_SUPER_SAMPLING
		if surface.sharpness >= 0.4: filters |= QUALITY_SHARPENING
		elif surface.sharpness > 0.0: filters |= NORMAL_SHARPENING
	var panel: MeshInstance3D = surface.panel
	var layers: Array = []
	var pose := origin.global_transform.affine_inverse() * panel.global_transform
	var scale := pose.basis.get_scale()
	pose.basis = pose.basis.orthonormalized()
	var shape := PackedFloat32Array()
	var type := 0
	if surface.geometry == Geometry.Geometry.FLAT:
		var size: Vector2 = surface._flat.size * Vector2(scale.x, scale.y) * (Vector2.ONE - 2.0 * inset)
		if surface.screen_curve <= 0.0:
			shape = PackedFloat32Array([size.x, size.y])
		else:
			type = 1
			var radius: float = surface._curve_radius() * scale.x
			# The mesh bends towards the viewer from the panel origin; the cylinder centre sits on that axis.
			pose.origin += pose.basis * Vector3(0, 0, radius)
			shape = PackedFloat32Array([radius, size.x / radius, size.x / size.y])
	else:
		type = 2
		var span := TAU if surface.geometry == Geometry.Geometry.EQUIRECT_360 else PI
		var upper := PI * 0.5
		var lower := -PI * 0.5
		if surface.geometry == Geometry.Geometry.EQUIRECT_360 and pano != Vector4(0, 0, 1, 1):
			# A partial panorama (photo sphere crop): the image spans only its window of the sphere,
			# centred where its middle column lies (u 0.5 looks along -Z; larger u turns right).
			span = TAU * pano.z
			upper = (0.5 - pano.y) * PI
			lower = (0.5 - (pano.y + pano.w)) * PI
			pose.basis = pose.basis * Basis(Vector3.UP, -(pano.x + pano.z * 0.5 - 0.5) * TAU)
		shape = PackedFloat32Array([surface.SPHERE_RADIUS * scale.x, span, upper, lower])
	var quat := pose.basis.get_rotation_quaternion()
	var head := PackedFloat32Array([0.0, 0.0, pose.origin.x, pose.origin.y, pose.origin.z, quat.x, quat.y, quat.z, quat.w])
	for eye in ([0] if not sbs else [1, 2]):
		var source := 0
		if sbs:
			var view: int = eye - 1 if viewing == 0 else viewing - 1
			source = 1 - view if surface.swap_eyes else view
		var rect := Rect2(Vector2.ZERO, image)
		if sbs:
			var offset: Vector2 = surface.stereo_offset_uv() if viewing == 0 and surface.has_method("stereo_offset_uv") else Vector2.ZERO
			var sign := -0.5 if eye == 1 else 0.5
			if top_bottom:
				rect = Rect2(0, source * image.y * 0.5, image.x, image.y * 0.5)
			else:
				rect = Rect2(source * image.x * 0.5, 0, image.x * 0.5, image.y)
			rect.position += sign * offset * rect.size
		if surface.geometry == Geometry.Geometry.FLAT and inset != Vector2.ZERO:
			rect = Rect2(rect.position + rect.size * inset, rect.size * (Vector2.ONE - 2.0 * inset))
		var values := head.duplicate()
		values[0] = type
		values[1] = eye
		values.append_array(PackedFloat32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]))
		values.append_array(shape)
		values.resize(STRIDE)
		# Our GL picture textures are top-first. An Android Surface has a producer/runtime
		# convention of its own; never apply the uploaded-picture rule to it unconditionally.
		# -1 omits an unsupported extension; 0 explicitly submits flags=0, as Godot's
		# native layer wrapper does. No flip and no image-layout structure are distinct states.
		values[17] = -1.0 if not _flip else (1.0 if source_kind == PICTURE or _surface_flip else 0.0)
		if debug_image_layout != -2: values[17] = debug_image_layout
		values[18] = filters
		values[19] = source_kind
		layers.append(values)
	var packed := PackedFloat32Array()
	for values in layers:
		packed.append_array(values)
	return packed

func _apply(count: int, values: PackedFloat32Array) -> bool:
	if not _provider:
		return false
	if count == _sent_count and values == _sent:
		return true
	if count > 0 and not platform.set_video_layers(count, values):
		DiagnosticLog.record("video_layer_rejected", {"count": count, "values": Array(values)})
		count = 0
		values = PackedFloat32Array()
		platform.set_video_layers(0, values)
	elif count == 0:
		platform.set_video_layers(0, values)
	_sent_count = count
	_sent = values
	var addresses := PackedInt64Array([0, 0])
	var debug_order := 0 # debug builds: a positive order draws the layers over the eye buffers
	for i in count:
		addresses[i] = platform.video_layer_address(i)
	_provider.addresses = addresses
	_provider.count = count
	return count > 0
