extends SceneTree
const Layer := preload("res://scripts/video_layer.gd")
const Renderer := preload("res://scripts/video_pip_compositor.gd")
const Quality := preload("res://scripts/video_pip_quality.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var calls: Array = []
	var draw_ok := true
	var mask_ok := true
	func render_pip_feather_mask(slot: int, feather: PackedFloat32Array) -> bool:
		calls.append(["feather", slot, feather.duplicate()]); return mask_ok
	func render_pip_atlas(slot: int, _color: int, external: bool, _mask: int, active: int, eyes: int, common: PackedFloat32Array, windows: PackedFloat32Array) -> bool:
		calls.append(["draw", slot, external, active, eyes, common.duplicate(), windows.duplicate()]); return draw_ok
	func create_layer_image(slot: int, width: int, height: int, _levels: int, _static: bool) -> bool:
		calls.append(["create", slot, width, height]); return true
	func acquire_layer_image(slot: int) -> int: calls.append(["acquire", slot]); return 1
	func release_layer_image(slot: int, _mips: bool) -> bool: calls.append(["release", slot]); return true
	func destroy_layer_image(slot: int) -> void: calls.append(["destroy", slot])
	func remap_layer_fisheye(slot: int, _color: int, _external: bool, params: PackedFloat32Array) -> bool:
		calls.append(["fisheye", slot, params.duplicate()]); return true
	func count_calls(kind: String) -> int: return calls.filter(func(call): return call[0] == kind).size()

class Surface extends "res://tests/test_video_pip.gd".Surface:
	var platform: RefCounted
	var video_layer: RefCounted
	var alpha_requested := false
	func portrait_requested() -> bool: return false
	var depth_requested := false
	var packed_file := false
	var viewing_eye := 0
	var layer_enabled := true
	var color_grade: RefCounted
	var media := {"state": "paused", "format": {}, "playback": {"layer_surface_width": 4096, "layer_surface_height": 2048}}
	var control := {"pending": false, "in_flight": 0}
	var _waiting_first := false
	var _pending_revision := {}
	var alignment := Vector2.ZERO
	func stereo_offset_uv() -> Vector2: return alignment

class MainLayer extends "res://scripts/video_layer.gd":
	var accepted := true
	var overlays_accepted := true
	var overlays := 0
	var processed_calls := 0
	func update_session() -> void: pass
	func show(_surface: Node3D, _origin: XROrigin3D, _source: int = SURFACE, _size := Vector2(SURFACE_SIZE, SURFACE_SIZE), _stereo: int = -1,
			_inset := Vector2.ZERO, _pano := Vector4(0, 0, 1, 1), _blend := OPAQUE, _extras: Array = [], processed := false) -> bool:
		if processed: processed_calls += 1
		return accepted
	func show_overlays(_owner: Object, _extras: Array) -> bool: overlays += 1; return overlays_accepted

class MainVideo extends "res://scripts/mpv_video_display.gd":
	var test_origin: XROrigin3D
	func _origin() -> XROrigin3D: return test_origin

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var host := Host.new(); var video := Surface.new(); root.add_child(video)
	video.platform = host; video.video_layer = Layer.new(host)
	var layer: RefCounted = video.video_layer
	layer.bound = true; layer._flip = true; layer._types = {"quad": true, "equirect": true}
	layer.runtime_layers = 16; layer.runtime_image_size = Vector2i(4096, 4096); layer.generation = 1
	check(layer.capacity() == 9, "Runtime budget reserves five menus, projection and passthrough")
	var origin := Node3D.new(); root.add_child(origin)
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	video.geometry = 3; video.stereo_sbs = true; video._apply_geometry()
	var defaults := [3, true, false, false, false, 0, 0, 190.0, Vector2(4096, 2048), Vector2.ONE, Vector2.ZERO,
		false, false, 0.035, 0.35, Vector2(0, 1), Vector2(32, 32), Vector4(0, 0, 1, 1), false,
		Vector2(768, 432), false, false, Vector3.ONE, Vector3.ONE, Vector3.ZERO, 1.0, 1.0, 0.0]
	for i in Renderer.COMMON.size():
		if Renderer.COMMON[i] != "color_uv_scale": video.material.set_shader_parameter(Renderer.COMMON[i], defaults[i])
	check(Renderer.parameters(video.material, Renderer.COMMON).size() == 43, "Material request matches the native 43-float common ABI")
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var color := ImageTexture.create_from_image(image)
	video._binding.color_rid = color.get_rid(); video._binding.alpha_rid = color.get_rid()
	video._binding.ticket = {"session_id": 1, "generation": 1, "slot_token": 1, "frame_id": 1}
	var pip: RefCounted = video.pip; var renderer: RefCounted = pip.compositor
	pip.set_count(3, head); pip.sync()
	var extras: Array = renderer.prepare(origin, 3)
	check(extras.size() == 3 and renderer.pending == [1, 2, 3], "Three mono windows submit three BOTH-eye quads")
	check(host.count_calls("create") == 1 and host.count_calls("draw") == 1 and host.count_calls("release") == 1, "One source frame draws one atlas and releases it")
	check(host.calls.filter(func(call): return call[0] == "draw")[0][6].size() == 48, "Three mono windows use the native 48-float crop ABI")
	for i in extras.size():
		var values: PackedFloat32Array = extras[i].values
		check(values[1] == 0 and values[26] == Layer.PIP_SLOT and values[18] == 0, "Each BOTH-eye window retains its atlas image and avoids redundant supersampling")
		check(values[9] >= 2 and values[10] >= 2 and values[9] + values[11] <= renderer.size.x - 2 and values[10] + values[12] <= renderer.size.y - 2, "Every image rectangle excludes duplicated gutters")
	renderer.commit(true)
	check(pip.windows.values().all(func(window): return window.on_compositor and window.frame.material_override == window.hole), "Only accepted composition quads punch eye-buffer holes")
	renderer.prepare(origin, 3)
	check(host.count_calls("draw") == 1, "Paused or repeated display frames reuse the atlas without a GPU redraw")
	pip.windows[2].position.x += 0.1; renderer.prepare(origin, 3)
	check(host.count_calls("draw") == 1, "Moving a window updates quad pose without resampling video")
	pip._action(2, "zoom", 4); renderer.prepare(origin, 3)
	check(host.count_calls("draw") == 2, "Magnification invalidates the atlas while keeping the leased frame")
	video._binding.ticket.slot_token = 2; renderer.prepare(origin, 3)
	check(host.count_calls("draw") == 3, "New source lease is sampled in the current frame")
	video.material.set_shader_parameter("grade_enabled", true); pip.sync(); renderer.prepare(origin, 3)
	check(host.count_calls("draw") == 4, "Live effect changes invalidate cached atlas pixels")
	layer.runtime_layers = 10
	extras = renderer.prepare(origin, 2); renderer.commit(true)
	check(extras.size() == 1 and renderer.pending == [3] and pip.windows[3].on_compositor and not pip.windows[2].on_compositor, "A limited runtime prioritises the topmost mono window and falls back other windows")
	layer.runtime_layers = 9
	extras = renderer.prepare(origin, 2); renderer.commit(false)
	check(extras.is_empty() and pip.windows.values().all(func(window): return not window.on_compositor), "Exhausted layer budget keeps every window in the eye buffer")
	layer.runtime_layers = 16; video._binding.ticket.slot_token = 3; host.draw_ok = false
	var released := host.count_calls("release")
	check(renderer.prepare(origin, 3).is_empty() and host.count_calls("release") == released + 1, "Failed GPU work still releases the acquired swapchain image")
	renderer.commit(false)
	var attempts := host.count_calls("draw")
	renderer.prepare(origin, 3)
	check(host.count_calls("draw") == attempts, "A native failure backs off instead of retrying every refresh")
	renderer.retry_after = 0; host.draw_ok = true
	check(renderer.prepare(origin, 3).size() == 3, "A transient failure retries from the same valid frame after backoff")
	layer.generation += 1
	var creates := host.count_calls("create")
	renderer.prepare(origin, 3)
	check(host.count_calls("create") == creates + 1, "New XR session recreates its atlas before exposing old pixels")
	extras = renderer.prepare(origin, 3)
	var mono: Array = host.calls.filter(func(call): return call[0] == "draw").back()
	check(extras.size() == 3 and mono[4] == 1 and mono[6][15] == 1 and mono[6][31] == 1 and mono[6][47] == 1, "All cameras sample one selected eye with one atlas column")
	check(renderer.size.x == renderer.tile.x + 4, "Mono atlas allocates no unused second-eye column")
	var still := Image.create(64, 32, false, Image.FORMAT_RGBA8); still.fill(Color.RED)
	var still_texture := ImageTexture.create_from_image(still)
	pip.windows[3].show_image(still_texture); pip.sync()
	extras = renderer.prepare(origin,3); renderer.commit(true)
	check(extras.size()==2 and renderer.pending==[1,2] and not pip.windows[3].on_compositor, "A static image is not submitted as a native video crop")
	check(host.calls.filter(func(call):return call[0]=="draw").back()[3]==3, "Mixed image/video atlas draws only the two video slots")
	for window in pip.windows.values(): window.show_image(still_texture)
	var before_images := host.count_calls("draw")
	check(renderer.prepare(origin,3).is_empty() and renderer.size==Vector2i.ZERO and host.count_calls("draw")==before_images, "All-image mode releases video atlas without another video draw")
	for window in pip.windows.values(): window.restore_video()
	pip.sync()
	video.geometry = 0; video._binding.layer = true; video._apply_geometry(); pip.sync()
	check(not renderer.direct_compatible(), "Virtual backgrounds require sampled feather rings")
	renderer.surface_background = true; layer.alpha_blend = true
	check(renderer.direct_compatible(), "Stereo main can retain direct Surface crops for mono cameras")
	for tb in [false, true]:
		for swap in [false, true]:
			for view in [0, 1, 2]:
				video.top_bottom = tb; video.swap_eyes = swap; video.viewing_eye = view; video._apply_geometry(); pip.sync()
				var before := host.count_calls("draw")
				extras = renderer.prepare(origin, 3)
				check(extras.size() == 6 and host.count_calls("draw") == before, "Mono SBS/TB and eye swap retain masked Surface crops without resampling video")
				var values: PackedFloat32Array = extras[1].values
				var expected_eye: int = 1 if view == 2 else 0
				if swap: expected_eye = 1 - expected_eye
				check(values[1] == 0 and values[19] == Layer.SURFACE and (values[10] >= expected_eye * 1024 and values[10] + values[12] <= (expected_eye + 1) * 1024 if tb else values[9] >= expected_eye * 2048 and values[9] + values[11] <= (expected_eye + 1) * 2048), "A direct BOTH-eye crop remains within the chosen source eye")
	var mask_draws := host.count_calls("feather")
	video._binding.ticket.slot_token += 1; pip.windows[1].position.x += 0.1
	pip.windows[1].zoom = 2; pip.windows[1].crop_parameters(); renderer.prepare(origin,3)
	check(host.count_calls("feather") == mask_draws, "Static masks survive new video frames, magnification and dragging")
	for i in 3:
		check(extras[i*2].values[27] == (Layer.MASK_WRITE | Layer.SOURCE_ALPHA) and extras[i*2+1].values[27] == Layer.MASKED,
			"Each Surface quad has its own preceding mask")
		check(extras[i*2].order < extras[i*2+1].order and (i == 2 or extras[i*2+1].order < extras[(i+1)*2].order),
			"Mask/video pairs retain explicit order across overlapping windows")
	pip.windows[2].set_size(Vector2(0.3,0.3)); renderer.prepare(origin,3)
	check(host.count_calls("feather") == mask_draws + 1, "Resizing redraws only the procedural mask")
	layer.alpha_blend = false
	check(not renderer.direct_compatible(), "Missing blend extension uses the sampled path")
	layer.alpha_blend = true; layer.runtime_layers = 15
	check(not renderer.direct_compatible(), "Layer budget includes all three mask/video pairs plus main and subtitle")
	layer.runtime_layers = 16
	pip.windows[3].show_image(still_texture)
	check(not renderer.direct_compatible(), "Mixed image/video windows cannot punch away a lower image")
	pip.windows[3].restore_video(); pip.sync()
	video.alignment = Vector2(0.02, 0)
	check(not renderer.direct_compatible(), "Alignment requiring border clipping selects the complete GPU sampling path")
	video.alignment = Vector2.ZERO; video.alpha_requested = true
	check(not renderer.direct_compatible(), "AI effects select their processed frame instead of bypassing the mask")
	video.alpha_requested = false; video.media.format.source_rotation_degrees = 90
	check(not renderer.direct_compatible(), "Rotated source metadata uses the sampling path")
	video.media.format.source_rotation_degrees = 0
	pip.windows[1].set_size(Vector2(0.31,0.29)); host.mask_ok = false
	check(renderer.prepare(origin,3).is_empty(), "Failed mask work exposes no unmasked Surface window")
	renderer.commit(false)
	check(not renderer.direct_compatible() and pip.windows.values().all(func(w): return not w.frame.visible), "Mask failure requests sampled reopening and hides invalid holes")
	var failed_masks := host.count_calls("feather")
	renderer.prepare(origin,3)
	check(host.count_calls("feather") == failed_masks, "Surface mask failure is not retried each refresh")
	host.mask_ok = true; layer.generation += 1; pip.sync()
	check(renderer.direct_compatible() and renderer.prepare(origin,3).size() == 6, "New XR session can retry its own masks")
	renderer.commit(true)
	check(pip.windows.values().all(func(w): return w.frame.visible and not w.soft_rim.visible), "Successful Surface transaction restores holes without a sampled ring")
	renderer.commit(false)
	check(not renderer.direct_compatible() and renderer.fallback == "surface_submit", "Runtime rejection also requests shared-texture recovery")
	var q := Quality.new(); q.settle(1000)
	check(q.update(1500, 1024, 4000, 20, 90, false) == 512, "Startup has a settling window")
	q.update(4000, 1024, 4000, 20, 90, false)
	check(q.update(6600, 1024, 4000, 20, 90, false) == 384, "Sustained overload reduces only atlas density")
	check(q.update(8000, 1024, 4000, 20, 90, true) == 384 and q.update(9000, 1024, 4000, 20, 90, false) == 384, "Seek and buffering noise cannot repeatedly degrade quality")
	q.update(11000, 1024, 4000, 20, 90, false)
	check(q.update(14000, 1024, 4000, 20, 90, false) == 256, "Lowest atlas tier bounds sampling cost")
	q.update(15000, 1024, 300, 11, 90, false)
	check(q.update(27001, 1024, 300, 11, 90, false) == 384, "Recovery requires sustained measured GPU headroom")
	check(q.update(50000, 1024, 0, 11, 90, false) == 384, "Missing GPU timing is not evidence of spare GPU time")
	var cheap := Quality.new(); cheap.settle(1000)
	cheap.update(4000, 512, 470, 20, 90, false)
	check(cheap.update(8000, 512, 470, 20, 90, false) == 512, "A cheap atlas keeps detail when a slow main video exceeds the frame budget")
	check(cheap.update(12000, 512, 0, 20, 90, false) == 512, "Unknown atlas timing cannot attribute main-frame overload to the crop")
	cheap.update(13000, 512, 1000, 20, 90, false)
	check(cheap.update(16000, 512, 1000, 20, 90, false) == 384, "Meaningful atlas cost still reduces density during sustained overload")
	check(pip.preferences[2] == 4, "Performance adaptation never overwrites per-slot global magnification")
	pip.clear()
	check(renderer.size == Vector2i.ZERO and renderer._surface_mask_size == Vector2i.ZERO, "Closing the group destroys video and mask atlases")
	# Opaque panoramas do not require the main to remain in the eye buffer.
	video._binding.layer = false; video.media.format.clear(); video.geometry = 3; video.top_bottom = false
	video._apply_geometry(); video.material.set_shader_parameter("source_size", Vector2(4096, 2048))
	pip.set_count(3, head); pip.sync()
	check(not renderer.needs_main() and renderer.prefers_main() and renderer.prepare_main(), "An opaque panoramic main shares the leased source through the existing compositor copy")
	check(renderer.main_size == Vector2i(4096, 2048) and renderer.prepare(origin, 3).size() == 3, "Panoramic main keeps full source resolution alongside three mono composition windows")
	renderer._main_cost_frames = 60; renderer.metrics["main_gpu_samples"] = 120; renderer.metrics["main_gpu_p95_us"] = 13000
	check(not renderer.prepare_main() and renderer.main_cost_fallback, "An expensive opaque main copy may fall back without reducing its resolution")
	check(renderer.prepare(origin, 0).size() == 3 and renderer.fallback == "", "Opaque PiP layers survive when only their panoramic main falls back")
	pip.clear()
	# Transparent windows must never erase the GPU-rendered main beneath their holes.
	video._binding.layer = false; video.media.format.clear(); video.geometry = 3
	video.stereo_sbs = true; video.top_bottom = true; video._apply_geometry()
	video.material.set_shader_parameter("source_size", Vector2(2048, 2048))
	video.material.set_shader_parameter("alpha_enabled", true)
	video.material.set_shader_parameter("swap_eyes", true)
	video.material.set_shader_parameter("stereo_offset", Vector2(0.02, 0.01))
	pip.set_count(3, head); pip.sync()
	check(renderer.needs_main(), "Transparent native windows require a processed main beneath them")
	check(renderer.prepare(origin, 3).is_empty() and renderer.fallback == "transparent_main", "An unprepared transparent main keeps all windows in the eye buffer")
	layer.runtime_layers = 12
	check(not renderer.prepare_main() and renderer.prepare(origin, 2).is_empty(), "Partial transparent budget never mixes native holes with lower GPU windows")
	layer.runtime_layers = 16
	layer.runtime_image_size = Vector2i(2048, 2048)
	check(not renderer.prepare_main(), "A large processed main falls back without reducing main-video quality")
	layer.runtime_image_size = Vector2i(4096, 4096)
	var before_main := host.count_calls("draw")
	check(renderer.prepare_main() and renderer.main_size == Vector2i(4096, 1024), "Top-bottom main is processed once into a full-resolution SBS image")
	var fish: PackedFloat32Array = renderer.parameters(video.material, renderer.COMMON)
	fish[0] = 2; fish[1] = 1; fish[2] = 0; fish[7] = 180; fish[8] = 8192; fish[9] = 4096
	check(renderer.main_dimensions(fish) == Vector2i(5760, 2880), "8K transparent fisheye reuses the established 16 pixels per degree main cache")
	fish[2] = 1; fish[8] = 4096; fish[9] = 8192; fish[7] = 220
	check(renderer.main_dimensions(fish) == Vector2i(7040, 2880), "Full-FOV top-bottom fisheye cache retains angular aspect and separate eyes")
	fish[1] = 0; fish[8] = 1024; fish[9] = 1024; fish[7] = 180
	check(renderer.main_dimensions(fish) == Vector2i(1024, 1024), "Small mono fisheye is bounded by its source density")
	check(renderer.main_size == Vector2i(4096, 1024) and video.material.get_shader_parameter("source_size") == Vector2(2048, 2048), "Main sizing does not mutate the active image or original source")
	var main_call: Array = host.calls.filter(func(call): return call[0] == "draw").back()
	check(main_call[1] == Layer.PICTURE_SLOT and main_call[3] == 8 and main_call[4] == 2, "Whole-frame rendering is distinct from the PiP atlas and retains both eyes")
	check(main_call[5][4] == 1 and is_equal_approx(main_call[5][12], 0.02), "Eye order and alignment use the production sampling math before composition")
	var main_creates := host.count_calls("create")
	check(renderer.prepare_main() and host.count_calls("draw") == before_main + 1 and host.count_calls("create") == main_creates, "Paused main reuses pixels even before the PiP atlas has been prepared")
	check(renderer.prepare(origin, 3).size() == 3, "Prepared transparent main allows all three mono windows")
	video.swap_eyes = true; video.alignment = Vector2(0.1, 0.05); video.sharpness = 0.8; layer._settings = true
	var processed_values: PackedFloat32Array = layer.layer_values(video, origin, Layer.PICTURE, Vector2(renderer.main_size), 1, Vector2.ZERO, Vector4(0, 0, 1, 1), Layer.SOURCE_ALPHA, true)
	check(processed_values[9] == 0 and processed_values[Layer.STRIDE + 9] == 2048 and processed_values[11] == 2048, "Processed eyes are not swapped, cropped or aligned a second time")
	check(int(processed_values[18]) & (Layer.NORMAL_SHARPENING | Layer.QUALITY_SHARPENING) == 0 and processed_values[20] == 1 and processed_values[23] == 0, "Processed colours and sharpening are not applied twice")
	video._binding.ticket.frame_id += 1
	before_main = host.count_calls("draw")
	check(renderer.prepare_main() and host.count_calls("draw") == before_main + 1, "Changed main frame identity invalidates its cached image")
	layer.generation += 1; main_creates = host.count_calls("create")
	check(renderer.prepare_main() and host.count_calls("create") == main_creates + 1, "New XR session independently recreates the processed main")
	video._binding.ticket.frame_id += 1; host.draw_ok = false
	released = host.count_calls("release")
	check(not renderer.prepare_main() and host.count_calls("release") == released + 1, "Failed main drawing releases the acquired image")
	before_main = host.count_calls("draw")
	check(not renderer.prepare_main() and host.count_calls("draw") == before_main, "Failed main rendering backs off without repeating full-frame draws")
	check(renderer.prepare(origin, 3).is_empty(), "Main failure never exposes transparent PiP holes over a GPU main")
	renderer._main_retry_after = 0; host.draw_ok = true
	check(renderer.prepare_main(), "A transient main failure can recover from the same source lease")
	renderer.metrics["main_gpu_samples"] = 120; renderer.metrics["main_gpu_p95_us"] = 13000
	renderer._main_cost_frames = 60
	check(not renderer.prepare_main() and renderer.main_size == Vector2i.ZERO and renderer.size == Vector2i.ZERO, "An expensive transparent-main copy releases both caches and returns to shared-frame meshes")
	before_main = host.count_calls("draw"); main_creates = host.count_calls("create")
	check(not renderer.prepare_main() and renderer.prepare(origin, 3).is_empty() and renderer.fallback == "transparent_cost" \
		and host.count_calls("draw") == before_main and host.count_calls("create") == main_creates, "Unchanged expensive input stays on the safe mesh path without retries or native holes")
	video.material.set_shader_parameter("grade_contrast", 1.1)
	check(renderer.prepare_main() and renderer._main_cost_frames == 1, "Changed source parameters start a fresh measured evaluation")
	check(renderer.metrics.main_gpu_samples == 0 and renderer.metrics.main_gpu_p95_us == 0, "A new source configuration cannot inherit an expensive previous main's sample count")
	layer.runtime_layers = 10
	check(not renderer.prepare_main() and renderer.prepare(origin, 3).is_empty(), "Insufficient main and mono-window budget preserves the complete GPU fallback")
	layer.runtime_layers = 16; video.layer_enabled = false
	check(not renderer.prepare_main(), "Disabling native video layers also disables the processed-main path")
	video.layer_enabled = true; video.material.set_shader_parameter("alpha_enabled", false)
	video.material.set_shader_parameter("packed_alpha", true)
	check(renderer.needs_main(), "Built-in packed alpha uses the same transparent composition protection")
	renderer.prepare_main()
	var before_destroy := host.count_calls("destroy")
	renderer.release_main(); renderer.release_main()
	check(host.count_calls("destroy") == before_destroy + 1 and layer.picture_size == Vector2.ZERO, "Processed-main release is idempotent and clears slot ownership")
	pip.clear()
	video._binding.color_rid = RID(); video._binding.alpha_rid = RID()
	video.queue_free(); origin.queue_free(); await process_frame
	var probe := preload("res://scripts/video_pip_device_probe.gd").new()
	var main := preload("res://tests/test_video_pip.gd").RoutingMain.new(); root.add_child(main)
	var player := preload("res://scripts/mpv_video_display.gd").new(); root.add_child(player); player.set_process(false)
	player.platform = preload("res://tests/test_player_menu.gd").Host.new()
	main.video = player; player.local_uri = "file:///pip-probe-test.mp4"; player.media.begin(7); player.media.frame_counter = 1
	player.geometry = 0; player._apply_geometry(); player.panel.visible = true
	var result: Dictionary = probe.run(main, {"step": "count", "value": 3})
	check(result.ok and player.pip.windows.size() == 3, "Device count probe uses the real menu action and source readiness gate")
	result = probe.run(main, {"step": "view", "slot": 1, "stereo": true})
	check(not result.ok and result.reason == "pip_2d_only", "Debug probe cannot restore retired PiP stereo")
	for step in ["zoom", "move", "resize", "pick"]:
		result = probe.run(main, {"step": step, "slot": 1, "value": 2.0})
		check(result.ok, "Device synthetic production gesture succeeds: " + step)
	result = probe.run(main, {"step": "samples"})
	check(not result.ok and result.reason == "no_sampleable_atlas", "Pixel probe never claims an unsupported readback succeeded")
	probe.run(main, {"step": "close", "slot": 1})
	check(player.pip.windows.keys() == [2, 3], "Device close probe preserves fixed slot numbers")
	result = probe.run(main, {"step": "format", "projection": 2, "layout": 4, "fov": 190, "swap": true, "eye": 2})
	check(result.ok and player.geometry == 2 and player.stereo_layout() == 4 and player.swap_eyes and player.viewing_eye == 2, "Device format probe uses the production projection, layout and eye controls")
	main.video = null; main.queue_free(); player.queue_free(); await process_frame
	var xr_origin := XROrigin3D.new(); root.add_child(xr_origin)
	var actual := MainVideo.new(); root.add_child(actual); actual.set_process(false); actual.test_origin = xr_origin
	var actual_host := Host.new(); var actual_layer := MainLayer.new(actual_host)
	actual.platform = actual_host; actual.video_layer = actual_layer
	actual_layer.bound = true; actual_layer._flip = true; actual_layer._types = {"quad": true, "equirect": true}
	actual_layer.runtime_layers = 16; actual_layer.runtime_image_size = Vector2i(4096, 4096)
	actual.alpha_requested = true; actual.geometry = 1; actual.stereo_sbs = true; actual._apply_geometry()
	actual.local_uri = "file:///transparent-pip-test.mp4"; actual.media.begin(7); actual.media.frame_counter = 1
	actual.panel.visible = true; actual._binding.material = actual.material
	for i in Renderer.COMMON.size():
		if Renderer.COMMON[i] != "color_uv_scale": actual.material.set_shader_parameter(Renderer.COMMON[i], defaults[i])
	actual.material.set_shader_parameter("video_geometry", 1)
	actual.material.set_shader_parameter("source_size", Vector2(2048, 1024)); actual.material.set_shader_parameter("alpha_enabled", true)
	actual.stereo_horizontal = 0.1; actual._apply_stereo_view()
	actual._binding.color_rid = color.get_rid(); actual._binding.alpha_rid = color.get_rid()
	actual._binding.ticket = {"session_id": 7, "generation": 1, "slot_token": 1, "frame_id": 1}
	actual.pip.set_count(3, head); actual.pip.sync(); actual._update_layer()
	check(actual.video_layer_shown and actual_layer.processed_calls == 1 and actual.pip.windows.values().all(func(window): return window.on_compositor), "Production layer update submits the transparent main before exposing native windows")
	check(actual._hole_material.next_pass == null, "Processed alpha edges do not receive the opaque alignment-border pass")
	actual_layer.accepted = false; actual._update_layer()
	check(not actual.video_layer_shown and actual_layer.overlays == 0 and actual.pip.windows.values().all(func(window): return not window.on_compositor), "Rejected main submission restores every window without submitting transparent overlays alone")
	actual.layer_enabled = false; actual._picture_token = 23; actual._update_layer()
	check(not actual._processed_picture and actual._picture_token == -1 and actual.pip.compositor.main_size == Vector2i.ZERO, "Leaving processed main invalidates old picture tokens before another slot-0 path can reuse them")
	actual.layer_enabled = true; actual.alpha_requested = false; actual.material.set_shader_parameter("alpha_enabled", false)
	actual_layer.accepted = true; actual._update_layer()
	check(actual.video_layer_shown and actual._processed_picture and actual.pip.compositor.main_eyes == 2 \
		and actual.pip.windows.values().all(func(window): return window.on_compositor), "Opaque VR main retains both source eyes on its compositor while mono windows remain native")
	actual_layer.accepted = false; actual._update_layer()
	check(not actual.video_layer_shown and actual_layer.overlays > 0 and actual.pip.windows.values().all(func(window): return window.on_compositor), "Rejected opaque main may fall back independently without taking its native mono windows with it")
	actual_layer.accepted = true; actual.layer_enabled = true; actual.geometry = 2; actual.alpha_requested = false
	actual._binding.ticket.width = 2048; actual._binding.ticket.height = 1024
	check(actual._show_fisheye_picture(xr_origin, []), "Fisheye main uses its existing picture path")
	var remaps := actual_host.count_calls("fisheye")
	actual._show_fisheye_picture(xr_origin, [])
	check(actual_host.count_calls("fisheye") == remaps, "Unchanged paused fisheye main reuses its remap")
	actual.fisheye_fov = 220; actual._show_fisheye_picture(xr_origin, [])
	check(actual_host.count_calls("fisheye") == remaps + 1, "Paused lens FOV change remaps the main even when the source token is unchanged")
	actual.stereo_half = not actual.stereo_half; actual._show_fisheye_picture(xr_origin, [])
	check(actual_host.count_calls("fisheye") == remaps + 2, "Paused Full/Half layout change invalidates the main projection")
	actual_layer.generation += 1; actual._show_fisheye_picture(xr_origin, [])
	check(actual_host.count_calls("fisheye") == remaps + 3, "A new XR generation cannot reuse an old paused fisheye picture")
	actual.stereo_sbs = false; actual._binding.warped = true; actual.geometry = 0
	actual.viewing_eye = 2; actual.swap_eyes = true; actual.stereo_horizontal = 0.5; actual.stereo_vertical = 0.25
	actual._apply_geometry()
	check(actual.material.get_shader_parameter("viewing_eye") == 0 and actual.material.get_shader_parameter("swap_eyes") == false \
		and actual.material.get_shader_parameter("stereo_offset") == Vector2.ZERO, "Generated depth eyes do not inherit previous native-stereo viewing or swap controls")
	var depth_values: PackedFloat32Array = actual_layer.layer_values(actual, xr_origin, Layer.PICTURE, Vector2(4096, 1024), 1)
	check(depth_values[9] == 0 and depth_values[Layer.STRIDE + 9] == 2048 and depth_values[11] == 2048, "Generated main layer retains independent, unshifted eyes after native single-eye viewing")
	actual._layer_session = true; actual._binding.warped = false
	actual.captures.recording = {"id": 77}; actual.pip.compositor.surface_background = false
	check(actual._layer_presentation(), "A background transition cannot reopen the decoder owned by an active recording")
	actual.captures.recording.clear()
	check(not actual._layer_presentation(), "After recording ends an incompatible background may reopen for sampled edges")
	actual._layer_session = false
	actual._binding.color_rid = RID(); actual._binding.alpha_rid = RID(); actual._binding.ticket.clear(); actual.media.close(); actual.queue_free(); xr_origin.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP compositor: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
