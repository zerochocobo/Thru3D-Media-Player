extends "res://scripts/media_surface.gd"
var source_location := {}
signal changed
var autoplay := preload("res://scripts/photo_autoplay.gd").new()
var slideshow := preload("res://scripts/photo_slideshow_transition.gd").new(self)

static func autoplay_effects() -> Array:
	return preload("res://scripts/photo_autoplay.gd").EFFECTS

var _image_rotations := {} # Album-session viewing transforms; never modify source pixels.
var _rotation_preview := false
var _rotation_depth := false
var _rotation_portrait := false
var _rotation_start := 0.0
var ground_vertical := false
var _placeholder_rotation := 0.0
const MediaUri := preload("res://scripts/media_uri.gd")
const Placement := preload("res://scripts/interface_move.gd")
const Info := preload("res://scripts/image_info.gd")
const Naming := preload("res://scripts/media_naming.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const ModeMemory := preload("res://scripts/file_mode_memory.gd")
const LastMode := preload("res://scripts/photo_mode_default.gd")
signal last_mode_changed(mode: Dictionary)
signal reuse_last_mode_changed(enabled: bool)
var reuse_last_mode := false
var last_mode := {}
var _last_mode_dirty := false
const SHADER := preload("res://shaders/photo.gdshader")
const PLACEHOLDER_SHADER := preload("res://shaders/photo_placeholder.gdshader")
const Methods := preload("res://scripts/platform_methods.gd")
const Gallery := preload("res://scripts/photo_gallery.gd")
const Directory := preload("res://scripts/photo_directory.gd")
var gallery := Gallery.new()
const Magazine := preload("res://scripts/photo_magazine.gd")
var magazine := Magazine.new(self)
const ComicReader := preload("res://scripts/photo_comic_reader.gd")
var comic := ComicReader.new(self)
var archive_mode := false
var _pdf_session := ""
var archive_origin := ""
var archive_entry := {}
var archive_browser_session := false
var _archive_previous_layout := 0
var reading_layout := -1 # Shared PDF/archive preference; -1 migrates from the ordinary layout.
var directory := Directory.new()
var queue_complete := true
var directory_error := ""
var _directory_result := {}
var _directory_reorder := false
const CACHE_IMAGE_BYTES := 32 * 1024 * 1024
const RECENT_FILE_BYTES := 128 * 1024 * 1024
const RECENT_FILE_COUNT := 4
var _recent_files := {} # Source/depth/pair files only; no extra decoded images or textures.
var reading_cache := preload("res://scripts/reading_page_window.gd").new(self)
var reading_render := preload("res://scripts/reading_render_cache.gd").new(self)
var _prefetched := {}
var _prefetch_failed := {}
var _prefetch_request := 0
var _prefetch_sequence := 0
var _prefetch_decode := {}
var _cache_epoch := 0
var _display_info := {}
var _display_result := {}
var _requested_direction := 0
var _deferred_release_ids := {}
var _deferred_depth_clear_ids := {}
var _pending_display := {}
var _display_depth_data := {}
var _prefetch_depth_request := 0
var resource_budget := preload("res://scripts/background_resource_budget.gd").new()
var render_cache := preload("res://scripts/photo_render_cache.gd").new(self)
var _background_work_suspended := false
var cache_each := 1
var _prefetch_portrait_request := 0
var _promoted_depth_request := 0
var _incoming_depth_result := {}
var _navigation_direction := 1
var platform: Object
var catalog: RefCounted
var history_enabled := true
var local_uri := ""
var display_name := ""
var queue: Array[Dictionary] = []
var index := -1
var pending_index := -1
var error := ""
var loading := false
const Loading := preload("res://scripts/media_loading.gd")
var _loading_status := {}
var _loading_started_ms := 0
var _loading_poll_ms := 0
var inspect := false
var magnification := 1.0
var crop_center := Vector2(0.5, 0.5)
var depth_requested := false
var auto_depth := false # User choice survives image navigation and incompatible source modes.
var depth_enabled := false
const DepthStrength := preload("res://scripts/depth_strength.gd")
var depth_strength := DepthStrength.PHOTO_DEFAULT
const DepthPosition := preload("res://scripts/depth_position.gd")
var depth_position := 0.0
var depth_error := ""
var spatial_requested := false
var spatial_preferred := false # Global photo preference; navigation and automatic cleanup never change it.
var _spatial_auto_due := false
var spatial_error := ""
var _spatial_token := 0
var _spatial_curve := 0.0
var _spatial_waiting := false
var _spatial: Node3D
var _depth_busy := false
var _depth_texture: ImageTexture
var placement_pending := true
var portrait_requested := false
var portrait_enabled := false
var auto_portrait := false # Continue the user's choice within this album, including incompatible photos.
var _portrait_auto_due := false
var _portrait_switching := false # Keep the isolated presentation while the next source prepares.
var portrait_error := ""
var _portrait_texture: Texture2D
## The mask's level 0 bytes (R8, the pair's size): the picture layer's cutout is drawn from it.
var _portrait_mask := PackedByteArray()
var _portrait_serial := 0
## The scene behind the photo is passthrough (no environment in the eye buffers): only then can the
## cutout sit on a layer beneath them, whose hole would otherwise erase the environment behind it.
var transparent_background := false
var _portrait_epoch := 0
var _portrait_strength := -1.0
var _portrait_curve := DEFAULT_CURVE
var _portrait_thread: Thread
var _portrait_job := {}
var _portrait_next := {}
var _portrait_pending_depth := {}
var _portrait_sent_epoch := -1
var _stereo_texture: Texture2D
var _depth_thread: Thread
var _depth_job := {}
var _depth_queue: Array[Dictionary] = []
var _depth_rebuild_seconds := 0.0
var _depth_rect := Vector4(0, 0, 1, 1)
var _texture: Texture2D
var _display_proxy: Image
var _cached_render_active := false
var animation := preload("res://scripts/photo_animation.gd").new(self)
var _size := Vector2(1920, 1080)
var _metadata := {}
var _request := 0
var _display_request := 0
var _serial := 0
var _thread: Thread
var _next_decode := {}
var _decoding := {}
var _detail: MeshInstance3D
var detail_placement: Variant
var _detail_material: ShaderMaterial
var _detail_zoom: Label3D
var _detail_direction := Vector3.FORWARD
var _inspect_line: MeshInstance3D
var _inspect_dot: MeshInstance3D
var _inspect_pointer_material: StandardMaterial3D
var mode_memory := ModeMemory.new("user://photo_settings")
var panorama_tiles := preload("res://scripts/panorama_tiles.gd").new()

const DEFAULT_CURVE := 25.4
const DEFAULT_DISTANCE := 3.0
const PHOTO_DISTANCE_LIMITS := DISTANCE_LIMITS
const PHOTO_SCALE_LIMITS := SCALE_LIMITS
const INSPECT_LIMITS := Vector2(2.0, 8.0)
const DEFAULT_MAGNIFICATION := 2.0
var inspect_magnification := DEFAULT_MAGNIFICATION
const IMMERSIVE_SIZE := Vector2(3.8, 2.6)
const SOFT_EDGE_METRES := 0.07
const SOFT_EDGE_SHORT_SIDE_RATIO := 0.03
const EDGE_FEATHER_LIMITS := Vector2(0.0, 3.0)
const DEFAULT_EDGE_FEATHER := 1.0
var edge_feather_strength := DEFAULT_EDGE_FEATHER
const LAYER_OVERLAP_METRES := 0.01
const TRANSITION_SECONDS := 0.24
const REVEAL_SECONDS := 0.30
var _departing: MeshInstance3D
var _transition_time := 0.0
var _transition_direction := 0
var _departing_pose := Transform3D.IDENTITY
var _transition_width := 0.0
var _placeholder: MeshInstance3D
var _placeholder_material: ShaderMaterial
var _placeholder_size := Vector2(3.8, 2.1375)
var _transition_active := false
var _reveal_seconds := 0.0
## A selected 3D photo stays covered until its final renderer can present it.
## Separate from IO loading so layer uploads and spatial preparation can run underneath.
var _presentation_pending := false
var _presented_us := 0
var _presentation_layer_failed := false
var _swipe_offset := 0.0
## Compositor picture layer (shared with the video player): the full photo goes to the compositor
## in slices across frames, mipmapped on the GPU, instead of one long full-resolution texture upload
## on the render thread. Godot keeps a small proxy for transitions; the full texture is made only
## when the shader needs it (magnifier, depth/portrait, unsupported projections).
const VideoLayer := preload("res://scripts/video_layer.gd")
const MAGNIFIER_SKEW := 0.5 # largest crop shear (of its scale) the upright magnifier layer stands in for
const PROXY_SIZE := 1024
const UPLOAD_BYTES := 3 * 1024 * 1024 # per frame: one band texture upload plus a GPU copy
var video_layer: VideoLayer
var layer_enabled := true
var layer_shown := false # main renders the eye buffers transparent while true
var _full_image: Image # source of a later full texture while _texture is the proxy
var _texture_full := true
var _upload := {} # {"key", "image", "data", "row", "channels"} while slices remain
var _layer_key := "" # the picture in the layer swapchain: "color:<request>" or "stereo:<request>:<strength>"
var _depth_textures_pending := false # depth data kept for the shader, its textures made on demand
var _hole: MeshInstance3D
## The magnifier's own hole: its window shows quad layers over the uploaded picture's crop.
var _detail_hole: MeshInstance3D
var magnifier_on_layer := false
var _hole_material: ShaderMaterial
var _logged_key := ""

func _init() -> void:
	gallery.photo = self
	add_child(gallery); add_child(directory); add_child(panorama_tiles)
	screen_curve = DEFAULT_CURVE
	screen_distance = DEFAULT_DISTANCE
	flat_pose.origin.z = -DEFAULT_DISTANCE

func restore_view_settings(settings: ConfigFile) -> void:
	autoplay.set_interval(settings.get_value("photo", "autoplay_interval", autoplay.DEFAULT_INTERVAL))
	autoplay.set_effect(settings.get_value("photo", "autoplay_effect", "slide"))
	ground_vertical = bool(settings.get_value("photo_screen", "ground_vertical", false))
	cache_each = clampi(int(settings.get_value("photo", "cache_each", 1)), 1, 2)
	magazine.right_to_left = bool(settings.get_value("photo_screen", "magazine_rtl", false))
	reading_layout = int(settings.get_value("photo_screen", "reading_layout", -1))
	if reading_layout not in [Gallery.Layout.SINGLE, Gallery.Layout.MAGAZINE]: reading_layout = -1
	spatial_preferred = bool(settings.get_value("photo", "spatial_preferred", false))
	var distance := float(settings.get_value("photo_screen", "distance", DEFAULT_DISTANCE))
	var scale := float(settings.get_value("photo_screen", "scale", 1.0))
	var zoom := float(settings.get_value("photo_screen", "magnification", DEFAULT_MAGNIFICATION))
	var feather := float(settings.get_value("photo_screen", "edge_feather_strength", DEFAULT_EDGE_FEATHER))
	screen_distance = clampf(distance, PHOTO_DISTANCE_LIMITS.x, PHOTO_DISTANCE_LIMITS.y) if is_finite(distance) else DEFAULT_DISTANCE
	screen_scale = clampf(scale, PHOTO_SCALE_LIMITS.x, PHOTO_SCALE_LIMITS.y) if is_finite(scale) else 1.0
	restore_screen_curve(settings, "photo_screen", 0.35)
	inspect_magnification = clampf(zoom, INSPECT_LIMITS.x, INSPECT_LIMITS.y) if is_finite(zoom) else DEFAULT_MAGNIFICATION
	edge_feather_strength = clampf(feather, EDGE_FEATHER_LIMITS.x, EDGE_FEATHER_LIMITS.y) if is_finite(feather) else DEFAULT_EDGE_FEATHER
	gallery.restore_settings(settings)

func save_layout_settings(settings: ConfigFile) -> void:
	settings.set_value("photo", "autoplay_interval", autoplay.interval)
	settings.set_value("photo", "autoplay_effect", autoplay.effect)
	settings.set_value("photo_screen", "ground_vertical", ground_vertical)
	settings.set_value("photo", "cache_each", cache_each)
	gallery.save_settings(settings)
	# The temporary container layout must not replace the ordinary photo layout on disk.
	if archive_mode: settings.set_value("photo_screen", "layout", _archive_previous_layout)
	if reading_layout in [Gallery.Layout.SINGLE, Gallery.Layout.MAGAZINE]:
		settings.set_value("photo_screen", "reading_layout", reading_layout)

func set_target_feedback(_state: int) -> void:
	# Full photographs keep their feathered edge; only overview cards have selection outlines.
	if material: material.set_shader_parameter("target_state", 0)

func set_screen_distance(value: float) -> void:
	if not is_finite(value): return
	screen_distance = clampf(value, PHOTO_DISTANCE_LIMITS.x, PHOTO_DISTANCE_LIMITS.y)
	_shape_screen()

func set_screen_scale(value: float) -> void:
	if not is_finite(value): return
	screen_scale = clampf(value, PHOTO_SCALE_LIMITS.x, PHOTO_SCALE_LIMITS.y)
	_flat.size = _screen_base * screen_scale
	_shape_screen()

func _screen_dimensions(aspect: float) -> Vector2:
	if slideshow.locked(): return slideshow.frame_size
	var width := minf(IMMERSIVE_SIZE.x, IMMERSIVE_SIZE.y * aspect)
	return Vector2(width, width / aspect)

func _curve_radius() -> float:
	return _photo_curve_radius(_flat.size, _curve_rotation())

func _curve_rotation() -> float: return deg_to_rad(slideshow.frame_rotation if slideshow.locked() else screen_rotation)

func _apply_flat_pose() -> void:
	super._apply_flat_pose()
	if slideshow.locked(): panel.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, deg_to_rad(slideshow.frame_rotation)), Vector3.ZERO)

func layer_content_scale() -> Vector2:
	return slideshow.content_scale() if geometry == Geometry.Geometry.FLAT else Vector2.ONE

func _photo_curve_radius(size: Vector2, rotation: float) -> float:
	return curve_radius_for(size, rotation)

func _legacy_curve_radius(value: float) -> float:
	var width := curve_span(_flat.size, _curve_rotation())
	return maxf(super._legacy_curve_radius(value), width * width / (4.0 * screen_distance))

func set_edge_feather_strength(value: float) -> void:
	if not is_finite(value): return
	edge_feather_strength = clampf(value, EDGE_FEATHER_LIMITS.x, EDGE_FEATHER_LIMITS.y)
	_shape_screen()
	gallery.refresh_feather()
	changed.emit()

## 100% preserves the bounded default; 0 is hard-edged, even on tiny photos.
## Reading mode never inherits the globally remembered photographic feather.
func soft_edge_metres(size: Vector2) -> float:
	return 0.0 if magazine.active() else minf(SOFT_EDGE_METRES, minf(size.x, size.y) * SOFT_EDGE_SHORT_SIDE_RATIO) * edge_feather_strength

func _edge_feather() -> Vector2:
	# Only Magazine / Comics disables feathering, including its standalone cover and last page.
	var content_size: Vector2 = slideshow.content_size()
	return Vector2.ZERO if magazine.active() else Vector2.ONE * soft_edge_metres(content_size) / content_size

func _layer_keep() -> Vector2:
	# Shrink the opaque seam overlap with the soft edge, so tiny/narrow photos
	# retain a valid compositor centre instead of an inverted hole rectangle.
	var content_size: Vector2 = slideshow.content_size()
	var overlap := minf(LAYER_OVERLAP_METRES, minf(content_size.x, content_size.y) * SOFT_EDGE_SHORT_SIDE_RATIO * LAYER_OVERLAP_METRES / SOFT_EDGE_METRES)
	return _edge_feather() + Vector2.ONE * overlap / content_size

func _shape_screen() -> void:
	super._shape_screen()
	if material:
		material.set_shader_parameter("edge_feather", _edge_feather())
		material.set_shader_parameter("target_width", Vector2.ONE * clampf(screen_distance * 0.004, 0.008, 0.035) / _flat.size)
	if placeholder_visible() and pending_index >= 0:
		_size_placeholder(pending_index, queue[pending_index].get("photo_info", {}))

func hand_zoomed() -> bool:
	return inspect or screen_scale > 1.05

func set_hand_scale(value: float) -> void:
	if inspect: return
	set_screen_scale(value)
	changed.emit()

func pan_hand(step: Vector2) -> void:
	if inspect: return
	# Translate within the photo's plane; do not orbit a magnified photo round the head.
	flat_pose.origin += flat_pose.basis * Vector3(step.x, step.y, 0) * 3.0
	_apply_flat_pose()

func _ready() -> void:
	initialize_surface(SHADER)
	panorama_tiles.photo = self
	# Tile vertices are already in the sphere's local coordinates.
	panorama_tiles.reparent(panel, false)
	changed.connect(gallery._refresh_textures)
	directory.completed.connect(func(entries, complete, failure): _directory_result = {"entries": entries, "complete": complete, "error": failure, "reorder":_directory_reorder})
	_placeholder = MeshInstance3D.new()
	_placeholder_material = ShaderMaterial.new()
	_placeholder_material.shader = PLACEHOLDER_SHADER
	_placeholder_material.render_priority = -10
	_placeholder.material_override = _placeholder_material
	_placeholder.visible = false
	add_child(_placeholder)
	mode_memory.load_saved()
	_detail = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.5)
	_detail.mesh = quad
	_detail_material = ShaderMaterial.new()
	_detail_material.shader = SHADER
	_detail_material.render_priority = 2
	_detail.material_override = _detail_material
	_detail.visible = false
	add_child(_detail)
	var border := MeshInstance3D.new()
	var border_mesh := QuadMesh.new()
	border_mesh.size = Vector2(0.814, 0.514)
	border.mesh = border_mesh
	var border_material := StandardMaterial3D.new()
	border_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	border_material.albedo_color = Color(0.08, 0.24, 0.2)
	border_material.render_priority = 1
	border.material_override = border_material
	border.position.z = -0.002
	_detail.add_child(border)
	_detail_zoom = Label3D.new()
	_detail_zoom.font_size = 19
	_detail_zoom.pixel_size = 0.0012
	_detail_zoom.position = Vector3(0.35, -0.274, 0.003)
	_detail_zoom.render_priority = 3
	_detail.add_child(_detail_zoom)
	_detail_hole = MeshInstance3D.new()
	_detail_hole.mesh = quad
	var detail_hole_material := ShaderMaterial.new()
	detail_hole_material.shader = preload("res://shaders/video_layer_hole.gdshader")
	detail_hole_material.render_priority = 2 # after the photo and the window's border
	_detail_hole.material_override = detail_hole_material
	_detail_hole.visible = false
	_detail.add_child(_detail_hole)
	_inspect_pointer_material = StandardMaterial3D.new()
	_inspect_pointer_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_inspect_pointer_material.no_depth_test = true
	_inspect_pointer_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_inspect_pointer_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_inspect_pointer_material.render_priority = 14
	_inspect_line = MeshInstance3D.new()
	_inspect_line.mesh = ImmediateMesh.new()
	_inspect_line.material_override = _inspect_pointer_material
	_inspect_line.visible = false
	add_child(_inspect_line)
	_inspect_dot = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.009; dot.height = 0.018
	_inspect_dot.mesh = dot
	_inspect_dot.material_override = _inspect_pointer_material
	_inspect_dot.visible = false
	add_child(_inspect_dot)
	_hole = MeshInstance3D.new()
	_hole_material = ShaderMaterial.new()
	_hole_material.shader = preload("res://shaders/video_layer_hole.gdshader")
	_hole_material.render_priority = -128
	_hole.material_override = _hole_material
	_hole.visible = false
	add_child(_hole)
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		platform = Engine.get_singleton("QuestPlayer")
		platform.connect("photo_ready", _on_ready)
		platform.connect("photo_depth", _on_depth)
		if platform.has_signal("photo_scene_depth"): platform.connect("photo_scene_depth", _on_spatial_depth)
		if platform.has_signal("photo_portrait"): platform.connect("photo_portrait", _on_portrait)
		if platform.has_signal("photo_preload_portrait"): platform.connect("photo_preload_portrait", _on_prefetch_portrait)
		if platform.has_signal("photo_preload_depth"): platform.connect("photo_preload_depth", _on_prefetch_depth)
	_spatial=preload("res://scripts/photo_spatial_scene.gd").new()
	add_child(_spatial)
	_spatial.completed.connect(_spatial_completed)
	_apply_geometry()

func _source_size() -> Vector2:
	return _size

func open_image(uri: String, title: String, entries: Array = [], location: Dictionary = {}, retained: Dictionary = {}, container: Dictionary = {}) -> bool:
	slideshow.clear(true)
	var pdf_key := preload("res://scripts/pdf_pages.gd").session(uri)
	if not pdf_key.is_empty() and (not Methods.supports(platform, "pdf_retain") or not platform.pdf_retain(pdf_key)): return false
	source_location = location.duplicate(true) if not location.is_empty() else preload("res://scripts/media_location.gd").infer(uri)
	var retain_frame := not local_uri.is_empty() and geometry == Geometry.Geometry.FLAT and gallery.mode in [Gallery.Layout.SINGLE, Gallery.Layout.SIDES] and not portrait_requested
	close_image(true, uri if source_location.has("online_source") else "")
	# Closing released the depth model; reopening keeps it, built while the first file loads.
	if auto_depth and Methods.supports(platform, "warm_photo_depth_runtime"): platform.warm_photo_depth_runtime()
	_pdf_session = pdf_key
	archive_mode = preload("res://scripts/pdf_pages.gd").container_page(uri)
	archive_entry = container.duplicate(true) if archive_mode else {}
	if archive_mode:
		_archive_previous_layout = gallery.mode
		if reading_layout < 0:
			reading_layout = Gallery.Layout.MAGAZINE if _archive_previous_layout == Gallery.Layout.MAGAZINE else Gallery.Layout.SINGLE
		gallery.set_mode(reading_layout, "open_container")
	placement_pending = not retain_frame
	queue.clear()
	for entry in entries:
		if entry is Dictionary and not str(entry.get("uri", "")).is_empty() and (entry.get("kind") == "image" or Info.is_image(str(entry.uri), str(entry.get("title", "")))):
			queue.append(entry.duplicate(true))
	var target := -1
	for i in queue.size():
		if queue[i].uri == uri: target = i; break
	if target < 0:
		queue = [{"uri": uri, "title": title, "kind": "image"}]
		target = 0
	if not retained.is_empty(): queue[target]["retained_source"] = retained.duplicate()
	index = -1
	gallery.recenter()
	return _select(target)

func start_directory(context: Dictionary, reorder: bool = false) -> void:
	_directory_result = {}
	_directory_reorder = reorder
	queue_complete = context.is_empty(); directory_error = ""
	directory.platform = platform; directory.start(context)
	changed.emit()

func reorder(entries: Array[Dictionary], context: Dictionary) -> void:
	if not context.is_empty(): start_directory(context, true); return
	directory.cancel()
	_directory_result = {"entries":entries,"complete":true,"error":"","reorder":true}
	if not loading and not _thread: _replace_directory()

func set_layout_mode(value: int) -> void:
	if archive_mode and value not in [Gallery.Layout.SINGLE, Gallery.Layout.MAGAZINE]: return
	if archive_mode: reading_layout = value
	if value not in [0, 1, 2, 3, 4] or value == gallery.mode: return
	var reload_spread: bool = magazine.active() or value == Gallery.Layout.MAGAZINE
	magazine.cancel()
	if spatial_requested: set_spatial(false, true)
	if portrait_requested or auto_portrait: set_portrait(false)
	gallery.set_mode(value, "layout_selection")
	if reload_spread:
		magazine.reload()
	elif gallery.overview():
		suspend_gallery_photo()
	elif _texture == null and not loading and index >= 0:
		_select(index)
	if value == Gallery.Layout.SINGLE and _texture != null: panel.visible = true
	changed.emit()

func _replace_directory() -> void:
	var result := _directory_result; _directory_result = {}
	queue_complete = bool(result.complete); directory_error = str(result.error)
	var entries: Array[Dictionary] = result.entries
	# A refreshed provider snapshot must not silently reshuffle the album already on show.
	_directory_reorder = false
	if not result.get("reorder", false) and not preload("res://scripts/library_order.gd").preserves_order(queue, entries):
		queue_complete = false; directory_error = "Images unavailable"; changed.emit(); return
	if not entries.is_empty() and entries.any(func(item): return str(item.uri) == local_uri):
		_cache_epoch += 1; _pause_prefetch()
		for target in _prefetched.keys(): _drop_prefetch(target)
		for entry in _recent_files.values(): _release_photo(int(entry.id), true)
		_recent_files.clear(); _prefetch_failed.clear()
		gallery.replace_indices(queue, entries)
		queue = entries
		for position in queue.size():
			if str(queue[position].uri) == local_uri: index = position; break
		pending_index = -1
	elif queue_complete:
		queue_complete = false; directory_error = "Images unavailable"
	changed.emit()

func navigate(direction: int) -> bool:
	if queue.size() <= 1 or direction == 0 or gallery._swap_phase != 0 or (_directory_reorder and directory.loading): return false
	if magazine.active(): return select_image(magazine.target(direction), 1 if direction > 0 else -1)
	var target := (pending_index if pending_index >= 0 else index) + direction
	if (geometry == Geometry.Geometry.FLAT or gallery.mode != 0) and queue_complete: target = posmod(target, queue.size())
	return select_image(target, 1 if direction > 0 else -1)

func can_rotate_image() -> bool:
	return geometry == Geometry.Geometry.FLAT and not loading and not _presentation_pending and not _transition_active \
		and _texture != null and panel.visible and not gallery.overview() and not gallery.returning

func autoplay_failed() -> bool:
	return not error.is_empty() or ((depth_requested or auto_depth) and not depth_error.is_empty()) \
		or ((portrait_requested or auto_portrait) and not portrait_error.is_empty()) \
		or ((spatial_requested or spatial_preferred) and not spatial_error.is_empty()) \
		or not panorama_tiles.error.is_empty() or animation.failed

func autoplay_ready() -> bool:
	if slideshow.busy(): return false
	if local_uri.is_empty() or _texture == null or not panel.is_visible_in_tree() or loading or _presentation_pending \
		or _transition_active or _reveal_seconds > 0 or placeholder_visible() or _rotation_preview or inspect \
		or gallery.overview() or gallery.returning or gallery.has_capture() or not _presentation_effects_ready(): return false
	if gallery.focus >= 0 and gallery.progress < 1.0: return false
	if portrait_requested and (not is_equal_approx(_portrait_strength, depth_strength) or not _portrait_pending_depth.is_empty()): return false
	if spatial_requested and (not is_instance_valid(_spatial) or not _spatial.prepared or not _spatial.visible): return false
	if panorama_tiles.active() and panorama_tiles.wanted.any(func(cell): return not panorama_tiles.tiles.has(cell)): return false
	if not _upload.is_empty(): return false
	if _layer_eligible() and _origin() != null and not layer_shown:
		var source := _layer_source()
		if not source.is_empty() and source.image != null: return false
	return true

func autoplay_identity() -> Array:
	return [_serial, _display_request, local_uri, index, _presented_us, geometry, stereo_sbs, top_bottom, swap_eyes,
		screen_rotation, depth_requested, depth_strength, depth_position, portrait_requested, _portrait_serial,
		spatial_requested, gallery.mode, gallery.focus]

func toggle_autoplay() -> void:
	if not autoplay.enabled and (queue.size() < 2 or gallery.overview() or (local_uri.is_empty() and not loading)): return
	autoplay.set_enabled(not autoplay.enabled); changed.emit()

func rotation_epoch() -> int: return _serial

func layout_head(head: Transform3D) -> Transform3D:
	return Placement.menu_head(head) if ground_vertical else head

func constrain_layout_pose(pose: Transform3D, preserve_roll: bool = false) -> Transform3D:
	if ground_vertical:
		var level := Placement._horizontal_basis(pose.basis)
		if preserve_roll:
			var x := pose.basis.x.slide(level.z).normalized()
			if x.length_squared() > 0.5: level = Basis(x, level.z.cross(x).normalized(), level.z)
		pose.basis = level
	return pose

func set_ground_vertical(enabled: bool) -> void:
	if enabled == ground_vertical: return
	finish_transition(); close_inspect(); gallery.cancel_all()
	ground_vertical = enabled
	# Reframe the existing layout about its anchor, keeping its position and batch.
	var basis: Basis = layout_head(view_camera.global_transform).basis if is_instance_valid(view_camera) else Basis.IDENTITY
	var next_anchor := gallery.anchor
	next_anchor.basis = basis
	var motion := next_anchor * gallery.anchor.affine_inverse()
	var pose := global_transform * flat_pose
	pose.basis = basis
	gallery._layout_offsets.clear(); gallery._viewing_offsets.clear()
	gallery.transform_layout(motion)
	set_flat_world_pose(pose)
	gallery.synchronize()
	changed.emit()

func begin_screen_rotation() -> void:
	_rotation_preview = true; _rotation_depth = depth_enabled; _rotation_portrait = portrait_enabled
	_rotation_start = screen_rotation

func set_screen_rotation(value: float) -> void:
	if not is_finite(value): return
	if _rotation_preview and not is_equal_approx(value, screen_rotation):
		# Keep native stereo generation at committed quarter turns, once on release.
		depth_enabled = false; portrait_enabled = false; _hide_layer(); _upload = {}
	super.set_screen_rotation(value)
	if screen_curve > 0.0 and absf(sin(_curve_rotation())) > 0.00001: _hide_layer(); _upload = {}
	_process_spatial()

func _cancel_rotation_preview() -> void:
	if not _rotation_preview: return
	_rotation_preview = false
	depth_enabled = _rotation_depth; portrait_enabled = _rotation_portrait
	if geometry == Geometry.Geometry.FLAT: super.set_screen_rotation(_rotation_start)

func finish_screen_rotation(commit: bool) -> void:
	if not _rotation_preview: return
	_rotation_preview = false
	depth_enabled = _rotation_depth; portrait_enabled = _rotation_portrait
	if commit: _image_rotations[local_uri] = fposmod(screen_rotation, 360.0)
	_apply_geometry()
	if commit: _refresh_rotated_depth()
	_process_spatial(); changed.emit()

func rotate_clockwise() -> bool:
	if not can_rotate_image(): return false
	close_inspect()
	screen_rotation = fposmod(screen_rotation + 90.0, 360.0)
	_image_rotations[local_uri] = screen_rotation
	_apply_geometry()
	_refresh_rotated_depth()
	_process_spatial()
	changed.emit()
	return true

func _stereo_rotation(at: int = -1) -> int:
	if (spatial_requested or spatial_preferred) and not portrait_requested and not auto_portrait: return 0
	if at < 0: at = index
	if at < 0 or at >= queue.size(): return 0
	return int(_image_rotations.get(str(queue[at].uri), 0.0))

func _depth_index(id: int) -> int:
	if id == _request and pending_index >= 0: return pending_index
	if id == _display_request: return index
	for at in _prefetched:
		if int(_prefetched[at].get("id", 0)) == id: return int(at)
	return -1

func _rotation_matches(data: Dictionary, at: int = -1) -> bool:
	return int(data.get("rotation", 0)) == _stereo_rotation(at)

func _refresh_rotated_depth() -> void:
	if animation.depth_mode:
		_apply_geometry(); return
	if not depth_requested or spatial_requested or stereo_sbs or geometry != 0 or _rotation_matches(_display_depth_data): return
	render_cache.cancel(); _hide_layer(); _upload = {}; _layer_key = ""
	# Keep raw depth for geometry/inference reuse, but never show an old-direction eye pair.
	_display_depth_data = _display_depth_data.duplicate()
	for key in ["stereo_image", "ready_stereo", "warming_texture", "portrait_data"]: _display_depth_data.erase(key)
	if not _display_result.is_empty(): _display_result["depth_data"] = _display_depth_data
	_stereo_texture = null; depth_enabled = false; depth_error = ""
	if portrait_requested:
		_invalidate_portrait_mask(); portrait_enabled = false
		_portrait_texture = null; _portrait_mask = PackedByteArray(); _portrait_strength = -1.0
	_presentation_pending = true
	_size_placeholder(index, _metadata); _placeholder.visible = true
	_placeholder.transform = panel.transform
	_placeholder_material.set_shader_parameter("reveal_progress", -1.0)
	material.set_shader_parameter("presentation_opacity", 0.0)
	_depth_busy = _prepare_depth(_display_request)
	_apply_geometry()
	if not _depth_busy: depth_error = "3D unavailable"

func select_image(target: int, direction: int = 0) -> bool:
	if target < 0 or target >= queue.size(): return false
	if autoplay.advancing:
		if not slideshow.begin(autoplay.effect): slideshow.clear(true)
	else:
		slideshow.clear(true)
	if spatial_requested: set_spatial(false, true)
	if portrait_requested and target == index: return false
	if auto_portrait:
		if target == index and not loading and _texture != null: return false
		# Snapshot before disabling the old mask or restoring its ordinary curved mesh.
		var outgoing := _surface_copy(panel) if portrait_enabled and panel.visible and not loading else null
		if portrait_requested: set_portrait(false, true)
		# Wall previews keep their existing bounded lifetime; only the brief fading copy survives.
		if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and not (resource_budget.policy.get("retain", false) \
			and int(resource_budget.policy.get("spare_bytes", 0)) >= 1536 * 1024 * 1024): _release_full_photo(false)
		_portrait_switching = true
		gallery.cancel_all()
		if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS]:
			gallery._restore_focus_card()
			gallery.focus = target; gallery.progress = 1.0; gallery.returning = false
			if not gallery.cards.has(target): gallery.new_window(target)
		return _select(target, direction, outgoing)
	if portrait_requested: set_portrait(false, true)
	var was_focused: bool = gallery.focus >= 0
	if was_focused: gallery.clear_focus()
	var accepted := _select(target, direction)
	if not accepted: slideshow.finish()
	if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and ((gallery.mode == Gallery.Layout.FRAGMENTS and not was_focused) or not gallery.cards.has(target)): gallery.new_window(target)
	if was_focused:
		gallery.synchronize(); gallery.activate(target)
	return accepted

func _select(target: int, direction: int = 0, outgoing: MeshInstance3D = null) -> bool:
	if target < 0 or target >= queue.size(): return false
	var current_render := render_cache.capture_current()
	if not current_render.is_empty(): _display_result = current_render.result
	if gallery.overview() and not _portrait_switching:
		_release_full_photo(false)
		_select_gallery_item(target)
		changed.emit()
		return true
	if target == index and not loading and _texture != null: return false
	_cancel_rotation_preview()
	_portrait_auto_due = false
	# Gallery cards already supply the outgoing preview. Do not hold an old full-size
	# colour/pair/scene while another large comic is decoded and converted.
	if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and not _portrait_switching: _release_full_photo(false)
	if portrait_requested: set_portrait(false, true)
	_portrait_texture = null; _portrait_mask = PackedByteArray(); _portrait_strength = -1.0; portrait_error = ""
	if target < 0 or target >= queue.size(): return false
	if target == index and not loading and _texture != null: return false
	comic.clear()
	magazine.cancel()
	var swipe_offset := _swipe_offset
	finish_transition()
	if _reveal_seconds > 0:
		_placeholder.visible = false; _reveal_seconds = 0.0
	var cached: Dictionary = _prefetched.get(target, {})
	if not reading_render.complete(cached): cached = {}
	if cached.is_empty(): cached = _recent_files.get(target, {})
	_promoted_depth_request = 0
	_incoming_depth_result = {}
	_pause_prefetch(int(cached.get("id", 0)) if cached.has("info") else 0)
	# A complete GPU hit needs no decode/inference peak. Keep the other ready neighbours
	# inside the measured resident budget so the second quick step remains a cache hit.
	if not render_cache.ready(cached,target) or not resource_budget.policy.get("retain",false):
		_release_cache_for_foreground(int(cached.get("id", 0)))
	_serial += 1
	_pending_display = {}
	_depth_busy = false
	if not depth_enabled: depth_requested = false
	_next_decode = {}
	if platform and _request > 0 and _request != _display_request: _release_photo(_request, true)
	if target == index and _texture != null and _cache_supported():
		if outgoing != null: outgoing.free()
		if platform: reading_render.activate(_display_request, target)
		if reading_render.active(): reading_cache.sync(target, false)
		_request = _display_request; pending_index = -1; loading = false; error = ""
		if _portrait_switching: _presentation_pending = true
		_restore_display()
		# The interrupted turn already cleared OCR. Restoring only the texture
		# leaves this page permanently idle until another successful page load.
		if not _display_result.is_empty(): comic.accept(_display_result)
		_portrait_auto_due = auto_portrait and not animation.available()
		changed.emit()
		return true
	pending_index = target
	_requested_direction = direction if direction != 0 else (1 if target > index else -1)
	_navigation_direction = _requested_direction
	reading_cache.sync(target, false)
	loading = true
	error = ""
	var item := queue[target]
	_loading_started_ms = Time.get_ticks_msec(); _loading_poll_ms = 0
	_loading_status = {"remote": Loading.remote(str(item.uri)), "phase": "connecting"}
	if swipe_offset != 0.0:
		var surface := _placeholder if placeholder_visible() else panel
		surface.position += flat_pose.basis * Vector3(swipe_offset, 0, 0)
	_show_placeholder(target, cached.get("info", cached.get("metadata", item.get("photo_info", {}))), outgoing)
	if cached.has("info") and not cached.info.get("preview_only",false) and reading_render.activate(int(cached.id), target):
		_prefetched.erase(target)
		_recent_files.erase(target)
		_request = int(cached.id)
		var job := {"id": _request, "serial": _serial, "index": target, "info": cached.info, "direction": _requested_direction,
			"depth_data": cached.get("depth_data", {}), "instant":true, "render_ready":render_cache.ready(cached, target)}
		DiagnosticLog.record("photo_cache_selected", {"request":_request,"index":target,"render_ready":job.render_ready,
			"color":cached.get("result", {}).has("image"),"depth":cached.has("depth_data"),"budget":resource_budget.report()})
		if cached.get("result", {}).has("image"): _prepare_display(cached.result, job)
		else: _next_decode = job
		changed.emit()
		return true
	if not cached.is_empty():
		_promoted_depth_request = 0
		if _recent_files.has(target):
			_release_photo(int(_recent_files[target].id), true); _recent_files.erase(target)
		else: _drop_prefetch(target)
	if reading_render.active(): _prune_prefetch(target)
	_request = platform.open_photo(str(item.uri)) if platform else _serial
	if _request <= 0:
		loading = false; error = "Image unavailable"; _restore_display(); changed.emit(); return false
	if not platform:
		var path := MediaUri.decode_path(str(item.uri).trim_prefix("file://"))
		if not path.is_absolute_path():
			loading = false; error = "Image unavailable"; _restore_display(); changed.emit(); return false
		_on_ready(_request, JSON.stringify({"state": "ready", "path": path}))
	changed.emit()
	return true

func _on_ready(id: int, payload: String) -> void:
	var info: Variant = JSON.parse_string(payload)
	if reading_render.ready(id, info): return
	if magazine.ready(id, info): return
	if info is Dictionary and info.get("state") == "metadata":
		if id == _request and loading: _on_metadata(id, _serial, pending_index, info)
		elif id == _prefetch_request:
			for target in _prefetched:
				if int(_prefetched[target].id) == id:
					_prefetched[target]["metadata"] = info
					queue[target]["photo_info"] = info
		return
	if id == _prefetch_request and id != 0:
		_prefetch_request = 0
		for target in _prefetched:
			if int(_prefetched[target].id) != id: continue
			if info is Dictionary and info.get("state") == "ready":
				_prefetched[target]["info"] = info
				_prefetched[target]["file_ready_us"] = Time.get_ticks_usec()
				if info.has("width"): queue[target]["photo_info"] = info
			else:
				_prefetch_failed[target] = true
				_drop_prefetch(target)
			return
	if id != _request or not loading:
		if platform: _release_photo(id)
		return
	if not info is Dictionary or info.get("state") != "ready":
		loading = false
		error = "Image too large" if info is Dictionary and info.get("error") == "PHOTO_TOO_LARGE" else "Image unavailable"
		if info is Dictionary and info.get("error") == "PHOTO_OUT_OF_MEMORY": error = "Not enough memory to open image"
		if info is Dictionary and info.get("error") == "PHOTO_MEMORY_UNAVAILABLE": error = "Unable to check available memory"
		if archive_mode and info is Dictionary and str(info.get("error", "")).begins_with("Archive "): error = str(info.error)
		magazine.cancel()
		_restore_display()
		changed.emit(); return
	_on_metadata(id, _serial, pending_index, info)
	DiagnosticLog.record("photo_source_ready", {"request":id, "index":pending_index, "wait_ms":Time.get_ticks_msec() - _loading_started_ms,
		"remote":bool(_loading_status.get("remote", false))})
	_next_decode = {"id": id, "serial": _serial, "index": pending_index, "info": info, "direction": _requested_direction}
	magazine.decorate(_next_decode)
	# Native depth reads the source file itself: run it beside the colour decode rather than after it.
	# _prepare_display then waits for this promoted request instead of starting another one.
	if not magazine.active() and _requires_depth(pending_index, info):
		if _prepare_depth(id): _promoted_depth_request = id
		else: _next_decode["depth_rejected"] = true # one attempt per selection, as before

func _on_metadata(id: int, serial: int, target: int, info: Dictionary) -> void:
	if serial != _serial or id != _request or not loading or target != pending_index: return
	if float(info.get("width", 0)) <= 0 or float(info.get("height", 0)) <= 0: return
	if not magazine.first.is_empty(): return
	queue[target]["photo_info"] = info
	_size_placeholder(target, info)

func placeholder_visible() -> bool:
	return is_instance_valid(_placeholder) and _placeholder.visible

func portrait_presentation_active() -> bool:
	return portrait_requested or _portrait_switching

func portrait_session_active() -> bool:
	# Background policy follows the album choice, including gaps between per-image masks.
	return auto_portrait or portrait_presentation_active() or portrait_enabled

func _size_placeholder(target: int, info: Dictionary) -> void:
	_placeholder_material.set_shader_parameter("portrait_loading", portrait_presentation_active())
	var dimensions := Vector2(float(info.get("width", 1920)), float(info.get("height", 1080)))
	if not dimensions.is_finite() or dimensions.x <= 0 or dimensions.y <= 0 or dimensions.x > (65536 if info.get("native_stereo", false) else 32768) or dimensions.y > 32768: return
	if int(info.get("orientation", 1)) in [5, 6, 7, 8]: dimensions = Vector2(dimensions.y, dimensions.x)
	var mode := _resolved_mode(target, info)
	var aspect := dimensions.x / dimensions.y
	if mode.stereo_sbs: aspect *= 2.0 if mode.top_bottom else 0.5
	_placeholder_size = _screen_dimensions(aspect) * screen_scale
	var rotation := deg_to_rad(float(_image_rotations.get(str(queue[target].uri), 0.0))) if target >= 0 and target < queue.size() else 0.0
	_placeholder_rotation = rotation
	var radius := _photo_curve_radius(_placeholder_size, rotation)
	if screen_curve > 0:
		_placeholder.mesh = _cylinder(_placeholder_size, radius, 48, rotation)
	else:
		var quad := QuadMesh.new(); quad.size = _placeholder_size; _placeholder.mesh = quad
	_placeholder_material.set_shader_parameter("surface_size", _placeholder_size)
	_placeholder_material.set_shader_parameter("feather_metres", soft_edge_metres(_placeholder_size))
	if _transition_active: _update_transition()
	else: _placeholder.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, rotation), Vector3.ZERO)

func _departing_material(surface: MeshInstance3D) -> ShaderMaterial:
	var copy := surface.material_override.duplicate() as ShaderMaterial
	copy.set_shader_parameter("comic_overlay_enabled", false)
	if surface == panel:
		# The compositor supplied the centre of the old picture. Its moving copy must
		# draw that centre itself once the stationary layer and its hole are hidden.
		copy.set_shader_parameter("layer_cut", Vector4.ZERO)
		if depth_enabled and _stereo_texture == null and _display_depth_data.has("stereo_image"):
			var pair: Image = _display_depth_data.stereo_image
			var ready: Texture2D = _display_depth_data.get("ready_stereo")
			if ready == null: pair = _transition_pair(pair)
			copy.set_shader_parameter("stereo_texture", ready if ready != null else ImageTexture.create_from_image(pair))
			copy.set_shader_parameter("photo_stereo", true)
			copy.set_shader_parameter("generated_size", Vector2(pair.get_width() / 2.0, pair.get_height()))
	return copy

## Reuse the completed pair's mip chain: no full-size GPU upload or new depth warp
## on a page turn. Only the departing material owns this bounded transition texture.
static func _transition_pair(pair: Image) -> Image:
	var level := 0
	var size := pair.get_size()
	while maxi(size.x, size.y) > PROXY_SIZE and level < pair.get_mipmap_count() and size.x >= 4:
		level += 1
		size = Vector2i(maxi(1, size.x / 2), maxi(1, size.y / 2))
	if level > 0:
		return Image.create_from_data(size.x, size.y, true, pair.get_format(), pair.get_data().slice(pair.get_mipmap_offset(level)))
	if maxi(size.x, size.y) > PROXY_SIZE:
		# Legacy/in-memory sources may not have mipmaps. Still bound the GPU copy.
		var small := pair.duplicate() as Image
		var scale := float(PROXY_SIZE) / maxi(size.x, size.y)
		small.clear_mipmaps()
		small.resize(maxi(2, int(size.x * scale) / 2 * 2), maxi(1, int(size.y * scale)), Image.INTERPOLATE_BILINEAR)
		small.generate_mipmaps()
		return small
	return pair

func _surface_copy(surface: MeshInstance3D) -> MeshInstance3D:
	var copy := MeshInstance3D.new()
	copy.mesh = surface.mesh.duplicate() as Mesh
	copy.material_override = _departing_material(surface)
	copy.material_override.render_priority = -11
	copy.transform = surface.transform
	return copy

func _copy_departing(surface: MeshInstance3D) -> void:
	_departing = _surface_copy(surface)
	add_child(_departing)
	_departing_pose = _departing.transform

func _show_placeholder(target: int, info: Dictionary, outgoing: MeshInstance3D = null) -> void:
	if slideshow.waiting:
		if outgoing != null: outgoing.free()
		_placeholder.visible = false
		return
	# Selection feedback starts before IO, colour decoding or conversion completes.
	if outgoing != null:
		_departing = outgoing; add_child(_departing); _departing_pose = _departing.transform
	elif not _portrait_switching:
		if placeholder_visible(): _copy_departing(_placeholder)
		elif _texture != null and geometry == Geometry.Geometry.FLAT and panel.visible: _copy_departing(panel)
	_hide_layer()
	_size_placeholder(target, info)
	_placeholder.visible = true
	_placeholder_material.set_shader_parameter("reveal_progress", -1.0)
	_placeholder.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation), Vector3.ZERO)
	material.set_shader_parameter("presentation_opacity", 0.0)
	material.set_shader_parameter("reveal_progress", 1.0)
	_detail.visible = false; inspect = false; hide_inspect_pointer()
	_reveal_seconds = 0.0; _swipe_offset = 0.0
	_transition_direction = _requested_direction
	_transition_width = _placeholder_size.x
	_transition_time = 0.0
	_transition_active = true
	_update_transition()

func _restore_display() -> void:
	slideshow.finish()
	if _portrait_switching and not error.is_empty():
		_portrait_switching = false
		if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS]:
			gallery.focus = index; gallery.progress = 1.0; gallery.returning = false
		gallery.synchronize(); gallery._refresh_visibility()
	finish_transition()
	_placeholder.visible = _presentation_pending
	_reveal_seconds = 0.0; _swipe_offset = 0.0
	material.set_shader_parameter("presentation_opacity", 0.0 if _presentation_pending else 1.0)
	material.set_shader_parameter("reveal_progress", 1.0)
	if _presentation_pending:
		_size_placeholder(index, _metadata)
		_placeholder.transform = panel.transform
		_placeholder_material.set_shader_parameter("reveal_progress", -1.0)
		_spatial_auto_due = true
		if depth_requested and not depth_enabled and not _depth_busy and depth_error.is_empty():
			_depth_busy = _prepare_depth(_display_request)
			if not _depth_busy: depth_error = "3D unavailable"

func preview_navigation(offset: float) -> void:
	if portrait_requested: return
	# Physical swipe feedback changes the presentation pose, never the saved screen position.
	var previous := _swipe_offset
	_swipe_offset = clampf(offset / 0.09, -1.0, 1.0) * minf(_flat.size.x * 0.14, 0.5)
	if _transition_active or geometry != Geometry.Geometry.FLAT or (previous == 0.0 and _swipe_offset == 0.0): return
	var surface := _placeholder if (loading or _presentation_pending) and placeholder_visible() else panel
	surface.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation if surface == _placeholder else deg_to_rad(screen_rotation)), Vector3.ZERO)
	surface.position += flat_pose.basis * Vector3(_swipe_offset, 0, 0)

static func _decode(job: Dictionary) -> Dictionary:
	var decode_started := Time.get_ticks_usec()
	var spread_encode_ms := 0.0
	var path := str(job.info.path)
	var raw: bool = job.info.get("raw_rgba", false)
	var header := {"width":int(job.info.get("decoded_width", 0)), "height":int(job.info.get("decoded_height", 0)),
		"codec":"rgba", "orientation":1} if raw else Info.read_header(path)
	if header.is_empty() or int(header.width) <= 0 or int(header.height) <= 0: return {"error": "Image unavailable"}
	var info: Dictionary = header.duplicate(true)
	info.merge(job.info, true)
	if job.has("metadata_ready"): job.metadata_ready.call_deferred(int(job.id), int(job.serial), int(job.index), info)
	DiagnosticLog.trail("photo.image", "idx=%d %dx%d %s prefetch=%s spread=%s" % [int(job.get("index", -1)), int(header.width), int(header.height),
		str(header.codec), job.get("prefetch", false), job.has("magazine_first")])
	if int(header.width) > 8192 or int(header.height) > 8192 or int(header.width) * int(header.height) > 32 * 1024 * 1024:
		return {"error": "Image too large"}
	if job.get("prefetch", false):
		var estimate := int(header.width) * int(header.height) * 16 / 3
		var limit: int = int(job.get("cache_image_limit", preload("res://scripts/reading_render_cache.gd").IMAGE_BYTES if job.get("reading", false) else CACHE_IMAGE_BYTES))
		if job.has("magazine_first"):
			var first_image: Image = job.magazine_first.image
			var width := int(header.height) if int(info.get("orientation", 1)) >= 5 else int(header.width)
			var height := int(header.width) if int(info.get("orientation", 1)) >= 5 else int(header.height)
			var ratio := float(first_image.get_width()) / first_image.get_height() + float(width) / height
			var joined_height := mini(4096, mini(maxi(first_image.get_height(), height), int(8192.0 / ratio)))
			estimate = maxi(estimate, int(ratio * joined_height * joined_height * 16.0 / 3.0))
			if ratio * joined_height >= 7680: return {"uncached":true,"info":info}
		if (maxi(int(header.width), int(header.height)) >= 7680 and not job.has("cache_image_limit")) or estimate > limit:
			var small := str(job.info.get("thumbnail_path", ""))
			if not small.is_empty():
				var thumbnail := Image.new()
				if thumbnail.load_jpg_from_buffer(FileAccess.get_file_as_bytes(small)) == OK:
					Info.orient(thumbnail, int(job.info.get("orientation", 1)))
					return {"uncached": true, "thumbnail": thumbnail, "info": info}
			return {"uncached": true, "info": info}
	var image := Image.new()
	if raw or header.codec == "rgba":
		var file := FileAccess.open(path, FileAccess.READ)
		if not file: return {"error": "Image unavailable"}
		var prefix := file.get_buffer(16)
		if file.get_length() == 16 + int(header.width) * int(header.height) * 4 and prefix.slice(0, 4).get_string_from_ascii() == "T3DI":
			file.close()
			image = preload("res://scripts/raw_image.gd").read(path)
			if image == null or image.get_size() != Vector2i(int(header.width), int(header.height)): return {"error": "Image unavailable"}
		else:
			# Existing HEIF/extended image bridges supply headerless RGBA with explicit dimensions.
			if not raw or file.get_length() != int(header.width) * int(header.height) * 4: return {"error": "Image unavailable"}
			file.seek(0)
			image = Image.create_from_data(int(header.width), int(header.height), false, Image.FORMAT_RGBA8, file.get_buffer(file.get_length()))
	else:
		var bytes := FileAccess.get_file_as_bytes(path)
		var code := image.load_jpg_from_buffer(bytes) if header.codec == "jpg" else (image.load_png_from_buffer(bytes) if header.codec == "png" else image.load_webp_from_buffer(bytes))
		if code != OK or image.is_empty(): return {"error": "Image unavailable"}
	Info.orient(image, int(info.get("orientation", 1)))
	DiagnosticLog.trail("photo.image.done", "idx=%d" % int(job.get("index", -1)))
	var thumbnail: Image = null
	# PDF directory previews must not generate thumbnails from rendered pages.
	if not job.get("skip_thumbnail", false):
		thumbnail = Image.new()
		var thumb_path := str(job.info.get("thumbnail_path", ""))
		if thumb_path.is_empty() or thumbnail.load_jpg_from_buffer(FileAccess.get_file_as_bytes(thumb_path)) != OK:
			thumbnail = image.duplicate() as Image
			var ratio := 384.0 / maxf(image.get_width(), image.get_height())
			thumbnail.resize(maxi(1, int(image.get_width() * ratio)), maxi(1, int(image.get_height() * ratio)), Image.INTERPOLATE_BILINEAR)
		else: Info.orient(thumbnail, int(info.get("orientation", 1)))
	var spread := job.has("magazine_first")
	var source_info := info
	var comic_rects := [Rect2(0, 0, 1, 1)]
	if spread:
		# The reading cache/main-thread memory counter may still own the first page.
		# compose() clears mips/resizes in place: give the worker a separate Image
		# object (its pixel buffer stays copy-on-write until modified).
		var first_page := job.magazine_first.image.duplicate() as Image
		var second_page := image
		image = Magazine.compose(first_page, image, bool(job.get("magazine_rtl", false)))
		var left_width: int = second_page.get_width() if job.get("magazine_rtl", false) else first_page.get_width()
		var split := float(left_width) / image.get_width()
		comic_rects = [Rect2(0, 0, split, 1), Rect2(split, 0, 1 - split, 1)]
		source_info = job.magazine_first.info
		info = {"width":image.get_width(), "height":image.get_height(), "orientation":1, "panorama":false, "magazine_unregistered":true}
		thumbnail = job.magazine_first.get("thumbnail")
		if job.has("magazine_path"):
			var encode_started := Time.get_ticks_usec()
			Magazine.save_raw(image, str(job.magazine_path))
			spread_encode_ms = (Time.get_ticks_usec() - encode_started) / 1000.0
	# RGBA here, off the render thread: the picture layer copies RGBA bands on the GPU (RGB textures
	# cannot be copied into its RGBA swapchain), and RGBA textures upload without conversion.
	if image.get_format() != Image.FORMAT_RGBA8: image.convert(Image.FORMAT_RGBA8)
	# A small display proxy: the picture layer shows the full image, the eye buffers only need this
	# for slides and the first frames (an upload a tenth of the full one).
	var proxy: Image = null
	if maxi(image.get_width(), image.get_height()) > PROXY_SIZE:
		proxy = image.duplicate() as Image
		var scale := float(PROXY_SIZE) / maxi(image.get_width(), image.get_height())
		proxy.resize(maxi(1, int(image.get_width() * scale)), maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_CUBIC)
		proxy.generate_mipmaps()
	# Mipmaps improve stability when the source is much larger than its angular screen size.
	image.generate_mipmaps()
	# The library picture encoded here too: the render thread only writes the file.
	var result := {"image": image, "proxy": proxy, "info": info,
		"source_info": source_info, "magazine": spread, "comic_rects": comic_rects,
		"decode_ms":(Time.get_ticks_usec() - decode_started) / 1000.0, "spread_encode_ms":spread_encode_ms}
	if thumbnail: result.merge({"thumbnail": thumbnail, "thumbnail_jpg": Thumbnails.encode(thumbnail)})
	return result

var _catalog_save_ms := 0
func _process(delta: float) -> void:
	animation.tick()
	resource_budget.tick(self, delta, auto_depth and geometry == 0 and not stereo_sbs and index >= 0 and not _background_work_suspended \
		and not spatial_requested and not animation.available())
	_trim_depth_cache()
	render_cache.diagnose()
	if reading_render.active(): reading_render.refresh_policy()
	if loading and Time.get_ticks_msec() >= _loading_poll_ms:
		_loading_poll_ms = Time.get_ticks_msec() + 500
		if Methods.supports(platform, "get_photo_loading_status"):
			var report: Variant = JSON.parse_string(platform.get_photo_loading_status(_request))
			if report is Dictionary: _loading_status = report
	if _catalog_save_ms > 0 and Time.get_ticks_msec() >= _catalog_save_ms and catalog:
		_catalog_save_ms = 0
		catalog.save()
	_process_spatial()
	_process_portrait()
	_process_layer()
	if not _directory_result.is_empty() and not loading and not _thread: _replace_directory()
	_process_depth_jobs()
	if _depth_rebuild_seconds > 0:
		_depth_rebuild_seconds = maxf(0, _depth_rebuild_seconds - delta)
		if _depth_rebuild_seconds == 0 and depth_requested:
			# A strength change during navigation belongs to the incoming photo.
			var target_request := _request if loading else _display_request
			if target_request > 0:
				_depth_busy = _prepare_depth(target_request)
				if not _depth_busy:
					depth_error = "3D unavailable"
					if portrait_requested: set_portrait(false, true)
					changed.emit()
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if _decoding.get("prefetch", false):
			if int(_decoding.id) == _request and loading and result.has("image"):
				var job: Dictionary = _next_decode.duplicate()
				job.merge({"id": _request, "serial": _serial, "index": pending_index, "direction": _requested_direction}, true)
				_next_decode = {}
				_prepare_display(result, job)
			elif _decoding.get("render_current", false) and int(_decoding.id) == _display_request and not loading and int(_decoding.epoch) == _cache_epoch:
				if result.has("image"):
					_display_result = result
					_display_result["ready_texture"] = _texture; _display_result["ready_proxy"] = not _texture_full
			elif int(_decoding.epoch) == _cache_epoch and _prefetched.has(int(_decoding.index)) \
				and int(_prefetched[int(_decoding.index)].id) == int(_decoding.id):
				var entry: Dictionary = _prefetched[int(_decoding.index)]
				if not reading_render.decoded(result, _decoding):
					entry["decoded"] = true
					if result.has("info"):
						entry["info"] = result.info
						queue[int(_decoding.index)]["photo_info"] = result.info
					if result.has("image") and result.image.get_data_size() <= int(_decoding.get("cache_image_limit", CACHE_IMAGE_BYTES)): entry["result"] = result
				var prefetched_uri := str(queue[int(_decoding.index)].uri)
				if result.has("thumbnail_jpg") and Thumbnails.store_encoded(prefetched_uri, result.thumbnail_jpg):
					result["thumbnail_cached"] = true
				elif not result.has("thumbnail_jpg") and result.has("thumbnail") and Thumbnails.store(prefetched_uri, result.thumbnail):
					result["thumbnail_cached"] = true
		elif _decoding.serial == _serial and _decoding.id == _request:
			_prepare_display(result, _decoding)
		elif platform and int(_decoding.id) != _display_request:
			_release_photo(int(_decoding.id))
		if _deferred_release_ids.erase(int(_decoding.id)) and int(_decoding.id) not in [_request, _display_request]:
			_release_photo(int(_decoding.id))
		magazine.cleanup_job(_decoding)
		_decoding = {}
	var background_ready: bool = not _prefetch_decode.is_empty() and (not _prefetch_decode.get("reading", false) \
		or reading_render.can_decode(_prefetch_decode))
	if not _thread and (not _next_decode.is_empty() or background_ready):
		var foreground := not _next_decode.is_empty()
		_decoding = _next_decode if foreground else _prefetch_decode
		if foreground: _decoding["metadata_ready"] = _on_metadata
		if foreground: _next_decode = {}
		else: _prefetch_decode = {}
		var decode_index := int(_decoding.index)
		_decoding["skip_thumbnail"] = decode_index >= 0 and decode_index < queue.size() \
			and preload("res://scripts/pdf_pages.gd").page(str(queue[decode_index].uri))
		_thread = Thread.new()
		var code := _thread.start(_decode.bind(_decoding))
		if code != OK:
			_thread = null
			if foreground: loading = false; error = "Image unavailable"; _restore_display(); changed.emit()
			else: _drop_prefetch(int(_decoding.index))
	if panel.visible and geometry != Geometry.Geometry.FLAT: _center_on_view()
	if _transition_active:
		_transition_time += delta
		_update_transition()
	slideshow.tick(delta)
	# Stopping autoplay returns the window to the picture's own size and rotation.
	if slideshow.locked() and not autoplay.enabled and not slideshow.busy(): slideshow.clear(true)
	if _reveal_seconds > 0:
		_reveal_seconds = maxf(0, _reveal_seconds - delta)
		var progress := 1.0 - _reveal_seconds / REVEAL_SECONDS
		material.set_shader_parameter("reveal_progress", progress)
		_placeholder_material.set_shader_parameter("reveal_progress", progress)
		if _reveal_seconds == 0: _placeholder.visible = false
	_maybe_start_portrait()
	_maybe_start_spatial()
	_process_presentation()
	_remember_last_mode()
	if not spatial_requested and not loading and not _presentation_pending and not _transition_active and _reveal_seconds == 0 and (portrait_requested or not gallery.overview()):
		# The next picture's 3D comes before the GPU copy kept for returning to this one: on 115 comics
		# that copy took ~2 s (each large upload restarts the settle) and the next spread waited for it.
		if _forward_depth_pending(): _pump_depth_prefetch()
		var uploading: bool = render_cache.pump()
		if not uploading: _pump_depth_prefetch()
		# Reading colour decodes on its own thread. Waiting for the current page's GPU copy held the
		# next spread's colour back ~1.4 s after each turn on 115 comics.
		if not uploading or reading_render.active(): _pump_prefetch()
	reading_cache.sync(pending_index if loading else index, not loading and not _transition_active and _reveal_seconds == 0 \
		and not _presentation_pending and not _depth_busy and not spatial_requested and not portrait_requested and not _foreground_thread())

func _forward_depth_pending() -> bool:
	var neighbors := _neighbors(index)
	if neighbors.is_empty() or _prefetch_depth_request != 0: return false
	var entry: Dictionary = _prefetched.get(neighbors[0], {})
	return entry.get("decoded", false) and reading_render.complete(entry) and entry.has("info") \
		and _requires_depth(neighbors[0], entry.info) and not entry.get("depth_failed", false) \
		and not _valid_cached_depth(entry.get("depth_data", {}), neighbors[0])

## Only foreground work pauses page rendering. Neighbour decode and depth reads run on their own
## threads; pausing for them made Android page rendering and Godot colour work take turns.
func _foreground_thread() -> bool:
	return (_thread != null and not _decoding.get("prefetch", false)) \
		or (_depth_thread != null and not bool(_depth_job.get("background", false)))

func _cache_supported() -> bool:
	if reading_render.active():
		return gallery.mode in [Gallery.Layout.SINGLE, Gallery.Layout.MAGAZINE] and (not platform or \
			(Methods.supports(platform, "preload_reading_photo") and Methods.supports(platform, "activate_photo")))
	if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and not (auto_portrait and Methods.supports(platform, "background_resource_policy")): return false
	return not platform or (Methods.supports(platform, "preload_photo") and Methods.supports(platform, "activate_photo"))

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_background_work_suspended = true
		resource_budget.stop()
		_cancel_depth_prefetch()
	elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
		_background_work_suspended = false
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT] and animation:
		animation.suspend()
	if what == NOTIFICATION_APPLICATION_PAUSED:
		for at in _prefetched: _drop_cached_depth(int(at))
		reading_render.suspended = true
		if reading_render.active():
			_pause_prefetch()
			for at in _prefetched.keys(): _drop_prefetch(at)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		reading_render.suspended = false
		_prefetch_failed.clear()

func _release_photo(id: int, cancel: bool = false) -> void:
	if not platform: return
	if (_thread and int(_decoding.get("id", 0)) == id) or (_depth_thread and int(_depth_job.get("id", 0)) == id) or (_portrait_thread and int(_portrait_job.get("id", 0)) == id):
		# Do not unlink the decoder's source between reading its header and pixels.
		_deferred_release_ids[id] = true
	elif cancel: platform.cancel_photo(id)
	else: platform.release_photo(id)

func _neighbors(position: int) -> Array[int]:
	var result: Array[int] = []
	if queue.size() <= 1 or position < 0: return result
	var steps: Array = []
	var forward := position; var backward := position
	for distance in range(clampi(cache_each, 1, 2)):
		forward = magazine.target_from(forward, _navigation_direction) if magazine.active() else forward + _navigation_direction
		backward = magazine.target_from(backward, -_navigation_direction) if magazine.active() else backward - _navigation_direction
		steps.append(forward); steps.append(backward)
	for adjacent in steps:
		var target: int = posmod(adjacent, queue.size()) if queue_complete and not reading_render.active() else adjacent
		if target >= 0 and target < queue.size() and target not in result and target != position: result.append(target)
	return result

func _drop_prefetch(target: int) -> void:
	if not _prefetched.has(target): return
	var id := int(_prefetched[target].id)
	if int(render_cache.job.get("entry", {}).get("id", 0)) == id: render_cache.cancel()
	if id == _prefetch_portrait_request: _cancel_portrait_prefetch()
	reading_render.cleanup(_prefetched[target])
	_prefetched.erase(target)
	if int(_prefetch_decode.get("id", 0)) == id: _prefetch_decode = {}
	if _prefetch_request == id: _prefetch_request = 0
	if _prefetch_depth_request == id:
		if Methods.supports(platform, "cancel_preloaded_photo_depth"): platform.cancel_preloaded_photo_depth()
		_prefetch_depth_request = 0
	if not _prefetch_decode.is_empty() and int(_prefetch_decode.id) == id: _prefetch_decode = {}
	_release_photo(id, true)

func _pause_prefetch(except_id: int = 0) -> void:
	render_cache.cancel()
	_cancel_portrait_prefetch()
	reading_render.pause()
	if _prefetch_depth_request != 0:
		if _prefetch_depth_request == except_id:
			_promoted_depth_request = except_id
		elif Methods.supports(platform, "cancel_preloaded_photo_depth"): platform.cancel_preloaded_photo_depth()
		_prefetch_depth_request = 0
	if _prefetch_request != 0 and _prefetch_request != except_id:
		for target in _prefetched.keys():
			if int(_prefetched[target].id) == _prefetch_request: _drop_prefetch(target)
	_prefetch_decode = {}

func _prune_prefetch(at: int = -1) -> void:
	var wanted: Array = _neighbors(index if at < 0 else at) if geometry == Geometry.Geometry.FLAT and _cache_supported() else []
	if reading_render.active():
		for failed in _prefetch_failed.keys():
			if failed not in wanted: _prefetch_failed.erase(failed)
	for target in _prefetched.keys():
		if target not in wanted:
			if geometry == Geometry.Geometry.FLAT and not reading_render.active(): _remember_files(target)
			else: _drop_prefetch(target)
	if geometry != Geometry.Geometry.FLAT:
		for entry in _recent_files.values(): _release_photo(int(entry.id), true)
		_recent_files.clear()

func _remember_files(target: int) -> void:
	var entry: Dictionary = _prefetched[target]
	# Beyond the adjacent window retain only source files, as before.
	_drop_cached_depth(target)
	var bytes := maxi(int(entry.get("info", {}).get("cache_bytes", 0)), int(entry.get("depth_data", {}).get("cache_bytes", 0)))
	if not entry.has("info") or bytes <= 0 or bytes > RECENT_FILE_BYTES or int(entry.id) == _prefetch_depth_request:
		_drop_prefetch(target)
		return
	_prefetched.erase(target)
	if int(_prefetch_decode.get("id", 0)) == int(entry.id): _prefetch_decode = {}
	var info: Dictionary = entry.info.duplicate()
	info["cache_bytes"] = bytes
	_recent_files[target] = {"id":entry.id, "info":info, "decoded":false}
	var total := 0
	for item in _recent_files.values(): total += int(item.info.cache_bytes)
	while _recent_files.size() > RECENT_FILE_COUNT or total > RECENT_FILE_BYTES:
		var oldest: int = _recent_files.keys()[0]
		total -= int(_recent_files[oldest].info.cache_bytes)
		_release_photo(int(_recent_files[oldest].id), true)
		_recent_files.erase(oldest)

func _pump_prefetch() -> void:
	if animation.available(): return
	if reading_render.active(): reading_render.pump(); return
	_prune_prefetch()
	if _depth_busy or _depth_thread: return # Current-page 3D owns the heavy-work slot.
	if index < 0 or geometry != Geometry.Geometry.FLAT or not _cache_supported(): return
	if _prefetch_depth_request != 0 or _prefetch_portrait_request != 0: return
	for target in _neighbors(index):
		if not _prefetched.has(target) and _recent_files.has(target):
			_prefetched[target] = _recent_files[target]
			_recent_files.erase(target)
		if _prefetched.has(target):
			var entry: Dictionary = _prefetched[target]
			if entry.has("info") and not entry.get("decoded", false) and _prefetch_decode.is_empty() \
				and not (_decoding.get("prefetch", false) and int(_decoding.id) == int(entry.id)):
				_prefetch_decode = {"id": entry.id, "index": target, "info": entry.info, "prefetch": true, "epoch": _cache_epoch}
			continue
		if _prefetch_request != 0 or _prefetch_failed.has(target): continue
		var uri := str(queue[target].uri)
		_prefetch_sequence += 1
		var id: int = platform.preload_photo(uri) if platform else -_prefetch_sequence
		if platform and id <= 0: _prefetch_failed[target] = true; continue
		_prefetched[target] = {"id": id, "decoded": false}
		_prefetch_request = id
		if not platform:
			var path := MediaUri.decode_path(uri.trim_prefix("file://"))
			_on_ready(id, JSON.stringify({"state": "ready", "path": path}) if path.is_absolute_path() else '{"state":"error"}')

func _cancel_depth_prefetch() -> void:
	_cancel_portrait_prefetch()
	if _prefetch_depth_request != 0 and Methods.supports(platform, "cancel_preloaded_photo_depth"):
		platform.cancel_preloaded_photo_depth()
	_prefetch_depth_request = 0
	_depth_queue = _depth_queue.filter(func(job): return not bool(job.background) or int(job.id) == _promoted_depth_request)

func _drop_cached_depth(target: int) -> void:
	var entry: Dictionary = _prefetched.get(target, {})
	if int(render_cache.job.get("entry", {}).get("id", 0)) == int(entry.get("id", -1)): render_cache.cancel()
	if int(entry.get("id", 0)) != 0 and int(entry.id) == _prefetch_portrait_request: _cancel_portrait_prefetch()
	if entry.has("depth_data") or entry.get("result", {}).has("depth_data"):
		entry.erase("depth_data")
		if entry.has("result"): entry.result.erase("depth_data")
		_discard_native_depth(int(entry.id))

func _trim_depth_cache() -> void:
	if not resource_budget.policy.get("retain", false): render_cache.cancel()
	# A frame stall only delays new work. Cancelling running inference threw away up to a
	# second of finished GPU work and restarted it after the next settle.
	if not resource_budget.policy.get("work", false): _cancel_depth_prefetch()
	var seen := {}
	var bytes: int = reading_render.memory(_prefetched, seen) + render_cache.optional_memory(seen)
	var limit: int = resource_budget.resident_limit(bytes)
	var targets: Array = _prefetched.keys()
	# Keep nearer neighbours first; the currently displayed photo is excluded.
	var neighbors := _neighbors(index)
	targets.sort_custom(func(a: int,b: int):
		var pa := neighbors.find(a); var pb := neighbors.find(b)
		return (pa if pa >= 0 else 999) > (pb if pb >= 0 else 999))
	for at in targets:
		if limit > 0 and bytes <= limit: break
		_drop_cached_depth(int(at))
		seen.clear(); bytes = reading_render.memory(_prefetched, seen) + render_cache.optional_memory(seen)
	# Full-size colour and GPU residents can outlive the effect data. Release those too
	# under pressure, retaining the source file so normal opening still works.
	for at in targets:
		if limit > 0 and bytes <= limit: break
		var entry: Dictionary = _prefetched[at]
		var result: Dictionary = entry.get("result", {})
		result.erase("ready_texture"); result.erase("ready_proxy"); result.erase("warming_texture")
		var image: Image = result.get("image")
		if image != null and image.get_data_size() > CACHE_IMAGE_BYTES: entry.erase("result")
		seen.clear(); bytes = reading_render.memory(_prefetched, seen) + render_cache.optional_memory(seen)

func _release_cache_for_foreground(except_id: int) -> void:
	# Foreground is never admitted/rejected by this budget. Free optional residents instead.
	if resource_budget.policy.is_empty() or (resource_budget.policy.get("retain", false) \
		and int(resource_budget.policy.get("spare_bytes", 0)) >= 1536 * 1024 * 1024): return
	for at in _prefetched.keys():
		if int(_prefetched[at].id) != except_id: _drop_prefetch(int(at))

func _pump_depth_prefetch() -> void:
	if not auto_depth or geometry != 0 or stereo_sbs or (spatial_preferred and not auto_portrait) or animation.available() or not _cache_supported() \
		or _depth_busy or _depth_thread or _thread or _prefetch_depth_request != 0 or _prefetch_request != 0 \
		or _prefetch_portrait_request != 0 or _portrait_thread or not _portrait_next.is_empty() \
		or (auto_portrait and not portrait_enabled) or _depth_rebuild_seconds > 0.0 or _display_depth_data.is_empty(): return
	var neighbors := _neighbors(index)
	if neighbors.is_empty(): return
	# One heavy task at a time. Fill both directions in distance/browsing order, up to the cap.
	for target in neighbors:
		if _prepare_cached_effect(target, neighbors): return

func _prepare_cached_effect(target: int, neighbors: Array[int]) -> bool:
	var entry: Dictionary = _prefetched.get(target, {})
	if not entry.get("decoded", false) or not reading_render.complete(entry) or not entry.has("info") \
		or not _requires_depth(target, entry.info) or entry.get("depth_failed", false): return false
	var data: Dictionary = entry.get("depth_data", {})
	if _valid_cached_depth(data, target):
		if auto_portrait and not _valid_cached_portrait(data.get("portrait_data", {}), data) and not entry.get("portrait_failed", false):
			return _prepare_cached_portrait(entry)
		return false
	var image: Image = entry.get("result", {}).get("image")
	var width: int = image.get_width() if image else int(entry.info.get("width", 0))
	var height: int = image.get_height() if image else int(entry.info.get("height", 0))
	var cost: Dictionary = resource_budget.photo_cost(width, height, not resource_budget.policy.get("photo_model_ready", false))
	# The next picture in the reading direction skips the settle after a page turn: that turn's own
	# frame stall delayed it ~0.5 s, and measured inference left stale frames at the idle level.
	# Sustained overload (frame_budget) and memory admission still apply.
	var forward: bool = not neighbors.is_empty() and target == neighbors[0] \
		and resource_budget.reason in ["frame_stall", "settling", "ready"]
	if cost.is_empty() or not (resource_budget.can_start(int(cost.peak), int(cost.resident)) \
		or (forward and resource_budget.can_continue(int(cost.peak), int(cost.resident)))): return false
	var bytes: int = render_cache.total_memory()
	if bytes + int(cost.resident) > resource_budget.resident_limit(bytes):
		# Never evict an earlier candidate to prepare a later one: that would churn forever
		# when the requested four neighbours do not all fit.
		for other in neighbors.slice(neighbors.find(target) + 1): _drop_cached_depth(other)
		bytes = render_cache.total_memory()
	if bytes + int(cost.resident) > resource_budget.resident_limit(bytes): return false
	_prefetch_depth_request = int(entry.id)
	if not _prepare_depth(_prefetch_depth_request, true):
		_prefetch_depth_request = 0
		resource_budget.defer_work()
	return true

func set_cache_each(value: int) -> void:
	cache_each = clampi(value, 1, 2)
	_prune_prefetch(); _trim_depth_cache(); changed.emit()

func _cancel_portrait_prefetch() -> void:
	if _prefetch_portrait_request != 0 and Methods.supports(platform, "cancel_preloaded_photo_portrait"):
		platform.cancel_preloaded_photo_portrait()
	_prefetch_portrait_request = 0
	if _portrait_next.get("background", false): _portrait_next = {}

func _valid_cached_portrait(mask: Dictionary, data: Dictionary) -> bool:
	var pair: Image = data.get("stereo_image")
	return pair != null and mask.get("image") is Image and mask.image.get_size() == pair.get_size() \
		and int(mask.get("source_id", 0)) > 0 and int(mask.source_id) == int(data.get("source_id", 0)) \
		and mask.get("mask") is PackedByteArray and mask.mask.size() == pair.get_width() * pair.get_height() \
		and is_equal_approx(float(mask.get("strength", -1)), depth_strength) \
		and int(mask.get("rotation", 0)) == int(data.get("rotation", 0))

func _prepare_cached_portrait(entry: Dictionary) -> bool:
	if not Methods.supports(platform, "prepare_preloaded_photo_portrait"): return false
	var pair: Image = entry.depth_data.get("stereo_image")
	if pair == null: return false
	var cost: Dictionary = resource_budget.photo_cost(pair.get_width() / 2, pair.get_height())
	var reserve := ceili(pair.get_width() * pair.get_height() * 7.0 / 3.0)
	var bytes: int = render_cache.total_memory()
	if not resource_budget.can_start(int(cost.peak), reserve) or bytes + reserve > resource_budget.resident_limit(bytes): return false
	_prefetch_portrait_request = int(entry.id)
	var rotation := _stereo_rotation(_depth_index(int(entry.id)))
	var accepted: bool = platform.prepare_preloaded_photo_portrait_rotated(int(entry.id), int(entry.id), depth_strength, rotation) \
		if Methods.supports(platform, "prepare_preloaded_photo_portrait_rotated") else rotation == 0 and platform.prepare_preloaded_photo_portrait(int(entry.id), int(entry.id), depth_strength)
	if not accepted:
		_prefetch_portrait_request = 0; resource_budget.defer_work()
	return true

func _on_prefetch_portrait(id: int, payload: String) -> void:
	if id <= 0 or id != _prefetch_portrait_request: return
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or int(result.get("token", -1)) != id: return
	if result.get("state") != "ready":
		_prefetch_portrait_request = 0
		if result.get("deferred", false): resource_budget.defer_work()
		else:
			for entry in _prefetched.values():
				if int(entry.id) == id: entry["portrait_failed"] = true
		return
	_portrait_next = {"id":id, "token":id, "payload":result, "background":true}

func _valid_cached_depth(data: Dictionary, at: int = -1) -> bool:
	return data.has("image") and (not Methods.supports(platform, "prepare_photo_3d") or \
		(data.has("stereo_image") and is_equal_approx(float(data.get("strength", -1)), depth_strength) and is_equal_approx(float(data.get("convergence", 0.35)), DepthPosition.convergence(depth_position)) and _rotation_matches(data, at)))

func _resolved_mode(target: int, info: Dictionary) -> Dictionary:
	if magazine.active(): return {"geometry": 0, "stereo_sbs": false, "top_bottom": false, "swap_eyes": false, "fisheye_fov": 180}
	var retained: Dictionary = queue[target].get("retained_source", {})
	if not retained.is_empty():
		return {"geometry":3 if retained.get("projection")=="sphere" else 0,"stereo_sbs":int(retained.get("layout",0))!=0,
			"top_bottom":int(retained.get("layout",0))==2,"swap_eyes":bool(retained.get("swap_eyes",false)),"fisheye_fov":180}
	var native_stereo := bool(info.get("native_stereo", false))
	var source_name := str(queue[target].get("basename", ""))
	if source_name.is_empty(): source_name = str(queue[target].get("title", ""))
	var stated := {} if native_stereo else Naming.from_name(source_name)
	var saved := mode_memory.lookup(str(queue[target].uri))
	if saved.is_empty():
		var captured: Dictionary = preload("res://scripts/capture_mode.gd").clean(info.get("capture_mode"), true)
		if not captured.is_empty(): saved = captured
	var mode := {"geometry": int(saved.get("geometry", stated.get("geometry", Geometry.Geometry.EQUIRECT_360 if info.get("panorama", false) else Geometry.Geometry.FLAT))),
		"stereo_sbs": bool(saved.get("stereo_sbs", stated.get("stereo", native_stereo))),
		"top_bottom": bool(saved.get("top_bottom", stated.get("top_bottom", false))),
		"swap_eyes": bool(saved.get("swap_eyes", stated.get("swap", false))),
		"fisheye_fov": int(saved.get("fisheye_fov", stated.get("fisheye_fov", 180)))}
	if saved.is_empty() and not mode_lock.is_empty() and not stated.has("geometry") and not stated.has("stereo") and not info.get("panorama", false) and not native_stereo:
		mode.geometry = int(mode_lock.geometry)
		mode.stereo_sbs = int(mode_lock.layout) != 0
		mode.top_bottom = int(mode_lock.layout) == 2
		mode.fisheye_fov = int(mode_lock.fisheye_fov)
	elif saved.is_empty() and reuse_last_mode and not last_mode.is_empty() and not archive_mode \
		and not stated.has("geometry") and not stated.has("stereo") and not info.get("panorama", false) and not native_stereo:
		mode = LastMode.resolved(last_mode)
	return mode

func _requires_depth(target: int, info: Dictionary) -> bool:
	if info.get("animated",false): return false
	if info.get("magazine_unregistered", false): return false
	if not auto_portrait and gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and (gallery.focus != target or gallery.returning): return false
	if queue[target].has("retained_source"): return false
	var mode := _resolved_mode(target, info)
	# OCR reads the decoded colour image; speech/translation do not override the user's 3D choice.
	return auto_depth and not info.get("native_stereo", false) and platform != null and int(mode.geometry) == Geometry.Geometry.FLAT and not mode.stereo_sbs

func _prepare_display(result: Dictionary, job: Dictionary) -> void:
	if magazine.prepare(result, job): return
	# A failed promoted decode has no info/image, even when the source job carried
	# depth_data. Route it through normal restoration before inspecting that data.
	if result.has("error"):
		_accept(result, job)
		return
	if int(job.id) > 0 and int(_incoming_depth_result.get("id", 0)) == int(job.id):
		# A promoted worker can finish before its colour decode, including instant file hits.
		job["depth_data"] = _incoming_depth_result.data
		if job.depth_data.is_empty(): result["depth_failed"] = true
		_incoming_depth_result = {}
	if job.has("depth_data"):
		# Instant colour promotion must adopt only a complete pair at the current strength.
		if _requires_depth(int(job.index), result.info) and _valid_cached_depth(job.depth_data, int(job.index)): result["depth_data"] = job.depth_data
		else: result.erase("depth_data")
	if job.get("instant", false) or result.has("error") or result.get("depth_failed", false) or not _requires_depth(int(job.index), result.info):
		_accept(result, job)
		return
	_pending_display = {"result": result, "job": job, "serial": _serial}
	var depth_data: Dictionary = job.get("depth_data", {})
	if depth_data.is_empty(): depth_data = result.get("depth_data", {})
	if int(job.id) > 0 and int(_incoming_depth_result.get("id", 0)) == int(job.id):
		depth_data = _incoming_depth_result.data
		_incoming_depth_result = {}
		if depth_data.is_empty():
			_fail_pending_depth()
			return
	if _valid_cached_depth(depth_data, int(job.index)):
		result["depth_data"] = depth_data
		_pending_display = {}
		_accept(result, job)
		return
	if int(job.id) > 0 and _promoted_depth_request == int(job.id): changed.emit()
	elif job.get("depth_rejected", false) or not _prepare_depth(int(job.id)): _fail_pending_depth()
	else: changed.emit()

func _fail_pending_depth() -> void:
	_promoted_depth_request = 0; _incoming_depth_result = {}
	# A conversion failure must not discard a successfully decoded colour image.
	# Keep the source lease for an explicit retry and all normal photo controls.
	if not _pending_display.is_empty() and int(_pending_display.serial) == _serial:
		var pending := _pending_display; _pending_display = {}
		pending.result["depth_failed"] = true
		_accept(pending.result, pending.job)
		return
	_pending_display = {}; loading = false; error = "3D unavailable"
	_restore_display()
	if _request != _display_request: _release_photo(_request, true)
	_request = _display_request
	changed.emit()

var _accept_timing := {}
func _mark(stage: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	_accept_timing[stage] = now - since
	return now

func _accept(result: Dictionary, job: Dictionary) -> void:
	var depth_failed := bool(result.get("depth_failed", false))
	result.erase("depth_failed") # A later explicit retry or cache promotion may succeed.
	if spatial_requested: set_spatial(false, true)
	spatial_error=""
	_accept_timing = {}
	var accept_started := Time.get_ticks_usec()
	var mark := accept_started
	loading = false
	slideshow.cover()
	_hide_layer() # before the departing copy of the material: it slides out whole, in the eye buffers
	if result.has("error"):
		# Release only this failed selection's promoted data; a different request owns
		# any other result. Late background callbacks then fail their normal ID gate.
		if _promoted_depth_request == int(job.id): _promoted_depth_request = 0
		if int(_incoming_depth_result.get("id", 0)) == int(job.id): _incoming_depth_result = {}
		error = str(result.error); _restore_display(); changed.emit(); return
	_presentation_pending = false
	_presentation_layer_failed = false
	var had_placeholder := placeholder_visible() or (gallery.focus == int(job.index) and not gallery.returning)
	var placeholder_time := _transition_time
	if gallery.focus == int(job.index) and not gallery.returning and gallery.progress >= 1:
		placeholder_time = maxf(placeholder_time, TRANSITION_SECONDS)
	var previous_index := index
	var previous_request := _display_request
	var previous_info := _display_info
	var previous_render := render_cache.capture_current()
	if not previous_render.is_empty(): _display_result = previous_render.result
	var previous_result := _display_result.duplicate()
	var previous_depth := _display_depth_data
	var previous_seen := {}
	var resident_bytes: int = reading_render.memory(_prefetched, previous_seen) + reading_render.memory(previous_result, previous_seen) \
		+ reading_render.memory(previous_depth, previous_seen)
	var keep_depth := auto_depth and (not spatial_preferred or auto_portrait) and _valid_cached_depth(previous_depth, previous_index) \
		and previous_index in _neighbors(int(job.index)) and resident_bytes <= resource_budget.resident_limit(resident_bytes)
	if not keep_depth:
		previous_depth = {}; previous_result.erase("depth_data")
		if previous_request != int(job.id): _discard_native_depth(previous_request)
	var previous_flat := _texture != null and geometry == Geometry.Geometry.FLAT and panel.visible
	var old_surface: MeshInstance3D
	if previous_flat and not had_placeholder and not slideshow.waiting:
		old_surface = MeshInstance3D.new()
		old_surface.mesh = panel.mesh.duplicate() as Mesh
		old_surface.material_override = _departing_material(panel)
		old_surface.transform = panel.transform
	_display_request = int(job.id)
	index = int(job.index)
	pending_index = -1
	local_uri = str(queue[index].uri)
	display_name = str(queue[index].get("title", local_uri.get_file()))
	_metadata = result.info
	animation.activate()
	panorama_tiles.configure(_metadata,platform)
	var retained: Dictionary = queue[index].get("retained_source", {})
	if not retained.is_empty():
		_metadata["native_stereo"] = int(retained.get("layout",0))!=0
		_metadata["spatial_disparity"] = float(retained.get("spatial_disparity",0))
		if retained.get("depth") is Image:
			result["depth_data"] = {"image":retained.depth,"rect":retained.depth_rect,"strength":depth_strength}
	queue[index]["photo_info"] = result.get("source_info", result.info)
	var mode := _resolved_mode(index, _metadata)
	depth_failed=depth_failed and int(mode.geometry)==Geometry.Geometry.FLAT and not bool(mode.stereo_sbs) and not _metadata.get("native_stereo",false)
	_cached_render_active = bool(job.get("render_ready", false))
	_hide_layer()
	_upload = {}
	_layer_key = ""
	_depth_textures_pending = false
	mark = _mark("before_texture", mark)
	var proxy: Image = result.get("proxy")
	DiagnosticLog.trail("photo.texture", "idx=%d %dx%d proxy=%s" % [index, result.image.get_width(), result.image.get_height(),
		"%dx%d" % [proxy.get_width(), proxy.get_height()] if proxy else "-"])
	_display_proxy = proxy
	if proxy and (_layer_possible(int(mode.geometry)) or (job.get("render_ready", false) and result.has("depth_data"))):
		_texture = result.ready_texture if result.get("ready_proxy", false) and result.has("ready_texture") else ImageTexture.create_from_image(proxy)
		_full_image = result.image
		_texture_full = false
	else:
		_texture = result.ready_texture if not result.get("ready_proxy", false) and result.has("ready_texture") else ImageTexture.create_from_image(result.image)
		_full_image = null
		_texture_full = true
	mark = _mark("texture", mark)
	_size = Vector2(result.image.get_width(), result.image.get_height())
	_depth_texture = null; _stereo_texture = null; depth_requested = false; depth_enabled = false; _depth_busy = false; depth_error = ""
	geometry = int(mode.geometry); stereo_sbs = bool(mode.stereo_sbs)
	if geometry != Geometry.Geometry.FLAT: slideshow.clear()
	screen_rotation = float(_image_rotations.get(local_uri, 0.0)) if geometry == 0 else 0.0
	top_bottom = stereo_sbs and bool(mode.top_bottom); swap_eyes = bool(mode.swap_eyes); fisheye_fov = int(mode.fisheye_fov)
	if _portrait_switching and (depth_failed or animation.available() or not can_portrait()):
		_portrait_switching = false
		gallery.synchronize(); gallery._refresh_visibility()
	_display_depth_data = result.get("depth_data", {}).duplicate() if geometry == Geometry.Geometry.FLAT and not stereo_sbs else {}
	if not _display_depth_data.is_empty():
		_display_depth_data["source_id"] = _display_request
		_depth_rect = _display_depth_data.rect
		_use_depth_textures()
		depth_requested = auto_depth or retained.get("kind")=="relief"; depth_enabled = depth_requested
	_display_info = result.info
	var image_limit: int = reading_render.IMAGE_BYTES if reading_render.active() else CACHE_IMAGE_BYTES
	var cacheable: bool = not reading_render.active() or maxi(result.image.get_width(), result.image.get_height()) < 7680
	_display_result = result if cacheable and geometry == Geometry.Geometry.FLAT and result.image.get_data_size() <= image_limit else {}
	comic.accept(result)
	_prefetch_failed.erase(index)
	if previous_flat and geometry == Geometry.Geometry.FLAT and previous_index in _neighbors(index) and _cache_supported() \
		and not previous_info.is_empty() and previous_request != _display_request:
		_drop_prefetch(previous_index)
		_prefetched[previous_index] = {"id": previous_request, "info": previous_info, "result": previous_result, "decoded": not previous_result.is_empty()}
		if keep_depth: _prefetched[previous_index]["depth_data"] = previous_depth
		if reading_render.active():
			_prefetched[previous_index]["stage"] = "done"
			# Oversized prior pages keep only the original file window, never retry render prefetch.
			if previous_result.is_empty(): reading_render.fail(previous_index)
	elif platform and previous_request > 0 and previous_request != _display_request:
		_release_photo(previous_request)
	_prune_prefetch()
	if reading_render.active(): reading_render.trim()
	_presentation_pending = slideshow.waiting or (not depth_failed and (_portrait_switching or _requires_depth(index, _metadata) or \
		(spatial_preferred and bool(_metadata.get("native_stereo", false)) and geometry == Geometry.Geometry.FLAT \
		and Methods.supports(platform, "prepare_photo_scene_depth"))))
	reset_view()
	material.set_shader_parameter("photo_texture", _texture)
	_detail_material.set_shader_parameter("sharpness", sharpness)
	_detail_material.set_shader_parameter("photo_texture", _texture)
	_apply_geometry()
	panel.visible = true
	if slideshow.waiting:
		_placeholder.visible = false
		_reveal_seconds = 0.0
		material.set_shader_parameter("reveal_progress", 1.0)
		material.set_shader_parameter("presentation_opacity", 0.0)
	elif _presentation_pending:
		# Cache hits still avoid IO, but colour readiness does not reveal a 3D selection.
		_size_placeholder(index, _metadata)
		_placeholder.visible = true
		_placeholder_material.set_shader_parameter("reveal_progress", -1.0)
		_reveal_seconds = 0.0
		material.set_shader_parameter("presentation_opacity", 0.0)
		if _transition_active: _update_transition()
		else: _placeholder.transform = panel.transform
		if old_surface != null: old_surface.free()
	elif job.get("instant", false):
		finish_transition(); _placeholder.visible = false; _reveal_seconds = 0
		if old_surface != null: old_surface.free()
	elif had_placeholder:
		# Keep the selection's slide in progress; a slow decode must not start a second slide.
		if geometry == Geometry.Geometry.FLAT and placeholder_time < TRANSITION_SECONDS:
			_placeholder.visible = false
			_transition_time = placeholder_time
			_transition_active = true
			_update_transition()
		else:
			finish_transition()
			_placeholder.visible = true
			_placeholder.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation), Vector3.ZERO)
			_placeholder_material.set_shader_parameter("presentation_opacity", 1.0)
			_reveal_seconds = REVEAL_SECONDS
			_placeholder_material.set_shader_parameter("reveal_progress", 0.0)
			material.set_shader_parameter("presentation_opacity", 1.0)
			material.set_shader_parameter("reveal_progress", 0.0)
	elif previous_flat and geometry == Geometry.Geometry.FLAT and previous_index != index:
		_departing = old_surface
		_departing.material_override.render_priority = -11
		add_child(_departing)
		_departing_pose = _departing.transform
		_transition_direction = int(job.get("direction", 1 if index > previous_index else -1))
		_transition_width = _flat.size.x
		_transition_time = 0.0
		_transition_active = true
		_update_transition()
	elif old_surface != null:
		old_surface.free()
	mark = _mark("display", mark)
	if depth_failed:
		depth_error = "3D unavailable"; _spatial_auto_due = false
	elif auto_depth and geometry == 0 and not stereo_sbs and retained.is_empty(): set_depth(true)
	mark = _mark("depth", mark)
	var thumbnail_key := str(queue[index].get("thumbnail_key", local_uri)) if index >= 0 and index < queue.size() else local_uri
	if result.has("thumbnail") and (not result.get("thumbnail_cached", false) or not Thumbnails.has(thumbnail_key)):
		var stored := Thumbnails.store_encoded(thumbnail_key, result.thumbnail_jpg) if result.has("thumbnail_jpg") \
			else Thumbnails.store(thumbnail_key, result.thumbnail)
		if stored: result["thumbnail_cached"] = true
	mark = _mark("thumbnail", mark)
	if catalog and history_enabled and not source_location.has("online_source"):
		if archive_mode: catalog.opened_container(archive_entry)
		else:
			catalog.opened(local_uri, display_name, false, "image")
			catalog.set_location(local_uri, source_location if not source_location.is_empty() else preload("res://scripts/media_location.gd").infer(local_uri))
		_catalog_save_ms = Time.get_ticks_msec() + 1000 # not in the frame that shows the photo
	mark = _mark("catalog", mark)
	_portrait_auto_due = auto_portrait and not depth_failed and not animation.available()
	if job.get("render_ready", false):
		# Ready full-resolution eye textures can be sampled now. The optional compositor copy
		# proceeds later; it must not cover an already complete picture with another loader.
		_maybe_start_portrait()
		if _presentation_effects_ready() and (not depth_requested or _stereo_texture != null):
			finish_transition(); _finish_presentation()
	changed.emit()
	mark = _mark("changed", mark)
	_spatial_auto_due=not animation.available()
	_accept_timing["total"] = Time.get_ticks_usec() - accept_started
	_accept_timing["decode_ms"] = result.get("decode_ms", 0.0)
	_accept_timing["spread_encode_ms"] = result.get("spread_encode_ms", 0.0)
	DiagnosticLog.record("photo_accept_timing", _accept_timing)
	_last_mode_dirty = reuse_last_mode
	_remember_last_mode()

func _update_transition() -> void:
	var fraction := clampf(_transition_time / TRANSITION_SECONDS, 0.0, 1.0)
	var eased := fraction * fraction * (3.0 - 2.0 * fraction)
	var travel := Vector3.ZERO if _portrait_switching else Vector3.RIGHT * _transition_width * float(_transition_direction)
	var surface := _placeholder if (loading or _presentation_pending) and placeholder_visible() else panel
	surface.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation if surface == _placeholder else deg_to_rad(screen_rotation)), Vector3.ZERO)
	surface.position += flat_pose.basis * travel * (1.0 - eased)
	surface.material_override.set_shader_parameter("presentation_opacity", eased)
	if is_instance_valid(_departing):
		_departing.transform = _departing_pose
		_departing.position -= _departing_pose.basis * travel * eased
		_departing.material_override.set_shader_parameter("presentation_opacity", 1.0 - eased)
	if fraction >= 1.0: finish_transition()

func finish_transition() -> void:
	if _reveal_seconds > 0:
		_reveal_seconds = 0.0
		if _placeholder: _placeholder.visible = false
	if material: material.set_shader_parameter("reveal_progress", 1.0)
	if is_instance_valid(_departing):
		_departing.free()
		_departing = null
	_transition_active = false
	if panel and geometry == Geometry.Geometry.FLAT: _apply_flat_pose()
	if _placeholder: _placeholder.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation), Vector3.ZERO)
	if _placeholder_material: _placeholder_material.set_shader_parameter("presentation_opacity", 1.0)
	if material: material.set_shader_parameter("presentation_opacity", 0.0 if _presentation_pending or (loading and placeholder_visible()) else 1.0)

## Conversion and automatic effects must agree before choosing the final display source.
func _presentation_effects_ready() -> bool:
	if animation.depth_mode: return true # Motion stays visible while its realtime model prepares.
	if depth_requested and (_depth_busy or _depth_rebuild_seconds > 0): return false
	if depth_requested and depth_error.is_empty():
		if not depth_enabled: return false
		if Methods.supports(platform, "prepare_photo_3d") and not _valid_cached_depth(_display_depth_data): return false
	if (auto_portrait and _portrait_auto_due and can_portrait()) or (portrait_requested and not portrait_enabled): return false
	if not auto_portrait and spatial_preferred and spatial_error.is_empty() and can_spatial(): return false
	return true

func _finish_presentation() -> void:
	_presented_us = Time.get_ticks_usec()
	# Selection to final picture: the wait the reader actually sees.
	DiagnosticLog.record("photo_presented", {"index":index, "request":_display_request, "depth":depth_enabled,
		"magazine":magazine.active(), "wait_ms":Time.get_ticks_msec() - _loading_started_ms})
	_presentation_pending = false
	_placeholder.visible = false
	_reveal_seconds = 0.0
	material.set_shader_parameter("reveal_progress", 1.0)
	material.set_shader_parameter("presentation_opacity", 1.0)
	slideshow.present()
	_remember_last_mode()
	changed.emit()

func _process_presentation() -> void:
	if not _presentation_pending or loading or not panel.visible or _transition_active: return
	if spatial_requested:
		if _spatial.prepared:
			_finish_presentation()
			_process_spatial()
		return
	if not _presentation_effects_ready(): return
	var source := _layer_source()
	# The layer path finishes only after upload AND successful submission, under the cover.
	if _layer_eligible(true) and _origin() != null and not source.is_empty() and source.image != null: return
	_ensure_full_texture()
	_finish_presentation()

func set_flat_world_pose(pose: Transform3D) -> void:
	_set_flat_world_pose(pose, true)

func apply_focus_world_pose(pose: Transform3D) -> void:
	# Animation reapplies a world-stable pose without recapturing a turned head's offset.
	_set_flat_world_pose(pose, false)

func _set_flat_world_pose(pose: Transform3D, remember_viewing: bool) -> void:
	pose = constrain_layout_pose(pose)
	var previous := flat_pose
	super.set_flat_world_pose(pose)
	if geometry == 0 and remember_viewing: gallery.remember_focus_pose(pose)
	var movement := flat_pose * previous.affine_inverse()
	slideshow.move(movement)
	if is_instance_valid(_departing):
		_departing_pose = movement * _departing_pose
	if _placeholder:
		_placeholder.transform = flat_pose * Transform3D(Basis(Vector3.FORWARD, _placeholder_rotation), Vector3.ZERO)
	if _transition_active:
		_update_transition()
	elif _swipe_offset != 0.0:
		preview_navigation(_swipe_offset)
	if _detail and inspect:
		_detail.transform = movement * _detail.transform

func _apply_geometry() -> void:
	if geometry != Geometry.Geometry.FLAT:
		slideshow.clear(); finish_transition()
	var aspect := _size.x / maxf(_size.y, 1.0) * ((2.0 if top_bottom else 0.5) if stereo_sbs else 1.0)
	slideshow.update_mapping(aspect)
	super._apply_geometry()
	if not _detail_material: return
	# Show 3D only in its final form: while the generated pair is on its way, the bare depth warp would
	# open holes around the subject that the pair then fills (a visible, dizzying step). Keep the flat
	# photo until the pair is on the layer or in the shader; the layer's pair still needs the depth map
	# for its feathered edge, and a depth result without a pair keeps the warp.
	var pair_pending := _display_depth_data.has("stereo_image") and _stereo_texture == null and not _layer_key.begins_with("stereo:")
	for target in [material, _detail_material]:
		target.set_shader_parameter("source_size", _size)
		target.set_shader_parameter("video_geometry", geometry)
		target.set_shader_parameter("stereo_sbs", stereo_sbs)
		target.set_shader_parameter("top_bottom", top_bottom)
		target.set_shader_parameter("swap_eyes", swap_eyes)
		target.set_shader_parameter("fisheye_fov", float(fisheye_fov))
		target.set_shader_parameter("pano_rect", Info.panorama_rect(_metadata))
		target.set_shader_parameter("native_stereo", bool(_metadata.get("native_stereo", false)))
		target.set_shader_parameter("spatial_disparity", clampf(float(_metadata.get("spatial_disparity", 0)), -1.0, 1.0))
		target.set_shader_parameter("photo_depth", depth_enabled and not _rotation_preview and not pair_pending and not stereo_sbs and geometry == Geometry.Geometry.FLAT)
		target.set_shader_parameter("depth_strength", depth_strength)
		target.set_shader_parameter("depth_convergence", DepthPosition.convergence(depth_position))
		target.set_shader_parameter("depth_texture", _depth_texture)
		target.set_shader_parameter("depth_rect", _depth_rect)
		target.set_shader_parameter("motion_depth", animation.depth_mode)
		var angle := deg_to_rad(screen_rotation)
		target.set_shader_parameter("depth_shift_axis", Vector2(cos(angle), -sin(angle) * _size.x / maxf(_size.y, 1.0)) if animation.depth_mode else Vector2.RIGHT)
		target.set_shader_parameter("photo_stereo", depth_enabled and not _rotation_preview and _stereo_texture != null and not stereo_sbs and geometry == Geometry.Geometry.FLAT)
		target.set_shader_parameter("stereo_texture", _stereo_texture)
		target.set_shader_parameter("portrait_enabled", portrait_enabled and not _rotation_preview)
		target.set_shader_parameter("portrait_texture", _portrait_texture)
		target.set_shader_parameter("generated_size", Vector2(_stereo_texture.get_width() / 2.0, _stereo_texture.get_height()) if _stereo_texture else Vector2.ONE)
	_update_inspect()

func set_projection(value: int) -> void:
	if magazine.active(): return
	if spatial_requested: set_spatial(false, true)
	if portrait_requested or auto_portrait: set_portrait(false)
	if value not in [0, 1, 2, 3]: return
	if value != geometry: _unlock_mode()
	geometry = value
	screen_rotation = float(_image_rotations.get(local_uri, 0.0)) if value == 0 else 0.0
	if value != 0: _suspend_conversion()
	elif auto_depth and not stereo_sbs: set_depth(true)
	reset_view(); _apply_geometry(); _remember_mode(); changed.emit()

func cycle_projection() -> void:
	set_projection((geometry + 1) % 4)

func set_stereo_layout(layout: int) -> void:
	if magazine.active(): return
	if spatial_requested: set_spatial(false, true)
	if portrait_requested or auto_portrait: set_portrait(false)
	if layout not in [0, 1, 2]: return
	if layout != current_lock().layout: _unlock_mode()
	stereo_sbs = layout != 0; top_bottom = layout == 2
	if stereo_sbs: _suspend_conversion()
	elif auto_depth and not magazine.active() and geometry == 0: set_depth(true)
	_apply_geometry(); _remember_mode(); changed.emit()

func toggle_stereo() -> void:
	set_stereo_layout(0 if stereo_sbs else 1)

func toggle_eye_order() -> bool:
	if spatial_requested: set_spatial(false, true)
	if not stereo_sbs: return false
	swap_eyes = not swap_eyes; _apply_geometry(); _remember_mode(); changed.emit(); return true

func set_fisheye_fov(value: int) -> void:
	if value not in FISHEYE_FOVS or value == fisheye_fov: return
	_unlock_mode()
	fisheye_fov = value; _apply_geometry(); _remember_mode(); changed.emit()

func _remember_mode() -> void:
	if local_uri.is_empty(): return
	_last_mode_dirty = reuse_last_mode
	_remember_last_mode()
	mode_memory.remember(local_uri, {"geometry": geometry, "stereo_sbs": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes,
		"fisheye_fov": fisheye_fov, "profile": "320x320", "alpha_requested": false})
	mode_memory.save()

func current_lock() -> Dictionary:
	return {"geometry": geometry, "layout": 2 if top_bottom else (1 if stereo_sbs else 0),
		"depth": depth_requested and not stereo_sbs, "fisheye_fov": fisheye_fov}

func toggle_mode_lock() -> void:
	if reuse_last_mode: set_reuse_last_mode(false)
	var current := current_lock()
	mode_lock = {} if mode_lock == current else current
	mode_lock_changed.emit(mode_lock.duplicate())
	changed.emit()

func load_last_mode_preferences(settings: ConfigFile) -> void:
	var enabled: Variant = settings.get_value("photo", "reuse_last_mode", false)
	reuse_last_mode = enabled is bool and enabled
	last_mode = LastMode.clean(settings.get_value("photo", "last_mode", {}))
	if reuse_last_mode: mode_lock = {}

func set_reuse_last_mode(enabled: bool) -> void:
	if reuse_last_mode == enabled: return
	reuse_last_mode = enabled
	_last_mode_dirty = enabled
	if enabled:
		_unlock_mode()
		_remember_last_mode()
	reuse_last_mode_changed.emit(enabled)
	changed.emit()

func _remember_last_mode() -> void:
	if not _last_mode_dirty or not reuse_last_mode or loading or _presentation_pending or _transition_active or _reveal_seconds > 0 \
		or pending_index >= 0 or _texture == null or _display_request <= 0 or _request != _display_request \
		or index < 0 or index >= queue.size() or str(queue[index].uri) != local_uri or not error.is_empty() or not panel.visible: return
	if gallery.mode in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS] and (gallery.focus != index or gallery.returning or gallery.progress < 1): return
	_last_mode_dirty = false
	# Reading, captured spatial sources and retained frames have their own display rules.
	if archive_mode or magazine.active() or _metadata.get("native_stereo", false) or queue[index].has("retained_source"): return
	var current := current_lock()
	current.swap_eyes = swap_eyes
	current = LastMode.clean(current)
	if current.is_empty() or current == last_mode: return
	last_mode = current
	last_mode_changed.emit(last_mode.duplicate())

func load_mode_lock(value: Variant) -> void:
	mode_lock = {}
	if not value is Dictionary or not value.get("depth") is bool: return
	for key in ["geometry", "layout", "fisheye_fov"]:
		var number: Variant = value.get(key)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floorf(float(number)): return
	if int(value.geometry) not in [0, 1, 2, 3] or int(value.layout) not in [0, 1, 2] or int(value.fisheye_fov) not in FISHEYE_FOVS: return
	mode_lock = {"geometry": int(value.geometry), "layout": int(value.layout),
		"depth": bool(value.depth) and int(value.layout) == 0 and int(value.geometry) == 0, "fisheye_fov": int(value.fisheye_fov)}

func toggle_inspect() -> void:
	if _presentation_pending: return
	if spatial_requested: set_spatial(false, true)
	if portrait_requested: return
	if inspect:
		close_inspect()
		return
	inspect = true
	magnification = inspect_magnification
	_place_detail()
	_update_inspect(); changed.emit()

func close_inspect() -> void:
	inspect = false; magnification = 1.0; crop_center = Vector2(0.5, 0.5)
	hide_inspect_pointer()
	_update_inspect(); changed.emit()

func _place_detail() -> void:
	var pose := view_camera.global_transform if view_camera else Transform3D(Basis(), Vector3(0, 1.6, 0))
	var local: Transform3D = detail_placement if detail_placement is Transform3D else Transform3D(Basis(), Vector3(0.42, 0.22, -1.4))
	_detail.global_transform = pose * local
	_detail_direction = panel.global_basis.inverse() * -pose.basis.z

func reset_view(reset_adjustments: bool = true) -> void:
	super.reset_view(reset_adjustments)
	inspect = false; magnification = 1.0; crop_center = Vector2(0.5, 0.5)
	if _detail_material: _update_inspect()

## The saved default is a parameter; a visible detail window keeps its opening value.
func set_inspect_magnification(value: float) -> void:
	if not is_finite(value): return
	inspect_magnification = clampf(value, INSPECT_LIMITS.x, INSPECT_LIMITS.y)
	changed.emit()

func zoom_view(_amount: float) -> void:
	if not inspect: toggle_inspect()

## The right stick scales the whole flat photo, including its mesh and corner hit targets.
## Inspect uses a separate detail window for both flat photos and panoramas.
func zoom_picture(amount: float) -> void:
	if inspect: return
	if gallery.overview():
		gallery.set_view_scale(gallery.view_scale * exp(amount * 2.0)); changed.emit(); return
	if geometry != Geometry.Geometry.FLAT:
		zoom_view(amount)
		return
	set_screen_scale(screen_scale * exp(amount * 2.0))
	changed.emit()

func inspect_ray(origin: Vector3, direction: Vector3, _drag: bool = false) -> bool:
	if not inspect or not panel.visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001: return false
	if geometry == Geometry.Geometry.FLAT:
		var uv := _inspect_uv(origin, direction)
		if not Rect2(0, 0, 1, 1).has_point(uv): return false
		crop_center = uv
	else:
		_detail_direction = (panel.global_basis.inverse() * direction).normalized()
	_update_inspect(); return true

func hide_inspect_pointer() -> void:
	if _inspect_line: _inspect_line.visible = false
	if _inspect_dot: _inspect_dot.visible = false

## The same ray selects a sample and shows its endpoint, including for optical hands.
func update_inspect_pointer(origin: Vector3, direction: Vector3, hand: String = "right_hand") -> bool:
	if not inspect or not panel.visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		hide_inspect_pointer()
		return false
	var ray := direction.normalized()
	var hit: bool = inspect_ray(origin, ray)
	var endpoint := origin + ray * 4.0
	if hit and geometry == Geometry.Geometry.FLAT:
		var uv := _inspect_uv(origin, ray)
		var x := (uv.x - 0.5) * _flat.size.x
		var y := (0.5 - uv.y) * _flat.size.y
		var local := surface_point(Vector3(x, y, 0))
		endpoint = panel.to_global(local)
	elif hit:
		# Intersect the immersive sphere to place the endpoint on the displayed picture.
		var start := panel.to_local(origin)
		var delta := panel.global_basis.inverse() * ray
		var b := start.dot(delta)
		var discriminant := b * b - (start.length_squared() - SPHERE_RADIUS * SPHERE_RADIUS)
		if discriminant >= 0.0:
			var distance := -b + sqrt(discriminant)
			if distance > 0.0: endpoint = origin + ray * distance
	_inspect_pointer_material.albedo_color = Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
	var mesh: ImmediateMesh = _inspect_line.mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_add_vertex(to_local(origin))
	mesh.surface_add_vertex(to_local(endpoint))
	mesh.surface_end()
	_inspect_line.visible = true
	_inspect_dot.visible = hit
	if hit:
		_inspect_dot.global_position = endpoint
		var distance := view_camera.global_position.distance_to(endpoint) if view_camera else origin.distance_to(endpoint)
		_inspect_dot.scale = Vector3.ONE * clampf(distance / 2.0, 0.3, 12.0)
	return hit

func _inspect_uv(origin: Vector3, direction: Vector3) -> Vector2:
	var hit: Variant = screen_hit(origin, direction)
	return surface_uv(panel.to_local(hit)) if hit != null else Vector2(-1, -1)

func pan_content(step: Vector2) -> void:
	if not inspect or geometry != 0: return
	crop_center += Vector2(step.x, -step.y) / magnification
	_update_inspect()

## Derivative of the viewer's projected position (x/depth, -y/depth).
## The camera's focal length cancels when comparing the picture and detail window.
static func _projected_tangent(point: Vector3, tangent: Vector3) -> Vector2:
	var depth := maxf(0.01, -point.z)
	return Vector2(tangent.x + point.x * tangent.z / depth, -tangent.y - point.y * tangent.z / depth) / depth

## At 1x, a source detail has the same apparent size in the window and original.
## Use actual mesh dimensions, position and tangent, rather than a fraction of the file.
func _flat_crop_mapping(at: Vector2) -> Vector4:
	var eye := view_camera.global_transform if view_camera else Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var view := eye.affine_inverse()
	var x := (at.x - 0.5) * _flat.size.x
	var plane := Vector3(x, (0.5 - at.y) * _flat.size.y, 0)
	var local := surface_point(plane)
	var tangent_u := surface_tangent(plane, Vector3(_flat.size.x, 0, 0))
	var source := view * (panel.global_transform * local)
	var source_u := _projected_tangent(source, view.basis * panel.global_basis * tangent_u)
	var source_v := _projected_tangent(source, view.basis * panel.global_basis * surface_tangent(plane, Vector3(0, -_flat.size.y, 0)))
	var window := view * _detail.global_position
	var size: Vector2 = _detail.mesh.size
	var window_u := _projected_tangent(window, view.basis * _detail.global_basis * Vector3(size.x, 0, 0))
	var window_v := _projected_tangent(window, view.basis * _detail.global_basis * Vector3(0, -size.y, 0))
	var determinant := source_u.x * source_v.y - source_v.x * source_u.y
	if absf(determinant) < 0.00000001 or source.z >= -0.01 or window.z >= -0.01:
		var ratio := maxf(0.01, absf(source.z)) / maxf(0.01, absf(window.z))
		return Vector4(size.x * ratio / _flat.size.x, 0, 0, size.y * ratio / _flat.size.y)
	var u := Vector2(window_u.x * source_v.y - source_v.x * window_u.y, source_u.x * window_u.y - window_u.x * source_u.y) / determinant
	var v := Vector2(window_v.x * source_v.y - source_v.x * window_v.y, source_u.x * window_v.y - window_v.x * source_u.y) / determinant
	return Vector4(u.x, v.x, u.y, v.y)

func _update_inspect() -> void:
	var mapping := Vector4(1, 0, 0, 1)
	if inspect and geometry == Geometry.Geometry.FLAT:
		# Recompute at the clamped centre too, since a curved picture changes its tangent.
		for _step in 2:
			mapping = _flat_crop_mapping(crop_center)
			var half := Vector2(absf(mapping.x) + absf(mapping.y), absf(mapping.z) + absf(mapping.w)) * (0.5 / magnification)
			# A tiny/distant picture may fit entirely inside the window at the true scale.
			# Centre it with outside margins; never enlarge it just to fill the window.
			half = half.min(Vector2(0.5, 0.5))
			crop_center = crop_center.clamp(half, Vector2.ONE - half)
	else:
		var half := Vector2.ONE * (0.5 / magnification)
		crop_center = crop_center.clamp(half, Vector2.ONE - half)
	material.set_shader_parameter("crop_center", Vector2(0.5, 0.5))
	material.set_shader_parameter("content_zoom", 1.0)
	_detail.visible = inspect and panel.visible
	if not _detail.visible: hide_inspect_pointer()
	_detail_zoom.text = "%.1f×" % magnification
	_detail_material.set_shader_parameter("detail_projection", geometry != Geometry.Geometry.FLAT)
	var detail_center := crop_center
	if geometry == Geometry.Geometry.FLAT and slideshow.locked():
		var transform_uv: Vector4 = slideshow.mapping
		var offset := crop_center - Vector2(0.5, 0.5)
		detail_center = Vector2(transform_uv.x * offset.x + transform_uv.y * offset.y, transform_uv.z * offset.x + transform_uv.w * offset.y) + Vector2(0.5, 0.5)
		mapping = Vector4(transform_uv.x * mapping.x + transform_uv.y * mapping.z, transform_uv.x * mapping.y + transform_uv.y * mapping.w,
			transform_uv.z * mapping.x + transform_uv.w * mapping.z, transform_uv.z * mapping.y + transform_uv.w * mapping.w)
	_detail_material.set_shader_parameter("crop_center", detail_center)
	_detail_material.set_shader_parameter("crop_aspect", Vector2(mapping.x, mapping.w))
	_detail_material.set_shader_parameter("crop_skew", Vector2(mapping.y, mapping.z))
	_detail_material.set_shader_parameter("content_zoom", magnification)
	var forward := _detail_direction.normalized()
	var right := forward.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.001: right = Vector3.RIGHT
	_detail_material.set_shader_parameter("detail_forward", forward)
	_detail_material.set_shader_parameter("detail_right", right)
	_detail_material.set_shader_parameter("detail_up", right.cross(forward).normalized())

func set_depth(enabled: bool) -> bool:
	if animation.available() and not portrait_requested and not spatial_requested:
		return animation.set_depth(enabled)
	if enabled: animation.freeze()
	if enabled and _metadata.get("magazine_unregistered", false): return false
	if spatial_requested: set_spatial(false, true)
	if not enabled and (portrait_requested or auto_portrait): set_portrait(false)
	if enabled and (_metadata.get("native_stereo", false) or stereo_sbs or geometry != 0 or not platform or _display_request <= 0): return false
	# The global viewing-mode choice survives conversion Off/On and photo navigation.
	if enabled != depth_requested: _unlock_mode()
	auto_depth = enabled
	depth_requested = enabled
	# Textures, or data whose textures the layer path makes only on demand.
	depth_enabled = enabled and (_depth_texture != null or _display_depth_data.has("image")) \
		and (not Methods.supports(platform, "prepare_photo_3d") or _stereo_texture != null or _display_depth_data.has("stereo_image"))
	if enabled and not _rotation_matches(_display_depth_data): depth_enabled = false
	depth_error = ""
	_spatial_auto_due=enabled
	if not enabled: _suspend_conversion()
	if enabled and (not depth_enabled or (Methods.supports(platform, "prepare_photo_3d") and
		 not _valid_cached_depth(_display_depth_data))) and not _depth_busy:
		_depth_busy = _prepare_depth(_display_request)
		if not _depth_busy: depth_error = "3D unavailable"
	_apply_geometry(); changed.emit(); return true

func _discard_native_depth(id: int) -> void:
	if id <= 0: return
	if _depth_thread and int(_depth_job.get("id", 0)) == id:
		_deferred_depth_clear_ids[id] = true
	elif Methods.supports(platform, "discard_photo_depth"):
		platform.discard_photo_depth(id)

func _on_prefetch_depth(id: int, payload: String) -> void:
	if id == 0 or id not in [_prefetch_depth_request, _promoted_depth_request]: return
	var info: Variant = JSON.parse_string(payload)
	if info is Dictionary and info.get("deferred", false):
		if id == _promoted_depth_request:
			_promoted_depth_request = 0; _prepare_depth(id)
		else:
			_prefetch_depth_request = 0; resource_budget.defer_work()
		return
	if _queue_depth_payload(id, payload, true): return
	_finish_depth(id, _read_depth(payload), true)

func _prepare_depth(id: int, background: bool = false) -> bool:
	if not _depth_source_allowed(id): return false
	var rotation := _stereo_rotation(_depth_index(id))
	if background:
		if Methods.supports(platform, "prepare_preloaded_photo_3d_view"): return bool(platform.prepare_preloaded_photo_3d_view(id, depth_strength, DepthPosition.convergence(depth_position), rotation))
		if Methods.supports(platform, "prepare_preloaded_photo_3d_rotated"): return bool(platform.prepare_preloaded_photo_3d_rotated(id, depth_strength, rotation))
		if rotation != 0: return false
		if Methods.supports(platform, "prepare_preloaded_photo_3d"): return bool(platform.prepare_preloaded_photo_3d(id, depth_strength))
		return Methods.supports(platform, "prepare_preloaded_photo_depth") and bool(platform.prepare_preloaded_photo_depth(id))
	if id == _promoted_depth_request and id != 0 and rotation == 0: return true
	_promoted_depth_request = 0
	render_cache.cancel()
	_cancel_depth_prefetch()
	_release_cache_for_foreground(id)
	_depth_rebuild_seconds = 0.0
	if Methods.supports(platform, "prepare_photo_3d_view"): return bool(platform.prepare_photo_3d_view(id, depth_strength, DepthPosition.convergence(depth_position), rotation))
	if Methods.supports(platform, "prepare_photo_3d_rotated"): return bool(platform.prepare_photo_3d_rotated(id, depth_strength, rotation))
	if rotation != 0: return false
	if Methods.supports(platform, "prepare_photo_3d"): return bool(platform.prepare_photo_3d(id, depth_strength))
	return Methods.supports(platform, "prepare_photo_depth") and bool(platform.prepare_photo_depth(id))

func _depth_source_allowed(id: int) -> bool:
	var target:=_depth_index(id)
	if target<0 or target>=queue.size(): return false
	if id==_display_request and not (id==_request and loading and pending_index>=0):
		return depth_requested and geometry==0 and not stereo_sbs and not _metadata.get("native_stereo",false) \
			and (not animation.available() or (animation.paused and not animation.depth_mode))
	var info: Dictionary=queue[target].get("photo_info",{})
	if not _pending_display.is_empty() and int(_pending_display.job.id)==id: info=_pending_display.result.info
	elif _prefetched.has(target): info=_prefetched[target].get("result",{}).get("info",_prefetched[target].get("info",info))
	return _requires_depth(target,info)

func _suspend_conversion() -> void:
	animation.stop_depth()
	# Keep the user's automatic 3D preference for the next compatible flat image.
	depth_requested=false; depth_enabled=false; depth_error=""; _depth_busy=false; _depth_rebuild_seconds=0
	_spatial_auto_due=false; _cancel_depth_prefetch()
	_depth_queue=_depth_queue.filter(func(job): return int(job.id)!=_display_request)
	if int(_incoming_depth_result.get("id",0))==_display_request: _incoming_depth_result={}
	_discard_native_depth(_display_request)

func _queue_depth_payload(id: int, payload: String, background: bool) -> bool:
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or not info.has("stereo_path"): return false
	if int(info.get("stereo_rotation", 0)) != _stereo_rotation(_depth_index(id)): return true
	# At most one queued result per source; pair loading and mip generation run off the frame thread.
	_depth_queue = _depth_queue.filter(func(job): return int(job.id) != id)
	_depth_queue.append({"id":id, "payload":payload, "background":background, "serial":_serial, "rotation":int(info.get("stereo_rotation", 0))})
	return true

func _process_depth_jobs() -> void:
	if _depth_thread and not _depth_thread.is_alive():
		var data: Dictionary = _depth_thread.wait_to_finish()
		_depth_thread = null
		var id := int(_depth_job.id)
		if (bool(_depth_job.background) or int(_depth_job.serial) == _serial) \
			and int(_depth_job.get("rotation", 0)) == _stereo_rotation(_depth_index(id)): _finish_depth(id, data, bool(_depth_job.background))
		_depth_job = {}
		if _deferred_depth_clear_ids.erase(id) and (id != _display_request or not depth_requested): _discard_native_depth(id)
		if _deferred_release_ids.erase(id) and id not in [_request, _display_request]: _release_photo(id)
	if _depth_thread: return
	while not _depth_queue.is_empty():
		var job: Dictionary = _depth_queue.pop_front()
		if bool(job.background):
			if int(job.id) not in [_prefetch_depth_request, _promoted_depth_request]: continue
		elif int(job.serial) != _serial or int(job.id) not in [_request, _display_request]: continue
		_depth_job = job
		_depth_thread = Thread.new()
		if _depth_thread.start(_read_depth.bind(str(job.payload))) != OK:
			_depth_thread = null; _finish_depth(int(job.id), {}, bool(job.background)); _depth_job = {}
		break

func _finish_depth(id: int, data: Dictionary, background: bool) -> void:
	if not _depth_source_allowed(id): return
	if not data.is_empty() and not _rotation_matches(data, _depth_index(id)): return
	if not data.is_empty(): data["source_id"] = id
	if background and id == _promoted_depth_request and id != 0: background = false
	if not background and id not in [_request, _display_request]: return
	if not background and id == _promoted_depth_request: _promoted_depth_request = 0
	if not background and data.has("strength") and (not is_equal_approx(float(data.strength), depth_strength) or not is_equal_approx(float(data.get("convergence", 0.35)), DepthPosition.convergence(depth_position))):
		_depth_busy = _prepare_depth(id)
		return
	if not background and data.has("strength"): _depth_rebuild_seconds = 0.0
	if background:
		if id != _prefetch_depth_request or id == 0: return
		_prefetch_depth_request = 0
		for target in _prefetched:
			var entry: Dictionary = _prefetched[target]
			if int(entry.id) != id: continue
			if data.is_empty(): entry["depth_failed"] = true
			elif _valid_cached_depth(data, int(target)) and resource_budget.policy.get("retain", false):
				entry["depth_data"] = data
				entry["depth_ready_us"] = Time.get_ticks_usec()
				_trim_depth_cache()
			else: _discard_native_depth(id)
			return
		return
	if id == _request and loading and _pending_display.is_empty():
		# The joined conversion can finish before the colour decoder. Keep its matching result.
		_incoming_depth_result = {"id": id, "data": data}
		return
	if not _pending_display.is_empty() and int(_pending_display.job.id) == id and int(_pending_display.serial) == _serial:
		if data.is_empty(): _fail_pending_depth(); return
		var pending := _pending_display; _pending_display = {}
		pending.result["depth_data"] = data
		_accept(pending.result, pending.job)
		return
	if id != _display_request: return
	_depth_busy = false
	if data.is_empty():
		depth_error = "3D unavailable"
		if portrait_requested: set_portrait(false, true)
		changed.emit(); return
	if portrait_requested:
		# Keep the visible colour/matte pair until both replacements share the latest strength.
		_portrait_pending_depth = data
		_request_portrait_mask()
		_apply_geometry(); changed.emit(); return
	_commit_depth_data(data)
	_apply_geometry(); changed.emit()

func _commit_depth_data(data: Dictionary) -> void:
	_display_depth_data = data.duplicate()
	_display_depth_data["source_id"] = _display_request
	if not _display_result.is_empty(): _display_result["depth_data"] = _display_depth_data
	_depth_rect = data.rect
	_use_depth_textures()
	depth_enabled = depth_requested and geometry == 0 and not stereo_sbs
	_spatial_auto_due=depth_enabled

func _on_depth(id: int, payload: String) -> void:
	if not _depth_source_allowed(id): return
	var info: Variant = JSON.parse_string(payload)
	if info is Dictionary and int(info.get("stereo_rotation", 0)) != _stereo_rotation(_depth_index(id)): return
	if info is Dictionary and info.get("deferred", false) and id in [_request, _display_request]:
		# Promotion races with the worker's pressure check. Foreground always gets a fresh try.
		_promoted_depth_request = 0; _depth_busy = _prepare_depth(id); return
	if _queue_depth_payload(id, payload, false): return
	_finish_depth(id, _read_depth(payload), false)

static func _read_depth(payload: String) -> Dictionary:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("state") != "ready": return {}
	var w := int(result.get("width", 0)); var h := int(result.get("height", 0))
	var rect: Variant = result.get("rect")
	# Accept the independent photo model and legacy cached/test depth, with bounded allocation.
	if Vector2i(w, h) not in [Vector2i(518, 518), Vector2i(252, 140)] or not rect is Array or rect.size() != 4: return {}
	for value in rect:
		if not (value is float or value is int) or not is_finite(float(value)): return {}
	if rect[0] < 0 or rect[1] < 0 or rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > 1.000001 or rect[1] + rect[3] > 1.000001: return {}
	if not FileAccess.file_exists(str(result.get("path", ""))): return {}
	var bytes := FileAccess.get_file_as_bytes(str(result.path))
	if bytes.size() != w * h * 4: return {}
	var depth := Image.create_from_data(w, h, false, Image.FORMAT_RF, bytes)
	var data := {"image": depth, "rect": Vector4(rect[0], rect[1], rect[2], rect[3]), "cache_bytes":int(result.get("cache_bytes", 0))}
	if result.has("stereo_path"):
		if not (result.get("stereo_strength") is float or result.get("stereo_strength") is int): return {}
		var strength := float(result.get("stereo_strength", -1))
		var plane: Variant = result.get("stereo_convergence", 0.35)
		if not (plane is float or plane is int) or not is_finite(float(plane)) or float(plane) < 0 or float(plane) > 1: return {}
		var sw := int(result.get("stereo_width", 0)); var sh := int(result.get("stereo_height", 0))
		if result.get("stereo_strategy", "") != "video_soft_shift_gpu" or not is_finite(strength) or strength < 0 or strength > 2 \
			or sw < 2 or sw % 2 != 0 or sw > 8192 or sh < 1 or sh > 4096 or sw * sh > 16 * 1024 * 1024: return {}
		var stereo := Image.new()
		if str(result.stereo_path).get_extension() == "rgba":
			# Raw RGBA rows straight from the GPU pair: no PNG encode on Android, no decode here.
			var pixels := FileAccess.get_file_as_bytes(str(result.stereo_path))
			if pixels.size() != sw * sh * 4: return {}
			stereo = Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, pixels)
		else:
			var header := Info.read_header(str(result.stereo_path))
			if header.is_empty() or int(header.width) != sw or int(header.height) != sh: return {}
			if stereo.load_png_from_buffer(FileAccess.get_file_as_bytes(str(result.stereo_path))) != OK or stereo.get_size() != Vector2i(sw, sh): return {}
		stereo.generate_mipmaps()
		var rotation := int(result.get("stereo_rotation", 0))
		if rotation not in [0, 90, 180, 270]: return {}
		data.merge({"stereo_image":stereo, "strength":strength, "strategy":str(result.stereo_strategy), "rotation":rotation, "convergence":float(plane)})
	return data

func set_depth_position(value: Variant) -> bool:
	if _metadata.get("native_stereo", false) or portrait_requested or stereo_sbs or geometry != 0: return false
	var next := DepthPosition.normalize(value)
	if is_equal_approx(next, depth_position): return true
	depth_position = next
	render_cache.cancel()
	for entry in _prefetched.values(): entry.erase("depth_failed")
	if material: material.set_shader_parameter("depth_convergence", DepthPosition.convergence(depth_position))
	if _detail_material: _detail_material.set_shader_parameter("depth_convergence", DepthPosition.convergence(depth_position))
	if depth_requested:
		if spatial_requested: set_spatial(false, true)
		if not animation.depth_mode and Methods.supports(platform, "prepare_photo_3d"): _depth_rebuild_seconds = 0.15
		_spatial_auto_due = not animation.depth_mode
	changed.emit()
	return true

func cycle_depth_strength() -> void:
	set_depth_strength(0.5 if depth_strength >= DepthStrength.PHOTO_MAX else depth_strength + 0.5)

func set_depth_strength(value: float) -> bool:
	if _metadata.get("native_stereo", false): return false
	var strength := DepthStrength.clamp_value(value, DepthStrength.PHOTO_MAX)
	# Zero disparity keeps the cutout active; the portrait button remains the explicit exit.
	if strength <= 0.0 and not portrait_requested: return set_depth(false)
	if stereo_sbs or geometry != 0 or not platform or _display_request <= 0: return false
	if is_equal_approx(strength,depth_strength) and depth_requested: return true
	if spatial_requested: set_spatial(false, true)
	if portrait_requested: _invalidate_portrait_mask()
	depth_strength = strength
	render_cache.cancel()
	for entry in _prefetched.values():
		entry.erase("depth_failed"); entry.erase("portrait_failed")
	if not animation.depth_mode and Methods.supports(platform, "update_photo_3d_strength"):
		platform.update_photo_3d_strength(depth_strength)
	if not depth_requested: return set_depth(true)
	# Reuse cached depth/person inference; coalesce slider changes before warping both eyes.
	if not portrait_requested:
		material.set_shader_parameter("depth_strength", depth_strength)
		_detail_material.set_shader_parameter("depth_strength", depth_strength)
	if not animation.depth_mode and Methods.supports(platform, "prepare_photo_3d"): _depth_rebuild_seconds = 0.15
	_spatial_auto_due=not portrait_requested and not animation.depth_mode
	changed.emit()
	return true

func spatial_metadata() -> Dictionary:
	if magazine.active(): return {}
	return SpatialCapture.normalize(_metadata.get("spatial_metadata", {})) if _metadata.get("native_stereo", false) else {}

func spatial_fov_scale() -> float:
	var capture := spatial_metadata()
	var selected: bool = gallery.mode in [Gallery.Layout.SINGLE, Gallery.Layout.SIDES] or (gallery.focus == index and gallery.progress >= 1 and not gallery.returning)
	if not capture.has("horizontal_fov_degrees") or _texture == null or loading or not selected \
		or geometry != Geometry.Geometry.FLAT or not stereo_sbs or top_bottom or portrait_requested or inspect: return -1.0
	return capture_fov_scale(float(capture.horizontal_fov_degrees), PHOTO_SCALE_LIMITS)

func match_spatial_fov() -> bool:
	var scale := spatial_fov_scale()
	if scale <= 0.0: return false
	set_screen_curve(0.0)
	set_screen_scale(scale)
	changed.emit()
	return true

func can_save_pictures() -> bool:
	return _texture != null and not loading and local_uri.begins_with("file://") and source_location.has("online_source") and Methods.supports(platform,"panorama_save_pictures")
func pictures_status() -> Dictionary:
	if not can_save_pictures(): return {}
	var report: Variant=JSON.parse_string(platform.panorama_save_status())
	return report if report is Dictionary and report.get("source","")==local_uri else {}
func save_to_pictures() -> bool:
	if not can_save_pictures() or pictures_status().get("state","") in ["saving","saved"]: return false
	return bool(platform.panorama_save_pictures(local_uri,display_name,geometry==Geometry.Geometry.EQUIRECT_360 and not stereo_sbs))
func snapshot() -> Dictionary:
	var position := pending_index if pending_index >= 0 else index
	var title := str(queue[position].get("title", "")) if position >= 0 and position < queue.size() else display_name
	var shown_size: Vector2=Vector2(panorama_tiles.dimensions) if panorama_tiles.active() else _size
	var progress: Dictionary = _loading_status.duplicate()
	progress.elapsed_ms = Time.get_ticks_msec() - _loading_started_ms
	# A ready autoplay picture held for one frame under the old one is not loading or preparing 3D.
	var preparing := _presentation_pending and not (slideshow.waiting and _presentation_effects_ready())
	return {"autoplay_enabled":autoplay.enabled,"autoplay_interval":autoplay.interval,"autoplay_effect":autoplay.effect,"ground_vertical":ground_vertical,"cache_each":cache_each,"animated":animation.available(),"animation_paused":animation.paused,"animation_ended":animation.ended,"animation_failed":animation.failed,"raw_preview":_metadata.get("raw_preview",false),
		"spatial_preferred":spatial_preferred,"spatial_requested":spatial_requested,"spatial_ready":_spatial.prepared if is_instance_valid(_spatial) else false,"spatial_available":can_spatial(),"spatial_error":spatial_error,
		"spatial_report":_spatial.report if is_instance_valid(_spatial) else {},"has_image": _texture != null, "loading": loading or preparing, "loading_caption": Loading.caption(progress) if loading else "", "placeholder": placeholder_visible(), "preparing_depth": preparing or not _pending_display.is_empty(), "title": title, "index": position, "count": queue.size(),
		"magazine_single": magazine.single(position), "magazine_pages": magazine.count(position) if magazine.active() else 1, "magazine_rtl": magazine.right_to_left,
		"archive_mode": archive_mode, "source_uri": local_uri, "layout": gallery.mode, "gallery_overview": gallery.overview(), "wall_rows": gallery.wall_rows, "gallery_scale": gallery.view_scale, "gallery_distance": gallery.view_distance, "gallery_swapping": gallery._swap_phase != 0, "gallery_focus": gallery.focus, "directory_loading": directory.loading, "directory_error": directory_error, "queue_complete": queue_complete,
		"can_save_pictures":can_save_pictures(), "pictures_save":pictures_status(),
		"can_background": can_background(), "background_issue":background_issue(), "panorama_detail_error": panorama_tiles.error,
		"can_previous": (position > 0) if magazine.active() else queue.size() > 1 and (((geometry == Geometry.Geometry.FLAT or gallery.mode != 0) and queue_complete) or position > 0),
		"can_next": (position >= 0 and magazine.target(1) < queue.size()) if magazine.active() else queue.size() > 1 and (((geometry == Geometry.Geometry.FLAT or gallery.mode != 0) and queue_complete) or (position >= 0 and position < queue.size() - 1)),
		"geometry": geometry, "stereo": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes, "fisheye_fov": fisheye_fov, "mode_lock": mode_lock.duplicate(), "reuse_last_mode": reuse_last_mode,
		"inspect": inspect, "zoom": magnification, "inspect_magnification": inspect_magnification,
		"screen_distance": screen_distance, "screen_scale": screen_scale, "edge_feather_strength": edge_feather_strength,
		"portrait_requested": portrait_requested, "portrait_enabled": portrait_enabled, "portrait_available": can_portrait(), "portrait_error": portrait_error,
		"depth_requested": depth_requested, "depth_enabled": depth_enabled, "animation_depth":animation.depth_stats if animation.depth_mode else {},
		"depth_available": geometry==0 and not stereo_sbs and platform != null and not _metadata.get("magazine_unregistered", false) and not _metadata.get("native_stereo", false), "native_stereo": not magazine.active() and _metadata.get("native_stereo", false), "depth_strength": depth_strength, "depth_position": depth_position, "depth_error": depth_error,
		"spatial_metadata": spatial_metadata(), "spatial_fov_available": spatial_fov_scale() > 0.0,
		"stereo_strategy":_display_depth_data.get("strategy", "inverse_shader"), "stereo_ready":_stereo_texture != null,
		"render_strength":_display_depth_data.get("strength", depth_strength),
		"source_size": "%d × %d" % [int(shown_size.x), int(shown_size.y)], "error": error, "screen_curve": screen_curve}

func can_background() -> bool:
	return background_issue().is_empty()

func background_issue() -> String:
	var rules = preload("res://scripts/panorama_background_rules.gd")
	if loading: return rules.LOADING
	if not error.is_empty(): return rules.READ
	if _texture == null or _size.x <= 0 or _size.y <= 0: return rules.OPEN
	if _metadata.get("raw_rgba", false): return rules.EXPORT
	if not Info.panorama_rect(_metadata).is_equal_approx(Vector4(0,0,1,1)): return rules.CROP
	if not rules.size_issue(_size).is_empty(): return rules.DIMENSIONS
	if geometry not in [1,3]:
		return rules.PROJECTION if rules.source_supported(_size,3,stereo_sbs,top_bottom) or rules.source_supported(_size,1,stereo_sbs,top_bottom) else rules.RATIO
	if not rules.source_supported(_size,geometry,stereo_sbs,top_bottom): return rules.LAYOUT
	return ""

func can_spatial() -> bool:
	if not is_instance_valid(_spatial) or _texture==null or loading or not error.is_empty() or geometry!=0 or portrait_requested or inspect \
		or _depth_busy or _depth_rebuild_seconds>0 or gallery.overview(): return false
	if bool(_metadata.get("native_stereo",false)):
		return Methods.supports(platform,"prepare_photo_scene_depth")
	# Plain 2D never starts a second conversion. Reuse the completed conversion at this strength.
	return not stereo_sbs and depth_requested and depth_enabled and _display_depth_data.has("image") \
		and (not Methods.supports(platform,"prepare_photo_3d") or (_display_depth_data.has("stereo_image") \
		and is_equal_approx(float(_display_depth_data.get("strength",-1)),depth_strength)))

func _maybe_start_spatial() -> void:
	if auto_portrait: return
	if not _spatial_auto_due or not spatial_preferred or spatial_requested or not spatial_error.is_empty(): return
	if loading or _transition_active or _reveal_seconds>0 or _depth_busy or _depth_rebuild_seconds>0: return
	if not bool(_metadata.get("native_stereo",false)) and not depth_requested:
		_spatial_auto_due=false; return
	if can_spatial(): set_spatial(true, true)

func set_spatial_mode(enabled: bool, enable_conversion: bool = false) -> bool:
	if geometry!=0 or loading or _texture==null or portrait_requested or gallery.overview(): return false
	set_portrait(false)
	if not enabled:
		set_spatial(false)
		spatial_error=""
		# Native static mode uses the captured SBS pair, with no mono conversion or strength change.
		if enable_conversion and not bool(_metadata.get("native_stereo",false)) and not depth_requested and not set_depth(true): return false
		changed.emit(); return true
	spatial_preferred=true; spatial_error=""; _spatial_auto_due=true
	if not bool(_metadata.get("native_stereo",false)) and not depth_requested:
		if not set_depth(true): changed.emit(); return false
	_maybe_start_spatial()
	changed.emit(); return true

func set_spatial(enabled: bool, automatic: bool = false) -> bool:
	if enabled: animation.freeze()
	if enabled and not spatial_requested and not can_spatial(): return false
	if not automatic: spatial_preferred=enabled
	_spatial_auto_due=false
	if enabled == spatial_requested: return true
	_spatial_token+=1; _spatial_waiting=false; spatial_error=""
	if not enabled:
		if Methods.supports(platform,"cancel_photo_scene_depth"): platform.cancel_photo_scene_depth(_display_request,_spatial_token-1)
		spatial_requested=false; _spatial.clear()
		_refresh_rotated_depth()
		material.set_shader_parameter("spatial_hidden",false)
		set_screen_curve(_spatial_curve); _apply_geometry(); changed.emit(); return true
	finish_transition(); close_inspect(); _pause_prefetch()
	_spatial_curve=screen_curve; set_screen_curve(0)
	spatial_requested=true; _hide_layer(); _upload={}; _apply_geometry()
	if _display_depth_data.has("image") and not bool(_metadata.get("native_stereo",false)):
		_start_spatial(_display_depth_data)
	else:
		_spatial_waiting=bool(platform.prepare_photo_scene_depth(_display_request,_spatial_token))
		if not _spatial_waiting: set_spatial(false, true); spatial_error="Spatial view unavailable"
	changed.emit(); return spatial_requested

func _on_spatial_depth(id: int, payload: String) -> void:
	var result: Variant=JSON.parse_string(payload)
	if not result is Dictionary or not spatial_requested or not _spatial_waiting or int(result.get("scene_token",0))!=_spatial_token or id!=_display_request: return
	_spatial_waiting=false
	var data:=_read_depth(payload)
	if data.is_empty():
		set_spatial(false, true); spatial_error="Spatial view unavailable"; changed.emit(); return
	_start_spatial(data)

func _start_spatial(data: Dictionary) -> void:
	var source: Image=_full_image if _full_image!=null else _texture.get_image()
	if _display_result.has("image"): source=_display_result.image
	var eye:=panel.global_transform.affine_inverse()*view_camera.global_position if view_camera else Vector3(0,0,screen_distance)
	var separation:=0.064
	var xr:=XRServer.primary_interface
	if xr and xr.is_initialized() and xr.get_view_count()>=2:
		var measured: float=xr.get_transform_for_view(0,Transform3D.IDENTITY).origin.distance_to(xr.get_transform_for_view(1,Transform3D.IDENTITY).origin)
		if measured>=0.045 and measured<=0.085: separation=measured
	if bool(_metadata.get("native_stereo",false)):
		var right:=panel.global_basis.inverse()*(view_camera.global_basis.x if view_camera else Vector3.RIGHT)
		eye-=right*separation*0.5
	_spatial.begin(source,data.image,data.rect,eye,_flat.size,bool(_metadata.get("native_stereo",false)),
		1.0, # Fixed spatial relief for both inputs, independent of the original SBS slider.
		true,separation,0.35 if bool(_metadata.get("native_stereo",false)) else DepthPosition.convergence(depth_position))

func _spatial_completed() -> void:
	if not spatial_requested: return
	if not _spatial.error.is_empty():
		var failure: String=_spatial.error
		set_spatial(false, true); spatial_error=failure
	changed.emit()

func _process_spatial() -> void:
	if not spatial_requested: return
	if loading or geometry!=0 or portrait_requested or inspect or gallery.overview() \
		or (not bool(_metadata.get("native_stereo",false)) and (not depth_requested or not depth_enabled)):
		set_spatial(false, true); return
	if not _spatial.prepared: return
	if _presentation_pending:
		_spatial.visible = false
		return
	var eye:=panel.global_transform.affine_inverse()*view_camera.global_position if view_camera else Vector3(0,0,screen_distance)
	_spatial.sync(panel.transform,_flat.size,eye,material.render_priority)
	_spatial.visible=_spatial.visible and panel.visible
	material.set_shader_parameter("spatial_hidden",_spatial.visible and _spatial.coverage>0.999)

func background_source() -> Dictionary:
	return {"path": _metadata.get("path", ""), "orientation": _metadata.get("orientation", 1),
		"geometry": geometry, "stereo": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes} if can_background() else {}

## Cancel queued/preloaded files from a removed volume while keeping an unrelated displayed photo.
func release_storage(volume: Dictionary) -> bool:
	var volumes := preload("res://scripts/storage_volume.gd")
	if not volumes.contains_uri(volume, local_uri) and not queue.any(func(item): return volumes.contains_uri(volume, str(item.get("uri", "")))):
		return false
	var remaining: Array[Dictionary] = []
	for item in queue:
		if not volumes.contains_uri(volume, str(item.get("uri", ""))): remaining.append(item)
	if volumes.contains_uri(volume, local_uri) or local_uri.is_empty():
		close_image()
		queue = remaining
		return true
	finish_transition()
	_cache_epoch += 1; _serial += 1
	_pause_prefetch()
	for target in _prefetched.keys(): _drop_prefetch(target)
	for entry in _recent_files.values(): _release_photo(int(entry.id), true)
	_recent_files.clear(); _prefetch_failed.clear()
	_prefetch_decode = {}; _next_decode = {}; _pending_display = {}
	_promoted_depth_request = 0; _incoming_depth_result = {}
	_depth_queue.assign(_depth_queue.filter(func(job): return int(job.id) == _display_request))
	if _request > 0 and _request != _display_request: _release_photo(_request, true)
	_request = _display_request; pending_index = -1; loading = false
	_restore_display()
	gallery.clear(); directory.cancel(); _directory_result = {}
	queue = remaining; index = -1
	for target in queue.size():
		if str(queue[target].uri) == local_uri: index = target; break
	changed.emit()
	return false

func _select_gallery_item(target: int) -> void:
	index = target; pending_index = -1; error = ""
	local_uri = str(queue[target].uri); display_name = str(queue[target].get("title", local_uri.get_file()))
	_metadata = queue[target].get("photo_info", gallery.previews.metadata(local_uri)).duplicate()
	var mode := _resolved_mode(target, _metadata)
	geometry = int(mode.geometry); stereo_sbs = bool(mode.stereo_sbs)
	top_bottom = stereo_sbs and bool(mode.top_bottom); swap_eyes = bool(mode.swap_eyes); fisheye_fov = int(mode.fisheye_fov)
	_apply_geometry()

func suspend_gallery_photo() -> void:
	if gallery.mode not in [Gallery.Layout.WALL, Gallery.Layout.FRAGMENTS]: return
	var target := pending_index if pending_index >= 0 else index
	_release_full_photo(false)
	if target >= 0 and target < queue.size(): _select_gallery_item(target)
	changed.emit()

## Full-size colour, generated eyes and native leases belong only to the expanded photo.
## Album identity, the directory scan and bounded preview cards have independent lifetimes.
func _release_full_photo(release_runtime: bool = true, release_reading_cache: bool = true) -> void:
	slideshow.clear()
	render_cache.cancel(); _display_proxy = null
	_cached_render_active = false
	resource_budget.stop()
	_portrait_switching = false
	_presentation_pending = false
	_presentation_layer_failed = false
	if release_reading_cache: reading_cache.clear()
	magazine.cancel()
	if spatial_requested: set_spatial(false, true)
	_spatial_auto_due = false; spatial_error=""
	panorama_tiles.clear()
	if portrait_requested: set_portrait(false, true)
	_portrait_auto_due = false
	_portrait_texture = null; _portrait_mask = PackedByteArray(); _portrait_strength = -1.0; portrait_error = ""; _portrait_next = {}
	_restore_display()
	_cache_epoch += 1
	_pause_prefetch()
	for target in _prefetched.keys(): _drop_prefetch(target)
	for entry in _recent_files.values(): _release_photo(int(entry.id), true)
	_recent_files.clear()
	_prefetch_decode = {}; _prefetch_request = 0; _prefetch_failed.clear()
	_display_info = {}; _display_result = {}
	_pending_display = {}; _display_depth_data = {}
	_promoted_depth_request = 0; _incoming_depth_result = {}
	_depth_queue.clear(); _depth_rebuild_seconds = 0.0
	_serial += 1
	if platform:
		if _request > 0: _release_photo(_request, true)
		if _display_request > 0: _release_photo(_display_request)
		# Keep the one shared model session warm between gallery selections. Native jobs
		# above are cancelled; the existing idle timeout and closing the album release the model.
		if release_runtime and Methods.supports(platform, "release_photo_depth_runtime"): platform.release_photo_depth_runtime()
	_request = 0; _display_request = 0; _next_decode = {}
	_hide_layer(); _upload = {}; _layer_key = ""; _full_image = null; _texture_full = true; _depth_textures_pending = false
	if Methods.supports(platform, "destroy_layer_image"): platform.destroy_layer_image(VideoLayer.PICTURE_SLOT)
	_texture = null; _depth_texture = null; _stereo_texture = null; _depth_busy = false; depth_requested = false; depth_enabled = false
	material.set_shader_parameter("photo_texture", null); material.set_shader_parameter("depth_texture", null)
	_detail_material.set_shader_parameter("sharpness", sharpness)
	_detail_material.set_shader_parameter("photo_texture", null); _detail_material.set_shader_parameter("depth_texture", null)
	for target in [material, _detail_material]:
		target.set_shader_parameter("stereo_texture", null); target.set_shader_parameter("photo_stereo", false)
	panel.visible = false; _detail.visible = false; loading = false; inspect = false
	hide_inspect_pointer()

func close_image(notify: bool = true, next_online_uri: String = "") -> void:
	slideshow.clear()
	autoplay.set_enabled(false)
	_cancel_rotation_preview()
	_image_rotations.clear(); screen_rotation = 0.0
	animation.close()
	auto_portrait = false; _portrait_auto_due = false
	comic.end_batch()
	magazine.reset()
	var restore_archive_layout := archive_mode
	if archive_mode:
		reading_layout = gallery.mode
		var key := local_uri.get_slice("/", 2)
		if key.is_empty() and not queue.is_empty(): key = str(queue[0].uri).get_slice("/", 2)
		if _pdf_session.is_empty() and not archive_browser_session and not key.is_empty() and Methods.supports(platform, "archive_close"): platform.archive_close(key)
		archive_mode = false
	if not _pdf_session.is_empty() and Methods.supports(platform, "pdf_close"): platform.pdf_close(_pdf_session)
	_pdf_session = ""
	archive_browser_session = false
	archive_origin = ""
	archive_entry.clear()
	_release_full_photo()
	if _catalog_save_ms > 0 and catalog:
		_catalog_save_ms = 0
		catalog.save()
	directory.cancel(); _directory_result = {}; queue_complete = true; directory_error = ""
	gallery.clear()
	if Methods.supports(platform, "panorama_original_view"): platform.panorama_original_view(next_online_uri)
	local_uri = ""; display_name = ""; error = ""; index = -1; pending_index = -1
	if restore_archive_layout:
		queue.clear()
		gallery.set_mode(_archive_previous_layout, "close_container")
	if notify: changed.emit()

func _exit_tree() -> void:
	slideshow.clear()
	comic.close()
	close_image(false)
	if _thread: _thread.wait_to_finish(); magazine.cleanup_job(_decoding); _thread = null
	if _depth_thread: _depth_thread.wait_to_finish(); _depth_thread = null
	if _portrait_thread: _portrait_thread.wait_to_finish(); _portrait_thread = null
	for id in _deferred_release_ids: _release_photo(int(id))
	_deferred_release_ids.clear()


func can_portrait() -> bool:
	var selected: bool = gallery.mode in [Gallery.Layout.SINGLE, Gallery.Layout.SIDES, Gallery.Layout.MAGAZINE] or (gallery.focus == index and gallery.progress >= 1 and not gallery.returning)
	return selected and not spatial_requested and not loading and _texture != null and geometry == 0 and not stereo_sbs \
		and not _metadata.get("magazine_unregistered", false) \
		and not _metadata.get("native_stereo",false) and _display_request > 0 \
		and Methods.supports(platform,"prepare_photo_3d") and Methods.supports(platform,"prepare_photo_portrait")

func _invalidate_portrait_mask() -> void:
	if Methods.supports(platform,"cancel_photo_portrait"): platform.cancel_photo_portrait(_portrait_epoch)
	_portrait_epoch += 1; _portrait_next = {}; _portrait_pending_depth = {}; _portrait_sent_epoch = -1

func _maybe_start_portrait() -> void:
	if not _portrait_auto_due or not auto_portrait or not error.is_empty() or not depth_error.is_empty(): return
	if can_portrait(): set_portrait(true, true)

func set_portrait(enabled: bool, automatic: bool = false) -> bool:
	if enabled: animation.freeze()
	if enabled and not portrait_requested and not can_portrait(): return false
	var was_session := portrait_session_active()
	if not automatic: auto_portrait = enabled
	_portrait_switching = false
	_placeholder_material.set_shader_parameter("portrait_loading", enabled)
	_portrait_auto_due = false
	if enabled == portrait_requested:
		if was_session != portrait_session_active(): changed.emit()
		return true
	if not enabled and not _portrait_pending_depth.is_empty(): _commit_depth_data(_portrait_pending_depth)
	_invalidate_portrait_mask(); portrait_error = ""
	if not enabled:
		portrait_requested = false; portrait_enabled = false
		set_screen_curve(_portrait_curve); _apply_geometry()
		gallery.synchronize(); gallery._refresh_visibility()
		changed.emit(); return true
	finish_transition(); close_inspect(); gallery.cancel_all(); _pause_prefetch()
	_portrait_curve = screen_curve
	portrait_requested = true; portrait_enabled = false; set_screen_curve(0)
	gallery.visible = false; panel.visible = true; set_target_feedback(0)
	if not automatic: depth_strength = DepthStrength.remembered(depth_strength,DepthStrength.PHOTO_MAX)
	if not set_depth(true):
		set_portrait(false, true); portrait_error = "3D unavailable"; changed.emit(); return false
	var accepted := _request_portrait_mask()
	_apply_geometry(); changed.emit(); return accepted

func _request_portrait_mask() -> bool:
	if not portrait_requested or _depth_busy or _depth_rebuild_seconds > 0: return true
	if not depth_error.is_empty():
		set_portrait(false, true); portrait_error = "3D unavailable"; changed.emit(); return false
	var data: Dictionary = _portrait_pending_depth if not _portrait_pending_depth.is_empty() else _display_depth_data
	if not data.has("stereo_image") or not is_equal_approx(float(data.get("strength",-1)),depth_strength) or not _rotation_matches(data): return true
	if _valid_cached_portrait(data.get("portrait_data", {}), data):
		var cached: Dictionary = data.portrait_data
		if not _portrait_pending_depth.is_empty(): _commit_depth_data(_portrait_pending_depth); _portrait_pending_depth = {}
		if _portrait_texture == null or not is_equal_approx(_portrait_strength, depth_strength):
			_portrait_texture = cached.ready_texture if cached.get("ready_texture") is Texture2D else ImageTexture.create_from_image(cached.image)
			_portrait_mask = cached.mask
			_portrait_strength = float(cached.strength); _portrait_serial += 1
		portrait_enabled = true
		return true
	if _portrait_texture != null and is_equal_approx(_portrait_strength,depth_strength):
		if not _portrait_pending_depth.is_empty(): _commit_depth_data(_portrait_pending_depth); _portrait_pending_depth = {}
		portrait_enabled = true
	elif _portrait_sent_epoch != _portrait_epoch:
		_portrait_sent_epoch = _portrait_epoch
		var rotation := _stereo_rotation()
		var accepted: bool = platform.prepare_photo_portrait_rotated(_display_request,_portrait_epoch,depth_strength,rotation) \
			if Methods.supports(platform, "prepare_photo_portrait_rotated") else rotation == 0 and platform.prepare_photo_portrait(_display_request,_portrait_epoch,depth_strength)
		if not accepted:
			set_portrait(false, true); portrait_error = "Portrait unavailable"; changed.emit(); return false
	return true

func _on_portrait(id: int, payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or not portrait_requested or id != _display_request or int(result.get("token",-1)) != _portrait_epoch: return
	if result.get("state") != "ready":
		set_portrait(false, true); portrait_error = "No person detected" if result.get("error") == "PHOTO_NO_PERSON" else "Portrait unavailable"; changed.emit(); return
	_portrait_next = {"id":id,"token":_portrait_epoch,"payload":result}

static func _read_portrait(result: Dictionary) -> Dictionary:
	var w := int(result.get("width",0)); var h := int(result.get("height",0))
	if result.get("format") != "r8_sbs" or result.get("strategy") != "video_soft_shift_gpu" or w < 2 or w % 2 != 0 \
		or w > 8192 or h < 1 or h > 4096 or w*h > 16*1024*1024: return {}
	var strength := float(result.get("strength",-1))
	if not is_finite(strength) or strength < 0 or strength > 2: return {}
	var file := FileAccess.open(str(result.get("path","")),FileAccess.READ)
	if not file or file.get_length() != w*h: return {}
	var mask := file.get_buffer(w*h)
	var image := Image.create_from_data(w,h,false,Image.FORMAT_R8,mask)
	image.generate_mipmaps()
	return {"image":image,"strength":strength,"mask":mask,"rotation":int(result.get("rotation", 0))}

func _process_portrait() -> void:
	if _rotation_preview: return
	if _portrait_thread and not _portrait_thread.is_alive():
		var data: Dictionary = _portrait_thread.wait_to_finish(); _portrait_thread = null
		var id := int(_portrait_job.id)
		if not data.is_empty(): data["source_id"] = id
		if _portrait_job.get("background", false):
			if id == _prefetch_portrait_request:
				_prefetch_portrait_request = 0
				for entry in _prefetched.values():
					if int(entry.id) != id: continue
					if _valid_cached_portrait(data, entry.get("depth_data", {})): entry.depth_data["portrait_data"] = data
					elif data.is_empty() or is_equal_approx(float(data.get("strength", -1)), depth_strength): entry["portrait_failed"] = true
				_trim_depth_cache()
		elif portrait_requested and id == _display_request and int(_portrait_job.token) == _portrait_epoch:
			var pair: Image = _portrait_pending_depth.get("stereo_image",_display_depth_data.get("stereo_image"))
			if data.is_empty() or not _rotation_matches(data) or pair == null or data.image.get_size() != pair.get_size() or not is_equal_approx(float(data.strength),depth_strength):
				set_portrait(false, true); portrait_error = "Portrait unavailable"
			else:
				if not _portrait_pending_depth.is_empty(): _commit_depth_data(_portrait_pending_depth); _portrait_pending_depth = {}
				_portrait_texture = ImageTexture.create_from_image(data.image); _portrait_strength = float(data.strength); portrait_enabled = true
				_portrait_mask = data.mask; _portrait_serial += 1
				_display_depth_data = _display_depth_data.duplicate()
				_display_depth_data["source_id"] = id
				_display_depth_data["portrait_data"] = data
				if not _display_result.is_empty(): _display_result["depth_data"] = _display_depth_data
			_apply_geometry(); changed.emit()
		_portrait_job = {}
		if _deferred_release_ids.erase(id) and id not in [_request,_display_request]: _release_photo(id)
	if not _portrait_thread and not _portrait_next.is_empty():
		_portrait_job = _portrait_next; _portrait_next = {}; _portrait_thread = Thread.new()
		if _portrait_thread.start(_read_portrait.bind(_portrait_job.payload)) != OK:
			_portrait_thread = null; set_portrait(false, true); portrait_error = "Portrait unavailable"; changed.emit()

## The layer can show this projection at all on this runtime.
func _layer_possible(projection: int) -> bool:
	return not _presentation_layer_failed and layer_enabled and video_layer != null and video_layer.available() and Methods.supports(platform, "copy_layer_band") \
		and projection != Geometry.Geometry.FISHEYE and video_layer.supports(projection, screen_curve > 0.0)

## What the layer shows now: the generated stereo pair while 3D is on, else the photo itself.
func _layer_source() -> Dictionary:
	if portrait_requested:
		# The cutout: the pair times its mask, premultiplied, over passthrough.
		var pair: Image = _display_depth_data.get("stereo_image")
		if not portrait_enabled or not transparent_background or pair == null or not Methods.supports(platform, "copy_layer_band_masked") \
			or _portrait_mask.size() != pair.get_width() * pair.get_height():
			return {}
		return {"key": "portrait:%d:%d:r%d" % [_display_request, _portrait_serial, int(_display_depth_data.get("rotation", 0))], "image": pair, "mask": _portrait_mask,
			"stereo": 1, "blend": VideoLayer.SOURCE_ALPHA}
	if depth_enabled and _display_depth_data.has("stereo_image"):
		var pair: Image = _display_depth_data.stereo_image
		return {"key": "stereo:%d:%.3f:%dx%d:r%d:c%.4f" % [_display_request, float(_display_depth_data.get("strength", 0)), pair.get_width(), pair.get_height(), int(_display_depth_data.get("rotation", 0)), float(_display_depth_data.get("convergence", 0.35))],
			"image": _display_depth_data.stereo_image, "stereo": 1}
	if depth_enabled:
		return {} # the shader's own depth parallax
	return {"key": "color:%d" % _display_request, "image": _full_image, "stereo": -1}

## The layer can show the photo as the shader would now: no shader-only effects or transitions.
func _layer_eligible(preparing: bool = false) -> bool:
	if slideshow.busy() or not slideshow.layer_compatible(): return false
	return not animation.available() and not spatial_requested and _display_request > 0 and _texture != null and panel.visible and not loading and error.is_empty() \
		and not _rotation_preview and not (geometry == 0 and screen_curve > 0.0 and absf(sin(_curve_rotation())) > 0.00001) \
		and not gallery.overview() and ((_presentation_pending and preparing and _presentation_effects_ready()) or \
		(not _presentation_pending and not _transition_active and _reveal_seconds == 0 and not placeholder_visible())) \
		and _layer_possible(geometry)

## A spatial photo's disparity as the layer's per-eye UV shift: the photo shader's own shift of each
## source eye, in the video's alignment convention (the left eye moves by -offset / 2).
func stereo_offset_uv() -> Vector2:
	if not bool(_metadata.get("native_stereo", false)) or not stereo_sbs or top_bottom or geometry != Geometry.Geometry.FLAT:
		return Vector2.ZERO
	var disparity := clampf(float(_metadata.get("spatial_disparity", 0)), -1.0, 1.0)
	return Vector2(disparity if swap_eyes else -disparity, 0)

func _origin() -> XROrigin3D:
	return view_camera.get_parent() as XROrigin3D if view_camera else null

var _diagnosed_request := 0
func _process_layer() -> void:
	# Until selection accepts new pixels, leave the old native picture submitted.
	if slideshow.waiting and loading:
		var held := _layer_source()
		var origin := _origin()
		if layer_shown and origin != null and not held.is_empty() and held.image != null:
			var image: Image = held.image
			# A user may still move the window while the next source loads.
			if not video_layer.show(self, origin, VideoLayer.PICTURE, Vector2(image.get_width(), image.get_height()), int(held.stereo), _edge_feather()): _hide_layer()
			if _hole: _hole.transform = panel.transform
		return
	var source := _layer_source()
	if _display_request != _diagnosed_request and _display_request > 0 and not loading:
		_diagnosed_request = _display_request
		DiagnosticLog.record("photo_layer_inputs", {"request": _display_request, "video_layer": video_layer != null,
			"available": video_layer != null and video_layer.available(), "possible": _layer_possible(geometry),
			"eligible": _layer_eligible(), "source": str(source.get("key", "")), "texture_full": _texture_full,
			"full_image": _full_image != null, "geometry": geometry, "curve": screen_curve, "depth": depth_enabled,
			"panel": panel.visible, "transition": _transition_active, "placeholder": placeholder_visible()})
	var eligible: bool = _layer_eligible(true) and not source.is_empty() and source.image != null
	if _presentation_pending and not eligible:
		_upload = {}
		_hide_layer()
		return
	if eligible and _layer_key != source.key and str(_upload.get("key", "")) != source.key:
		_upload = {"key": source.key, "image": source.image, "mask": source.get("mask"), "row": 0} # replaces an unfinished other picture
	if not _upload.is_empty():
		_continue_upload()
	var origin := _origin()
	var shown: bool = origin != null and eligible and _layer_key == str(source.key) and not _transition_active
	if shown:
		var flat := geometry == Geometry.Geometry.FLAT
		# A masked layer owns the whole cutout. A photo-shaped eye-buffer rim would
		# still sample the colour proxy while its large stereo texture is deferred.
		var opaque_flat := flat and int(source.get("blend", VideoLayer.OPAQUE)) == VideoLayer.OPAQUE
		var inset := _edge_feather() if opaque_flat else Vector2.ZERO
		# The opaque edge covers the layer's outer rim: the compositor's filtered quad edge and the
		# antialiased hole edge are both part transparent, and meeting on one line they showed a
		# see-through frame between the soft edge and the picture.
		var keep := _layer_keep() if opaque_flat else Vector2.ZERO
		var content := layer_content_scale()
		var start := (Vector2.ONE - content) * 0.5 + keep * content
		var extent := (Vector2.ONE - 2.0 * keep) * content
		var cut := Vector4(start.x, start.y, extent.x, extent.y)
		var pano := Info.panorama_rect(_metadata) if geometry == Geometry.Geometry.EQUIRECT_360 and not stereo_sbs else Vector4(0, 0, 1, 1)
		var picture: Image = source.image
		var image := Vector2(picture.get_width(), picture.get_height())
		var magnifier := _magnifier_layers(origin, image, int(source.stereo))
		shown = video_layer.show(self, origin, VideoLayer.PICTURE, image, int(source.stereo), inset, pano, int(source.get("blend", VideoLayer.OPAQUE)), magnifier.layers)
		if _presentation_pending:
			if shown: _finish_presentation()
			else: _presentation_layer_failed = true
		if shown:
			_hole.mesh = panel.mesh
			_hole.transform = panel.transform
			_hole_material.set_shader_parameter("keep_rect", cut if flat else Vector4(0, 0, 1, 1))
			_hole_material.set_shader_parameter("content_rect", Vector4((1.0-content.x)*0.5, (1.0-content.y)*0.5, content.x, content.y))
			# A shifted spatial pair leaves part of each eye without picture: it stays in the eye buffers.
			var offset := stereo_offset_uv()
			_hole_material.set_shader_parameter("stereo_sbs", offset != Vector2.ZERO)
			_hole_material.set_shader_parameter("stereo_offset", offset)
			_hole.visible = true
			material.set_shader_parameter("layer_cut", cut if flat else Vector4(0, 0, 1, 1))
		_show_magnifier_hole(magnifier.window if shown else Rect2())
	if not shown:
		_hide_layer()
		# Off the layer the shader shows the photo: the full picture, once nothing transient is on.
		# Only for a picture on show: the wall overview keeps its previews and the proxy.
		if not spatial_requested and (not _texture_full or _depth_textures_pending) and panel.visible and not loading and not _transition_active and _reveal_seconds == 0 \
			and _upload.is_empty():
			_ensure_full_texture()
	elif inspect and not magnifier_on_layer:
		_ensure_full_texture() # the eye-buffer magnifier samples the full picture
	if shown != layer_shown or (shown and str(_upload.get("key", "")) == "" and _layer_key != _logged_key):
		_logged_key = _layer_key if shown else ""
		DiagnosticLog.record("photo_layer", layer_snapshot().merged({"shown": shown, "eligible": eligible,
			"source": str(source.get("key", "")), "panel": panel.visible, "loading": loading, "placeholder": placeholder_visible(),
			"transition": _transition_active, "reveal": _reveal_seconds, "overview": gallery.overview(), "origin": origin != null}))
	layer_shown = shown

func _hide_layer() -> void:
	layer_shown = false
	_show_magnifier_hole(Rect2())
	if _hole: _hole.visible = false
	if material: material.set_shader_parameter("layer_cut", Vector4.ZERO)
	if video_layer: video_layer.hide(self)

## Flat inspect over the picture layer: the window's crop as quad layers above it (one per eye for a
## stereo pair), so the eye buffers neither sample nor hold the full picture while it is open.
## window: the part of the detail window the picture covers (a small picture leaves margins).
func _magnifier_layers(origin: XROrigin3D, image: Vector2, stereo: int) -> Dictionary:
	var none := {"layers": [], "window": Rect2()}
	if not inspect or not _detail.visible or geometry != Geometry.Geometry.FLAT: return none
	var aspect: Variant = _detail_material.get_shader_parameter("crop_aspect")
	var skew: Variant = _detail_material.get_shader_parameter("crop_skew")
	# A quad shows an upright crop where the shader shears it to the source's projected slant (about 20%
	# for a large photo with the window above-right of the crop): fine for a loupe; extremes stay sheared.
	if not aspect is Vector2 or not skew is Vector2 or aspect.x <= 0 or aspect.y <= 0 \
		or absf(skew.x) > MAGNIFIER_SKEW * aspect.x or absf(skew.y) > MAGNIFIER_SKEW * aspect.y:
		_record_magnifier(false, {"aspect": str(aspect), "skew": str(skew)})
		return none
	var span: Vector2 = aspect / magnification
	var center: Vector2 = _detail_material.get_shader_parameter("crop_center")
	var start := center - span * 0.5
	var crop := Rect2(start, span).intersection(Rect2(0, 0, 1, 1))
	if crop.size.x <= 0 or crop.size.y <= 0: return none
	var window := Rect2((crop.position - start) / span, crop.size / span)
	var mesh: Vector2 = _detail.mesh.size
	var pose := _detail.global_transform
	var centre := window.get_center() - Vector2(0.5, 0.5)
	pose.origin += pose.basis * Vector3(centre.x * mesh.x, -centre.y * mesh.y, 0)
	var size := mesh * Vector2(_detail.global_basis.x.length(), _detail.global_basis.y.length()) * window.size
	# Each eye's crop in its own view: the generated pair side by side, or a packed stereo photo's views.
	var packed := stereo != 1 and stereo_sbs
	var below := packed and top_bottom
	var eye_image: Vector2 = image * (Vector2(1.0, 0.5) if below else Vector2(0.5, 1.0)) if stereo == 1 or packed else image
	var layers := []
	for eye in ([0] if stereo != 1 and not packed else [1, 2]):
		var view: int = (2 - eye if swap_eyes else eye - 1) if packed else maxi(eye - 1, 0)
		var corner := Vector2(0.0, eye_image.y * view) if below else Vector2(eye_image.x * view, 0.0)
		var rect := Rect2(corner + crop.position * eye_image, crop.size * eye_image)
		layers.append({"values": video_layer.quad_values(origin, pose, size, VideoLayer.PICTURE_SLOT, image, rect, VideoLayer.OPAQUE, eye),
			"order": VideoLayer.OVERLAY_ORDER})
	_record_magnifier(true, {"window": str(window), "eyes": layers.size()})
	return {"layers": layers, "window": window}

var _magnifier_logged := -1
func _record_magnifier(on_layer: bool, detail: Dictionary) -> void:
	if int(on_layer) == _magnifier_logged: return
	_magnifier_logged = int(on_layer)
	DiagnosticLog.record("photo_magnifier_layer", detail.merged({"on_layer": on_layer}))

func _show_magnifier_hole(window: Rect2) -> void:
	magnifier_on_layer = window.has_area()
	if not _detail_hole: return
	_detail_hole.visible = magnifier_on_layer
	var cut := Vector4(window.position.x, window.position.y, window.size.x, window.size.y) if magnifier_on_layer else Vector4.ZERO
	_detail_hole.material_override.set_shader_parameter("keep_rect", cut)
	_detail_material.set_shader_parameter("layer_cut", cut)

func _ensure_full_texture() -> void:
	if not _texture_full and _full_image != null and not (_cached_render_active and depth_requested and _stereo_texture != null):
		DiagnosticLog.trail("photo.texture.full", "%dx%d" % [_full_image.get_width(), _full_image.get_height()])
		_texture = ImageTexture.create_from_image(_full_image)
		_texture_full = true
		material.set_shader_parameter("photo_texture", _texture)
		_detail_material.set_shader_parameter("photo_texture", _texture)
	if _depth_textures_pending:
		_create_depth_textures()
		_apply_geometry()

## The small depth map is made at once: while the layer shows the stereo pair, the feathered edge
## left in the eye buffers needs it to stand at the pair's depth. Without it the edge took one
## uniform disparity and framed the picture in front of its own 3D. Only the large pair waits.
func _use_depth_textures() -> void:
	if _display_depth_data.has("ready_depth") and _display_depth_data.has("ready_stereo"):
		_depth_texture = _display_depth_data.ready_depth
		_stereo_texture = _display_depth_data.ready_stereo
		_depth_textures_pending = false
		return
	if _texture_full:
		_create_depth_textures()
		return
	_depth_texture = ImageTexture.create_from_image(_display_depth_data.image) if _display_depth_data.has("image") else null
	_stereo_texture = null
	_depth_textures_pending = true

func _create_depth_textures() -> void:
	_depth_textures_pending = false
	DiagnosticLog.trail("photo.texture.depth", "stereo=%s" % _display_depth_data.has("stereo_image"))
	_depth_texture = ImageTexture.create_from_image(_display_depth_data.image) if _display_depth_data.has("image") else null
	_stereo_texture = ImageTexture.create_from_image(_display_depth_data.stereo_image) if _display_depth_data.has("stereo_image") else null

## One slice of the full picture per frame into the static layer image; the last one mipmaps it.
func _continue_upload() -> void:
	var image: Image = _upload.image
	var width := image.get_width()
	var height := image.get_height()
	if not _upload.has("started"):
		if image.get_format() != Image.FORMAT_RGBA8:
			image = image.duplicate() as Image
			image.clear_mipmaps()
			image.convert(Image.FORMAT_RGBA8)
			_upload.image = image
		var levels := int(floor(log(maxf(width, height)) / log(2.0))) + 1
		DiagnosticLog.trail("photo.layer", "%dx%d levels=%d" % [width, height, levels])
		var started := Time.get_ticks_usec()
		var created: bool = platform.create_layer_image(VideoLayer.PICTURE_SLOT, width, height, levels, true)
		var created_us := Time.get_ticks_usec() - started
		video_layer.invalidate()
		started = Time.get_ticks_usec()
		var acquired: int = platform.acquire_layer_image(VideoLayer.PICTURE_SLOT) if created else 0
		_upload.timing = {"create_us": created_us, "acquire_us": Time.get_ticks_usec() - started, "slices": 0,
			"slice_max_us": 0, "slice_total_us": 0, "get_data_us": 0}
		DiagnosticLog.record("photo_layer_upload", {"key": str(_upload.key), "size": [width, height], "levels": levels,
			"created": created, "acquired": acquired > 0})
		if acquired <= 0:
			if _presentation_pending: _presentation_layer_failed = true
			_upload = {}
			return
		_upload.started = true
	var rows := clampi(UPLOAD_BYTES / (width * 4), 1, height - int(_upload.row))
	var slice_started := Time.get_ticks_usec()
	# A band of rows as a small Godot texture (the engine's own upload), then a GPU copy into place.
	var band := ImageTexture.create_from_image(image.get_region(Rect2i(0, int(_upload.row), width, rows)))
	var uploaded := false
	var mask: Variant = _upload.get("mask")
	if mask is PackedByteArray:
		var mask_band := ImageTexture.create_from_image(Image.create_from_data(width, rows, false, Image.FORMAT_R8,
			(mask as PackedByteArray).slice(int(_upload.row) * width, (int(_upload.row) + rows) * width)))
		uploaded = platform.copy_layer_band_masked(VideoLayer.PICTURE_SLOT, RenderingServer.texture_get_native_handle(band.get_rid()),
			RenderingServer.texture_get_native_handle(mask_band.get_rid()), int(_upload.row), rows)
	else:
		uploaded = platform.copy_layer_band(VideoLayer.PICTURE_SLOT, RenderingServer.texture_get_native_handle(band.get_rid()), int(_upload.row), rows)
	var slice_us := Time.get_ticks_usec() - slice_started
	_upload.timing.slices = int(_upload.timing.slices) + 1
	_upload.timing.slice_total_us = int(_upload.timing.slice_total_us) + slice_us
	_upload.timing.slice_max_us = maxi(int(_upload.timing.slice_max_us), slice_us)
	if not uploaded:
		if _presentation_pending: _presentation_layer_failed = true
		platform.destroy_layer_image(VideoLayer.PICTURE_SLOT)
		video_layer.invalidate()
		_upload = {}
		return
	_upload.row = int(_upload.row) + rows
	if int(_upload.row) >= height:
		var release_started := Time.get_ticks_usec()
		var released: bool = platform.release_layer_image(VideoLayer.PICTURE_SLOT, true)
		_upload.timing.release_us = Time.get_ticks_usec() - release_started
		if released:
			_layer_key = str(_upload.key)
			if _layer_key.begins_with("stereo:"): _apply_geometry() # the pair is up: its edge takes the depth map
		elif _presentation_pending: _presentation_layer_failed = true
		DiagnosticLog.record("photo_layer_uploaded", {"key": str(_upload.key), "released": released, "timing": _upload.timing})
		_upload = {}

## Debug report: where the photo is shown.
func layer_snapshot() -> Dictionary:
	return {"shown": layer_shown, "texture_full": _texture_full, "uploading": not _upload.is_empty(),
		"layer_key": _layer_key, "display_request": _display_request, "depth_textures_pending": _depth_textures_pending,
		"texture_size": [_texture.get_width(), _texture.get_height()] if _texture else [], "size": [_size.x, _size.y]}
