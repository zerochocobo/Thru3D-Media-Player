extends SceneTree

const Overlay := preload("res://scripts/playback_status_overlay.gd")
const Fps := preload("res://scripts/fps_overlay.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Loading := preload("res://scripts/media_loading.gd")
const I18n := preload("res://scripts/i18n.gd")
var sample := {}
var state := {}
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("THRU3D_TEST_OUTPUT")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var fps := Fps.new(); camera.add_child(fps); fps.set_process(false)
	var status := Overlay.new(); status.source = func(): return sample
	camera.add_child(status); status.set_process(false)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.set_process(false)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		var caption := Loading.caption({"remote": true, "phase": "buffering", "elapsed_ms": 12000, "bytes_per_second": 2300000})
		state = {"has_video": true, "title": "Movie.mkv", "loading_caption": caption}
		for placement in ["overlay", "fps_and_overlay", "controls"]:
			fps.set_shown(placement == "fps_and_overlay")
			fps.text = "Video 59.9 · XR 72 FPS L"
			menu.visible = placement == "controls"
			if menu.visible: menu.refresh()
			sample = {"caption": "" if menu.visible else caption, "fps_visible": fps.visible}
			status.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if status.visible and status.get_aabb().size.x > 0.44: failures.append("Status too wide: " + language)
			if fps.visible and status.position.y + status.get_aabb().size.y / 2 > fps.position.y - fps.get_aabb().size.y / 2:
				failures.append("Status overlaps FPS: " + language)
			if menu.visible and (status.visible or not menu._status.visible): failures.append("Duplicate or missing feedback")
			if viewport.get_texture().get_image().save_png(output.path_join(language + "-" + placement + ".png")) != OK: failures.append("Preview save failed")
	for failure in failures: push_error(failure)
	viewport.queue_free(); await process_frame
	print("Playback status preview cases=12 failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)
