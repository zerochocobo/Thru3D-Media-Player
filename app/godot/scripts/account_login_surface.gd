extends Node3D
## Dedicated account slot; same provider and acknowledged Surface lifetime as the browser.
const Layer := preload("res://scripts/web_browser_layer.gd")
const Page := preload("res://scripts/web_browser_page.gd")
const HOLE := preload("res://shaders/web_browser_hole.gdshader")
const ChineseInput := preload("res://scripts/chinese_input.gd")
const I18n := preload("res://scripts/i18n.gd")
var target: WeakRef
var bridge: JavaClass
var layer: RefCounted
var hole: MeshInstance3D
var identity := ""
var generation := 0
var attached := false
var pixels := Vector2i.ZERO
var retry_at := 0
var status := ""
var _keyboard_mode := -1
var _keyboard_seen := 0

func configure(menu: Node) -> void: target = weakref(menu)
static func pixel_size(info: Dictionary) -> Vector2i:
	# Phone widths need not divide by three; round after applying the shared runtime density.
	return Vector2i((Vector2(info.get("width", 440), info.get("height", 600)) * float(info.get("pixel_units", 4)) / 3.0).round())
func _ready() -> void:
	if OS.get_name() != "Android": set_process(false); return
	bridge = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.GeckoLoginSurfaceBridge")
	if not bridge or JavaClassWrapper.get_exception(): status = "surface_unavailable"; set_process(false); return
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if not xr: set_process(false); return
	xr.session_stopping.connect(_release)
	xr.session_loss_pending.connect(_release)
	xr.instance_exiting.connect(_release)
	hole = MeshInstance3D.new(); hole.mesh = QuadMesh.new()
	var material := ShaderMaterial.new(); material.shader = HOLE; material.render_priority = 25
	hole.material_override = material; hole.visible = false; add_child(hole)
	set_meta("menu_eye_buffer", true)

func _release() -> bool:
	_close_keyboard()
	if hole: hole.visible = false
	if not layer: return true
	layer.hide()
	if attached:
		var stopped: bool = bridge.detach(identity, generation)
		if JavaClassWrapper.get_exception() or not stopped:
			status = "surface_stop_timeout"; retry_at = Time.get_ticks_msec() + 2000; return false
	layer.destroy(); layer = null; attached = false; identity = ""; status = ""
	var menu: Node = target.get_ref() if target else null
	if menu: menu.remove_meta("menu_browser_layer")
	return true

func _process(_delta: float) -> void:
	var menu: Node = target.get_ref() if target else null
	if not menu:
		if _release(): queue_free()
		return
	if Time.get_ticks_msec() < retry_at: return
	var panel: RefCounted = menu.account_panel
	var info: Dictionary = panel.data.get("web", {})
	if not menu.is_visible_in_tree() or not panel.web_gecko() or panel.paused or str(info.get("surface_id", "")).is_empty():
		_release(); return
	_sync_keyboard(menu, panel, info)
	var desired := pixel_size(info)
	var next_id := str(info.surface_id)
	var recreate: bool = int(info.get("generation", 0)) == generation and info.get("needs_surface", false)
	if layer and (identity != next_id or pixels != desired or recreate or (Layer.api and layer.session != Layer.api.get_session())):
		if not _release(): return
	if not layer:
		var page := Page.needed()
		layer = Page.new() if page else Layer.new(); pixels = desired; identity = next_id
		if not layer.create(5, pixels):
			layer = null; status = "surface_unavailable"; retry_at = Time.get_ticks_msec() + 1000; return
		if page:
			# The page keeps updating this material: a menu overlay must not swap in a copy.
			hole.material_override = layer.material; hole.set_meta("menu_overlay_own", true)
		menu.set_meta("menu_browser_layer", true)
	if not attached:
		generation += 1
		attached = bool(bridge.attach(identity, layer.surface, pixels.x, pixels.y, generation))
		if JavaClassWrapper.get_exception(): attached = false
		retry_at = Time.get_ticks_msec() + 100
	if attached and str(info.get("surface_id", "")) == identity and int(info.get("generation", 0)) == generation and info.get("attached", false):
		var rect: Rect2 = panel.web_rect()
		global_transform = menu.global_transform * Transform3D(Basis.IDENTITY, Vector3(rect.get_center().x, rect.get_center().y, 0.007))
		hole.mesh.size = rect.size
		hole.visible = layer.present(global_transform, rect.size, panel.web_focus)
		status = ""
	else:
		layer.hide(); hole.visible = false

## Generic OpenXR runtimes (QIYU) may not show the system IME in VR: as in the browser
## (web_browser_panel.gd), the player's keyboard types into the focused login field.
## Quest and PICO keep the system keyboard.
func _sync_keyboard(menu: Node, panel: RefCounted, info: Dictionary) -> void:
	var mode := int(ChineseInput.is_generic_openxr() and ChineseInput.browser_enabled())
	if mode != _keyboard_mode:
		_keyboard_mode = mode
		bridge.keyboardMode(bool(mode)); JavaClassWrapper.get_exception()
	var epoch := int(info.get("keyboard_epoch", 0))
	if not mode or not info.get("editing", false) or epoch <= 0:
		_close_keyboard(); return
	if epoch == _keyboard_seen and ChineseInput.active(): return
	_keyboard_seen = epoch
	var surface_id := str(info.get("surface_id", ""))
	# Bound to the editor this popup opened for: a newer connection on the same page replaces
	# the popup, and the old one's close must not blur that new field (QIYU 115 login).
	var current := func() -> bool:
		var web: Dictionary = panel.data.get("web", {})
		return str(web.get("surface_id", "")) == surface_id and web.get("editing", false) \
			and int(web.get("keyboard_epoch", 0)) == epoch
	ChineseInput.open(menu, "account_web", func(operation: String, value: String) -> bool:
		if not current.call(): return false
		match operation:
			"close": panel.web_action("keyboard_close")
			"text", "backspace", "enter", "left", "right": panel.web_action(operation, Vector2.ZERO, value)
			_: return false
		return true,
		current, Callable(), bool(info.get("keyboard_latin", false)) or I18n.language != "zh")

func _close_keyboard() -> void:
	_keyboard_seen = 0
	if ChineseInput.active() and ChineseInput.popup.owner_id == "account_web": ChineseInput.close("account_web")

func _exit_tree() -> void: _release()
