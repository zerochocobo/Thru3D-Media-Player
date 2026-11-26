extends RefCounted
## Borrowed native GL names. Caller must claim a complete pair before bind(),
## and keep the native display lease until unbind() plus the post-draw fence.
## This helper neither claims nor retires native slots.

const PAIR_SHADER := preload("res://shaders/video_rvm_pair.gdshader")
const DECODER_SHADER := preload("res://shaders/video_rvm_pair_oes.gdshader")
static func _frame_shader(decoder: bool) -> Shader:
	return DECODER_SHADER if decoder else PAIR_SHADER
## Plain playback (the pair shaders' fast path conditions hold) draws with a shader generated from the
## pair shader that holds only that path: the GPU then allocates registers for it alone instead of for
## the whole body, which cut 8K VR180 eye-buffer cycles by about 30% on Quest 3 (2026-11-26). It draws
## exactly what the branch draws. Everyone else still sees the pair shader (source_shader()).
## perf_tune plain_shader turns it off for A/B.
static var plain_shader_enabled := true
static var _plain_variants := {}
## Every generated variant (plain or depth) to the pair shader it came from.
static var _plain_sources := {}
const PLAIN_OFF := ["alpha_enabled", "depth_enabled", "pip_enabled", "packed_alpha", "projection_mesh", "projection_uv_packed"]
## Mono 2D->3D through the shader's own parallax (GPUs without the bridge's stereo pair: Quest 2 and the
## PICO headsets on Adreno 650) draws with the full path specialised to it: these switches become
## constants, so the compiler drops the mask, packed Alpha, PiP, mesh and sharpening code and allocates
## registers for parallax, footprint, grade and captions alone. Minified, it reads the bridge's 2x reductions
## when the display asked for them (as the plain path does). perf_tune depth_shader turns it off.
static var depth_shader_enabled := true
static var _depth_variants := {}
const FULL_FOOTPRINT := "rgb = footprint_color(color_p, color_dx, color_dy, lo, hi, rgb);"
const DEPTH_FOOTPRINT := "rgb = minified_color(color_p, color_dx, color_dy, lo, hi, plain_footprint_taps);"
const DEPTH_FIXED := {"alpha_enabled": "false", "depth_enabled": "true", "pip_enabled": "false", "packed_alpha": "false",
	"projection_mesh": "false", "projection_uv_packed": "false", "stereo_sbs": "false"}

## [code] with fragment() cut down to its plain fast path, or "" when the markers changed.
static func plain_code(code: String) -> String:
	code = code.replace("\r\n", "\n")
	var fragment := code.find("void fragment() {\n")
	var start := code.find("\tif (!alpha_enabled && !depth_enabled", fragment)
	var full := code.find("\t} else { // Full path.", start)
	if fragment < 0 or start < 0 or full < 0: return ""
	var open := code.find("{\n", start) + 2
	var lines := code.substr(open, full - open).split("\n")
	for i in lines.size():
		if lines[i].begins_with("\t"): lines[i] = lines[i].substr(1)
	return code.substr(0, fragment) + "void fragment() {\n" + "\n".join(lines) + "}\n"

## The plain variant of a pair shader (null when it cannot be cut).
static func plain_variant(source: Shader) -> Shader:
	if not _plain_variants.has(source):
		var code := plain_code(source.code)
		var shader: Shader = null
		if not code.is_empty():
			shader = Shader.new(); shader.code = code; shader.resource_name = source.resource_name + "_plain"
			_plain_sources[shader] = source
		_plain_variants[source] = shader
	return _plain_variants[source]

## [code] with fragment() cut down to its full path with DEPTH_FIXED (and sharpening off) as constants,
## or "" when the markers changed.
static func depth_code(code: String) -> String:
	code = code.replace("\r\n", "\n")
	var fragment := code.find("void fragment() {\n")
	var full := code.find("\t} else { // Full path.", fragment)
	var end := code.rfind("\t}\n}")
	if fragment < 0 or full < 0 or end < full: return ""
	var open := code.find("\n", full) + 1
	var body := code.substr(open, end - open)
	if body.count("sharpness > 0.0") != 1 or body.count(FULL_FOOTPRINT) != 1: return ""
	body = body.replace("sharpness > 0.0", "false")
	# Minified (4K on a flat screen) it reads the bridge's reductions where they exist, as the plain path does.
	body = body.replace(FULL_FOOTPRINT, DEPTH_FOOTPRINT)
	var word := RegEx.new()
	for name in DEPTH_FIXED:
		word.compile("\\b%s\\b" % name)
		body = word.sub(body, DEPTH_FIXED[name], true)
	return code.substr(0, fragment) + "void fragment() {\n" + body + "}\n"

## The depth variant of a pair shader (null when it cannot be cut).
static func depth_variant(source: Shader) -> Shader:
	if not _depth_variants.has(source):
		var code := depth_code(source.code)
		var shader: Shader = null
		if not code.is_empty():
			shader = Shader.new(); shader.code = code; shader.resource_name = source.resource_name + "_depth"
			_plain_sources[shader] = source
		_depth_variants[source] = shader
	return _depth_variants[source]

## Whether the pair shader would run its parallax with nothing else of the full path in use.
static func depth_ready(target: ShaderMaterial) -> bool:
	if not depth_shader_enabled or not _parameter(target, "depth_enabled") or _parameter(target, "stereo_sbs"): return false
	for name in PLAIN_OFF:
		if name != "depth_enabled" and _parameter(target, name): return false
	var sharpness: Variant = _parameter(target, "sharpness")
	return sharpness != null and float(sharpness) <= 0.0

## The pair (or other) shader a material shows, whether drawn front-faced, plain or depth.
static func source_shader(shader: Shader) -> Shader:
	shader = Facing.source(shader)
	return _plain_sources.get(shader, shader)

## The shader a material would have without the plain variant, facing kept.
static func full_shader(target: ShaderMaterial) -> Shader:
	return Facing.for_material(target, source_shader(target.shader))

static func _parameter(target: ShaderMaterial, name: String) -> Variant:
	var value: Variant = target.get_shader_parameter(name)
	if value == null and target.shader: value = RenderingServer.shader_get_parameter_default(target.shader.get_rid(), name)
	return value

## Whether the pair shader would take its plain fast path with [target]'s parameters.
static func plain_ready(target: ShaderMaterial) -> bool:
	if not plain_shader_enabled or not _parameter(target, "plain_fast_path"): return false
	for name in PLAIN_OFF:
		if _parameter(target, name): return false
	var sharpness: Variant = _parameter(target, "sharpness")
	return sharpness != null and float(sharpness) <= 0.0

## [canonical] (a pair shader) or its plain or depth variant, whichever [target] should draw with now.
static func _draw_shader(target: ShaderMaterial, canonical: Shader) -> Shader:
	if canonical != PAIR_SHADER and canonical != DECODER_SHADER: return canonical
	var variant: Shader = null
	if plain_ready(target): variant = plain_variant(canonical)
	elif depth_ready(target): variant = depth_variant(canonical)
	return variant if variant else canonical

## Once a frame: parameters can change between frames (a paused video has none), so follow them.
## Only a material showing a pair shader or one of its variants is touched.
func refresh_plain() -> void:
	if not material or layer: return
	var source := source_shader(material.shader)
	if source != PAIR_SHADER and source != DECODER_SHADER: return
	_use_shader(material, _draw_shader(material, source))
const PORTRAIT_SHADER := preload("res://shaders/video_portrait.gdshader")
const PORTRAIT_DECODER_SHADER := preload("res://shaders/video_portrait_oes.gdshader")
const Facing := preload("res://scripts/surface_facing.gd")

var material: ShaderMaterial
var color_rid := RID()
# Decoder images (MPV direct mode) arrive as EGLImages; one external texture is rebound per pair.
var _decoder_color: ExternalTexture
var alpha_rid := RID()
var portrait_rid := RID()
## The frame's 2x reductions (color_level_ids), largest first: flat QIYU playback samples them when minified.
var level_rids: Array[RID] = []
var ticket: Dictionary = {}
## 2D->3D: the bridge rendered this mono frame's stereo pair (side by side, warp_size); it is shown
## instead of the color, with no shader parallax.
var warped := false

## Both eyes of a warped pair: large sources are scaled to the bridge's realtime budget.
static func warp_size(pair: Dictionary) -> Vector2i:
	return Vector2i(int(pair.get("warp_width", int(pair.width) * 2)), int(pair.get("warp_height", pair.height)))

## The picture of a layer pair is on the compositor's video layer: nothing to bind here.
var layer := false
## Picture quality mode in the eye buffers: the plugin draws the frame denoised, enlarged and sharpened
## into a texture of its own, which the materials read in the frame's place (always with the RGBA shader;
## the frame itself stays color_texture() for whoever reads the source). The wrapper outlives the pairs:
## the plugin draws every frame into the same texture.
var enhanced_rid := RID()
var _enhanced_name := 0
var _enhanced_size := Vector2i.ZERO
var _enhanced := false
## Set while the mode works on this display's frames: a decoder frame then binds with the RGBA shader
## and the texture's last picture at once, instead of swapping shaders twice a frame.
var enhance_expected := false

func enhanced() -> bool:
	return _enhanced

func enhanced_size() -> Vector2i:
	return _enhanced_size

## Shows the plugin's texture [name] of [size] in the bound frame's place.
func show_enhanced(name: int, size: Vector2i) -> bool:
	if not material or layer or name <= 0: return false
	if name != _enhanced_name or size != _enhanced_size or not enhanced_rid.is_valid():
		drop_enhanced()
		enhanced_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_RGBA8, name, size.x, size.y, 1)
		_enhanced_name = name; _enhanced_size = size
	if not enhanced_rid.is_valid(): return false
	_use_shader(material, _draw_shader(material, PAIR_SHADER))
	RenderingServer.material_set_param(material.get_rid(), "color_texture", enhanced_rid)
	_enhanced = true
	_show_levels(false)
	return true

## Back to the frame as it was bound.
func show_original() -> void:
	if not _enhanced: return
	_enhanced = false
	if not material or layer: return
	var decoder := str(ticket.get("color_target", "")) == "external"
	_use_shader(material, _draw_shader(material, _frame_shader(decoder)))
	if decoder:
		var scale: Array = ticket.get("color_uv_scale", [1.0, 1.0])
		material.set_shader_parameter("color_uv_scale", Vector2(float(scale[0]), float(scale[1])))
	RenderingServer.material_set_param(material.get_rid(), "color_texture", color_texture())
	_show_levels(true)

## Forgets the plugin's texture (it made another, or the mode is over). No material may still show it.
func drop_enhanced() -> void:
	if enhanced_rid.is_valid(): RenderingServer.free_rid(enhanced_rid)
	enhanced_rid = RID(); _enhanced_name = 0; _enhanced_size = Vector2i.ZERO

## What the materials show as the frame's colour.
func shown_texture() -> RID:
	return enhanced_rid if _enhanced and enhanced_rid.is_valid() else color_texture()
## Secondary pictures borrow this exact display lease; detach all RIDs before retiring it.
var _consumers: Array[ShaderMaterial] = []
var _shared_shader: Shader
var _shared_uniforms: Array[String] = []
var _shared_values := {}

func shared_parameters() -> Dictionary:
	if not material or layer: return {}
	if _shared_shader != material.shader:
		_shared_shader = material.shader; _shared_uniforms.clear(); _shared_values.clear()
		for uniform in material.shader.get_shader_uniform_list():
			var name := str(uniform.name)
			# The reductions belong to this material's own frame lease; consumers sample the frame itself.
			if not name.begins_with("pip_") and not name.begins_with("subtitle_") and not name.begins_with("bitmap_subtitle_") and not name.begins_with("color_level") and not name in ["color_texture", "alpha_texture", "separate_subtitles"]:
				_shared_uniforms.append(name)
	var values := {}
	for name in _shared_uniforms: values[name] = material.get_shader_parameter(name)
	return values

func share_with(target: ShaderMaterial, parameters: Dictionary = {}, portrait: bool = false, shader_override: Shader = null) -> void:
	if not material or layer: return
	if not _consumers.has(target): _consumers.append(target)
	if parameters.is_empty(): parameters = shared_parameters()
	var canonical := source_shader(material.shader)
	var shader := (PORTRAIT_DECODER_SHADER if canonical == DECODER_SHADER else PORTRAIT_SHADER) if portrait else canonical
	if shader_override: shader = shader_override
	shader = Facing.for_material(target, shader)
	if target.shader != shader:
		target.shader = shader; _shared_values.erase(target.get_instance_id())
	var values: Dictionary = _shared_values.get_or_add(target.get_instance_id(), {})
	for name in parameters:
		var value: Variant = parameters[name]
		if not values.has(name) or values[name] != value:
			target.set_shader_parameter(name, value); values[name] = value
	for name in ["color_texture", "alpha_texture", "portrait_texture"]:
		var texture := shown_texture() if name == "color_texture" else (alpha_rid if name == "alpha_texture" else portrait_rid)
		if values.get(name) != texture:
			RenderingServer.material_set_param(target.get_rid(), name, texture); values[name] = texture

func unshare(target: ShaderMaterial) -> void:
	RenderingServer.material_set_param(target.get_rid(), "color_texture", null)
	RenderingServer.material_set_param(target.get_rid(), "alpha_texture", null)
	RenderingServer.material_set_param(target.get_rid(), "portrait_texture", null)
	_consumers.erase(target); _shared_values.erase(target.get_instance_id())

func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
	if material or not target:
		return false
	if str(pair.get("color_target", "")) == "layer":
		if not _valid_identity(pair):
			return false
		layer = true
		material = target
		ticket = pair.duplicate(true)
		return true
	if not _valid(pair):
		return false
	warped = int(pair.get("warp_texture_id", 0)) > 0 and not bool(pair.stereo_sbs)
	var decoder := str(pair.get("color_target", "")) == "external" and not warped
	# A decimal string: JSON numbers are doubles and cannot carry a 64-bit pointer.
	var egl_image := str(pair.get("color_egl_image", "0")).to_int()
	if decoder and egl_image == 0:
		return false
	if warped:
		color_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_RGBA8, int(pair.warp_texture_id), warp_size(pair).x, warp_size(pair).y, 1)
	elif not decoder:
		color_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_RGBA8, int(pair.color_texture_id), int(pair.width), int(pair.height), 1)
		var levels: Array = pair.get("color_level_ids", [])
		for k in mini(levels.size(), 4):
			# The bridge sizes level k+1 as the frame's size shifted right by k+1, at least 1.
			var level := RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D, Image.FORMAT_RGBA8,
				int(levels[k]), maxi(1, int(pair.width) >> (k + 1)), maxi(1, int(pair.height) >> (k + 1)), 1)
			if int(levels[k]) <= 0 or not level.is_valid():
				if level.is_valid(): RenderingServer.free_rid(level)
				break
			level_rids.append(level)
	alpha_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
		Image.FORMAT_R8, int(pair.alpha_texture_id), int(pair.alpha_width), int(pair.alpha_height), 1)
	if int(pair.get("portrait_texture_id", 0)) > 0:
		portrait_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_R8, int(pair.portrait_texture_id), int(pair.input_width), int(pair.input_height), 1)
	if (not decoder and not color_rid.is_valid()) or not alpha_rid.is_valid() or (pair.has("portrait_texture_id") and not portrait_rid.is_valid()):
		_free_wrappers()
		return false
	_enhanced = decoder and enhance_expected and enhanced_rid.is_valid()
	_use_shader(target, _draw_shader(target, _frame_shader(decoder and not _enhanced)))
	var rect: Array = pair.model_content_rect
	material = target
	ticket = pair.duplicate(true)
	if warped:
		ticket.stereo_sbs = true
		ticket.color_target = "texture"
	material.set_shader_parameter("source_size", Vector2(warp_size(pair)) if warped else Vector2(pair.width, pair.height))
	material.set_shader_parameter("model_size", Vector2(pair.input_width, pair.input_height))
	material.set_shader_parameter("model_content_rect", Vector4(rect[0], rect[1], rect[2], rect[3]))
	material.set_shader_parameter("stereo_sbs", bool(pair.stereo_sbs) or warped)
	material.set_shader_parameter("rotation_degrees", int(pair.rotation_degrees))
	# The GLES material backend accepts texture RIDs directly. Avoid CPU copies.
	if decoder:
		if not _decoder_color:
			_decoder_color = ExternalTexture.new()
		_decoder_color.size = Vector2(int(pair.buffer_width), int(pair.buffer_height))
		_decoder_color.set_external_buffer_id(egl_image)
		var scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
		if not _enhanced: material.set_shader_parameter("color_uv_scale", Vector2(float(scale[0]), float(scale[1])))
		RenderingServer.material_set_param(material.get_rid(), "color_texture", enhanced_rid if _enhanced else _decoder_color.get_rid())
	else:
		RenderingServer.material_set_param(material.get_rid(), "color_texture", color_rid)
	RenderingServer.material_set_param(material.get_rid(), "alpha_texture", alpha_rid)
	_show_levels(not _enhanced)
	return true

## Lets the material sample this frame's reductions, or not (the enhanced picture has none).
func _show_levels(shown: bool) -> void:
	if not material: return
	var count := level_rids.size() if shown else 0
	material.set_shader_parameter("color_levels", count)
	for k in 4:
		RenderingServer.material_set_param(material.get_rid(), "color_level_%d" % (k + 1), level_rids[k] if k < count else null)

## The bound frame's colour texture (the decoder image in direct mode).
func color_texture() -> RID:
	return _decoder_color.get_rid() if str(ticket.get("color_target", "")) == "external" and _decoder_color else color_rid

func unbind() -> Dictionary:
	for target in _consumers:
		RenderingServer.material_set_param(target.get_rid(), "color_texture", null)
		RenderingServer.material_set_param(target.get_rid(), "alpha_texture", null)
		RenderingServer.material_set_param(target.get_rid(), "portrait_texture", null)
		var values: Dictionary = _shared_values.get(target.get_instance_id(), {})
		values.erase("color_texture"); values.erase("alpha_texture"); values.erase("portrait_texture")
	if material:
		RenderingServer.material_set_param(material.get_rid(), "color_texture", null)
		RenderingServer.material_set_param(material.get_rid(), "alpha_texture", null)
		_show_levels(false)
	material = null
	warped = false
	layer = false
	_enhanced = false
	# The slot retires after this and destroys its EGLImage. Forget it: ExternalTexture.size
	# rebinds the remembered image on a size change, and a dead image leaves GL_INVALID_OPERATION.
	if _decoder_color:
		_decoder_color.set_external_buffer_id(0)
	_free_wrappers()
	var previous := ticket
	ticket = {}
	return previous

## Switch between the RGBA and decoder-image shader, keeping every uniform the display set.
static func _use_shader(target: ShaderMaterial, shader: Shader) -> void:
	shader = Facing.for_material(target, shader)
	if target.shader == shader:
		return
	var values := {}
	if target.shader:
		for uniform in target.shader.get_shader_uniform_list():
			var name := str(uniform.name)
			if not name in ["color_texture", "alpha_texture"]:
				values[name] = target.get_shader_parameter(name)
	target.shader = shader
	for name in values:
		if values[name] != null:
			target.set_shader_parameter(name, values[name])

func _free_wrappers() -> void:
	for rid in [color_rid, alpha_rid, portrait_rid]:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	for rid in level_rids: RenderingServer.free_rid(rid)
	level_rids.clear()
	color_rid = RID()
	alpha_rid = RID()
	portrait_rid = RID()

static func _valid_identity(pair: Dictionary) -> bool:
	for key in ["session_id", "logical_session_id", "generation", "frame_id", "pts_us", "slot_token", "width", "height"]:
		if not pair.has(key):
			return false
	for key in ["session_id", "logical_session_id", "generation", "slot_token", "width", "height"]:
		if int(pair[key]) <= 0:
			return false
	return int(pair.frame_id) >= 0 and int(pair.pts_us) >= 0 and pair.get("source_pts_verified", false)

static func _valid(pair: Dictionary) -> bool:
	for key in ["session_id", "logical_session_id", "generation", "frame_id", "pts_us", "format_revision",
		"effect_revision", "model_generation", "slot_token", "color_texture_id", "alpha_texture_id",
		"width", "height", "input_width", "input_height", "alpha_width", "alpha_height",
		"rotation_degrees", "model_content_rect", "stereo_sbs", "alpha_slot_token", "alpha_frame_id", "alpha_pts_us"]:
		if not pair.has(key):
			return false
	if not pair.get("source_pts_verified", false) or not pair.get("immutable_color_frame", false) \
		or not pair.get("pair_identity_verified", false) or not pair.get("alpha_fence_ready", false) \
		or not pair.get("alpha_gpu_uploaded", false) or pair.get("alpha_texture_format") != "GL_R8_numeric":
		return false
	for key in ["session_id", "logical_session_id", "generation", "format_revision", "effect_revision", "model_generation",
		"slot_token", "color_texture_id", "alpha_texture_id", "width", "height", "input_width", "input_height"]:
		if int(pair[key]) <= 0:
			return false
	if int(pair.frame_id) < 0 or int(pair.pts_us) < 0 or pair.color_texture_id == pair.alpha_texture_id:
		return false
	if pair.alpha_slot_token != pair.slot_token or pair.alpha_frame_id != pair.frame_id or pair.alpha_pts_us != pair.pts_us:
		return false
	if pair.has("portrait_texture_id"):
		if bool(pair.stereo_sbs) or int(pair.get("warp_texture_id", 0)) > 0 or int(pair.portrait_texture_id) <= 0 \
			or pair.portrait_texture_id in [pair.color_texture_id, pair.alpha_texture_id] \
			or pair.get("portrait_slot_token") != pair.slot_token or pair.get("portrait_frame_id") != pair.frame_id \
			or pair.get("portrait_pts_us") != pair.pts_us:
			return false
	if int(pair.alpha_width) != int(pair.input_width) * 2 or int(pair.alpha_height) != int(pair.input_height):
		return false
	if int(pair.rotation_degrees) not in [0, 90, 180, 270] or (bool(pair.stereo_sbs) and int(pair.width) % 2 != 0):
		return false
	var rect: Variant = pair.model_content_rect
	if not rect is Array or rect.size() != 4:
		return false
	for value in rect:
		if not (value is float or value is int) or not is_finite(float(value)):
			return false
	# model = rect.xy + eye * rect.zw. Letterbox: the eye lies inside the model.
	# ROI zoom: the model window [-xy/zw, (1-xy)/zw] lies inside the eye (zoom <= 8x).
	for axis in [0, 1]:
		var offset := float(rect[axis])
		var scale := float(rect[axis + 2])
		if scale <= 0 or scale > 8.0:
			return false
		var letterbox := offset >= 0 and offset + scale <= 1.000001
		var window_start := -offset / scale
		var window_end := (1.0 - offset) / scale
		var zoom := window_start >= -0.000001 and window_end <= 1.000001
		if not letterbox and not zoom:
			return false
		if letterbox:
			var size := float(pair.input_width if axis == 0 else pair.input_height)
			if ceilf(offset * size - 0.5) > floorf((offset + scale) * size - 0.5):
				return false
	return true
