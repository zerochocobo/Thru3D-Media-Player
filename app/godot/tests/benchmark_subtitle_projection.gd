extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const BASELINE := "res://tests/fixtures/subtitle_longitude_baseline.gdshaderinc"
const WARMUP := 40
const FRAMES := 90
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func percentile(values: Array[float], fraction: float) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(round((sorted.size() - 1) * fraction)), 0, sorted.size() - 1)] if not sorted.is_empty() else 0.0

static func legacy_shader(source: String, overlay: bool) -> Shader:
	source = source.replace('#include "res://shaders/projected_subtitles.gdshaderinc"', FileAccess.get_file_as_string(BASELINE))
	var lines := PackedStringArray()
	for line in source.split("\n"):
		if not line.contains("subtitle_patch_position =") and not line.contains("subtitle_patch_eye ="): lines.append(line)
	source = "\n".join(lines).replace("projected_caption()", "projected_caption(media_direction, eye_index)")
	if overlay: source = source.replace("void vertex()", "varying vec3 media_direction; varying flat int eye_index;\nvoid vertex()")
	source = source.replace("void vertex() {", "void vertex() { media_direction = VERTEX; eye_index = int((INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).x > 0.0);")
	if not overlay: source = source.replace("eye_index = int(VIEW_INDEX);", "")
	var shader := Shader.new()
	shader.code = source
	return shader

func block(viewports: Array[SubViewport], label: String) -> Dictionary:
	for _frame in WARMUP: await RenderingServer.frame_post_draw
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var elapsed: Array[float] = []
	var previous := Time.get_ticks_usec()
	for _frame in FRAMES:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		elapsed.append(float(now - previous) / 1000)
		previous = now
		var gpu_ms := 0.0
		var cpu_ms := 0.0
		for viewport in viewports:
			gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
			cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
		gpu.append(gpu_ms)
		cpu.append(cpu_ms)
	var calls := 0
	for viewport in viewports:
		calls += RenderingServer.viewport_get_render_info(viewport.get_viewport_rid(), RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	return {"mode": label, "samples": FRAMES, "gpu_ms_median": percentile(gpu, 0.5), "gpu_ms_p95": percentile(gpu, 0.95),
		"render_cpu_ms_median": percentile(cpu, 0.5), "wall_frame_ms_median": percentile(elapsed, 0.5), "draw_calls": calls}

func _run() -> void:
	var output := OS.get_environment("SUBTITLE_BENCHMARK_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var world := World3D.new()
	var viewports: Array[SubViewport] = []
	for index in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(2048, 2048)
		viewport.world_3d = world
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
		var eye := Camera3D.new()
		eye.position = Vector3((index - 0.5) * 0.063, 1.6, 0)
		eye.fov = 90
		viewport.add_child(eye)
		eye.make_current()
		viewports.append(viewport)
	var head := Camera3D.new()
	head.position = Vector3(0, 1.6, 0)
	viewports[0].add_child(head)
	var video := Video.new()
	viewports[0].add_child(video)
	video.set_process(false)
	video.view_camera = head
	video.caption.text = "今天的风景很美。\nBeautiful scenery today."
	video.caption.visible = true
	video.subtitle_distance = 0.1
	var color := Image.create(4096, 2048, false, Image.FORMAT_RGB8)
	color.fill(Color(0.1, 0.2, 0.35))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8)
	alpha.fill(Color.WHITE)
	var color_texture := ImageTexture.create_from_image(color)
	var alpha_texture := ImageTexture.create_from_image(alpha)
	var physical_video: Shader = load("res://shaders/video_rvm_pair.gdshader")
	var physical_surface: Shader = load("res://shaders/subtitle_surface.gdshader")
	var legacy_video := legacy_shader(physical_video.code, false)
	var legacy_surface := legacy_shader(physical_surface.code, true)
	var samples: Array[Dictionary] = []
	for geometry in [1, 2]:
		video.geometry = geometry
		video._apply_geometry()
		for separate in [false, true]:
			video.set_screen_rotation(90 if separate else 0)
			for mode in ["legacy", "physical", "physical", "legacy", "legacy_off", "physical_off", "physical_off", "legacy_off"]:
				video.material.shader = legacy_video if mode.begins_with("legacy") else physical_video
				video._subtitle_material.shader = legacy_surface if mode.begins_with("legacy") else physical_surface
				video.material.set_shader_parameter("color_texture", color_texture)
				video.material.set_shader_parameter("alpha_texture", alpha_texture)
				video.material.set_shader_parameter("source_size", Vector2(4096, 2048))
				video.material.set_shader_parameter("model_size", Vector2(2, 2))
				video.material.set_shader_parameter("alpha_enabled", false)
				video.material.set_shader_parameter("sharpness", 0)
				video.panel.visible = true
				video._place_caption()
				video._sync_subtitle_surface()
				if mode.begins_with("legacy"):
					for material in [video.material, video._subtitle_material]:
						material.set_shader_parameter("subtitle_anchor_inverse", Basis.IDENTITY)
						material.set_shader_parameter("subtitle_parallax", 2 * atan(0.063 / (2 * video.subtitle_distance)))
				if mode.ends_with("_off"):
					video.projected_subtitles.clear(video.material)
					video._sync_subtitle_surface()
				var result := await block(viewports, mode)
				result.merge({"geometry": geometry, "separate": separate})
				var expected_calls := 2 if mode.ends_with("_off") or not separate else 4
				if result.draw_calls != expected_calls: failures.append("Projection changes the expected draw-call count")
				result["caption_server_update_mode"] = RenderingServer.viewport_get_update_mode(video.projected_subtitles.viewport.get_viewport_rid())
				if result.caption_server_update_mode != RenderingServer.VIEWPORT_UPDATE_DISABLED:
					failures.append("Unchanged caption canvas redraws during benchmark")
				samples.append(result)
				print(JSON.stringify(result))
	# Bound the extra per-frame CPU geometry work separately from render-server timings.
	var geometry_us: Array[float] = []
	for _sample in 1000:
		var start := Time.get_ticks_usec()
		Video.ProjectedSubtitles.projection_plane(video.subtitle_transform(), Basis.IDENTITY, video.subtitle_distance, head.global_position).affine_inverse()
		geometry_us.append(float(Time.get_ticks_usec() - start))
	var gpu_available := samples.all(func(sample): return sample.gpu_ms_median > 0)
	if not gpu_available: failures.append("GPU timer queries are unavailable; these timings cannot establish GPU performance")
	var report := {"state": "passed" if failures.is_empty() else "failed", "samples": samples, "failures": failures,
		"gpu": RenderingServer.get_video_adapter_name(), "godot": Engine.get_version_info().string,
		"eye_resolution": [2048, 2048], "source_resolution": [4096, 2048], "baseline": "fb48dfe shared longitude shader, preserved as a test fixture",
		"subtitle_distance_m": video.subtitle_distance,
		"baseline_sha256": FileAccess.get_sha256(BASELINE), "physical_shader_sha256": FileAccess.get_sha256("res://shaders/projected_subtitles.gdshaderinc"),
		"geometry_cpu_us_median": percentile(geometry_us, 0.5), "geometry_cpu_us_p95": percentile(geometry_us, 0.95),
		"gpu_timing_available": gpu_available,
		"scope": "Desktop OpenGL dual-view shader benchmark, ABBA order, one cached caption canvas, 0.1m bilingual subtitles. Render CPU excludes script time; geometry calculation measured separately. Constant 4K texture, no decoder/RVM/native XR/thermal performance claim."}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle projection benchmark completed; GPU timing available=", report.gpu_timing_available)
	for viewport in viewports: viewport.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
