extends RefCounted
## Autoplay-only fixed window. Selection/IO/conversion keep their existing request ownership.
## The outgoing material is retained until the new picture is ready; one shader mixes RGBA.
const FADE_SECONDS := 0.45
## Sweeping reveals need longer than a uniform mix to read as movement rather than a flicker.
const SECONDS := {"fade": FADE_SECONDS, "wipe": 0.6, "depth": 0.8}
const STYLES := {"fade": 0, "wipe": 1, "depth": 2}
const IDENTITY := Vector4(1, 0, 0, 1)
var photo: Node3D
var frame_size := Vector2.ZERO
var frame_rotation := 0.0
var mapping := IDENTITY
var fitted_size := Vector2.ZERO
var waiting := false
var fading := false
var elapsed := 0.0
var effect := "slide"
var outgoing: MeshInstance3D

func _init(owner: Node3D) -> void: photo = owner

func locked() -> bool: return frame_size != Vector2.ZERO
func busy() -> bool: return waiting or fading

func begin(value: String) -> bool:
	if value == "slide" or photo.geometry != 0 or photo.gallery.overview() or photo.gallery.focus >= 0 \
		or photo.auto_portrait or photo.portrait_requested or photo.spatial_requested or photo.spatial_preferred \
		or photo.animation.available() or photo._texture == null or not photo.panel.visible: return false
	finish()
	if not locked():
		frame_size = photo._screen_base
		frame_rotation = photo.screen_rotation
	# Full GPU cache hits are reused. The existing departing path bounds uncached stereo copies.
	outgoing = photo._surface_copy(photo.panel)
	outgoing.material_override.set_shader_parameter("slideshow_mix", 1.0)
	outgoing.visible = false
	photo.add_child(outgoing)
	effect = value; waiting = true
	return true

func cover() -> void:
	if waiting and is_instance_valid(outgoing): outgoing.visible = true

func update_mapping(aspect: float) -> void:
	mapping = IDENTITY
	if locked() and aspect > 0:
		var angle := deg_to_rad(photo.screen_rotation - frame_rotation)
		var c := cos(angle); var s := sin(angle)
		var bounds := Vector2(absf(c) * aspect + absf(s), absf(s) * aspect + absf(c))
		var fit := minf(frame_size.x / bounds.x, frame_size.y / bounds.y)
		fitted_size = Vector2(aspect, 1.0) * fit
		mapping = Vector4(c * frame_size.x / (aspect * fit), s * frame_size.y / (aspect * fit),
			-s * frame_size.x / fit, c * frame_size.y / fit)
	if photo.material: photo.material.set_shader_parameter("slideshow_mapping", mapping)

func content_size() -> Vector2:
	return fitted_size * photo.screen_scale if locked() and fitted_size != Vector2.ZERO else photo._flat.size

func content_scale() -> Vector2:
	return Vector2(1.0 / mapping.x, 1.0 / mapping.w) if layer_compatible() else Vector2.ONE

func layer_compatible() -> bool:
	return absf(mapping.y) < 0.00001 and absf(mapping.z) < 0.00001 and mapping.x > 0 and mapping.w > 0

func present() -> void:
	if not waiting: return
	waiting = false
	if effect == "cut" or not is_instance_valid(outgoing):
		finish(); return
	var old: ShaderMaterial = outgoing.material_override
	var target: ShaderMaterial = photo.material
	var generated := bool(old.get_shader_parameter("photo_stereo"))
	var stereo := generated or bool(old.get_shader_parameter("stereo_sbs"))
	var texture: Texture2D = old.get_shader_parameter("stereo_texture" if generated else "photo_texture")
	target.set_shader_parameter("slideshow_old_texture", texture)
	target.set_shader_parameter("slideshow_old_layout", (2 if bool(old.get_shader_parameter("top_bottom")) and not generated else 1) if stereo else 0)
	target.set_shader_parameter("slideshow_old_swap", not generated and bool(old.get_shader_parameter("swap_eyes")))
	var source_size: Vector2 = old.get_shader_parameter("source_size")
	target.set_shader_parameter("slideshow_old_size", Vector2(texture.get_width(), texture.get_height()) if generated else source_size)
	target.set_shader_parameter("slideshow_old_depth", not generated and not stereo and bool(old.get_shader_parameter("photo_depth")))
	target.set_shader_parameter("slideshow_old_disparity", float(old.get_shader_parameter("spatial_disparity")) if bool(old.get_shader_parameter("native_stereo")) and stereo and not bool(old.get_shader_parameter("top_bottom")) else 0.0)
	for key in ["slideshow_mapping", "edge_feather", "depth_texture", "depth_rect", "depth_strength", "depth_convergence", "sharpness", "comic_overlay_enabled", "comic_overlay_texture"]:
		target.set_shader_parameter("slideshow_old_" + key.trim_prefix("slideshow_"), old.get_shader_parameter(key))
	target.set_shader_parameter("slideshow_style", STYLES.get(effect, 0))
	# The incoming map orders its own reveal; a picture without one borrows the outgoing map, else crossfades.
	var depth_source := 0
	if effect == "depth":
		if photo._depth_texture != null: depth_source = 1
		elif old.get_shader_parameter("depth_texture") != null: depth_source = 2
	target.set_shader_parameter("slideshow_depth_source", depth_source)
	target.set_shader_parameter("slideshow_mix", 0.0)
	outgoing.visible = false
	fading = true; elapsed = 0.0

func tick(delta: float) -> void:
	if not fading: return
	elapsed += maxf(0, delta)
	var fraction := clampf(elapsed / float(SECONDS.get(effect, FADE_SECONDS)), 0, 1)
	photo.material.set_shader_parameter("slideshow_mix", smoothstep(0.0, 1.0, fraction))
	if fraction >= 1.0: finish()

func finish() -> void:
	waiting = false; fading = false; elapsed = 0.0
	if is_instance_valid(outgoing): outgoing.free()
	outgoing = null
	if photo.material:
		photo.material.set_shader_parameter("slideshow_mix", 1.0)
		for key in ["texture", "depth_texture", "comic_overlay_texture"]:
			photo.material.set_shader_parameter("slideshow_old_" + key, null)

func clear(reflow: bool = false) -> void:
	var was_locked := locked()
	finish(); frame_size = Vector2.ZERO; fitted_size = Vector2.ZERO; mapping = IDENTITY
	if photo.material: photo.material.set_shader_parameter("slideshow_mapping", IDENTITY)
	if was_locked and reflow and photo.material: photo._apply_geometry()

func move(pose: Transform3D) -> void:
	if is_instance_valid(outgoing): outgoing.transform = pose * outgoing.transform

func resources() -> Dictionary:
	var result := {}
	if is_instance_valid(outgoing):
		for key in ["photo_texture", "stereo_texture", "depth_texture", "comic_overlay_texture"]:
			result[key] = outgoing.material_override.get_shader_parameter(key)
	return result
