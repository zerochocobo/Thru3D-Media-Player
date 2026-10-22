extends SceneTree
## Production PlayerMenu controls on the fixed cinema anchor. No decoder or XR claim.
const Menu := preload("res://scripts/player_menu.gd")
const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const Layout := preload("res://scripts/environments/cinema_menu_layout.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var actions: Array = []
var volumes: Array = []
var seeks: Array = []
var depths: Array = []

class MainHarness extends "res://scripts/main.gd":
	var head := Transform3D(Basis.IDENTITY, Vector3(-0.4, 7.05, 17.65))
	func _ready() -> void: pass
	func _head_pose() -> Variant: return head
	func _move_pose(_hand: String) -> Variant: return head

class VideoFixture extends Node3D:
	var geometry := 0

class EnvironmentFixture extends Node3D:
	var active := true
	var screen: Dictionary
	func snapshot() -> Dictionary: return {"screen": screen}

class CompositionFixture extends Node:
	var enabled := true
	var calls: Array = []
	func set_active(value: bool) -> void:
		calls.append(value)
		set_process(value)

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func control(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if int(item.target) == target: return item
	return {}

func aim(menu: Node3D, target: int, eye: Vector3) -> Vector3:
	return (control(menu, target).node.global_position - eye).normalized()

func tap(menu: Node3D, target: int, eye: Vector3) -> void:
	var hit: Dictionary = menu.ray_hit(eye, aim(menu, target, eye))
	check(int(hit.get("target", -1)) == target, "Actual ray reaches control %d" % target)
	menu.press_pointer("desktop", eye, aim(menu, target, eye), true)
	menu.release_pointer("desktop", eye, aim(menu, target, eye), true)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	I18n.use("en")
	var state := {"has_video": true, "playing": true, "playback_state": "playing", "title": "Owned movie.mp4",
		"source_uri": "file:///owned.mp4", "geometry": 0, "duration_ms": 600000, "position_ms": 120000,
		"volume": 50, "audio_available": true, "volume_writable": true, "screen_scene_locked": true,
		"whisper_available": false, "depth_available": true}
	var main := MainHarness.new()
	root.add_child(main)
	main.set_process(false)
	var video := VideoFixture.new()
	main.add_child(video)
	main.video = video
	var environment := EnvironmentFixture.new()
	environment.screen = Blueprint.manifest().screen
	main.add_child(environment)
	main.cinema_environment = environment
	var composition := CompositionFixture.new()
	main.add_child(composition)
	composition.set_process(true)
	main.menu_composition = composition
	var menu := Menu.new()
	menu.state_provider = func(): return state
	menu.layout_head_provider = main._head_pose
	menu.session_controls_provider = func(): return {"follow": false, "passthrough_visible": false}
	menu.action_requested.connect(func(action): actions.append(action))
	menu.volume_requested.connect(func(value, _muted): volumes.append(value); state.volume = value)
	menu.seek_requested.connect(func(value): seeks.append(value))
	menu.depth_strength_requested.connect(func(value): depths.append(value); state.depth_strength = value; state.depth_requested = true)
	main.add_child(menu)
	main.video_menu = menu
	main.player_menu = menu
	menu.toggle()
	menu.set_process(false)
	var ordinary_pose := menu.global_transform
	var ordinary_shader: Shader = menu._backdrop.material_override.shader
	main._sync_cinema_transport()
	var fixed := menu.global_transform
	check(fixed.is_equal_approx(Layout.transport_pose(environment.screen)), "Production main applies the screen-only fixed world pose")
	check(fixed.origin.is_equal_approx(Vector3(0, -3.03, -3.90)) and fixed.basis.get_scale().is_equal_approx(Vector3.ONE * 16),
		"Transport uses the agreed 16x scale, physical gap and front offset")
	check(menu.ray_max_distance == 100 and menu.cinema_world_anchor and menu.scene_overlay, "Only cinema transport opts into long rays and overlay")
	check(composition.calls == [false] and not composition.is_processing(), "Visible cinema overlay pauses depth-tested menu underlays")
	var bounds: Rect2 = menu._bar_bounds()
	check(menu.to_global(Vector3(0, bounds.end.y, 0)).y <= 1.052, "All ordinary transport visuals stay 15cm below the physical screen")
	check("depth_test_disabled" in menu._backdrop.material_override.shader.code and menu._title.no_depth_test,
		"Panel and text use the cinema overlay policy")
	for seat_id in ["A15", "I15", "N15"]:
		var eye := Vector3.ZERO
		for seat: Dictionary in Blueprint.manifest().seats:
			if seat.id == seat_id: eye = Vector3(seat.eye_position[0], seat.eye_position[1], seat.eye_position[2])
		main.head = Transform3D(Basis(Vector3.UP, 0.4), eye)
		main._place_menu(menu, true)
		check(menu.global_transform.is_equal_approx(fixed), "Reposition after seat change preserves world anchor: " + seat_id)
		for target in [102, Menu.SEEK, 109, 11]:
			var hit: Dictionary = menu.ray_hit(eye, aim(menu, target, eye))
			check(hit.get("target", -1) == target and float(hit.get("distance", 0)) > 5.0,
				"A real distant ray reaches %s control %d" % [seat_id, target])
	main.head = Transform3D(Basis.IDENTITY, Vector3(-0.4, 7.05, 17.65))
	main._begin_interface_move("right_hand", "grip_click")
	check(main.interface_move.capture.is_empty(), "Grip cannot drag the fixed transport")
	tap(menu, 102, main.head.origin)
	check(actions.back() == "play", "The original play control still dispatches its production action")
	var seek_start := menu.to_global(Vector3(-0.3, -0.08, 0.005))
	var seek_end := menu.to_global(Vector3(0.205, -0.08, 0.005))
	menu.press_pointer("desktop", main.head.origin, (seek_start - main.head.origin).normalized(), true)
	menu.update_pointer("desktop", main.head.origin, (seek_end - main.head.origin).normalized(), true)
	menu.release_pointer("desktop", main.head.origin, (seek_end - main.head.origin).normalized(), true)
	check(not seeks.is_empty() and absi(int(seeks.back()) - 450000) < 1000, "Timeline drag preserves original logical coordinates under the world scale")
	menu._hover.desktop = 108
	menu._update_highlights()
	check(menu._tooltip.visible and menu.SurfaceLayout.bounds([menu._tooltip], menu).end.y < 0.255,
		"Floating-control tooltips stay below the transport instead of entering the movie")
	menu._hover.clear()
	tap(menu, 11, main.head.origin)
	check(menu._popup_surfaces.size() == 1, "Original settings render in an independent surface")
	var popup: Node3D = menu._popup_surfaces[0]
	var popup_pose := popup.global_transform
	check(popup.global_basis.get_scale().is_equal_approx(Vector3.ONE), "Settings retain their original near-field scale")
	check(popup.global_position.distance_to(main.head.origin) < 2.5, "Settings are legible near the viewer instead of 30m away")
	main.head.origin += Vector3(2, 0, 1)
	menu.refresh()
	check(menu._popup_surfaces[0].global_transform.is_equal_approx(popup_pose), "An open settings window keeps its world pose when the viewer moves")
	check(menu.global_transform.is_equal_approx(fixed), "Settings redraws never move the fixed transport")
	menu._activate(Menu.SETTINGS_CLOSE)
	menu._volume_open = true
	menu.refresh()
	check(menu._popup_surfaces.size() == 1 and control(menu, Menu.VOLUME).node.get_parent() != menu,
		"The original volume quick slider is separated from the transport footprint")
	var volume_surface: Node3D = menu._popup_surfaces[0]
	var volume_from := volume_surface.to_global(Vector3(menu.VOLUME_X, menu.VOLUME_SPAN.x + 0.02, 0.025))
	var volume_to := volume_surface.to_global(Vector3(menu.VOLUME_X, menu.VOLUME_SPAN.y, 0.025))
	menu.press_pointer("desktop", main.head.origin, (volume_from - main.head.origin).normalized(), true)
	menu.update_pointer("desktop", main.head.origin, (volume_to - main.head.origin).normalized(), true)
	menu.release_pointer("desktop", main.head.origin, (volume_to - main.head.origin).normalized(), true)
	check(not volumes.is_empty() and int(volumes.back()) == 100, "The relocated volume slider still drags through the original pointer path")
	menu._volume_open = false
	menu._depth_open = true
	menu.refresh()
	check(menu._popup_surfaces.size() == 1 and control(menu, Menu.DEPTH).node.get_parent() != menu,
		"The original depth quick slider is also independent from the transport")
	var depth_surface: Node3D = menu._popup_surfaces[0]
	var depth_from := depth_surface.to_global(Vector3(menu.DEPTH_X, menu.DEPTH_SPAN.x + 0.02, 0.025))
	var depth_to := depth_surface.to_global(Vector3(menu.DEPTH_X, menu.DEPTH_SPAN.y, 0.025))
	menu.press_pointer("desktop", main.head.origin, (depth_from - main.head.origin).normalized(), true)
	menu.update_pointer("desktop", main.head.origin, (depth_to - main.head.origin).normalized(), true)
	menu.release_pointer("desktop", main.head.origin, (depth_to - main.head.origin).normalized(), true)
	check(not depths.is_empty() and is_equal_approx(float(depths.back()), menu.DepthStrength.MAX), "Relocated depth slider retains its full logical range")
	menu.dismiss()
	main._sync_cinema_transport()
	check(composition.calls == [false, true] and composition.is_processing(), "Hiding transport restores the prior compositor processing state")
	environment.active = false
	main._sync_cinema_transport()
	check(not menu.cinema_world_anchor and not menu.scene_overlay and menu.ray_max_distance == 5,
		"Leaving cinema restores ordinary menu mode, occlusion and ray range")
	check(menu.global_transform.is_equal_approx(ordinary_pose), "Leaving cinema restores the ordinary menu transform and scale")
	check(menu._backdrop.material_override.shader == ordinary_shader and not menu._title.no_depth_test,
		"Leaving cinema restores the original shader and label depth policy")
	main.free()
	for failure in failures: push_error(failure)
	print("CINEMA_WORLD_TRANSPORT checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
