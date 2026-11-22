extends RefCounted
## web_browser_layer.gd's stand-in on runtimes without Android-surface swapchains (the QIYU
## factory runtime): Gecko draws into a SurfaceTexture behind an ExternalTexture, and the owner's
## hole quad shows it in the eye buffer through `material`. Browser 3D draws its side-by-side
## pair into the same texture and each eye samples its half.
const Layer := preload("res://scripts/web_browser_layer.gd")
const SHADER := preload("res://shaders/web_browser_page.gdshader")
const QiyuController := preload("res://scripts/qiyu_controller.gd")
static var bridge: JavaClass
static var _retired: Array = [] # [token, texture]: alive until the render thread let go of it
static var _checked := 0
static var _needed := false
## Menus are drawn in the eye buffer and over the scenery (main.gd): so is the page.
static var over_scene := false
static var _over_shader: Shader
var id := 0
var surface: JavaObject
var session := 0
var sort_order := -7
var stereo := false
var alpha := false
var source_crop := Rect2(0, 0, 1, 1)
var effect_state := "preparing"
var effects: JavaClass
var pixels := Vector2i.ZERO
var _effect_sent := ""
var _effect_poll := 0
var _effect_error := ""
var material: ShaderMaterial
var _texture: ExternalTexture
var _token := 0
var _frame := ""
## No 2D picture quality here: the page has no thread of its own between Gecko and the eye buffer.
var quality := false
var _picture_sent := PackedFloat32Array()

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

func create(window: int, size: Vector2i, convert: bool = false, crop: Rect2 = Rect2(0, 0, 1, 1), edge_limit: int = 1536, matte: bool = false, _quality: bool = false) -> bool:
	if not Layer.api or not Layer.api.is_running(): return false
	if not bridge:
		bridge = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserTextureBridge")
		if not bridge or JavaClassWrapper.get_exception(): bridge = null; return false
	_retired = _retired.filter(func(old: Array) -> bool: return not bridge.released(old[0]))
	id = window; session = Layer.api.get_session()
	stereo = convert; alpha = matte; source_crop = crop; pixels = size
	if stereo:
		# Same pair size as web_browser_layer.gd: the crop at the edge limit, twice as wide.
		var selected := Vector2(size) * crop.size
		var limit := clampi(edge_limit, 512, 1536)
		var scale := minf(1.0, minf(float(limit) / selected.x, float(limit) / selected.y))
		pixels = Vector2i(maxi(16, roundi(selected.x * scale)) * 2, maxi(16, roundi(selected.y * scale)))
	_texture = ExternalTexture.new(); _texture.size = pixels
	_token = int(bridge.create(id, _texture.get_external_texture_id(), pixels.x, pixels.y))
	if JavaClassWrapper.get_exception() or _token <= 0: _token = 0; _texture = null; return false
	surface = bridge.surface(id, _token)
	if JavaClassWrapper.get_exception() or not surface: destroy(); return false
	if stereo:
		effects = JavaClassWrapper.wrap("org.vrpassthroughplayer.plugin.WebBrowserDepthBridge")
		if not effects or JavaClassWrapper.get_exception(): effects = null; destroy(); return false
		var started: bool = effects.start(id, surface, size.x, size.y, pixels.x / 2, pixels.y,
			PackedFloat32Array([crop.position.x, crop.position.y, crop.size.x, crop.size.y]), matte)
		if JavaClassWrapper.get_exception() or not started: effects = null; destroy(); return false
	material = ShaderMaterial.new(); material.shader = _shader(); material.render_priority = 25
	material.set_shader_parameter("page", _texture)
	material.set_shader_parameter("page_size", Vector2(pixels))
	material.set_shader_parameter("stereo", stereo)
	material.set_shader_parameter("matte", alpha)
	DiagnosticLog.record("web_browser_page_texture", {"window": id, "size": [pixels.x, pixels.y], "stereo": stereo, "matte": alpha,
		"decode": QiyuController.runtime and QiyuController.page_decode})
	return true

static func _shader() -> Shader:
	if not over_scene: return SHADER
	if not _over_shader:
		_over_shader = Shader.new()
		_over_shader.code = SHADER.code.replace("render_mode ", "render_mode depth_test_disabled, ")
	return _over_shader

func hide() -> void: pass

func destroy(asynchronous: bool = false) -> bool:
	# The depth producer draws into the texture's Surface: stop it first (web_browser_layer.gd).
	if stereo and effects:
		if asynchronous:
			if int(effects.stopState(id)) != 1:
				effects.requestStop(id); JavaClassWrapper.get_exception(); return false
		var stopped: bool = true if asynchronous else effects.stop(id)
		if JavaClassWrapper.get_exception() or not stopped: return false
		effects = null
	if _token != 0:
		bridge.release(id, _token)
		JavaClassWrapper.get_exception()
		_retired.append([_token, _texture])
	if material: material.set_shader_parameter("page", null)
	_token = 0; _texture = null; surface = null; _frame = ""
	return true

func input_surface() -> JavaObject:
	if not stereo: return surface
	var input: JavaObject = effects.surface(id) if effects else null
	JavaClassWrapper.get_exception()
	return input

## Picture quality mode over a 3D pair (web_browser_layer.gd); nothing for a 2D page.
func configure_picture(values: PackedFloat32Array) -> void:
	if not stereo or not effects or values == _picture_sent: return
	effects.quality(id, values)
	JavaClassWrapper.get_exception()
	_picture_sent = values

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

func present(_pose: Transform3D, _size: Vector2, crop: Rect2) -> bool:
	if _token == 0 or not Layer.api or not Layer.api.is_running() or Layer.api.get_session() != session: return false
	var frame := str(bridge.frame(id, _token))
	if JavaClassWrapper.get_exception() or frame.is_empty(): return false
	if frame != _frame:
		var m := frame.split_floats(",")
		if m.size() != 16: return false
		_frame = frame
		material.set_shader_parameter("surface_transform", Projection(Vector4(m[0], m[1], m[2], m[3]), Vector4(m[4], m[5], m[6], m[7]), Vector4(m[8], m[9], m[10], m[11]), Vector4(m[12], m[13], m[14], m[15])))
	# The pair already holds the crop (web_browser_layer.gd presents it whole too).
	var shown := Rect2(0, 0, 1, 1) if stereo else crop
	material.set_shader_parameter("crop", Vector4(shown.position.x, shown.position.y, shown.size.x, shown.size.y))
	material.set_shader_parameter("decode_srgb", QiyuController.runtime and QiyuController.page_decode)
	return true
