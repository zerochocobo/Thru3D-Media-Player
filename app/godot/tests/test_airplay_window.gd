extends SceneTree
const Session := preload("res://scripts/airplay_window.gd")
const Main := preload("res://scripts/main.gd")
const CastPanel := preload("res://scripts/cast_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
class Host extends Node:
	var menu_composition: Object
	var _grab := {}
	var interface_move := {"capture": {}}
	var head := Transform3D.IDENTITY
	var poses := {}
	var menu: Node3D
	var rays := {}
	func _input_focused() -> bool: return true
	func _pip_move_pose(hand: String) -> Variant: return poses.get(hand)
	func _head_pose() -> Transform3D: return head
	func _active_menu() -> Node3D: return menu
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _pip_hand_pointer(_hand: String) -> bool: return false
class MenuFixture extends Node3D:
	var hit_distance := 2.0
	func panel_centre() -> Vector3: return Vector3(0, -0.1, 0)
	func has_pointer_capture() -> bool: return false
	func ray_hit(_origin: Vector3, _direction: Vector3) -> Dictionary: return {"distance": hit_distance}
class LayerFixture extends RefCounted:
	var destroys := 0
	var hidden := false
	var id := 6
	var source_pixels := Vector2i(886, 1920)
	var sort_order := 0
	var presentations := 0
	var resize_allowed := true
	var present_allowed := true
	func hide() -> void: hidden = true
	func destroy() -> bool: destroys += 1; return true
	func resize_decoder_producer(_size: Vector2i) -> bool: return resize_allowed
	func present(_pose: Transform3D, _size: Vector2, _crop: Rect2) -> bool:
		presentations += 1; hidden = not present_allowed; return present_allowed
class TestSession extends Session:
	var created: Array = []
	func _make_layer(slot: int, size: Vector2i) -> RefCounted:
		var candidate := LayerFixture.new(); candidate.id = slot; candidate.source_pixels = size
		created.append(candidate)
		return candidate
class RoutingMain extends Main:
	var test_menu: Node3D
	var menu_presses := 0
	func _controller_allowed(_hand: String) -> bool: return true
	func _vr_passthrough_active() -> bool: return false
	func _active_menu() -> Node3D: return test_menu
	func _disc_menu_bar_press(_hand: String) -> bool: return false
	func _disc_menu_press(_hand: String) -> bool: return false
	func _try_screen_rotation(_hand: String) -> bool: return false
	func _ray(_hand: String) -> Variant: return [Vector3.ZERO, Vector3.FORWARD]
	func _on_video_trigger(_hand: String) -> void: menu_presses += 1
class Bridge extends RefCounted:
	var ready := true
	var disconnects := 0
	var bindings: Array = []
	func airplay_receiver_poll() -> String: return "{}"
	func airplay_receiver_attach_layer(epoch: int, slot: int, width: int, height: int) -> bool:
		bindings.append([epoch, slot, width, height]); return ready
	func airplay_receiver_suspend(_epoch: int) -> bool: return ready
	func airplay_receiver_detach_layer(_epoch: int) -> bool: return ready
	func airplay_receiver_disconnect(_epoch: int) -> void: disconnects += 1
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func ray_to(window: Node3D, point: Vector2) -> Array:
	return [window.to_global(Vector3(point.x, point.y, 0.8)), -window.global_basis.z]
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var previous_language: String = I18n.language
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.language = language
		var off: PackedStringArray = CastPanel.receiver_tooltip({"enabled": false}).split("\n")
		check(off[0] == "DLNA: " + I18n.t("Off") and off[1] == "AirPlay: " + I18n.t("Off"), "Both off states precede instructions in " + language)
		var on: PackedStringArray = CastPanel.receiver_tooltip({"enabled": true, "airplay_state": "ready"}).split("\n")
		check(on[0] == "DLNA: " + I18n.t("On") and on[1] == "AirPlay: " + I18n.t("On"), "Both on states precede instructions in " + language)
		var combined: PackedStringArray = CastPanel.receiver_tooltip({"enabled": true, "airplay_state": "ready", "miracast_supported": true, "miracast_state": "ready"}).split("\n")
		check(combined == on, "Archived Miracast ready data cannot expose a receiver row in " + language)
		var unavailable: PackedStringArray = CastPanel.receiver_tooltip({"enabled": true, "airplay_state": "ready", "miracast_supported": true, "miracast_state": "unavailable"}).split("\n")
		check(unavailable == on, "Archived Miracast unavailable data stays hidden in " + language)
		var failed: PackedStringArray = CastPanel.receiver_tooltip({"enabled": true, "airplay_state": "failed", "airplay_error": "AirPlay receiver unavailable"}).split("\n")
		check(failed[1] == "AirPlay: " + I18n.t("Off") and failed[-1] == I18n.t("AirPlay receiver unavailable"), "Receiver failure remains truthful below grouped status lines in " + language)
	I18n.language = previous_language
	var host := Host.new(); root.add_child(host)
	var session := TestSession.new(); root.add_child(session); session.bind(host, null)
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	host.head = head
	session.pip._open(1, head)
	var window: Node3D = session.pip.windows[1]
	var menu := MenuFixture.new(); root.add_child(menu); host.menu = menu
	menu.position = Vector3(0, 1.6, -1.2)
	session._place_new_window(window)
	check(window.global_position.distance_to(head.origin) < head.origin.distance_to(menu.to_global(menu.panel_centre())), "Only a new AirPlay window starts closer than the current menu")
	check(window.global_position.distance_to(head.origin) <= 0.851 and session._layer_order(window) == -2, "Near AirPlay uses the matching compositor order in front of menus")
	menu.position = Vector3(0, 1.6, -0.65)
	session._place_new_window(window)
	check(window.global_position.distance_to(head.origin) < 0.65, "A user-moved near menu is respected by AirPlay's initial distance")
	menu.position = Vector3(0, 1.6, -1.2)
	session._place_new_window(window)
	var menu_ray := ray_to(window, Vector2.ZERO)
	check(not session._menu_blocks(menu, menu_ray), "A nearer AirPlay body remains interactive over a distant menu")
	menu.hit_distance = 0.1
	check(session._menu_blocks(menu, menu_ray), "A physically nearer menu keeps its input priority")
	menu.hit_distance = 2.0; host.rays["right_hand"] = menu_ray
	var route := RoutingMain.new(); route.test_menu = menu; route.airplay_session = session
	route._on_controller_button("trigger_click", "right_hand")
	check(route.menu_presses == 0 and route._controller_consumed.get("right_hand/trigger_click", false), "Controller trigger routes the nearer AirPlay body before a menu hit")
	route.controller_bindings.release("right_hand", "trigger_click")
	menu.hit_distance = 0.1
	route._on_controller_button("trigger_click", "right_hand")
	check(route.menu_presses == 1, "Controller trigger still reaches a physically nearer menu")
	route.airplay_session = null; route.free()
	host.menu = null
	window.live_source = true
	var image := Image.create(320, 180, false, Image.FORMAT_RGBA8); image.fill(Color.DARK_CYAN)
	window.show_image(ImageTexture.create_from_image(image)); window.controls = true; window.refresh()
	var targets: Array = window._buttons.map(func(button): return button.target)
	check(targets == [1, 9, 10], "Live source exposes close, sound and the normal-player entry")
	check(window._tips[1] == I18n.t("Close window"), "A single AirPlay window does not append a slot number")
	window.set_compositor(true)
	check(window.on_compositor and window.frame.material_override == window.hole, "Live image source can expose its independent native compositor layer")
	window.set_compositor(false)
	check(not window.on_compositor and window.frame.material_override == window.image_material, "Live source retains the OES fallback")
	var original: Transform3D = window.global_transform
	session.position = Vector3(2, 1, 3)
	check(window.global_transform.is_equal_approx(original), "Window stays fixed when its owner moves")
	session.pip.sync()
	check(window.frame.visible, "Mirror remains visible without any main movie frame")
	var ray := ray_to(window, Vector2.ZERO)
	var pose := Transform3D(Basis.looking_at(ray[1]), ray[0])
	check(session.pip.press("right_hand", "grip_click", ray, pose, head), "Controller grip captures live window")
	host.poses["right_hand"] = pose
	var main := Main.new(); main.airplay_session = session
	main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.05)
	check(window.global_transform.is_equal_approx(original), "Preheld stick must return to centre before changing AirPlay distance")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.05)
	var distance: float = window.global_position.distance_to(head.origin)
	main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.05)
	check(not is_equal_approx(distance, window.global_position.distance_to(head.origin)), "The actual main stick route adjusts held AirPlay window distance")
	var own_hand: Transform3D = window.global_transform
	main._process_sticks(Vector2(0, 1), Vector2.ZERO, 0.05)
	check(window.global_transform.is_equal_approx(own_hand), "The other hand's stick cannot adjust the captured AirPlay window")
	pose.origin.x += 0.15
	session.pip.update_input({"right_hand": ray}, {"right_hand": pose}, head, 1000)
	check(not window.global_transform.is_equal_approx(original), "Existing movement moves the independent live source")
	check(session.pip.release("right_hand", "grip_click"), "Grip release ends live movement")
	var fixed: Transform3D = window.global_transform
	session.pip.update_input({}, {}, Transform3D(Basis(Vector3.UP, 0.9), Vector3(1,2,3)), 1200)
	check(window.global_transform.is_equal_approx(fixed), "Released mirror does not follow head motion")
	var corner: Vector2 = window.corner_point(3)
	ray = ray_to(window, corner)
	var size: Vector2 = window.size
	check(session.pip.press("right_hand", "trigger_click", ray, null, head), "Corner ray captures live resizing")
	session.pip.update_input({"right_hand": ray_to(window, corner * 1.5)}, {}, head, 1300)
	check(window.size.x > size.x and is_equal_approx(window.size.x/window.size.y, size.x/size.y), "Physical resize keeps phone aspect")
	check(session.pip.release("right_hand", "trigger_click"), "Resize releases independently")
	window._activate(6)
	check(window.live_source and window.image_mode, "Hidden movie mode cannot replace the AirPlay input")
	var placed: Transform3D = window.global_transform
	var longest: float = maxf(window.size.x, window.size.y)
	for dimensions in [Vector2i(1920, 886), Vector2i(886, 1920), Vector2i(1920, 886)]:
		Session.fit_source(window, dimensions.x, dimensions.y)
		check(is_equal_approx(window.size.x / window.size.y, float(dimensions.x) / dimensions.y), "Phone orientation updates the complete live picture aspect")
		check(window.global_transform.is_equal_approx(placed) and is_equal_approx(maxf(window.size.x, window.size.y), longest), "Phone rotation preserves the placed window centre, distance and longest edge")
	var bridge := Bridge.new(); session.platform = bridge; session.epoch = 7
	var display := LayerFixture.new(); display.source_pixels = Vector2i(1334, 1920); session.layer = display
	var live := {"target_width": 1334, "target_height": 1920, "width": 1334, "height": 1920,
		"video_ready": true, "layer_slot": 6, "frames": 0, "submitted_frames": 0}
	session._present_window(window, live)
	check(display.presentations == 0 and not window.frame.visible, "A configured decoder without an output buffer does not expose an empty Surface")
	live.submitted_frames = 1
	session._present_window(window, live)
	check(display.presentations == 1 and window.frame.visible and not display.hidden, "The first submitted iPad frame starts the XR layer before any rendered callback")
	for i in range(30):
		live.submitted_frames += 1
		session._present_window(window, live)
	check(display.presentations == 31 and window.frame.visible and live.frames == 0, "Absent rendered timing callbacks cannot keep decoded AirPlay video hidden")
	live.submitted_frames = 0; live.frames = 500
	session._present_window(window, live)
	check(not window.frame.visible and display.presentations == 31, "An old callback count cannot reveal a replacement decoder before it submits a frame")
	live.submitted_frames = 1; live.frames = 0; live.width = 1328
	session._present_window(window, live)
	check(not window.frame.visible and display.presentations == 31, "The first-output fix retains the exact output extent guard")
	live.width = 1334; live.error = "AirPlay decoder unavailable"
	session._present_window(window, live)
	check(not window.frame.visible and display.presentations == 31, "Decoder errors still hide the AirPlay layer despite queued output")
	live.error = ""; live.layer_slot = 7
	session._present_window(window, live)
	check(not window.frame.visible and display.presentations == 31, "A different producer slot cannot expose a stale Surface")
	live.layer_slot = 6; display.resize_allowed = false
	session._present_window(window, live)
	check(not window.frame.visible and display.presentations == 31, "Producer resize failure remains hidden and is distinct from waiting for output")
	display.resize_allowed = true; display.present_allowed = false
	session._present_window(window, live)
	check(not window.frame.visible and display.hidden, "A failed layer submission hides its cutout")
	display.present_allowed = true
	session._present_window(window, live)
	check(window.frame.visible and not display.hidden, "Layer submission can recover without a reconnect or rendered callback")
	session.layer = null
	session._present_window(window, live)
	check(not window.frame.visible, "OES fallback still waits for updateTexImage rather than queued Surface output")
	live.frames = 1
	session._present_window(window, live)
	check(window.frame.visible, "OES fallback becomes visible only when its own texture has a frame")
	var portrait := LayerFixture.new(); session.layer = portrait
	var landscape := {"target_width": 1920, "target_height": 886, "video_ready": true, "layer_slot": 6}
	check(not session._sync_layer(landscape) and portrait.hidden and portrait.destroys == 0, "Rotation hides the old extent but retains its producer until acknowledged")
	var replacement: RefCounted = session.pending_layer
	check(replacement.id == 7 and bridge.bindings[-1] == [7, 7, 1920, 886], "Landscape opens a fresh correctly shaped AirPlay-only Surface")
	session._sync_layer(landscape)
	check(session.created.size() == 1 and portrait.destroys == 0, "Repeated polls cannot replace or destroy an unacknowledged producer")
	landscape.layer_slot = 7
	check(session._sync_layer(landscape) and portrait.destroys == 1 and session.layer == replacement, "New producer acknowledgement permits releasing the old Surface exactly once")
	var rotated := {"target_width": 1920, "target_height": 886, "width": 1920, "height": 886,
		"video_ready": true, "layer_slot": 7, "frames": 0, "submitted_frames": 1}
	session._present_window(window, rotated)
	check(window.frame.visible and replacement.presentations == 1, "A rotated producer starts from its own decoded output without waiting for a callback")
	check(window.global_transform.is_equal_approx(placed), "Producer rotation leaves the existing spatial window untouched")
	var back := {"target_width": 886, "target_height": 1920, "video_ready": true, "layer_slot": 7}
	check(not session._sync_layer(back) and session.pending_layer.id == 6, "Back rotation reuses the other dedicated slot without touching browser or movie PiP")
	var pending: RefCounted = session.pending_layer
	bridge.ready = false
	session._suspend_display()
	check(replacement.destroys == 0 and pending.destroys == 0, "Sleep during rotation retains both producers until decoder stop acknowledgement")
	bridge.ready = true; session._park_display()
	check(replacement.destroys == 1 and pending.destroys == 1 and session.pending_layer == null, "Acknowledged sleep releases both rotation producers")
	var sleeping_layer := LayerFixture.new(); session.layer = sleeping_layer; session._display_attached = true
	session._suspend_display()
	check(bridge.disconnects == 0 and session.epoch == 7 and session.pip.windows.has(1), "Headset sleep preserves the sender session and live window")
	check(sleeping_layer.hidden and sleeping_layer.destroys == 1 and not window.frame.visible, "Headset sleep acknowledges the stopped producer and releases its XR layer")
	session._resume_display()
	check(session._presenting and window.global_transform.is_equal_approx(placed), "Headset wake resumes the same spatial placement")
	var waiting_layer := LayerFixture.new(); session.layer = waiting_layer; bridge.ready = false
	check(not session._clear() and waiting_layer.destroys == 0 and session.epoch == 7, "A delayed producer stop cannot destroy a live swapchain")
	bridge.ready = true
	check(session._clear() and waiting_layer.destroys == 1 and session.epoch == 0, "The swapchain is destroyed once after the producer stop acknowledgement")
	main.airplay_session = null; main.free()
	session.close(); session.free(); host.free(); menu.free(); await process_frame
	for message in failures: push_error(message)
	print("AirPlay window: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
