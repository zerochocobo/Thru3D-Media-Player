extends "res://tests/render_cinema_player.gd"
## Pixel check of the actual movie surface and local lighting with a fixed reference frame.
## Any shader that fails to compile also fails the run: on a headset it draws flat colour.

class ShaderErrors extends Logger:
	var found := PackedStringArray()
	func _log_message(message: String, error: bool) -> void:
		if error and message.contains("SHADER ERROR"): found.append(message.strip_edges())
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SHADER: found.append("%s:%d %s %s" % [file, line, code, rationale])

var shader_errors := ShaderErrors.new()

func _run() -> void:
	OS.add_logger(shader_errors)
	output = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance","background","dark")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280,720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	main = RenderMain.new()
	main.settings_path = output.path_join("settings.cfg")
	main.display = Logic.SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.report_timer.stop()
	main.video.set_process(false)
	main.photo.set_process(false)
	main.video.history_enabled = false
	main.video.platform = HostTest.Host.new()
	main.video.local_uri = "file:///cottage-display-check.mp4"
	main.video.media.begin(7)
	main.video.media.state = "paused"
	main.video.media.format.width = 640
	main.video.media.format.height = 360
	main.video._waiting_first = false
	main.video._apply_geometry()
	main.video.panel.visible = true
	main.video.material.set_shader_parameter("color_texture",_original_video_texture())
	main.video.material.set_shader_parameter("source_size",Vector2(640,360))
	_close_menus()
	main.scenery.select("global","magic_cottage")
	for frame in 600:
		if main.cottage: break
		if not main._cottage_pending.is_empty(): main._sync_cottage(main._cottage_pending[0],main._cottage_pending[1])
		await process_frame
	for i in 4: await process_frame
	main._tick_cottage(.02)
	main._sync_cinema_screen()
	_look_at_screen()
	var paused := await _shot("paused")
	main.video.media.state = "playing"
	main.video.requested_play = true
	main._tick_cottage(1.)
	var playing := await _shot("playing")
	var lit := 0.
	var dim := 0.
	# Sample the stonework, shelves and windows on both sides of the arch.
	for x in range(32,1248,12):
		if x>450 and x<830: continue
		for y in range(128,630,12):
			lit += paused.get_pixel(x,y).get_luminance()
			dim += playing.get_pixel(x,y).get_luminance()
	check(lit>5. and dim<lit*.73,"Room luminance falls during movie",dim/maxf(.001,lit))
	var center:=Vector2i(640,360)
	var color := paused.get_pixelv(center)
	check(color.get_luminance()>.12 and color.is_equal_approx(playing.get_pixelv(center)),"Video reference pixel holds its brightness",color)
	main._on_playback_adjustment("screen_distance",3.6)
	main._on_playback_adjustment("screen_scale",82.)
	main._turn_picture(-.18,.04)
	main._on_playback_adjustment("screen_rotation",20.)
	main._sync_cinema_screen()
	await _shot("moved")
	main.video.media.state = "paused"
	main._tick_cottage(1.)
	check(is_equal_approx(main.cottage.light_fraction,1.),"Pausing fades the house lights back up")
	check(shader_errors.found.is_empty(),"Every shader compiles",shader_errors.found)
	viewport.queue_free()
	await process_frame
	print("Cottage playback OpenGL: %d checks, %d failures" % [checks.size(),failures.size()])
	quit(0 if failures.is_empty() else 1)
