extends SceneTree
## Production PlayerMenu controls near the cinema viewer. No decoder or XR claim.
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
	var head: Variant = Transform3D(Basis.IDENTITY, Vector3(-0.45, 5.25, 19.9))
	func _ready() -> void: pass
	func _head_pose() -> Variant: return head
	func _move_pose(_hand: String) -> Variant: return head

class VideoFixture extends Node3D:
	var geometry := 0

class EnvironmentFixture extends Node3D:
	var active := true
	var screen: Dictionary
	func snapshot() -> Dictionary: return {"screen": screen}
	var light_mode := "auto"
	func set_lighting(mode: String, _playing: bool) -> void: light_mode = mode

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
	menu.set_meta("space_locked", true)
	menu.set_meta("space_pose", ordinary_pose)
	menu.set_meta("space_head", main.head)
	var ordinary_shader: Shader = menu._backdrop.material_override.shader
	var tracked_head: Transform3D = main.head
	main.head = null
	main._sync_cinema_transport()
	main._sync_cinema_transport()
	check(main._cinema_transport_saved.is_empty() and menu.global_transform == ordinary_pose,
		"Saved cinema waits for tracking without committing a partial menu entry")
	check(menu.get_meta("space_head") == tracked_head, "Missing head cannot overwrite the spatial lock with nil")
	main.head = tracked_head
	main._sync_cinema_transport()
	var fixed := menu.global_transform
	check(absf(fixed.origin.distance_to(main.head.origin) - 1.4) < .2, "Transport opens near the current viewer")
	check(fixed.basis.get_scale().is_equal_approx(Vector3.ONE), "Transport uses normal scale instead of 16x")
	check(menu.ray_max_distance == 5 and menu.cinema_world_anchor and menu.scene_overlay, "Cinema uses near-field rays and overlay")
	main.head = null
	main._sync_cinema_transport(true)
	check(menu.global_transform == fixed and menu.get_meta("space_head") == tracked_head,
		"Tracking loss during recenter preserves the last valid menu and lock")
	main.head = tracked_head
	check(composition.calls.is_empty() and composition.is_processing(), "Cinema keeps high-density native menu composition active")
	check("depth_test_disabled" in menu._backdrop.material_override.shader.code and menu._title.no_depth_test, "Menu avoids occlusion by chair geometry")
	for seat_id in ["A12", "I12", "N12"]:
		var eye := Vector3.ZERO
		for seat: Dictionary in Blueprint.manifest().seats:
			if seat.id == seat_id: eye = Vector3(seat.eye_position[0], seat.eye_position[1], seat.eye_position[2])
		main.head = Transform3D(Basis(Vector3.UP, 0.4), eye)
		main._place_menu(menu, true)
		check(absf(menu.global_position.distance_to(main.head.origin) - 1.4) < .2, "Menu recentres near viewer: " + seat_id)
		for target in [102, Menu.SEEK, 109, 11]:
			var hit: Dictionary = menu.ray_hit(eye, aim(menu, target, eye))
			check(hit.get("target", -1) == target and float(hit.get("distance", 0)) < 2,
				"A near ray reaches %s control %d" % [seat_id, target])
	main.head = Transform3D(Basis.IDENTITY, Vector3(-0.45, 7.05, 17.65))
	main._place_menu(menu, true)
	fixed = menu.global_transform
	main._begin_interface_move("right_hand", "grip_click")
	check(main.interface_move.capture.is_empty(), "Grip cannot drag the fixed transport")
	tap(menu, 102, main.head.origin)
	check(actions.back() == "play", "The original play control still dispatches its production action")
	# The light switch lives in the footer beside free movement: auto -> on -> off.
	main.settings.set_value("appearance", "cinema_lights", "auto")
	main._on_session_control("cinema_lights_cycle")
	check(main.settings.get_value("appearance", "cinema_lights") == "on", "Footer light switch cycles auto to manual on")
	main._on_session_control("cinema_lights_cycle"); main._on_session_control("cinema_lights_cycle")
	check(main.settings.get_value("appearance", "cinema_lights") == "auto", "Three presses return to auto")
	var seek_start := menu.to_global(Vector3(-0.3, -0.08, 0.005))
	var seek_end := menu.to_global(Vector3(0.205, -0.08, 0.005))
	menu.press_pointer("desktop", main.head.origin, (seek_start - main.head.origin).normalized(), true)
	menu.update_pointer("desktop", main.head.origin, (seek_end - main.head.origin).normalized(), true)
	menu.release_pointer("desktop", main.head.origin, (seek_end - main.head.origin).normalized(), true)
	check(not seeks.is_empty() and absi(int(seeks.back()) - 450000) < 1000, "Timeline drag preserves original logical coordinates under the world scale")
	menu._hover.desktop = 108
	menu._update_highlights()
	check(menu._tooltip.visible and menu.SurfaceLayout.bounds([menu._tooltip], menu).has_area(),
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
	var volume_x := menu.to_local(volume_surface.to_global(Vector3(menu.VOLUME_X, 0, 0))).x
	check(absf(volume_x - menu.VOLUME_X) < .02, "Volume slider stays above its own button, not centred: %s" % volume_x)
	check(volume_surface.global_transform.is_equal_approx(menu.global_transform), "Volume slider sits exactly where it does outside the cinema")
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
	var depth_x := menu.to_local(depth_surface.to_global(Vector3(menu.DEPTH_X, 0, 0))).x
	check(absf(depth_x - menu.DEPTH_X) < .02, "3D strength slider stays above its own button, not centred: %s" % depth_x)
	check(depth_surface.global_transform.is_equal_approx(menu.global_transform), "3D strength slider sits exactly where it does outside the cinema")
	var depth_from := depth_surface.to_global(Vector3(menu.DEPTH_X, menu.DEPTH_SPAN.x + 0.02, 0.025))
	var depth_to := depth_surface.to_global(Vector3(menu.DEPTH_X, menu.DEPTH_SPAN.y, 0.025))
	menu.press_pointer("desktop", main.head.origin, (depth_from - main.head.origin).normalized(), true)
	menu.update_pointer("desktop", main.head.origin, (depth_to - main.head.origin).normalized(), true)
	menu.release_pointer("desktop", main.head.origin, (depth_to - main.head.origin).normalized(), true)
	check(not depths.is_empty() and is_equal_approx(float(depths.back()), menu.DepthStrength.MAX), "Relocated depth slider retains its full logical range")
	menu.dismiss()
	main._sync_cinema_transport()
	check(composition.calls.is_empty() and composition.is_processing(), "Hiding transport leaves compositor enabled")
	environment.active = false
	main._sync_cinema_transport()
	check(not menu.cinema_world_anchor and not menu.scene_overlay and menu.ray_max_distance == 5,
		"Leaving cinema restores ordinary menu mode, occlusion and ray range")
	check(menu.global_transform.is_equal_approx(ordinary_pose), "Leaving cinema restores the ordinary menu transform and scale")
	check(menu.space_locked() and menu.get_meta("space_pose").is_equal_approx(ordinary_pose), "Leaving cinema restores the ordinary spatial lock")
	check(menu._backdrop.material_override.shader == ordinary_shader and not menu._title.no_depth_test,
		"Leaving cinema restores the original shader and label depth policy")
	main.free()
	for failure in failures: push_error(failure)
	print("CINEMA_WORLD_TRANSPORT checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
