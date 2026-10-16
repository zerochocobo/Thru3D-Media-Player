extends SceneTree
## Exercise selection through the attached browser and the real compositor together.
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Harness := preload("res://tests/test_compact_library.gd").Harness
const Video := preload("res://tests/test_compact_library.gd").LocationVideo
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frames() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func settle(capture: Node) -> void:
	capture.update(); await frames(); capture.update(); await frames()

func ray(menu: Node3D, target: int) -> Array:
	for item in menu._buttons:
		if item.target == target:
			return [item.node.global_position + item.node.global_basis.z * 0.3, -item.node.global_basis.z]
	return []

func coverage(capture: Node, point: Vector3) -> float:
	var result := 0.0
	for slot in capture.slots:
		if not slot.used or slot.empty: continue
		var local: Vector3 = slot.layer.to_local(point)
		var uv := Vector2(local.x / slot.layer.quad_size.x + 0.5, 0.5 - local.y / slot.layer.quad_size.y)
		if absf(local.z) > 0.04 or uv.x <= 0 or uv.y <= 0 or uv.x >= 1 or uv.y >= 1: continue
		var image: Image = slot.raw.get_texture().get_image()
		result = maxf(result, image.get_pixelv(Vector2i(uv * Vector2(image.get_size()))).a)
	return result

func run() -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(800, 600); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var main := Harness.new(); viewport.add_child(main)
	var camera := Camera3D.new(); main.add_child(camera); camera.position = Vector3(0, 1.6, 0)
	var video := Video.new(); main.add_child(video); video.set_process(false); video.view_camera = camera; main.video = video
	video.history_enabled = false; video.local_uri = "file:///recovery/first.mp4"; video.media.state = "playing"
	var photo := preload("res://scripts/photo_display.gd").new(); main.add_child(photo); photo.set_process(false); main.photo = photo
	var player := Player.new(); main.add_child(player); player.set_process(false); player.state_provider = main._menu_state
	main.player_menu = player; main.video_menu = player
	var library := Library.new(); main.add_child(library); library.set_process(false); main.recent_menu = library
	library.current_file_provider = func(): return video.local_uri
	library.chosen.connect(main._on_library_chosen); player.recent_requested.connect(main._show_recent_menu)
	player.expanded_library = library
	library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/recovery", "title": "Recovery"}]
	library._local_entries = [{"uri": video.local_uri, "title": "First.mp4"}, {"uri": "file:///recovery/second.mp4", "title": "Second.mp4"}]
	library.refresh(); library.remember_playback_context(); main._show_player_menu()
	var display := preload("res://scripts/xr_display.gd").new()
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(main, camera, display, [library, player], false, true); capture.set_process(false)
	for expanded in [false, true]:
		for hand in ["left_hand", "right_hand"]:
			main._show_recent_menu()
			if expanded: main._toggle_library_layout()
			await settle(capture)
			var target := Library.ROW_BASE + (1 if video.local_uri.ends_with("first.mp4") else 0)
			var pick := ray(library, target)
			check(not pick.is_empty(), "Playback browser contains the other video")
			if pick.is_empty(): library.dismiss(); continue
			var old_point: Vector3 = library._backdrop.global_position
			check(coverage(capture, old_point) > 0.9, "Visible browser has captured pixels")
			main.rays[hand] = pick
			main._on_controller_button("trigger_click", hand); main._on_controller_release("trigger_click", hand)
			check(video.opens > 0 and not library.visible and player.visible and not player.has_pointer_capture(), "Selecting a video folds the browser and releases input")
			await settle(capture)
			check(not capture.originals.any(func(item): return is_instance_valid(item.node) and library.is_ancestor_of(item.node)), "Closed library geometry leaves the transport capture entirely")
			check(coverage(capture, old_point) < 0.01, "Selected browser leaves no stale compositor pixels")
			player.dismiss(); main._show_player_menu(); await settle(capture)
			check(not library.visible and coverage(capture, old_point) < 0.01, "Reopening controls cannot resurrect the closed browser")
			main._show_recent_menu(); await settle(capture)
			var close := ray(library, Library.CLOSE if library.compact else Library.EXPAND_LIBRARY)
			check(not close.is_empty() and player.ray_hit(close[0], close[1]).get("library", false), "Reopened browser routes rays through transport")
			library.dismiss()
	capture.queue_free(); main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Playback recovery render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
