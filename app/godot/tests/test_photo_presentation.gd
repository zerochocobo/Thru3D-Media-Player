extends SceneTree
## Drive production navigation/render preparation with delayed native conversion and layer uploads.
## No headset or native GPU inference is required; real Godot images/textures/meshes are used.
const Photo := preload("res://scripts/photo_display.gd")
const VideoLayer := preload("res://scripts/video_layer.gd")
var checks := 0
var failures: Array[String] = []
var color: Image
var proxy: Image
var depth: Image
var stereo: Image

class Host extends RefCounted:
	var calls: Array[int] = []
	var bands := 0
	var releases := 0
	var failure := ""
	var next_id := 10
	var scene_token := 0
	func has_java_method(method: String) -> bool: return has_method(method)
	func open_photo(_uri: String) -> int: next_id += 1; return next_id
	func activate_photo(_id: int) -> bool: return true
	func preload_photo(_uri: String) -> int: return 0
	func prepare_photo_3d(id: int, _strength: float) -> bool: calls.append(id); return true
	func prepare_photo_scene_depth(id: int, token: int) -> bool: calls.append(id); scene_token = token; return true
	func cancel_photo_scene_depth(_id: int, _token: int) -> void: pass
	func update_photo_3d_strength(_strength: float) -> void: pass
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass
	func discard_photo_depth(_id: int) -> void: pass
	func create_layer_image(_slot: int, _w: int, _h: int, _levels: int, _static: bool) -> bool: return failure != "create"
	func acquire_layer_image(_slot: int) -> int: return 0 if failure == "acquire" else 1
	func copy_layer_band(_slot: int, _texture: int, _row: int, _rows: int) -> bool: bands += 1; return failure != "copy"
	func release_layer_image(_slot: int, _mips: bool) -> bool: releases += 1; return failure != "release"
	func destroy_layer_image(_slot: int) -> void: pass

class Layer extends VideoLayer:
	var submissions := 0
	var keys: Array[String] = []
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true
	func hide(_owner: Object = null) -> void: pass
	func show(surface: Node3D, _origin: XROrigin3D, _source: int = SURFACE, _size := Vector2(SURFACE_SIZE, SURFACE_SIZE), _stereo: int = -1,
			_inset := Vector2.ZERO, _pano := Vector4(0, 0, 1, 1), _blend := OPAQUE, _extras: Array = [], _processed := false) -> bool:
		submissions += 1
		keys.append(surface._layer_key)
		return platform.failure != "show"

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func _initialize() -> void: run.call_deferred()

func make_photo(layers: bool = true) -> Node3D:
	var photo := Photo.new(); photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new("user://presentation-%d" % photo.get_instance_id())
	root.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.auto_depth = true; photo.platform = Host.new()
	photo.queue.assign([{"uri":"file://one.jpg","title":"one"},{"uri":"file://two.jpg","title":"two"},{"uri":"file://three.jpg","title":"three"}])
	var origin := XROrigin3D.new(); photo.add_child(origin)
	var camera := XRCamera3D.new(); origin.add_child(camera); photo.view_camera = camera
	if layers: photo.video_layer = Layer.new(photo.platform)
	return photo

func result() -> Dictionary:
	return {"image":color,"proxy":proxy,"info":{"width":color.get_width(),"height":color.get_height(),"path":"unused.jpg"}}

func converted(strength: float = 1.0) -> Dictionary:
	return {"image":depth,"rect":Vector4(0,0,1,1),"stereo_image":stereo,"strength":strength,"strategy":"video_soft_shift_gpu"}

func cold(photo: Node3D) -> int:
	photo._select(0)
	photo._process(.3) # The selection slide ends while native IO/conversion is still pending.
	var id: int = photo._request
	photo._prepare_display(result(), {"id":id,"index":0,"serial":photo._serial})
	check(photo.loading and photo.placeholder_visible() and not photo.panel.visible, "Cold selection stays covered before conversion")
	photo._finish_depth(id, converted(photo.depth_strength), false)
	check(photo._presentation_pending and photo.placeholder_visible() and photo.snapshot().loading, "CPU stereo completion is not presentation completion")
	check(photo.material.get_shader_parameter("presentation_opacity") == 0.0, "No colour frame is exposed on conversion callback")
	return id

func tick(photo: Node3D, count: int = 1) -> void:
	for i in count: photo._process(.1)

func finish(photo: Node3D) -> void:
	for i in 12:
		if not photo._presentation_pending: break
		tick(photo)
	check(not photo._presentation_pending and not photo.placeholder_visible() and not photo.snapshot().loading, "Final renderer releases the cover without an arbitrary timer")

func cached(photo: Node3D, at: int, id: int) -> void:
	photo._prefetched[at] = {"id":id,"info":result().info,"result":result(),"decoded":true}
	check(photo._select(at, 1), "Prepared colour source can be selected")

func dispose(photo: Node3D) -> void:
	photo.close_image(); photo.free()

func run() -> void:
	color = Image.create(1024,1024,false,Image.FORMAT_RGBA8); color.fill(Color.RED)
	proxy = Image.create(64,64,false,Image.FORMAT_RGBA8); proxy.fill(Color.RED)
	depth = Image.create(518,518,false,Image.FORMAT_RF); depth.fill(Color(.7,0,0))
	stereo = Image.create(2048,1024,false,Image.FORMAT_RGBA8); stereo.fill(Color.GREEN)
	stereo.fill_rect(Rect2i(1024,0,1024,1024), Color.BLUE); stereo.generate_mipmaps()
	var photo := make_photo()
	var id := cold(photo)
	check(photo._stereo_texture == null and photo._depth_textures_pending, "Layer path keeps its existing memory-saving deferred stereo texture")
	tick(photo)
	check(photo.platform.bands == 1 and photo.platform.releases == 0, "Upload starts under the cover and spans multiple frames")
	check(photo.placeholder_visible() and photo.video_layer.submissions == 0 and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Partial upload reveals neither flat preview nor incomplete stereo")
	photo.toggle_inspect()
	check(not photo.inspect and not photo._detail.visible, "Magnifier cannot expose the intermediate image behind the cover")
	photo.finish_transition()
	check(photo.placeholder_visible() and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Finishing a slide cannot bypass pending presentation")
	finish(photo)
	check(photo.layer_shown and photo.video_layer.submissions == 1 and photo.platform.releases == 1, "Cover releases on successful final layer submission")
	check(photo._stereo_texture == null and photo.video_layer.keys[0].begins_with("stereo:%d:" % id), "Final stereo layer needs no duplicate full Godot stereo texture")
	# Cached colour must never make a colour layer while its own conversion is pending.
	cached(photo, 1, 21)
	check(is_instance_valid(photo._departing) and photo._departing.material_override.get_shader_parameter("layer_cut") == Vector4.ZERO, "Departing layer photo keeps its centre when the compositor is hidden")
	var departing: ShaderMaterial = photo._departing.material_override
	var previous_pair: Texture2D = departing.get_shader_parameter("stereo_texture")
	check(departing.get_shader_parameter("photo_stereo") and previous_pair != null, "Departure retains the completed stereo eyes, not a new depth warp of the colour proxy")
	check(previous_pair.get_width() <= Photo.PROXY_SIZE and previous_pair.get_height() <= Photo.PROXY_SIZE and photo._stereo_texture == null, "Departure only uploads a bounded pair and leaves full stereo textures deferred")
	var previous_pixels := previous_pair.get_image()
	check(previous_pixels.get_pixel(20,20).g > .9 and previous_pixels.get_pixel(previous_pixels.get_width()-20,20).b > .9, "Retained transition pair preserves distinct left and right eyes")
	check(not photo._hole.visible and not photo.layer_shown, "The stationary compositor hole is hidden in the same selection call")
	var bands: int = photo.platform.bands
	tick(photo, 4)
	check(not is_instance_valid(photo._departing), "Completed slide releases the departing render")
	check(photo.placeholder_visible() and photo.platform.bands == bands and not photo.layer_shown, "Cached 3D page remains glass, with no interim colour upload")
	photo._finish_depth(id, converted(photo.depth_strength), false)
	check(photo.placeholder_visible() and photo._display_depth_data.is_empty(), "Previous photo's late conversion cannot uncover this page")
	photo.set_depth_strength(.75)
	photo._finish_depth(21, converted(1.0), false)
	tick(photo)
	check(photo.placeholder_visible() and photo.platform.bands == bands, "Obsolete strength remains covered and triggers current-strength work")
	photo._finish_depth(21, converted(.75), false)
	finish(photo)
	check(photo._layer_key.begins_with("stereo:21:0.750:"), "Only the selected strength reaches the display")
	# Cancelling during upload discards that upload and all callbacks belonging to it.
	cached(photo, 2, 22); photo._finish_depth(22, converted(.75), false); tick(photo)
	cached(photo, 0, 23); photo._finish_depth(22, converted(.75), false)
	check(photo.placeholder_visible() and photo._display_request == 23 and photo._upload.is_empty(), "Rapid turn cancels the old upload without revealing the next colour")
	photo._finish_depth(23, converted(.75), false); tick(photo)
	photo.close_image(); photo._finish_depth(23, converted(.75), false)
	check(not photo._presentation_pending and photo._upload.is_empty() and not photo.placeholder_visible() and not photo.panel.visible, "Close rejects late completion and releases the cover")
	photo.free()
	photo = make_photo(); id = cold(photo); tick(photo)
	photo._select(1); tick(photo); photo._select(0)
	check(photo.placeholder_visible() and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Cancelling a turn back to an unfinished current photo preserves its cover")
	finish(photo); check(photo._layer_key.begins_with("stereo:%d:" % id), "Restored selection finishes its own upload")
	dispose(photo)
	# Any layer failure falls back to complete shader textures, rather than retrying forever.
	for failure in ["create", "acquire", "copy", "release", "show"]:
		photo = make_photo(); photo.platform.failure = failure; cold(photo); finish(photo)
		check(photo._presentation_layer_failed and photo._stereo_texture != null and photo.material.get_shader_parameter("photo_stereo"), "%s failure reveals the complete shader stereo pair" % failure)
		dispose(photo)
	photo = make_photo(false); cold(photo); finish(photo)
	check(photo._stereo_texture != null and photo.material.get_shader_parameter("photo_stereo"), "Devices without layers reveal only their completed shader pair")
	dispose(photo)
	# Conversion failure leaves a usable original, and ordinary 2D keeps its instant cache path.
	photo = make_photo(); cached(photo, 0, 24); photo._finish_depth(24, {}, false); finish(photo)
	check(photo.depth_error == "3D unavailable" and not photo.depth_enabled, "Conversion failure resolves the cover to the original image")
	photo.auto_depth = false; cached(photo, 1, 25)
	check(not photo.placeholder_visible() and not photo._presentation_pending and not photo._transition_active, "2D cache hits still display instantly")
	dispose(photo)
	photo = make_photo(); cached(photo, 0, 27); photo.set_depth(false); finish(photo)
	photo._finish_depth(27, converted(photo.depth_strength), false); tick(photo)
	check(not photo.depth_enabled and not photo.placeholder_visible() and photo._layer_key == "color:27", "Disabling conversion reveals the requested 2D view and rejects late 3D activation")
	dispose(photo)
	# The spatial worker prepares while covered; it must not expose the static intermediate pair.
	photo = make_photo(); photo.spatial_preferred = true; cold(photo); tick(photo)
	check(photo.spatial_requested and photo.placeholder_visible() and not photo._spatial.visible, "Spatial preparation begins under flowing glass")
	check(photo.platform.bands == 0, "Spatial selection skips the unused static stereo upload")
	var deadline := Time.get_ticks_msec() + 10000
	while not photo._spatial.prepared and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(photo._spatial.prepared and not photo._spatial.visible and photo.placeholder_visible(), "Prepared spatial mesh remains hidden until presentation commits")
	tick(photo)
	check(photo._spatial.visible and not photo.placeholder_visible() and photo.material.get_shader_parameter("spatial_hidden"), "Spatial mesh and flat-photo hiding commit together")
	dispose(photo)
	# Native stereo also stays covered while waiting for spatial depth; failure reveals native stereo.
	photo = make_photo(); photo.spatial_preferred = true; photo._request = 28
	var native := result(); native.info["native_stereo"] = true
	photo._show_placeholder(0, native.info)
	photo._prepare_display(native, {"id":28,"index":0,"serial":photo._serial})
	tick(photo, 4)
	check(photo.spatial_requested and photo._spatial_waiting and photo.placeholder_visible() and photo.platform.bands == 0, "Native spatial selection waits under glass without showing its static pair")
	photo._on_spatial_depth(28, JSON.stringify({"state":"error","scene_token":photo.platform.scene_token}))
	finish(photo)
	check(not photo.spatial_requested and not photo.spatial_error.is_empty() and photo.stereo_sbs and photo.layer_shown, "Failed spatial preparation falls back to the native stereo renderer without hanging")
	dispose(photo)
	# Gallery visibility refresh must not discard a pending selected photo's glass cover.
	photo = make_photo(); cached(photo, 0, 26)
	photo.gallery.mode = photo.Gallery.Layout.WALL; photo.gallery.focus = 0; photo.gallery.progress = 1.0
	photo._placeholder.visible = false # The expanding card owned the glass until the focus animation ended.
	photo.finish_transition(); photo.gallery._refresh_visibility()
	check(photo.placeholder_visible() and photo.material.get_shader_parameter("presentation_opacity") == 0.0, "Expanded gallery keeps the cover through visibility and pose refresh")
	dispose(photo)
	print("Photo presentation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
