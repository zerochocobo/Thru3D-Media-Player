extends RefCounted
## web_browser_layer.gd's stand-in on runtimes without Android-surface swapchains (the QIYU
## factory runtime): Gecko draws into a SurfaceTexture behind an ExternalTexture, and the owner's
## hole quad shows it in the eye buffer through `material`. Plain 2D pages only.
const Layer := preload("res://scripts/web_browser_layer.gd")
const SHADER := preload("res://shaders/web_browser_page.gdshader")
static var bridge: JavaClass
static var _retired: Array = [] # [token, texture]: alive until the render thread let go of it
static var _checked := 0
static var _needed := false
var id := 0
var surface: JavaObject
var session := 0
var sort_order := -7
var stereo := false
var alpha := false
var source_crop := Rect2(0, 0, 1, 1)
var effect_state := "preparing"
var effects: JavaClass
var material: ShaderMaterial
var _texture: ExternalTexture
var _token := 0
var _frame := ""

## Whether this runtime cannot give the browser a compositor layer. Asked once per instance.
static func needed() -> bool:
	var api: OpenXRAPIExtension = Layer.api
	if not api or not api.is_running(): return false
	var instance := api.get_instance()
	if instance != _checked:
		_checked = instance
		_needed = api.get_instance_proc_addr("xrCreateSwapchainAndroidSurfaceKHR") == 0 \
			or (OS.is_debug_build() and FileAccess.file_exists("user://browser_page_texture"))
	return _needed

func create(window: int, size: Vector2i, convert: bool = false, _crop: Rect2 = Rect2(0, 0, 1, 1), _edge_limit: int = 1536, _matte: bool = false) -> bool:
	if convert or not Layer.api or not Layer.api.is_running(): return false
	if not bridge:
		bridge = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserTextureBridge")
		if not bridge or JavaClassWrapper.get_exception(): bridge = null; return false
	_retired = _retired.filter(func(old: Array) -> bool: return not bridge.released(old[0]))
	id = window; session = Layer.api.get_session()
	_texture = ExternalTexture.new(); _texture.size = size
	_token = int(bridge.create(id, _texture.get_external_texture_id(), size.x, size.y))
	if JavaClassWrapper.get_exception() or _token <= 0: _token = 0; _texture = null; return false
	surface = bridge.surface(id, _token)
	if JavaClassWrapper.get_exception() or not surface: destroy(); return false
	material = ShaderMaterial.new(); material.shader = SHADER; material.render_priority = 25
	material.set_shader_parameter("page", _texture)
	return true

func hide() -> void: pass

func destroy(_asynchronous: bool = false) -> bool:
	if _token != 0:
		bridge.release(id, _token)
		JavaClassWrapper.get_exception()
		_retired.append([_token, _texture])
	if material: material.set_shader_parameter("page", null)
	_token = 0; _texture = null; surface = null; _frame = ""
	return true

func input_surface() -> JavaObject: return surface

func configure_effect(_strength: float, _position: float, _identity: String, _fill: bool = false, _depth: bool = true) -> String: return ""

func present(_pose: Transform3D, _size: Vector2, crop: Rect2) -> bool:
	if _token == 0 or not Layer.api or not Layer.api.is_running() or Layer.api.get_session() != session: return false
	var frame := str(bridge.frame(id, _token))
	if JavaClassWrapper.get_exception() or frame.is_empty(): return false
	if frame != _frame:
		var m := frame.split_floats(",")
		if m.size() != 16: return false
		_frame = frame
		material.set_shader_parameter("surface_transform", Projection(Vector4(m[0], m[1], m[2], m[3]), Vector4(m[4], m[5], m[6], m[7]), Vector4(m[8], m[9], m[10], m[11]), Vector4(m[12], m[13], m[14], m[15])))
	material.set_shader_parameter("crop", Vector4(crop.position.x, crop.position.y, crop.size.x, crop.size.y))
	return true
