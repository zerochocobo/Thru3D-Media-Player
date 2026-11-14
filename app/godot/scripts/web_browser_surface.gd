extends Node3D
## Android Surface producer and OpenXR consumer have independent threads. Keep this root outside
## the menu's visibility tree; a menu refresh/hide must not destroy a Surface still used by Gecko.
const LOGICAL := Vector2i(1440, 900)
const CSS_UNITS := 3
# Keep a 720 CSS-pixel short edge in either orientation. A fixed 1280-pixel
# minimum width plus a fixed area budget would prohibit portrait viewports.
const MIN_COLUMNS := 240
const MIN_ROWS := 240
const MIN_RATIO := float(MIN_COLUMNS * CSS_UNITS * MIN_COLUMNS * CSS_UNITS) / (LOGICAL.x * LOGICAL.y)
const MAX_RATIO := float(LOGICAL.x * LOGICAL.y) / (MIN_ROWS * CSS_UNITS * MIN_ROWS * CSS_UNITS)
const PIXEL_UNITS := 5
const LOW_END_PIXEL_UNITS := 4
const PIXELS := Vector2i(2400, 1500)
const LOW_END_PIXELS := Vector2i(1920, 1200)
const HOLE := preload("res://shaders/web_browser_hole.gdshader")
const Layer := preload("res://scripts/web_browser_layer.gd")
var target: WeakRef
var platform: Object
var layer: RefCounted
var hole: MeshInstance3D
var bridge: Object
var xr: OpenXRInterface
var window_id := 1
var generation := 0
var attached := false
var ending := false
var shown := false
var rect := Rect2(-0.59, -0.48, 1.44, 0.90)
var status := ""
var retry_at := 0
var state_poll := 0
var state := {}
var _state_raw := ""
var surface_retries := 0
var pixels := PIXELS
var resize_at := 0
var requested_pixels := PIXELS
var preparation_api: Object

func _release_for_transition() -> bool:
	if not attached: return true
	var complete := int(bridge.windowReleaseState(window_id,generation)) == 1
	if OS.get_name()=="Android" and JavaClassWrapper.get_exception(): status="surface_release_failed";return false
	if not complete:
		bridge.requestWindowRelease(window_id,generation)
		if OS.get_name()=="Android": JavaClassWrapper.get_exception()
	return complete

static func logical_for(size: Vector2) -> Vector2i:
	var ratio := clampf(size.x / size.y, MIN_RATIO, MAX_RATIO)
	var width := sqrt(float(LOGICAL.x * LOGICAL.y) * ratio)
	var height := width / ratio
	# One CSS geometry for both tiers, with a shared limit matching the smaller
	# device's existing 2560-pixel edge budget. Quantize before applying density so
	# both Surfaces represent exactly the same CSS width/height at every breakpoint.
	var factor := minf(1.0, 1920.0 / maxf(width, height))
	# Stabilize exact multiples (including 1440x900) carried through Vector2 floats.
	var columns := maxi(MIN_COLUMNS, floori(width * factor / CSS_UNITS + 0.0001))
	# Derive height from the quantized width: independently rounding both down
	# magnifies the aspect error on very wide windows. Still respect the area cap.
	var rows := maxi(MIN_ROWS, mini(roundi(columns / ratio), floori(float(LOGICAL.x * LOGICAL.y) / (columns * CSS_UNITS * CSS_UNITS))))
	return Vector2i(columns, rows) * CSS_UNITS

static func pixels_for(size: Vector2, low_end: bool) -> Vector2i:
	return pixels_at(size, LOW_END_PIXEL_UNITS if low_end else PIXEL_UNITS)

## Surface pixels for Gecko's process-wide raster tier (browser clarity: 3, 4 or 5 units).
static func pixels_at(size: Vector2, units: int) -> Vector2i:
	return logical_for(size) / CSS_UNITS * units

func configure(menu: Node3D, backend: Object, id: int = 1) -> void:
	window_id = id
	target = weakref(menu); platform = backend
	pixels = LOGICAL / CSS_UNITS * menu.browser.pixel_units
	requested_pixels = pixels
	set_meta("menu_eye_buffer", true)

func _ready() -> void:
	if OS.get_name() != "Android": status = "headset_only"; set_process(false); return
	xr = XRServer.find_interface("OpenXR") as OpenXRInterface
	if not xr or not xr.is_initialized(): status = "xr_unavailable"; set_process(false); return
	bridge = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserSurfaceBridge")
	if not bridge or JavaClassWrapper.get_exception(): status = "bridge_unavailable"; set_process(false); return
	xr.session_stopping.connect(_session_stop)
	xr.session_loss_pending.connect(_session_stop)
	xr.instance_exiting.connect(_session_stop)
	xr.session_begun.connect(_session_start)
	# Allocate the producer in _process once the session is running. Opening while
	# XR is resuming must not permanently disable this window's processing.
	hole = MeshInstance3D.new()
	hole.mesh = QuadMesh.new()
	var material := ShaderMaterial.new(); material.shader = HOLE; material.render_priority = 25
	hole.material_override = material; hole.visible = false
	hole.set_meta("menu_eye_buffer", true); add_child(hole)
	var menu: Node = target.get_ref()
	if menu: menu.set_meta("menu_browser_layer", true)

func _create_layer() -> void:
	layer = Layer.new()
	var menu: Node = target.get_ref() if target else null
	var convert: bool = menu != null and (menu.depth.enabled or menu.depth.matte) and not menu.selecting
	var matte: bool = menu != null and menu.depth.matte and not menu.selecting
	var crop: Rect2 = menu.focus_crop() if menu else Rect2(0, 0, 1, 1)
	if not layer.create(window_id, pixels, convert, crop, 1024 if menu and menu.browser.low_end else 1536, matte):
		if convert and menu:
			menu.depth.enabled = false; menu.depth.matte = false; menu.depth.error = "3D unavailable"; menu.refresh(); menu.browser.effects_changed.emit()
		status = "surface_unavailable"; layer = null; return
	if menu: menu.set_meta("menu_browser_layer", true)

func present(value: bool, bounds: Rect2) -> void:
	shown = value; rect = bounds

func _session_start() -> void:
	if layer and layer.session != Layer.api.get_session():
		if not layer.destroy(): status = "surface_stop_timeout"; return
		layer = null
	attached = false; ending = false; retry_at = 0; state = {}; _state_raw = ""; surface_retries = 0

func _session_stop() -> void:
	if layer: layer.hide()
	if not bridge or generation <= 0:
		if layer:
			if not layer.destroy(): status = "surface_stop_timeout"; return
			layer = null
		ending = true
		return
	var stopped: bool = bridge.detachWindowBeforeSessionStop(window_id, generation)
	var failed := JavaClassWrapper.get_exception() != null
	if not stopped or failed: status = "surface_stop_timeout"
	else:
		attached = false
		if layer:
			if not layer.destroy(): status = "surface_stop_timeout"; return
			layer = null
	ending = true
	if hole: hole.visible = false

func _process(_delta: float) -> void:
	var menu: Node3D = target.get_ref() if target else null
	if not menu:
		_session_stop(); queue_free(); return
	if not menu.browser.active() or not menu.visible:
		_release_idle_surface()
		return
	if ending: return
	var conversion: bool = (menu.depth.enabled or menu.depth.matte) and not menu.selecting
	var matte: bool = menu.depth.matte and not menu.selecting
	var preparation_pending := false
	if conversion and (not layer or not layer.stereo or layer.alpha != matte):
		if not preparation_api: preparation_api = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserDepthBridge")
		var prepared: Variant = JSON.parse_string(str(preparation_api.prepare(window_id,menu.depth.enabled,matte))) if preparation_api else null
		if OS.get_name()=="Android": JavaClassWrapper.get_exception()
		preparation_pending = not prepared is Dictionary or prepared.get("state") != "ready"
		if prepared is Dictionary and prepared.get("state") == "failed":
			menu.depth.enabled=false;menu.depth.matte=false;menu.depth.state="failed";menu.depth.error="3D unavailable";menu.refresh();menu.browser.effects_changed.emit()
		elif preparation_pending: menu.depth.state="preparing"
	elif not conversion and preparation_api:
		preparation_api.clearPreparation(window_id)
		if OS.get_name()=="Android": JavaClassWrapper.get_exception()
	if layer and not preparation_pending and (layer.stereo != conversion or layer.alpha != matte or (conversion and layer.source_crop != menu.focus_crop())):
		if attached:
			if not _release_for_transition(): status="surface_switch_pending";return
		if not layer.destroy(true): status = "surface_switch_pending"; return
		layer = null; attached = false; state = {}; _state_raw = ""; retry_at = 0
	# Recreate only after a completed drag, with Gecko's release acknowledgement.
	# Keep the pixel budget bounded even for an extremely wide or tall window.
	var desired := pixels_at(menu.render_size(), menu.browser.pixel_units)
	if desired != requested_pixels:
		requested_pixels = desired; resize_at = Time.get_ticks_msec() + 250
	if pixels != requested_pixels and menu.drag.is_empty() and Time.get_ticks_msec() >= resize_at:
		if attached:
			if not _release_for_transition(): status="surface_resize_pending";return
		if layer:
			if not layer.destroy(true): status="surface_resize_pending";return
			layer = null
		attached = false; pixels = requested_pixels; state = {}; _state_raw = ""; retry_at = 0
		if hole: hole.visible = false
	if not layer:
		if preparation_pending: return
		if Time.get_ticks_msec() < retry_at: return
		_create_layer(); retry_at = Time.get_ticks_msec() + 500
		if not layer: return
	if layer.stereo:
		var current: Dictionary = menu.browser.window_state(window_id)
		var issue: String = layer.configure_effect(menu.depth.strength, menu.depth.position,
			str(current.get("tab_id", 0)) + ":" + str(current.get("navigation", 0)), menu.depth.render_mode == "fill", menu.depth.enabled)
		if menu.depth.state != layer.effect_state:
			menu.depth.state = layer.effect_state; menu.refresh()
		if not issue.is_empty():
			status = issue; menu.depth.enabled = false; menu.depth.matte = false; menu.depth.error = "3D unavailable"; menu.refresh(); menu.browser.effects_changed.emit(); layer.hide(); hole.visible = false; return
	var layout: Dictionary = menu.page_layout()
	global_transform = layout.pose
	var distance: float = global_position.distance_to(menu.head().origin)
	var nearer := 0
	for peer in menu.browser.windows.values():
		if peer != menu and peer.visible and peer.page_layout().pose.origin.distance_to(menu.head().origin) < distance: nearer += 1
	layer.sort_order = -7 - nearer
	var visible_now := shown and menu.is_visible_in_tree()
	if not visible_now:
		layer.hide()
		hole.visible = false
		return
	if ending: return
	if Time.get_ticks_msec() >= state_poll:
		state_poll = Time.get_ticks_msec() + 250
		var raw := str(platform.web_browser_status())
		var parsed: Variant = null if raw == _state_raw else JSON.parse_string(raw)
		_state_raw = raw
		if parsed is Dictionary:
			for item in parsed.get("windows", []):
				if int(item.id) == window_id: state = item
	if state.has("tab_id") and int(state.tab_id) == 0:
		_release_idle_surface(); return
	if int(state.get("generation", 0)) == generation and state.get("needs_surface", false):
		hole.visible = false; layer.hide()
		if surface_retries >= 3: status = "surface_recreate_failed"; return
		if Time.get_ticks_msec() < retry_at: return
		var stopped: bool = bridge.detachWindowBeforeSessionStop(window_id, generation)
		if JavaClassWrapper.get_exception() or not stopped: status = "surface_stop_timeout"; retry_at = Time.get_ticks_msec() + 2000; return
		# Gecko has acknowledged release; only now destroy the OpenXR producer.
		if not layer.destroy(): status = "surface_stop_timeout"; return
		layer = null; attached = false; state = {}; _state_raw = ""; surface_retries += 1
		_create_layer(); retry_at = Time.get_ticks_msec() + 250
		# The next attach binds the selected page. A global resume could recreate
		# a blank tab if the user closed the last window during surface recovery.
		return
	if not attached and Time.get_ticks_msec() >= retry_at:
		retry_at = Time.get_ticks_msec() + 500
		var surface: JavaObject = layer.input_surface()
		if surface:
			generation += 1
			attached = bool(bridge.attachWindow(window_id, surface, pixels.x, pixels.y, generation))
			if JavaClassWrapper.get_exception(): attached = false; status = "surface_attach_failed"
	if attached and int(state.get("generation", 0)) == generation and state.get("attached", false):
		var ready: bool = layer.present(layout.pose, layout.size, menu.focus_crop())
		hole.mesh.size = layout.size
		hole.visible = ready
	else:
		layer.hide(); hole.visible = false

func _release_idle_surface() -> void:
	if hole: hole.visible = false
	if not layer: return
	layer.hide()
	if attached:
		# Each attempt can block this thread for up to 1.5 s; never retry every frame.
		if Time.get_ticks_msec() < retry_at: return
		# Producer acknowledgement is required before destroying its swapchain.
		var stopped: bool = bridge.detachWindowBeforeSessionStop(window_id, generation)
		if JavaClassWrapper.get_exception() or not stopped:
			status = "surface_stop_timeout"; retry_at = Time.get_ticks_msec() + 2000; return
	attached = false; state = {}; _state_raw = ""; surface_retries = 0
	if not layer.destroy(): status = "surface_stop_timeout"; return
	layer = null
	var menu: Node = target.get_ref() if target else null
	if menu: menu.remove_meta("menu_browser_layer")

func _exit_tree() -> void:
	_session_stop()
	var menu: Node = target.get_ref() if target else null
	if menu: menu.remove_meta("menu_browser_layer")
