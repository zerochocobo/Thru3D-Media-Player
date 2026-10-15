extends RefCounted
## Normal video playback on OpenXR compositor layers: the decoder writes into one Android-surface
## swapchain (native/xr-layer) and the runtime samples it once at display time, instead of the video
## being drawn into the eye buffers. This script registers itself with Godot's frame end as a
## composition layer provider and keeps the layer shapes in step with the video surface.
## Stereo uses two layers (left/right eye visibility) over the halves of the same swapchain.

const Geometry := preload("res://scripts/video_geometry.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const STRIDE := 28 # floats per layer, see VideoLayerNative.setLayers
const MAX_LAYERS := 6 # native/xr-layer kMaxLayers
const SURFACE_SIZE := 4096.0 # nominal swapchain units (MpvVideoBridge.LAYER_SURFACE_SIZE)
const ORDER := -8 # beneath the menu layers (-6..-3) and eye buffers; the video panel punches the hole
## Layer sources: the decoder's surface, or the RGBA picture swapchain (2D->3D pairs, photos).
const SURFACE := 0
const PICTURE := 1
## Picture swapchain slots (native kSlots): photos and 2D->3D pairs, subtitles, the photo magnifier.
const PICTURE_SLOT := 0
const SUBTITLE_SLOT := 1
const MAGNIFIER_SLOT := 2
## Layer blending (values[27]): opaque, or the texture's premultiplied alpha.
const OPAQUE := 0
const SOURCE_ALPHA := 1
## Overlays (subtitles, magnifier) above the video, still beneath the menu layers and eye buffers.
const OVERLAY_ORDER := -7

class Provider extends OpenXRExtensionWrapper:
	## Read by Godot's frame end. Android runs Godot's frame and rendering on one thread.
	var count := 0
	var addresses := PackedInt64Array()
	var orders := PackedInt32Array()
	var debug_order := 0 # debug builds: a positive order draws the layers over the eye buffers
	func _get_composition_layer_count() -> int:
		return count
	func _get_composition_layer(index: int) -> int:
		return addresses[index] if index >= 0 and index < count else 0
	func _get_composition_layer_order(index: int) -> int:
		if debug_order != 0: return debug_order
		return orders[index] if index >= 0 and index < orders.size() else ORDER

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
## XR_KHR_composition_layer_color_scale_bias, requested by the player plugin's GDExtension: the colour
## grade stays on the layer as a per-channel scale and bias instead of sending playback to the eye buffers.
var color_scale_bias := false
const NORMAL_SUPER_SAMPLING := 1
const QUALITY_SUPER_SAMPLING := 2
const NORMAL_SHARPENING := 4
const QUALITY_SHARPENING := 8
## Compositor supersampling of video and photo layers: 0 off, 1 normal, 2 quality.
var supersampling := 1
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

## The layer can show [grade] (a ColorGrade): ungraded, or graded linearly with the extension enabled.
func grades(grade: RefCounted) -> bool:
	if grade == null: return true
	var terms: Dictionary = grade.linear_terms()
	return not terms.is_empty() and (color_scale_bias or (terms.scale == Vector3.ONE and terms.bias == Vector3.ZERO))

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
	color_scale_bias = PlatformMethods.supports(platform, "video_layer_color_scale_bias") and bool(platform.video_layer_color_scale_bias())
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
		"pico_build": pico_build, "driver": driver, "settings": _settings, "color_scale_bias": color_scale_bias})
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
## surface says (a 2D->3D pair), 0 mono, -1 as the surface. blend: OPAQUE, or SOURCE_ALPHA for a
## cut-out picture. extras: overlay layers drawn above it ({"values": STRIDE floats, "order": int}).
func show(surface: Node3D, origin: XROrigin3D, source: int = SURFACE, size := Vector2(SURFACE_SIZE, SURFACE_SIZE), stereo: int = -1,
		inset := Vector2.ZERO, pano := Vector4(0, 0, 1, 1), blend := OPAQUE, extras: Array = []) -> bool:
	var values := layer_values(surface, origin, source, size, stereo, inset, pano, blend)
	var orders := PackedInt32Array()
	for i in values.size() / STRIDE: orders.append(ORDER)
	for extra in extras:
		if values.size() / STRIDE >= MAX_LAYERS: break
		values.append_array(extra.values)
		orders.append(int(extra.order))
	_owner = surface
	return _apply(values.size() / STRIDE, values, orders)

## One quad over a picture slot, posed in the origin's space ([pose] places its centre), [size] metres,
## showing [rect] (pixels) of the slot's [image]: subtitles, the magnifier. eye 0 both, 1 left, 2 right.
func quad_values(origin: Node3D, pose: Transform3D, size: Vector2, slot: int, image: Vector2,
		rect := Rect2(), blend := SOURCE_ALPHA, eye := 0) -> PackedFloat32Array:
	var local := origin.global_transform.affine_inverse() * pose
	local.basis = local.basis.orthonormalized()
	var quat := local.basis.get_rotation_quaternion()
	if rect.size == Vector2.ZERO: rect = Rect2(Vector2.ZERO, image)
	var values := PackedFloat32Array([0.0, float(eye), local.origin.x, local.origin.y, local.origin.z, quat.x, quat.y, quat.z, quat.w,
		rect.position.x, rect.position.y, rect.size.x, rect.size.y, size.x, size.y])
	values.resize(STRIDE)
	values[17] = 1.0 if _flip else -1.0 # GL pictures are top-first
	values[18] = NORMAL_SUPER_SAMPLING if _settings else 0
	values[19] = PICTURE
	values[20] = 1.0; values[21] = 1.0; values[22] = 1.0
	values[26] = slot
	values[27] = blend
	return values

## A section of a cylinder over a picture slot: [pose] is the cylinder's centre with the section's
## middle along its -Z; [angle] radians wide, [aspect] its arc length over its height.
func cylinder_values(origin: Node3D, pose: Transform3D, radius: float, angle: float, aspect: float, slot: int,
		image: Vector2, rect := Rect2(), blend := SOURCE_ALPHA) -> PackedFloat32Array:
	var values := quad_values(origin, pose, Vector2.ONE, slot, image, rect, blend)
	values[0] = 1.0
	values[13] = radius; values[14] = angle; values[15] = aspect
	return values

## STRIDE floats per layer (one, or left and right). The supersampling and sharpness settings become
## the compositor's own filters (no shader on this path).
## inset: the fraction of a flat screen's width/height left to the eye buffers on each side (a photo's
## soft edge drawn there); the layer shows the inner part of the screen and of each eye's picture.
func layer_values(surface: Node3D, origin: Node3D, source_kind: int = SURFACE, image := Vector2(SURFACE_SIZE, SURFACE_SIZE),
		stereo: int = -1, inset := Vector2.ZERO, pano := Vector4(0, 0, 1, 1), blend := OPAQUE) -> PackedFloat32Array:
	var sbs: bool = surface.stereo_sbs if stereo < 0 else stereo == 1
	var top_bottom: bool = surface.top_bottom and stereo < 0
	var viewing: int = int(surface.get("viewing_eye")) if surface.get("viewing_eye") != null else 0
	var filters := 0
	if _settings:
		filters = [0, NORMAL_SUPER_SAMPLING, QUALITY_SUPER_SAMPLING][clampi(supersampling, 0, 2)]
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
			# A rotated source on the decoder surface keeps its coded orientation: turn the quad about its
			# normal (clockwise as the rotation metadata says) with its sides swapped for 90/270.
			var turn: int = int(surface.get("layer_rotation")) if source_kind == SURFACE and surface.get("layer_rotation") != null else 0
			if turn != 0:
				if turn % 180 != 0: shape = PackedFloat32Array([size.y, size.x])
				pose.basis = pose.basis * Basis(Vector3.BACK, -deg_to_rad(turn))
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
	for eye in ([0] if not sbs else [1, 2]):
		var source := 0
		if sbs:
			var view: int = eye - 1 if viewing == 0 else viewing - 1
			source = 1 - view if surface.swap_eyes else view
		var rect := Rect2(Vector2.ZERO, image)
		var shift := Vector2.ZERO
		if sbs:
			var offset: Vector2 = surface.stereo_offset_uv() if viewing == 0 and surface.has_method("stereo_offset_uv") else Vector2.ZERO
			var sign := -0.5 if eye == 1 else 0.5
			shift = sign * offset
			if top_bottom:
				rect = Rect2(0, source * image.y * 0.5, image.x, image.y * 0.5)
			else:
				rect = Rect2(source * image.x * 0.5, 0, image.x * 0.5, image.y)
		if surface.geometry == Geometry.Geometry.FLAT and inset != Vector2.ZERO:
			rect = Rect2(rect.position + rect.size * inset, rect.size * (Vector2.ONE - 2.0 * inset))
		var pixel_start := Vector2(roundf(rect.position.x), roundf(rect.position.y))
		rect = Rect2(pixel_start, Vector2(roundf(rect.end.x), roundf(rect.end.y)) - pixel_start)
		# UV shifts cannot move imageRect outside its eye or the swapchain. Crop valid
		# pixels and move/shrink their destination geometry instead. 360 longitude wraps
		# by rotating the full eye image, without dropping the seam or adding a layer.
		var aligned := _aligned_layer(rect, shift, type, shape, pose, surface.geometry == Geometry.Geometry.EQUIRECT_360)
		rect = aligned.rect
		var eye_pose: Transform3D = aligned.pose
		var quat := eye_pose.basis.get_rotation_quaternion()
		var values := PackedFloat32Array([float(type), float(eye), eye_pose.origin.x, eye_pose.origin.y, eye_pose.origin.z, quat.x, quat.y, quat.z, quat.w])
		values.append_array(PackedFloat32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]))
		values.append_array(aligned.shape)
		values.resize(STRIDE)
		# Our GL picture textures are top-first. An Android Surface has a producer/runtime
		# convention of its own; never apply the uploaded-picture rule to it unconditionally.
		# -1 omits an unsupported extension; 0 explicitly submits flags=0, as Godot's
		# native layer wrapper does. No flip and no image-layout structure are distinct states.
		values[17] = -1.0 if not _flip else (1.0 if source_kind == PICTURE or _surface_flip else 0.0)
		if debug_image_layout != -2: values[17] = debug_image_layout
		values[18] = filters
		values[19] = source_kind
		var color := _color_terms(surface)
		values[20] = color.scale.x; values[21] = color.scale.y; values[22] = color.scale.z
		values[23] = color.bias.x; values[24] = color.bias.y; values[25] = color.bias.z
		values[26] = PICTURE_SLOT
		values[27] = blend
		layers.append(values)
	var packed := PackedFloat32Array()
	for values in layers:
		packed.append_array(values)
	return packed

## The surface's colour grade as the layer's linear-light scale/bias; identity when absent or not representable.
func _color_terms(surface: Node3D) -> Dictionary:
	var grade: RefCounted = surface.get("color_grade") as RefCounted
	var terms: Dictionary = grade.layer_terms() if grade and color_scale_bias else {}
	return terms if not terms.is_empty() else {"scale": Vector3.ONE, "bias": Vector3.ZERO}

static func _aligned_layer(eye_rect: Rect2, shift: Vector2, type: int, shape: PackedFloat32Array,
		pose: Transform3D, wrap: bool) -> Dictionary:
	if shift == Vector2.ZERO:
		return {"rect": eye_rect, "shape": shape, "pose": pose}
	var crop_shift := Vector2(0.0 if wrap else shift.x, shift.y)
	var destination := Rect2(Vector2.ZERO, Vector2.ONE).intersection(Rect2(-crop_shift, Vector2.ONE))
	var start := eye_rect.position + (destination.position + crop_shift) * eye_rect.size
	var end := eye_rect.position + (destination.end + crop_shift) * eye_rect.size
	# Integer pixel endpoints keep independent rounding from overflowing a swapchain,
	# while the destination follows the actual quantized source window (no rescaling drift).
	start = Vector2(ceilf(start.x), ceilf(start.y))
	end = Vector2(floorf(end.x), floorf(end.y))
	var rect := Rect2(start, end - start)
	destination = Rect2((start - eye_rect.position) / eye_rect.size - crop_shift, rect.size / eye_rect.size)
	var centre := destination.get_center() - Vector2(0.5, 0.5)
	var mapped := shape.duplicate()
	if type == 0:
		pose.origin += pose.basis * Vector3(centre.x * shape[0], -centre.y * shape[1], 0)
		mapped[0] *= destination.size.x
		mapped[1] *= destination.size.y
	elif type == 1:
		var height := shape[0] * shape[1] / shape[2]
		pose.origin += pose.basis * Vector3(0, -centre.y * height, 0)
		pose.basis *= Basis(Vector3.UP, -centre.x * shape[1])
		mapped[1] *= destination.size.x
		mapped[2] *= destination.size.x / destination.size.y
	else:
		pose.basis *= Basis(Vector3.UP, shift.x * shape[1] if wrap else -centre.x * shape[1])
		mapped[1] *= destination.size.x
		mapped[2] = shape[2] - destination.position.y * (shape[2] - shape[3])
		mapped[3] = shape[2] - destination.end.y * (shape[2] - shape[3])
	return {"rect": rect, "shape": mapped, "pose": pose}

func _apply(count: int, values: PackedFloat32Array, orders := PackedInt32Array()) -> bool:
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
	var addresses := PackedInt64Array()
	for i in count:
		addresses.append(platform.video_layer_address(i))
	_provider.addresses = addresses
	_provider.orders = orders
	_provider.count = count
	return count > 0
